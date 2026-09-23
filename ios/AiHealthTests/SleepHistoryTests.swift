import XCTest
import SwiftData
@testable import AiHealth

final class SleepHistoryTests: XCTestCase {
    let zone = "Asia/Shanghai"
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func sample(_ category: String, _ start: String, _ end: String, source: String = "watch") -> HealthSample {
        HealthSample(healthkitUuid: newID(), type: "sleep_analysis", unit: "category", category: category, startAt: date(start), endAt: date(end), sourceBundleId: source)
    }
    func testHistoricalNightUsesFollowingFragmentsForWakeBoundary() {
        let rows = [sample("asleep_core", "2026-09-14T23:00:00+08:00", "2026-09-15T06:00:00+08:00"),
                    sample("asleep_core", "2026-09-15T23:00:00+08:00", "2026-09-15T23:45:00+08:00"),
                    sample("asleep_rem", "2026-09-15T23:45:00+08:00", "2026-09-16T06:00:00+08:00")]
        let nights = SleepHistory.nights(samples: rows, zone: zone, days: [DayKey.date("2026-09-15", zone: zone)!, DayKey.date("2026-09-16", zone: zone)!], now: date("2026-09-23T09:00:00+08:00"))
        XCTAssertEqual(nights.map(\.minutes), [420, 420])
        XCTAssertEqual(nights.map(\.date), ["2026-09-15", "2026-09-16"])
    }
    func testOverlapUnknownDaysAndMissingStages() {
        let core = sample("asleep_core", "2026-09-14T23:00:00+08:00", "2026-09-15T06:00:00+08:00")
        let rows = [core, core, sample("asleep_deep", "2026-09-15T02:00:00+08:00", "2026-09-15T03:00:00+08:00"),
                    sample("awake", "2026-09-16T02:00:00+08:00", "2026-09-16T06:00:00+08:00")]
        let nights = SleepHistory.nights(samples: rows, zone: zone, days: [DayKey.date("2026-09-15", zone: zone)!, DayKey.date("2026-09-16", zone: zone)!], now: date("2026-09-23T09:00:00+08:00"))
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(SleepHistory.average(nights), 420)
        XCTAssertEqual(nights[0].stages["asleep_deep"], 60)
        XCTAssertEqual(nights[0].stages["asleep_core"], 360)
        XCTAssertNil(nights[0].stages["asleep_rem"])
        XCTAssertEqual(nights[0].segments.count, 3)
        XCTAssertNil(SleepHistory.average([]))
    }
    func testCloudCannotSubstituteAnotherDateZoneOrStageSource() {
        let now = date("2026-09-15T09:00:00+08:00")
        var summary = LocalHealthOverview.make(samples: [sample("asleep_core", "2026-09-14T23:00:00+08:00", "2026-09-15T06:00:00+08:00")], zone: zone, now: now)
        XCTAssertNotNil(SleepHistory.cloudNight(summary, date: "2026-09-15", zone: zone, now: now))
        XCTAssertNil(SleepHistory.cloudNight(summary, date: "2026-09-14", zone: zone, now: now))
        XCTAssertNil(SleepHistory.cloudNight(summary, date: "2026-09-15", zone: "UTC", now: now))
        summary.metrics["sleep_deep_minutes"] = HealthMetric(value: 60, unit: "min", observedAt: now, source: "other", samples: 1, coverage: "unknown", method: "test")
        XCTAssertNil(SleepHistory.cloudNight(summary, date: "2026-09-15", zone: zone, now: now)?.stages["asleep_deep"])
        summary.metrics["sleep_total_minutes"]?.observedAt = now.addingTimeInterval(1)
        XCTAssertNil(SleepHistory.cloudNight(summary, date: "2026-09-15", zone: zone, now: now))
    }
    func testCacheQueryIsScopeAndWindowBounded() async throws {
        let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let worker = HealthStorage(modelContainer: container)
        let row = sample("asleep_core", "2026-09-14T23:00:00+08:00", "2026-09-15T06:00:00+08:00")
        try await worker.persist(samples: [row], anchor: nil, cursorKey: "owner/sleep", scope: "owner", upload: false)
        let days = [DayKey.date("2026-09-15", zone: zone)!], now = date("2026-09-23T09:00:00+08:00")
        let visible = try await worker.sleepHistory(scope: "owner", zone: zone, days: days, since: date("2026-09-01T00:00:00+08:00"), now: now)
        XCTAssertEqual(visible.first?.minutes, 420)
        let restarted = HealthStorage(modelContainer: container)
        let cached = try await restarted.sleepHistory(scope: "owner", zone: zone, days: days, since: date("2026-09-01T00:00:00+08:00"), now: now)
        XCTAssertEqual(cached.first?.minutes, 420)
        let repeatedRawScans = await restarted.sleepRawScanCount
        XCTAssertEqual(repeatedRawScans, 0, "opening the night again must use the saved aggregate")
        let other = try await worker.sleepHistory(scope: "other", zone: zone, days: days, since: date("2026-09-01T00:00:00+08:00"), now: now)
        XCTAssertTrue(other.isEmpty)
        let clipped = try await worker.sleepHistory(scope: "owner", zone: zone, days: days, since: date("2026-09-16T00:00:00+08:00"), now: now)
        XCTAssertTrue(clipped.isEmpty)
        let tombstone = HealthSample(healthkitUuid: row.healthkitUuid, type: "sleep_analysis", unit: "category", deleted: true)
        try await worker.persist(samples: [tombstone], anchor: nil, cursorKey: "owner/sleep", scope: "owner", upload: false)
        let afterDelete = try await worker.sleepHistory(scope: "owner", zone: zone, days: days, since: date("2026-09-01T00:00:00+08:00"), now: now)
        XCTAssertTrue(afterDelete.isEmpty, "HealthKit deletion must invalidate the saved night")
    }
    func testLocalOverviewCacheSurvivesRestartAndWaterChangeWithoutRawScan() async throws {
        let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let worker = HealthStorage(modelContainer: container)
        let now = date("2026-09-23T09:00:00+08:00"), since = date("2026-08-23T00:00:00+08:00")
        var weight = HealthSample(healthkitUuid: newID(), type: "body_mass", value: 76, unit: "kg", startAt: now.addingTimeInterval(-60), endAt: now.addingTimeInterval(-60), sourceBundleId: "test.scale")
        try await worker.persist(samples: [weight], anchor: nil, cursorKey: "owner/body", scope: "owner", upload: false)
        let initial = try await worker.overview(scope: "owner", zone: zone, now: now, water: 0, since: since)
        XCTAssertEqual(initial.summary.metrics["body_mass"]?.value, 76)
        let restarted = HealthStorage(modelContainer: container)
        let reused = try await restarted.overview(scope: "owner", zone: zone, now: now, water: 250, since: since)
        XCTAssertEqual(reused.summary.metrics["body_mass"]?.value, 76)
        XCTAssertEqual(reused.summary.metrics["water_ml"]?.value, 250)
        let scans = await restarted.overviewRawScanCount
        XCTAssertEqual(scans, 0, "opening the app again must reuse the saved overview")
        weight.healthkitUuid = newID(); weight.value = 75; weight.startAt = now; weight.endAt = now
        try await worker.persist(samples: [weight], anchor: nil, cursorKey: "owner/body", scope: "owner", upload: false)
        let updated = try await worker.overview(scope: "owner", zone: zone, now: now, water: 250, since: since)
        XCTAssertEqual(updated.summary.metrics["body_mass"]?.value, 75)
    }
}
