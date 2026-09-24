import Foundation
import Security

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
enum Keychain {
    static func save(_ data: Data, key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.aijiankang.session", kSecAttrAccount as String: key]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw AppError.message("无法安全保存登录信息") }
        } else if status != errSecSuccess { throw AppError.message("无法更新登录信息") }
    }
    static func read(key: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.aijiankang.session", kSecAttrAccount as String: key, kSecReturnData as String: true]
        var result: CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }; return result as? Data
    }
    static func remove(key: String) { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.aijiankang.session", kSecAttrAccount as String: key] as CFDictionary) }
}

enum CloudAccountScope {
    static let previousURL = "https://health.qyos.top"
    static func aliasKey(userID: String) -> String { "riyi.accountScope.\(userID)" }
    static func value(currentURL: String, userID: String, rememberedAlias: String?) -> String {
        let original = previousURL + "/" + userID
        return rememberedAlias == original ? original : currentURL + "/" + userID
    }
}

@MainActor final class Network {
    static var defaultURL: String { Bundle.main.object(forInfoDictionaryKey: "AIHealthDefaultServerURL") as? String ?? "http://localhost:18089" }
    static func permits(_ base: URL) -> Bool {
        guard let host = base.host, base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else { return false }
        if base.scheme == "https" { return true }
        guard base.scheme == "http" else { return false }
        if ["localhost", "127.0.0.1", "::1"].contains(host) { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && UInt8($0) != nil }) else { return false }
        let numbers = parts.map { Int($0)! }
        return numbers[0] == 10 || (numbers[0] == 172 && (16...31).contains(numbers[1])) || (numbers[0] == 192 && numbers[1] == 168)
    }
    var baseURL: URL
    var tokens: Tokens?
    var onSessionExpired: (() -> Void)?
    private var refreshTask: Task<Tokens, Error>?
    init(baseURL: URL) {
        self.baseURL = baseURL
        if let data = Keychain.read(key: baseURL.absoluteString) { tokens = try? Wire.read(data) }
    }
    func authenticate(email: String, password: String, register: Bool, expectedUserID: String? = nil) async throws {
        let body = try Wire.data(["email": email, "password": password, "timezone": TimeZone.current.identifier])
        let data = try await request(register ? "/v1/auth/register" : "/v1/auth/login", method: "POST", body: body, authenticated: false)
        let value: Tokens = try Wire.read(data)
        if let expectedUserID, value.userId != expectedUserID { throw AppError.message("登录的是另一个账号。本机记录仍保留在原账号，请用原账号重新登录。") }
        try Keychain.save(Wire.data(value), key: baseURL.absoluteString); tokens = value
    }
    func request(_ path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = true, retry: Bool = true, timeout: TimeInterval = 85) async throws -> Data {
        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else { throw AppError.message("服务器地址无效") }
        var req = URLRequest(url: url); req.httpMethod = method; req.httpBody = body; req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated { guard let t = tokens else { throw AppError.message("请先登录云端账号") }; req.setValue("Bearer \(t.accessToken)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AppError.message("服务器未返回有效响应") }
        if http.statusCode == 401 && authenticated && retry {
            try await refresh(); return try await request(path, method: method, body: body, authenticated: authenticated, retry: false, timeout: timeout)
        }
        guard (200..<300).contains(http.statusCode) else {
            let error = try? JSONDecoder().decode([String: String].self, from: data)
            if http.statusCode == 401 && ((path == "/v1/auth/refresh" && error?["code"] == "SESSION_EXPIRED") || (authenticated && !retry)) { onSessionExpired?() }
            throw AppError.message(error?["message"] ?? "请求失败（\(http.statusCode)）")
        }; return data
    }
    private func refresh() async throws {
        if let refreshTask { tokens = try await refreshTask.value; return }
        guard let t = tokens else { throw AppError.message("请重新登录") }
        let task = Task<Tokens, Error> {
            let data = try await self.request("/v1/auth/refresh", method: "POST", body: Wire.data(["refresh_token": t.refreshToken]), authenticated: false)
            let value: Tokens = try Wire.read(data); try Keychain.save(Wire.data(value), key: self.baseURL.absoluteString); return value
        }
        refreshTask = task; defer { refreshTask = nil }; tokens = try await task.value
    }
    func forget() { Keychain.remove(key: baseURL.absoluteString); tokens = nil }
}
