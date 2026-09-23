import XCTest
@testable import AiHealth

private final class PhotoProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var fail = false
    static let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 0x01, 0x02, 0xff, 0xd9])
    static func reset(failing: Bool = false) { lock.lock(); defer { lock.unlock() }; requests = []; fail = failing }
    static func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); let failing = Self.fail; Self.lock.unlock()
        if failing { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/jpeg"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.jpeg)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ExerciseMediaTests: XCTestCase {
    private func makeCache(limit: Int = 1024) -> (ExerciseMediaCache, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PhotoProtocol.self]
        return (ExerciseMediaCache(directory: directory, session: URLSession(configuration: config), baseURL: URL(string: "https://media.example.test/v1")!, limit: limit), directory)
    }
    func testThumbnailAndDetailAreSeparateAndOfflineCacheWorks() async throws {
        PhotoProtocol.reset(); let (cache, dir) = makeCache(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await cache.data(filename: "Bench_0.jpg", thumbnail: true)
        XCTAssertEqual(PhotoProtocol.snapshot().map { $0.url!.path }, ["/v1/thumb/Bench_0.jpg"])
        _ = try await cache.data(filename: "Bench_0.jpg", thumbnail: false)
        XCTAssertEqual(PhotoProtocol.snapshot().last?.url?.path, "/v1/full/Bench_0.jpg")
        XCTAssertTrue(PhotoProtocol.snapshot().allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "Cookie") == nil })
        PhotoProtocol.reset(failing: true)
        let cached = try await cache.data(filename: "Bench_0.jpg", thumbnail: true)
        XCTAssertEqual(cached, PhotoProtocol.jpeg); XCTAssertTrue(PhotoProtocol.snapshot().isEmpty)
        try await cache.clear()
        let size = await cache.byteCount(); XCTAssertEqual(size, 0)
        do { _ = try await cache.data(filename: "Bench_0.jpg", thumbnail: true); XCTFail("Cleared image should require the offline network") } catch {}
        XCTAssertEqual(PhotoProtocol.snapshot().count, 1)
    }
    func testEvictionAndInvalidPaths() async throws {
        PhotoProtocol.reset(); let (cache, dir) = makeCache(limit: 8); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await cache.data(filename: "A.jpg", thumbnail: true)
        _ = try await cache.data(filename: "B.jpg", thumbnail: true)
        let size = await cache.byteCount(); XCTAssertLessThanOrEqual(size, 8)
        do { _ = try await cache.data(filename: "../secret.jpg", thumbnail: false); XCTFail("Path traversal accepted") } catch {}
        XCTAssertEqual(PhotoProtocol.snapshot().count, 2)
        PhotoProtocol.reset(failing: true)
        _ = try await cache.data(filename: "B.jpg", thumbnail: true)
        do { _ = try await cache.data(filename: "A.jpg", thumbnail: true); XCTFail("Old entry should have been evicted") } catch {}
    }
    func testConcurrentRequestsForSamePhotoShareDownload() async throws {
        PhotoProtocol.reset(); let (cache, dir) = makeCache(); defer { try? FileManager.default.removeItem(at: dir) }
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<10 { group.addTask { try await cache.data(filename: "A.jpg", thumbnail: true) } }
            for try await data in group { XCTAssertEqual(data, PhotoProtocol.jpeg) }
        }
        XCTAssertEqual(PhotoProtocol.snapshot().count, 1)
    }
}
