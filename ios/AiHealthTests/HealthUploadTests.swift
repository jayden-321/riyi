import XCTest
import SwiftData
@testable import AiHealth

private enum CacheSchemaV3 {
    @Model final class LocalHealthRecord {
        @Attribute(.unique) var key: String
        var scope: String; var sampleId: String; var type: String
        var startAt: Date?; var endAt: Date?; var deleted: Bool; var payload: Data
        init(sample: HealthSample, data: Data) {
            scope = "migration"; sampleId = sample.healthkitUuid; key = "migration/" + sample.healthkitUuid
            type = sample.type; startAt = sample.startAt; endAt = sample.endAt; deleted = false; payload = data
        }
    }
}

extension HealthStorage {
    func isExecutingOnMainThread() -> Bool { Thread.isMainThread }
    func cacheCount(scope: String) throws -> Int { try modelContext.fetchCount(FetchDescriptor<LocalHealthRecord>(predicate: #Predicate { $0.scope == scope })) }
}

final class HealthUploadTests: XCTestCase {
    @MainActor func testLegacyDeletedPayloadAcknowledgesAfterFlagRepair() async throws {
        let db = try container(), context = ModelContext(db), scope = "legacy-delete"
        let value = HealthSample(healthkitUuid: newID(), type: "body_mass", unit: "kg", deleted: true)
        let row = LocalHealthRecord(scope: scope, sample: value, payload: try Wire.data(value))
        row.tombstoned = false // Legacy persisted-state mismatch, with reliable tombstone JSON.
        context.insert(row)
        context.insert(PendingChange(scope: scope, kind: "health", recordId: newID(), payload: try Wire.data(["samples": [value]])))
        try context.save()
        let worker = HealthStorage(modelContainer: db)
        let batch = try await next(worker, scope: scope, since: Date())
        _ = try await worker.acknowledge(scope: scope, batch: batch)
        let check = ModelContext(db), saved = try XCTUnwrap(check.fetch(FetchDescriptor<LocalHealthRecord>()).first)
        XCTAssertTrue(saved.tombstoned); XCTAssertTrue(saved.cloudUploaded)
        XCTAssertEqual(try check.fetchCount(FetchDescriptor<PendingChange>()), 0)
    }
    @MainActor func testRepeatedReadDoesNotDuplicateUploadQueue() async throws {
        let db = try container(), owner = "deduplicate-" + newID()
        let worker = await Task.detached { HealthStorage(modelContainer: db) }.value
        var value = sample(1, at: Date())
        try await worker.persist(samples: [value], anchor: nil, cursorKey: owner, scope: owner, upload: true)
        try await worker.persist(samples: [value], anchor: nil, cursorKey: owner, scope: owner, upload: true)
        let once = try await worker.progress(scope: owner); XCTAssertEqual(once.pendingBatches, 1)
        let batch = try await next(worker, scope: owner, since: .distantPast)
        _ = try await worker.acknowledge(scope: owner, batch: batch)
        try await worker.persist(samples: [value], anchor: nil, cursorKey: owner, scope: owner, upload: true)
        let noRepeat = try await worker.progress(scope: owner); XCTAssertEqual(noRepeat.pendingBatches, 0)
        value.deleted = true
        try await worker.persist(samples: [value], anchor: nil, cursorKey: owner, scope: owner, upload: true)
        let deletion = try await worker.progress(scope: owner); XCTAssertEqual(deletion.pendingBatches, 1)
    }
    @MainActor func testPauseAndResumeUploadAgainstServer() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["AICORE_TEST_API"], let url = URL(string: endpoint) else { throw XCTSkip("AICORE_TEST_API required") }
        let client = Network(baseURL: url), password = "upload-test-" + newID()
        try await client.authenticate(email: newID() + "@example.test", password: password, register: true)
        do {
            let db = try container(), store = AppStore(container: db)
            store.network = client; store.scope = url.absoluteString + "/" + client.tokens!.userId
            store.healthReadingEnabled = true; store.settings.healthConsent = true; store.healthUploadPaused = true
            _ = try await client.request("/v1/settings", method: "PUT", body: Wire.data(store.settings))
            let worker = await store.healthStorage.value, date = Date().addingTimeInterval(-60)
            try await worker.persist(samples: (0..<1251).map { sample($0, at: date) }, anchor: nil, cursorKey: store.scope + "/test", scope: store.scope, upload: false)
            try await store.enqueueLocalHealthForUpload()
            await store.synchronize()
            let pausedExport = try JSONSerialization.jsonObject(with: await client.request("/v1/export")) as! [String: Any]
            XCTAssertEqual((pausedExport["health_samples"] as? [Any])?.count, 0)
            await store.resumeHealthUpload()
            XCTAssertNil(store.error); XCTAssertEqual(store.pendingHealthCount, 0)
            let export = try JSONSerialization.jsonObject(with: await client.request("/v1/export")) as! [String: Any]
            XCTAssertEqual((export["health_samples"] as? [Any])?.count, 1251)
            _ = try await client.request("/v1/account", method: "DELETE", body: Wire.data(["password": password])); client.forget()
        } catch {
            _ = try? await client.request("/v1/account", method: "DELETE", body: Wire.data(["password": password])); client.forget(); throw error
        }
    }
    @MainActor func testV3CacheSurvivesReceiptMigration() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("v3-health-migration-" + newID())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cache.store"), value = sample(7, at: Date())
        try autoreleasepool {
            let old = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, CacheSchemaV3.LocalHealthRecord.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            let c = ModelContext(old); c.insert(CacheSchemaV3.LocalHealthRecord(sample: value, data: try Wire.data(value))); try c.save()
        }
        let upgraded = try container(url: url), c = ModelContext(upgraded)
        let rows = try c.fetch(FetchDescriptor<LocalHealthRecord>())
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.sampleId, value.healthkitUuid)
        XCTAssertEqual(rows.first?.cloudUploaded, false)
    }
    private func next(_ worker: HealthStorage, scope: String, since: Date) async throws -> HealthUploadBatch {
        let batch = try await worker.nextUpload(scope: scope, since: since); return try XCTUnwrap(batch)
    }
    @MainActor private func container(url: URL? = nil) throws -> ModelContainer {
        let config = url.map { ModelConfiguration(url: $0, cloudKitDatabase: .none) } ?? ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: config)
    }
    private func sample(_ index: Int, at date: Date) -> HealthSample {
        HealthSample(healthkitUuid: String(format: "%08x-0000-4000-8000-%012x", index, index), type: "heart_rate", value: 70, unit: "bpm", startAt: date, endAt: date, sourceBundleId: "test.synthetic.watch")
    }
    @MainActor func testBoundedBatchesResumeAndKeepOldCache() async throws {
        let db = try container(), owner = "upload-" + newID(), now = Date()
        let worker = await Task.detached { HealthStorage(modelContainer: db) }.value
        let onMain = await worker.isExecutingOnMainThread(); XCTAssertFalse(onMain)
        let since = now.addingTimeInterval(-365 * 86400)
        for start in stride(from: 0, to: 1251, by: 250) {
            let samples = (start..<min(start + 250, 1251)).map { sample($0, at: now.addingTimeInterval(-60)) }
            try await worker.persist(samples: samples, anchor: nil, cursorKey: owner + "/heart", scope: owner, upload: false)
        }
        try await worker.persist(samples: [sample(9999, at: now.addingTimeInterval(-800 * 86400))], anchor: nil, cursorKey: owner + "/heart", scope: owner, upload: false)
        let initial = try await worker.startBackfill(scope: owner, restart: true, since: since)
        XCTAssertEqual(initial.target, 1251); XCTAssertEqual(initial.pendingBatches, 0)
        let prepared = try await worker.prepareNextBatch(scope: owner, since: since); XCTAssertEqual(prepared.pendingBatches, 1)
        let first = try await next(worker, scope: owner, since: since)
        XCTAssertEqual(first.count, 500)
        // Recreating the worker simulates app restart; the exact pending batch survives.
        let resumed = await Task.detached { HealthStorage(modelContainer: db) }.value
        let replay = try await next(resumed, scope: owner, since: since)
        XCTAssertEqual(replay.id, first.id); XCTAssertEqual(replay.payload, first.payload)
        _ = try await resumed.acknowledge(scope: owner, batch: replay)
        var total = 500
        while true {
            let progress = try await resumed.prepareNextBatch(scope: owner, since: since)
            if progress.finished { break }
            let batch = try await next(resumed, scope: owner, since: since)
            XCTAssertLessThanOrEqual(batch.count, 500)
            total += batch.count; _ = try await resumed.acknowledge(scope: owner, batch: batch)
        }
        XCTAssertEqual(total, 1251)
        let kept = try await resumed.cacheCount(scope: owner); XCTAssertEqual(kept, 1252)
        let again = try await resumed.startBackfill(scope: owner, restart: true, since: since); XCTAssertEqual(again.target, 0)
    }
    @MainActor func testLegacyQueueFiltersWindowWithoutMarkingExcludedRowsUploaded() async throws {
        let db = try container(), owner = "legacy-" + newID(), now = Date()
        let worker = await Task.detached { HealthStorage(modelContainer: db) }.value
        let fresh = sample(1, at: now.addingTimeInterval(-3600)), old = sample(2, at: now.addingTimeInterval(-100 * 86400))
        try await worker.persist(samples: [fresh, old], anchor: nil, cursorKey: owner, scope: owner, upload: true)
        let month = HealthHistoryWindow.month.start(now: now)
        let batch = try await next(worker, scope: owner, since: month); XCTAssertEqual(batch.count, 1)
        _ = try await worker.acknowledge(scope: owner, batch: batch)
        let expanded = try await worker.startBackfill(scope: owner, restart: true, since: HealthHistoryWindow.year.start(now: now)); XCTAssertEqual(expanded.target, 1)
        let count = try await worker.cacheCount(scope: owner); XCTAssertEqual(count, 2)
    }
    @MainActor func testThreeHundredThousandSamples() async throws {
        guard ProcessInfo.processInfo.environment["AIHEALTH_STRESS"] == "1" else { throw XCTSkip("Set AIHEALTH_STRESS=1 for the 300,000-record stress test") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("health-stress-" + newID())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try container(url: folder.appendingPathComponent("stress.store")), owner = "stress", now = Date()
        let worker = await Task.detached { HealthStorage(modelContainer: db) }.value
        var ticks = 0
        let heartbeat = Task { @MainActor in while !Task.isCancelled { ticks += 1; try? await Task.sleep(nanoseconds: 5_000_000) } }
        defer { heartbeat.cancel() }
        let started = Date()
        for start in stride(from: 0, to: 300_000, by: 500) {
            let records = (start..<start+500).map { sample($0, at: now.addingTimeInterval(-Double($0) * 60)) }
            try await worker.persist(samples: records, anchor: nil, cursorKey: owner, scope: owner, upload: false)
            if (start + 500) % 50_000 == 0 { print("STRESS_SEEDED \(start + 500)") }
        }
        let before = ticks
        let year = HealthHistoryWindow.year.start(now: now)
        let progress = try await worker.startBackfill(scope: owner, restart: true, since: year)
        XCTAssertEqual(progress.target, 300_000)
        _ = try await worker.prepareNextBatch(scope: owner, since: year)
        let batch = try await next(worker, scope: owner, since: year); XCTAssertEqual(batch.count, 500)
        XCTAssertGreaterThan(ticks, before, "Main actor must remain schedulable during preparation")
        let q = try await worker.progress(scope: owner); XCTAssertEqual(q.pendingBatches, 1)
        print("STRESS_PASS records=300000 pending_batches=1 batch_records=500 main_actor_ticks=\(ticks) seconds=\(Date().timeIntervalSince(started))")
    }
}
