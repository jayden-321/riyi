import XCTest
import SwiftData
@testable import AiHealth

final class PlanningTests: XCTestCase {
    func testSingleDayTrainingCycleUsesSelectedDateAndSnapshot() throws {
        let original = Plan.starter()
        let day = original.days[0]
        let cycle = singleDayTrainingCycle(original, date: "2026-09-25", timezone: "Asia/Shanghai")
        XCTAssertEqual(cycle.startDate, "2026-09-25")
        XCTAssertEqual(cycle.endDate, "2026-09-25")
        XCTAssertEqual(cycle.days.count, 1)
        XCTAssertEqual(cycle.days[0].trainingBlocks.count, 1)
        XCTAssertEqual(cycle.days[0].trainingBlocks[0].plan?.scheduledDate, "2026-09-25")
        XCTAssertEqual(cycle.days[0].trainingBlocks[0].plan?.days[0].id, day.id)
        XCTAssertNil(original.scheduledDate)
    }
    func testManualTrainingDateRangePreservesEditedDay() throws {
        let zone = "Asia/Shanghai"
        let start = try XCTUnwrap(DayKey.date("2026-09-23", zone: zone))
        let end = try XCTUnwrap(DayKey.date("2026-09-25", zone: zone))
        var days = manualTrainingDays(from: start, through: end, timezone: zone)
        XCTAssertEqual(days.map(\.date), ["2026-09-23", "2026-09-24", "2026-09-25"])
        XCTAssertTrue(days.allSatisfy(\.rest))
        days[1].rest = false
        days[1].plan = Plan.starter()
        let shifted = manualTrainingDays(from: try XCTUnwrap(DayKey.date("2026-09-24", zone: zone)), through: try XCTUnwrap(DayKey.date("2026-09-26", zone: zone)), timezone: zone, preserving: days)
        XCTAssertEqual(shifted.map(\.date), ["2026-09-24", "2026-09-25", "2026-09-26"])
        XCTAssertEqual(shifted[0].id, days[1].id)
        XCTAssertEqual(shifted[0].plan?.name, "增肌计划 A")
        XCTAssertTrue(shifted[2].rest)
    }
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
    @MainActor func testDeletingScheduledTrainingKeepsActualWorkoutAndOtherDate() throws {
        let db = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: db); store.scope = "local-demo"; store.reload()
        let plan = Plan.starter(), first = CycleDay(date: "2026-09-23", plan: plan), second = CycleDay(date: "2026-09-24", rest: true)
        let cycle = PlanningCycle(name: "两日周期", kind: "training", startDate: first.date, endDate: second.date, timezone: "Asia/Shanghai", days: [first, second])
        XCTAssertTrue(store.save(cycle, kind: "cycle", id: cycle.id))
        let workout = Workout(plan: plan, day: plan.days[0])
        XCTAssertTrue(store.save(workout, kind: "workout", id: workout.id))
        XCTAssertTrue(store.deleteScheduledTraining(on: first.date))
        XCTAssertNil(store.scheduled("training", date: first.date))
        XCTAssertNotNil(store.scheduled("training", date: second.date))
        XCTAssertEqual(store.workouts.count, 1)
    }
    @MainActor func testAddingSwimmingAfterStrengthKeepsBothSessionsAndActualRecord() async throws {
        let db = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: db); store.scope = "local-demo"; store.reload()
        let date = DayKey.string(Date(), zone: "Asia/Shanghai")
        let strength = Plan.starter(), first = TrainingBlock(plan: strength)
        let cycle = PlanningCycle(name: "当天训练", kind: "training", startDate: date, endDate: date, timezone: "Asia/Shanghai",
                                  days: [CycleDay(date: date, sessions: [first])])
        XCTAssertTrue(store.save(cycle, kind: "cycle", id: cycle.id))
        let actual = Workout(plan: strength, day: strength.days[0], scheduledBlockId: first.id)
        XCTAssertTrue(store.save(actual, kind: "workout", id: actual.id))
        var swim = Plan.draft(); swim.category = "swimming"; swim.name = "游泳"
        swim.days = [PlanDay(name: "泳池游泳", exercises: [], activity: TimedActivity(name: "泳池游泳", sport: "swimming", swimLocation: "pool", poolLengthMeters: 25))]
        try await store.upsertTrainingBlock(on: date, plan: swim)
        let blocks = store.trainingBlocks(on: date)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].id, first.id)
        XCTAssertEqual(blocks[1].sport, "swimming")
        XCTAssertEqual(store.workouts.count, 1)
        XCTAssertTrue(store.deleteTrainingBlock(on: date, blockID: blocks[1].id))
        XCTAssertEqual(store.trainingBlocks(on: date).map(\.id), [first.id])
        XCTAssertEqual(store.workouts.count, 1)
    }
    @MainActor func testLaterPlanMatchesOnlyUnambiguousSameSportActual() throws {
        let db = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: db); store.scope = "local-demo"; store.reload()
        let date = DayKey.string(Date(), zone: store.settings.timezone)
        var recorded = Workout(activity: TimedActivity(name: "游泳", sport: "swimming", swimLocation: "open_water"))
        recorded.status = "completed"; recorded.finishedAt = Date()
        XCTAssertTrue(store.save(recorded, kind: "workout", id: recorded.id))
        var swim = Plan.draft(); swim.category = "swimming"
        swim.days = [PlanDay(name: "游泳", exercises: [], activity: TimedActivity(name: "泳池游泳", sport: "swimming", swimLocation: "pool", poolLengthMeters: 25))]
        let block = TrainingBlock(plan: swim)
        let cycle = PlanningCycle(name: "今日", kind: "training", startDate: date, endDate: date, timezone: store.settings.timezone, days: [CycleDay(date: date, sessions: [block])])
        XCTAssertTrue(store.save(cycle, kind: "cycle", id: cycle.id))
        XCTAssertEqual(store.workouts(for: block, on: date).map(\.id), [recorded.id])
        var another = recorded; another.id = newID(); another.startedAt = another.startedAt.addingTimeInterval(1); another.finishedAt = Date()
        XCTAssertTrue(store.save(another, kind: "workout", id: another.id))
        XCTAssertEqual(store.workouts(for: block, on: date).map(\.id), [another.id, recorded.id], "Repeated sessions belong under the same unambiguous plan")
        var secondPlan = swim; secondPlan.id = newID()
        var revised = cycle; revised.days[0].setTrainingBlocks([block, TrainingBlock(plan: secondPlan)])
        XCTAssertTrue(store.save(revised, kind: "cycle", id: revised.id))
        XCTAssertTrue(store.workouts(for: block, on: date).isEmpty, "Two swimming plans make an old unlinked session ambiguous")
        XCTAssertNil(store.associatedBlockID(for: recorded, on: date))
    }
    @MainActor func testRepeatedRunsStayGroupedAfterPlanEditAndSurviveDeletion() throws {
        let db = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: db); store.scope = "local-demo"; store.reload()
        let date = DayKey.string(Date(), zone: store.settings.timezone)
        let plan = Plan.starter(), block = TrainingBlock(plan: plan)
        let cycle = PlanningCycle(name: "当天", kind: "training", startDate: date, endDate: date, timezone: store.settings.timezone, days: [CycleDay(date: date, sessions: [block])])
        XCTAssertTrue(store.save(cycle, kind: "cycle", id: cycle.id))
        var first = Workout(plan: plan, day: plan.days[0], scheduledBlockId: block.id)
        first.status = "completed"; first.finishedAt = Date()
        for i in first.exercises.indices { for j in first.exercises[i].sets.indices { first.exercises[i].sets[j].status = "skipped" } }
        XCTAssertTrue(store.save(first, kind: "workout", id: first.id))
        store.restartWorkout(first)
        let second = try XCTUnwrap(store.activeWorkout)
        XCTAssertEqual(store.workouts(for: block, on: date).map(\.id), [second.id, first.id])
        var updatedPlan = plan; updatedPlan.days[0].exercises[0].sets[0].weight = 70
        let swimActivity = TimedActivity(name: "游泳", sport: "swimming", swimLocation: "open_water")
        let swimBlock = TrainingBlock(activity: swimActivity)
        var revised = cycle; revised.days[0].setTrainingBlocks([TrainingBlock(id: block.id, plan: updatedPlan), swimBlock])
        XCTAssertTrue(store.save(revised, kind: "cycle", id: revised.id))
        let swimRun = Workout(activity: swimActivity, scheduledBlockId: swimBlock.id)
        XCTAssertTrue(store.save(swimRun, kind: "workout", id: swimRun.id))
        XCTAssertEqual(store.workouts(for: block, on: date).count, 2)
        XCTAssertEqual(store.workouts(for: swimBlock, on: date).map(\.id), [swimRun.id])
        XCTAssertEqual(store.workouts.first(where: { $0.id == first.id })?.exercises[0].sets[0].plannedWeight, 40)
        XCTAssertTrue(store.deleteTrainingBlock(on: date, blockID: block.id))
        XCTAssertEqual(store.workouts(on: date).count, 3)
        XCTAssertNil(store.associatedBlockID(for: first, on: date))
        XCTAssertEqual(store.workouts(for: swimBlock, on: date).map(\.id), [swimRun.id])
    }
    @MainActor func testAddingSportToLegacyScheduledStrengthDoesNotReplaceIt() async throws {
        let db = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: db); store.scope = "local-demo"; store.reload()
        let date = DayKey.string(Date(), zone: "Asia/Shanghai")
        var legacy = Plan.starter(); legacy.scheduledDate = date
        XCTAssertTrue(store.save(legacy, kind: "plan", id: legacy.id))
        XCTAssertEqual(store.trainingBlocks(on: date).count, 1)
        var swim = Plan.draft(); swim.category = "swimming"; swim.name = "游泳"
        swim.days = [PlanDay(name: "开放水域游泳", exercises: [], activity: TimedActivity(name: "开放水域游泳", sport: "swimming", swimLocation: "open_water"))]
        try await store.upsertTrainingBlock(on: date, plan: swim)
        XCTAssertEqual(store.trainingBlocks(on: date).map(\.sport), ["strength", "swimming"])
        XCTAssertNil(store.plans.first(where: { $0.id == legacy.id })?.scheduledDate)
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
