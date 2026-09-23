import Foundation
import CryptoKit

/// A separate, bounded cache for public exercise photos; no user authentication or health data.
actor ExerciseMediaCache {
    static let version = "fedb-a859101d633a"
    static let shared = ExerciseMediaCache()
    private let directory: URL
    private let session: URLSession
    private let baseURL: URL
    private let limit: Int
    private var pending: [String: Task<Data, Error>] = [:]
    private var generation = 0

    init(directory: URL? = nil, session: URLSession? = nil, baseURL: URL? = nil, limit: Int = 80 * 1024 * 1024) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ExercisePhotos", isDirectory: true)
        self.limit = limit
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpMaximumConnectionsPerHost = 3
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 45
        self.session = session ?? URLSession(configuration: config)
        var address = "https://health.qyos.top/media/exercises/" + Self.version
        #if DEBUG
        if let testURL = ProcessInfo.processInfo.environment["AIHEALTH_EXERCISE_MEDIA_BASE"], testURL.hasPrefix("http://127.0.0.1:") { address = testURL }
        #endif
        self.baseURL = baseURL ?? URL(string: address)!
    }

    func data(filename: String, thumbnail: Bool) async throws -> Data {
        guard !filename.contains("/"), !filename.contains("\\"), filename.hasSuffix(".jpg"), !filename.hasPrefix(".") else { throw URLError(.badURL) }
        let url = baseURL.appendingPathComponent(thumbnail ? "thumb" : "full").appendingPathComponent(filename)
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(key + ".jpg")
        if let data = try? Data(contentsOf: file), Self.validJPEG(data) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return data
        }
        if let running = pending[key] { return try await running.value }
        let epoch = generation
        let task = Task<Data, Error> { [session] in
            var request = URLRequest(url: url); request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.mimeType == "image/jpeg", Self.validJPEG(data) else { throw URLError(.cannotDecodeContentData) }
            return data
        }
        pending[key] = task
        do {
            let data = try await task.value
            if generation == epoch {
                pending[key] = nil
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
                trim()
            }
            return data
        } catch {
            if generation == epoch { pending[key] = nil }
            throw error
        }
    }
    private static func validJPEG(_ data: Data) -> Bool {
        data.count > 4 && data.count <= 2 * 1024 * 1024 && data.starts(with: [0xff, 0xd8, 0xff])
    }
    private func files() -> [(url: URL, bytes: Int, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []).compactMap { url in
            guard url.pathExtension == "jpg", let info = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, info.fileSize ?? 0, info.contentModificationDate ?? .distantPast)
        }
    }
    func byteCount() -> Int { files().reduce(0) { $0 + $1.bytes } }
    private func trim() {
        let entries = files().sorted { $0.date < $1.date }
        var size = entries.reduce(0) { $0 + $1.bytes }
        for entry in entries where size > limit {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { size -= entry.bytes }
        }
    }
    func clear() throws {
        generation += 1
        for task in pending.values { task.cancel() }; pending.removeAll()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}
