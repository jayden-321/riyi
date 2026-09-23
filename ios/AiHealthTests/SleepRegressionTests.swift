import XCTest
import SwiftData
@testable import AiHealth

final class SleepRegressionTests: XCTestCase {
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func sample(_ source: String, _ category: String, _ start: String, _ end: String) -> HealthSample {
        HealthSample(healthkitUuid: newID(), type: "sleep_analysis", unit: "category", category: category,
                     startAt: date(start), endAt: date(end), sourceBundleId: source)
    }
    func testOldHighCountSourceCannotHideCurrentNight() {
        let samples = [
            sample("old", "asleep_core", "2026-09-21T00:00:00+08:00", "2026-09-21T01:00:00+08:00"),
            sample("old", "asleep_deep", "2026-09-21T01:00:00+08:00", "2026-09-21T02:00:00+08:00"),
            sample("old", "asleep_rem", "2026-09-21T02:00:00+08:00", "2026-09-21T03:00:00+08:00"),
            sample("current", "asleep_core", "2026-09-21T23:00:00+08:00", "2026-09-22T06:00:00+08:00")
        ]
        let overview = LocalHealthOverview.make(samples: samples, zone: "Asia/Shanghai", now: date("2026-09-22T08:00:00+08:00"))
        XCTAssertEqual(overview.metrics["sleep_total_minutes"]?.value, 420)
        XCTAssertEqual(overview.metrics["sleep_total_minutes"]?.source, "current")
        XCTAssertNil(overview.metrics["sleep_deep_minutes"]?.value)
    }
    func testAwakeOnlySourceCannotHideActualSleep() {
        let samples = [
            sample("awake", "awake", "2026-09-22T02:00:00+08:00", "2026-09-22T03:00:00+08:00"),
            sample("awake", "in_bed", "2026-09-22T03:00:00+08:00", "2026-09-22T06:00:00+08:00"),
            sample("sleep", "asleep_unspecified", "2026-09-21T23:00:00+08:00", "2026-09-22T06:00:00+08:00")
        ]
        let overview = LocalHealthOverview.make(samples: samples, zone: "Asia/Shanghai", now: date("2026-09-22T08:00:00+08:00"))
        XCTAssertEqual(overview.metrics["sleep_total_minutes"]?.value, 420)
        XCTAssertNil(overview.metrics["sleep_rem_minutes"]?.value)
    }
    @MainActor func testSameDayCloudFallbackDoesNotShowOldSleep() throws {
        let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: container); store.scope = "local-demo"; store.settings.timezone = "Asia/Shanghai"
        let now = date("2026-09-22T08:00:00+08:00")
        store.localSummary = LocalHealthOverview.make(samples: [], zone: "Asia/Shanghai", now: now)
        store.cloudSummary = LocalHealthOverview.make(samples: [sample("cloud-watch", "asleep_core", "2026-09-21T23:00:00+08:00", "2026-09-22T06:00:00+08:00")], zone: "Asia/Shanghai", now: now)
        XCTAssertEqual(store.sleepMetric("sleep_total_minutes", now: now)?.value, 420)
        XCTAssertTrue(store.sleepMetric("sleep_total_minutes", now: now)?.method.hasPrefix("cloud_fallback_") == true)
        store.cloudSummary?.date = "2026-09-21"
        XCTAssertNil(store.sleepMetric("sleep_total_minutes", now: now))
        store.cloudSummary?.date = "2026-09-22"
        store.cloudSummary?.metrics["sleep_total_minutes"]?.observedAt = date("2026-09-21T06:00:00+08:00")
        XCTAssertNil(store.sleepMetric("sleep_total_minutes", now: now))
        store.cloudSummary?.metrics["sleep_total_minutes"]?.observedAt = now.addingTimeInterval(3600)
        XCTAssertNil(store.sleepMetric("sleep_total_minutes", now: now))
        store.localSummary = LocalHealthOverview.make(samples: [sample("local-watch", "asleep_core", "2026-09-22T00:00:00+08:00", "2026-09-22T06:00:00+08:00")], zone: "Asia/Shanghai", now: now)
        XCTAssertEqual(store.sleepMetric("sleep_total_minutes", now: now)?.value, 360)
        XCTAssertEqual(store.sleepMetric("sleep_total_minutes", now: now)?.source, "local-watch")
        store.cloudSummary?.metrics["sleep_total_minutes"]?.observedAt = date("2026-09-22T06:00:00+08:00")
        store.cloudSummary?.metrics["sleep_deep_minutes"] = HealthMetric(value: 60, unit: "min", observedAt: now, source: "cloud-watch", samples: 1, coverage: "unknown", method: "server")
        XCTAssertNil(store.sleepMetric("sleep_deep_minutes", now: now), "Local total cannot be mixed with another source's stages")
    }

}
