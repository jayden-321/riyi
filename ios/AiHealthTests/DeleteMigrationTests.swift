import XCTest
import SwiftData
@testable import AiHealth

final class DeleteMigrationTests: XCTestCase {
    @MainActor func testV8DeletionFlagsAndRecordsSurviveRename() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("v8-deletion-" + newID())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cache.store")
        let plan = Plan.starter(), scope = "migration"
        let count = ProcessInfo.processInfo.environment["AIHEALTH_STRESS"] == "1" ? 300000 : 4
        try autoreleasepool {
            let old = try ModelContainer(for: LegacyV8.LocalRecord.self, LegacyV8.PendingChange.self, LegacyV8.LocalHealthRecord.self, HealthCursor.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            let context = ModelContext(old); context.autosaveEnabled = false
            context.insert(LegacyV8.LocalRecord(scope: scope, id: plan.id, payload: try Wire.data(plan), deleted: true))
            context.insert(LegacyV8.PendingChange(scope: scope, recordId: plan.id, payload: try Wire.data(plan), deleted: true))
            let anchor = HealthCursor(key: scope + "/year/body_mass"); anchor.anchor = Data([1, 2, 3]); context.insert(anchor)
            for i in 0..<count {
                let sample = HealthSample(healthkitUuid: newID(), type: "body_mass", value: 80, unit: "kg", startAt: Date(), endAt: Date(), sourceBundleId: "test.synthetic", deleted: i == 0)
                context.insert(LegacyV8.LocalHealthRecord(scope: scope, sample: sample, payload: try Wire.data(sample)))
                if i % 1000 == 0 { try context.save() }
            }
            try context.save()
        }
        let start = Date()
        let upgraded = try ModelContainer(for: LocalRecord.self, PendingChange.self, LocalHealthRecord.self, HealthCursor.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let context = ModelContext(upgraded)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<LocalRecord>()).first)
        XCTAssertEqual(row.recordId, plan.id); XCTAssertTrue(row.tombstoned)
        let change = try XCTUnwrap(context.fetch(FetchDescriptor<PendingChange>()).first)
        XCTAssertTrue(change.tombstoned); change.baseVersion = 3; try context.save()
        XCTAssertTrue(change.tombstoned, "Saving another attribute must retain the deletion intent")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LocalHealthRecord>()), count)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LocalHealthRecord>(predicate: #Predicate { $0.tombstoned })), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<HealthCursor>()).first?.anchor, Data([1, 2, 3]))
        if count == 300000 { print("MIGRATION_PASS records=\(count) seconds=\(Date().timeIntervalSince(start))") }
    }
}

private enum LegacyV8 {
    @Model final class LocalRecord {
        @Attribute(.unique) var key: String
        var scope: String; var kind: String; var recordId: String; var version: Int; var deleted: Bool; var payload: Data; var updatedAt: Date
        init(scope: String, id: String, payload: Data, deleted: Bool) { key = scope + "/plan/" + id; self.scope = scope; kind = "plan"; recordId = id; version = 2; self.deleted = deleted; self.payload = payload; updatedAt = Date() }
    }
    @Model final class PendingChange {
        @Attribute(.unique) var id: String
        var scope: String; var kind: String; var recordId: String; var payload: Data; var deleted: Bool
        var baseVersion: Int; var createdAt: Date; var conflictData: Data?
        init(scope: String, recordId: String, payload: Data, deleted: Bool) { id = newID(); self.scope = scope; kind = "plan"; self.recordId = recordId; self.payload = payload; self.deleted = deleted; baseVersion = -1; createdAt = Date() }
    }
    @Model final class LocalHealthRecord {
        @Attribute(.unique) var key: String
        var scope: String; var sampleId: String; var type: String; var startAt: Date?; var endAt: Date?; var deleted: Bool; var payload: Data
        var cloudUploaded: Bool = false
        init(scope: String, sample: HealthSample, payload: Data) { key = scope + "/" + sample.healthkitUuid; self.scope = scope; sampleId = sample.healthkitUuid; type = sample.type; startAt = sample.startAt; endAt = sample.endAt; deleted = sample.deleted; self.payload = payload }
    }
}
