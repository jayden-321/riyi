import XCTest
import SwiftData
@testable import AiHealth

final class PlanningTests: XCTestCase {
    @MainActor func testWalkingRecoveryBecomesTimedTrainingWithoutFakeSets() throws {
        let db = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: db); store.scope = "local-demo"; store.reload()
        let day = CycleDay(date: "2026-09-23", rest: true, recoveryActivity: "饭后散步")
        let cycle = PlanningCycle(name: "今日安排", kind: "training", startDate: day.date, endDate: day.date, timezone: "Asia/Shanghai", days: [day])
        XCTAssertTrue(store.save(cycle, kind: "cycle", id: cycle.id))
        store.promoteWalkingRecovery()
        let scheduled = try XCTUnwrap(store.scheduled("training", date: day.date)?.1)
        XCTAssertFalse(scheduled.rest)
        XCTAssertEqual(scheduled.activity?.name, "饭后散步")
        XCTAssertNil(scheduled.plan)
        let workout = Workout(activity: try XCTUnwrap(scheduled.activity))
        XCTAssertTrue(workout.exercises.isEmpty)
        XCTAssertEqual(workout.totalSets, 0)
    }
    @MainActor func testWalkingPromotionUpdatesPendingCloudPayload() throws {
        let db = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: db); store.scope = "https://example.test/user"; store.reload()
        let day = CycleDay(date: "2026-09-23", rest: true, recoveryActivity: "饭后散步")
        let cycle = PlanningCycle(name: "今日安排", kind: "training", startDate: day.date, endDate: day.date, timezone: "Asia/Shanghai", days: [day])
        XCTAssertTrue(store.save(cycle, kind: "cycle", id: cycle.id))
        XCTAssertEqual(store.pending.count, 1)
        store.promoteWalkingRecovery()
        XCTAssertEqual(store.pending.count, 1)
        let pending: PlanningCycle = try Wire.read(try XCTUnwrap(store.pending.first?.payload))
        XCTAssertFalse(pending.days[0].rest)
        XCTAssertEqual(pending.days[0].activity?.resolvedSport, "walking")
    }
    @MainActor func testRecoveryActivityAndDeletingOneRestDayPreserveOtherDates() throws {
        let db = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: db); store.scope = "local-demo"; store.reload()
        let first = CycleDay(date: "2026-09-23", rest: true)
        let second = CycleDay(date: "2026-09-24", rest: true)
        let cycle = PlanningCycle(name: "休息与恢复", kind: "training", startDate: first.date, endDate: second.date, timezone: "Asia/Shanghai", days: [first, second])
        XCTAssertTrue(store.save(cycle, kind: "cycle", id: cycle.id))
        XCTAssertTrue(store.setRestDayRecovery(on: first.date, activity: "饭后散步"))
        XCTAssertEqual(store.scheduled("training", date: first.date)?.1.recoveryActivity, "饭后散步")
        XCTAssertTrue(store.deleteRestDay(on: first.date))
        XCTAssertNil(store.scheduled("training", date: first.date))
        XCTAssertNotNil(store.scheduled("training", date: second.date))
        XCTAssertTrue(store.deleteRestDay(on: second.date))
        XCTAssertTrue(store.cycles.isEmpty)
    }
    func testLabelCaloriesUnknownAndFuture() {
        var log = MealLog(description: "蛋糕40克",eatenAt: Date().addingTimeInterval(-60),energyMethod: "label",grams: 40,kcalPer100: 250)
        log.calculateEnergy(); XCTAssertEqual(log.energyKcal,100); XCTAssertTrue(log.valid)
        log.energyMethod = "unknown"; log.calculateEnergy(); XCTAssertNil(log.energyKcal); XCTAssertTrue(log.valid)
        log.eatenAt = Date().addingTimeInterval(3600); XCTAssertFalse(log.valid)
    }
    func testCycleShiftCrossYearRetainsIdentity() throws {
        var c = PlanningCycle(name: "一周",kind: "training",startDate: "2026-12-28",endDate: "2027-01-03",timezone: "Asia/Shanghai",days: [CycleDay(date: "2026-12-28",rest: true),CycleDay(date: "2027-01-03",rest: true)])
        let id = c.days[1].id;c.shift(to: try XCTUnwrap(DayKey.date("2027-01-04",zone: c.timezone)))
        XCTAssertEqual(c.startDate,"2027-01-04");XCTAssertEqual(c.endDate,"2027-01-10");XCTAssertEqual(c.days[1].id,id)
        XCTAssertEqual(stableID("meal/test"),stableID("meal/test"));XCTAssertNotNil(UUID(uuidString: stableID("meal/test")))
    }
    @MainActor func testExtraMealOfflineIsolationAndUnknownCalories() throws {
        let db = try ModelContainer(for: LocalRecord.self,PendingChange.self,HealthCursor.self,LocalHealthRecord.self,HealthUploadCheckpoint.self,configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: db);store.scope = "meal-test-account"
        let log = MealLog(slot: "drink",description: "半杯奶茶",eatenAt: Date().addingTimeInterval(-60))
        XCTAssertTrue(store.save(log,kind: "meal",id: log.id));store.reload()
        XCTAssertEqual(store.mealLogs.count,1);XCTAssertNil(store.mealLogs.first?.energyKcal);XCTAssertEqual(store.pending.count,1)
        store.scope = "other-account";store.reload();XCTAssertTrue(store.mealLogs.isEmpty)
        store.scope = "meal-test-account";store.reload();store.remove(kind: "meal",id: log.id);XCTAssertTrue(store.mealLogs.isEmpty)
    }
}
