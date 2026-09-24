import XCTest
import SwiftData
@testable import AiHealth

final class ModelsTests: XCTestCase {
    @MainActor func testAppleFitnessHIITBecomesOneCompletedWorkoutAndFollowsDeletion() throws {
        let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: container)
        store.startDemo(); store.setHealthReading(true)
        let end = Date().addingTimeInterval(-60)
        let start = end.addingTimeInterval(-660)
        let uuid = newID()
        var sample = HealthSample(healthkitUuid: uuid, type: "workout", unit: "workout", startAt: start, endAt: end, sourceName: "Apple Watch", sourceBundleId: "com.apple.health.watch")
        sample.workoutJson = ["activity_type": .number(63), "duration_seconds": .number(640), "active_energy_kcal": .number(78)]
        XCTAssertTrue(store.reconcileImportedWorkouts([sample]))
        XCTAssertFalse(store.reconcileImportedWorkouts([sample]))
        XCTAssertEqual(store.workouts.count, 1)
        XCTAssertEqual(store.workouts[0].status, "completed")
        XCTAssertEqual(store.workouts[0].activity?.sport, "hiit")
        XCTAssertEqual(store.workouts[0].elapsedSeconds(at: Date()), 640, accuracy: 0.01)
        XCTAssertEqual(store.workouts[0].importedActiveEnergyKcal, 78)
        XCTAssertEqual(store.workouts[0].sourceHealthkitUuid, uuid.lowercased())
        XCTAssertEqual(store.records.first(where: { $0.kind == "workout" })?.recordId, HealthWorkoutImport.id(for: uuid))
        var removed = HealthSample(healthkitUuid: uuid, type: "workout", unit: "workout", deleted: true)
        XCTAssertTrue(removed.deleted)
        XCTAssertTrue(store.reconcileImportedWorkouts([removed]))
        XCTAssertTrue(store.workouts.isEmpty)
        XCTAssertFalse(store.reconcileImportedWorkouts([sample]))
        removed.metadataJson["riyi_session_id"] = .string(newID())
        XCTAssertNil(HealthWorkoutImport.make(removed, zone: store.settings.timezone, ownBundleID: "com.riyi.ios"))
        var owned = sample; owned.healthkitUuid = newID(); owned.metadataJson["riyi_session_id"] = .string(newID())
        XCTAssertNil(HealthWorkoutImport.make(owned, zone: store.settings.timezone, ownBundleID: "com.riyi.ios"))
        owned.metadataJson = [:]; owned.sourceName = "日益 Watch 测试"; owned.sourceBundleId = "com.aijiankang.watchtrial.hong.ios"
        XCTAssertNil(HealthWorkoutImport.make(owned, zone: store.settings.timezone, ownBundleID: "com.riyi.ios"))
    }
    @MainActor func testAlreadyCachedAppleWorkoutAppearsWhenHealthOverviewRefreshes() async throws {
        let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: container)
        store.scope = "local-demo"; store.reload(); store.setHealthReading(true)
        let end = Date().addingTimeInterval(-30), start = end.addingTimeInterval(-600)
        var sample = HealthSample(healthkitUuid: newID(), type: "workout", unit: "workout", startAt: start, endAt: end, sourceName: "Apple Watch", sourceBundleId: "com.apple.health.watch")
        sample.workoutJson = ["activity_type": .number(63), "duration_seconds": .number(600)]
        let worker = await store.healthStorage.value
        try await worker.persist(samples: [sample], anchor: nil, cursorKey: store.scope + "/workout", scope: store.scope, upload: false)
        await store.refreshLocalHealth()
        XCTAssertEqual(store.workouts.count, 1)
        XCTAssertEqual(store.workouts[0].status, "completed")
        await store.refreshLocalHealth()
        XCTAssertEqual(store.workouts.count, 1)
    }
    @MainActor func testWaterHistoryAndTotalFollowSelectedCalendarDay() throws {
        let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: container)
        store.startDemo()
        let zone = store.settings.timezone
        let today = Date()
        let yesterday = DayKey.calendar(zone).date(byAdding: .day, value: -1, to: today)!
        store.addWater(250, date: yesterday)
        store.addWater(500, date: today)
        store.calendarDate = yesterday
        XCTAssertEqual(store.water(on: store.calendarKey), 250)
        XCTAssertEqual(store.waters(on: store.calendarKey).map(\.amountMl), [250])
        store.calendarDate = today
        XCTAssertEqual(store.water(on: store.calendarKey), 500)
        XCTAssertEqual(store.waters(on: store.calendarKey).map(\.amountMl), [500])
    }
    @MainActor func testWaterReminderRouteSelectsTodayWithoutInventingIntake() throws {
        let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: container)
        store.startDemo()
        store.calendarDate = Date().addingTimeInterval(-86400)
        store.openWaterEntryFromReminder()
        XCTAssertEqual(store.selectedTab, "diet")
        XCTAssertTrue(store.showWaterEntryFromReminder)
        XCTAssertEqual(store.waterToday, 0)
        XCTAssertTrue(DayKey.calendar(store.settings.timezone).isDateInToday(store.calendarDate))
    }
    func testSportPlanCreatesTimeBasedWorkoutAndKeepsLegacyStrengthPlan() throws {
        var sport = Plan.draft(); sport.category = "swimming"; sport.trainingGoal = "custom"
        sport.days = [PlanDay(name: "周末游泳", exercises: [], activity: TimedActivity(name: "自由泳", targetMinutes: 30, sport: "swimming", targetDistanceMeters: 800, swimLocation: "pool", poolLengthMeters: 25))]
        let restored = try Wire.read(Wire.data(sport), as: Plan.self)
        XCTAssertEqual(restored.resolvedCategory, "swimming")
        let workout = Workout(plan: restored, day: restored.days[0])
        XCTAssertEqual(workout.activity?.resolvedSport, "swimming")
        XCTAssertTrue(workout.exercises.isEmpty)
        XCTAssertEqual(workout.totalSets, 0)
        XCTAssertEqual(healthWorkoutConfiguration(for: workout).activityType, .swimming)
        XCTAssertEqual(healthWorkoutConfiguration(for: workout).swimmingLocationType, .pool)
        XCTAssertEqual(healthWorkoutConfiguration(for: workout).lapLength?.doubleValue(for: .meter()), 25)
        let legacy = Plan.starter()
        XCTAssertEqual(legacy.resolvedCategory, "strength")
        XCTAssertEqual(healthWorkoutConfiguration(for: Workout(plan: legacy, day: legacy.days[0])).activityType, .traditionalStrengthTraining)
        XCTAssertEqual(healthWorkoutConfiguration(for: Workout(activity: TimedActivity(name: "HIIT", targetMinutes: 25, sport: "hiit"))).activityType, .highIntensityIntervalTraining)
    }
    @MainActor func testStartedPlanCannotBeDeletedAndUnusedStarterCanBeRemoved() throws {
        let db = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: db); store.startDemo()
        let plan = try XCTUnwrap(store.plans.first)
        store.start(plan: plan, day: plan.days[0]); store.remove(kind: "plan", id: plan.id)
        XCTAssertEqual(store.plans.count, 1); XCTAssertEqual(store.workouts.count, 1)
        XCTAssertTrue(store.error?.contains("请新增训练计划") == true)
        XCTAssertEqual(store.activeWorkout?.planDayId, plan.days[0].id)
        let unused = Plan.draft(); XCTAssertTrue(store.save(unused, kind: "plan", id: unused.id))
        store.remove(kind: "plan", id: unused.id)
        store.startDemo(); store.reload()
        XCTAssertEqual(store.plans.map(\.id), [plan.id], "Deleting an unused draft must not affect the protected plan")
        XCTAssertEqual(store.workouts.first?.name, plan.days[0].name)
    }
    @MainActor func testHealthProfileDisplaysReadingsAndKeepsManualHistory() async throws {
        let db = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: db); store.scope = "profile-fixture"; store.healthReadingEnabled = true
        var profile = Profile(); profile.heightCm = 180; profile.measuredAt = Date().addingTimeInterval(-86400)
        XCTAssertTrue(store.save(profile, kind: "profile", id: profile.id))
        let date = Date().addingTimeInterval(-60)
        let height = HealthSample(healthkitUuid: newID(), type: "height_cm", value: 178, unit: "cm", startAt: date, endAt: date, sourceName: "Synthetic", sourceBundleId: "test.health")
        let weight = HealthSample(healthkitUuid: newID(), type: "body_mass", value: 76, unit: "kg", startAt: date, endAt: date, sourceName: "Synthetic", sourceBundleId: "test.health")
        try await store.enqueueHealth(samples: [height, weight], anchor: nil, cursorKey: "profile-fixture/body", expectedScope: store.scope)
        await store.refreshLocalHealth()
        XCTAssertEqual(store.profileMetric("height_cm")?.value, 178)
        XCTAssertEqual(store.profileMetric("body_mass")?.value, 76)
        XCTAssertEqual(store.profile.heightCm, 180, "Displaying HealthKit must not rewrite the manual record")
        profile.id = newID(); profile.heightCm = 181; profile.measuredAt = Date(); profile.updatedAt = Date()
        XCTAssertTrue(store.save(profile, kind: "profile", id: profile.id))
        XCTAssertEqual(store.profileMetric("height_cm")?.value, 181)
        XCTAssertEqual(store.profileMetric("height_cm")?.source, "手动记录")
    }
    func testTrainingGroupsSnapshotAndVolume() throws {
        var plan = Plan.starter(); plan.setPattern = "pyramid"
        var day = plan.days[0]; day.volumeTargetKg = 10_000
        day.exercises.append(PlanExercise(name: "夹胸"))
        day.groups = [ExerciseGroup(name: "胸部组合", style: "giant", exerciseIds: day.exercises.map(\.id))]
        XCTAssertTrue(validGroups(day.groups!, exerciseIds: day.exercises.map(\.id)))
        var workout = Workout(plan: plan, day: day)
        XCTAssertEqual(workout.groups?.first?.exerciseIds, workout.exercises.map(\.id))
        XCTAssertNotEqual(workout.groups?.first?.exerciseIds, day.exercises.map(\.id))
        XCTAssertEqual(workout.exercises.first?.setPattern, "pyramid")
        workout.exercises[0].sets[0].status = "completed"
        workout.exercises[0].sets[0].actualWeight = 40; workout.exercises[0].sets[0].actualReps = 8
        workout.exercises[1].loadCount = 2
        workout.exercises[1].sets[0].status = "completed"
        workout.exercises[1].sets[0].actualWeight = 20; workout.exercises[1].sets[0].actualReps = 10
        XCTAssertEqual(workout.completedVolumeKg, 720)
        workout.exercises[0].sets[0].role = "warmup"
        XCTAssertEqual(workout.completedVolumeKg, 400)
        workout.exercises[1].loadBasis = "assisted"
        XCTAssertEqual(workout.completedVolumeKg, 0)
        let restored = try Wire.read(Wire.data(workout), as: Workout.self)
        XCTAssertEqual(restored.volumeTargetKg, day.plannedVolumeKg)
        XCTAssertEqual(restored.groups?.first?.style, "giant")
        day.groups![0].exerciseIds.removeLast()
        XCTAssertFalse(validGroups(day.groups!, exerciseIds: day.exercises.map(\.id)))
        // Old JSON lacks every new optional field and must remain readable.
        var raw = try JSONSerialization.jsonObject(with: Wire.data(workout)) as! [String: Any]
        raw.removeValue(forKey: "volume_target_kg"); raw.removeValue(forKey: "groups")
        raw["exercises"] = (raw["exercises"] as! [[String: Any]]).map { e in var old = e; old.removeValue(forKey: "set_pattern"); old.removeValue(forKey: "load_count"); return old }
        let legacy = try Wire.read(JSONSerialization.data(withJSONObject: raw), as: Workout.self)
        XCTAssertNil(legacy.volumeTargetKg); XCTAssertNil(legacy.groups); XCTAssertNil(legacy.exercises[0].setPattern)
    }
    func testPlannedVolumeComesFromWorkingSetsAndSelectedLoadCount() {
        var plan = Plan.draft()
        plan.days[0].exercises = [
            PlanExercise(name: "杠铃卧推", loadBasis: "total", sets: [PlanSet(role: "working", weight: 50, reps: 10), PlanSet(role: "warmup", weight: 20, reps: 10)]),
            PlanExercise(name: "哑铃卧推", loadBasis: "per_hand", sets: [PlanSet(role: "working", weight: 20, reps: 10)], loadCount: 2),
            PlanExercise(name: "自重动作", loadBasis: "bodyweight", sets: [PlanSet(role: "working", weight: 70, reps: 10)])
        ]
        plan.days[0].volumeTargetKg = 15_000 // Old manual value must not override the set details.
        XCTAssertEqual(plan.days[0].plannedVolumeKg, 900)
        XCTAssertEqual(plan.withCalculatedVolume().days[0].volumeTargetKg, 900)
        XCTAssertEqual(Workout(plan: plan, day: plan.days[0]).volumeTargetKg, 900)
        plan.days[0].exercises[0].sets[0].weight = 60
        XCTAssertEqual(plan.days[0].plannedVolumeKg, 1000)
    }
    @MainActor func testAddingLocalHealthStoragePreservesExistingRecords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aihealth-migration-" + newID())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("records.store")
        let water = WaterLog(amountMl: 250)
        try autoreleasepool {
            let old = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            let c = ModelContext(old)
            c.insert(LocalRecord(scope: "local-demo", kind: "water", id: water.id, payload: try Wire.data(water)))
            try c.save()
        }
        let upgraded = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let c = ModelContext(upgraded), rows = try c.fetch(FetchDescriptor<LocalRecord>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(try Wire.read(rows[0].payload, as: WaterLog.self).amountMl, 250)
        XCTAssertEqual(try c.fetchCount(FetchDescriptor<LocalHealthRecord>()), 0)
    }
    @MainActor func testLocalHealthWorksWithoutCloudAndKeepsDeletes() async throws {
        let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: container); store.scope = "local-demo"; store.settings.healthConsent = false; store.setHealthReading(true); store.reload()
        let now = Date().addingTimeInterval(-30)
        var sample = HealthSample(healthkitUuid: newID(), type: "body_mass", value: 76.4, unit: "kg", startAt: now, endAt: now, sourceBundleId: "test.scale")
        try await store.enqueueHealth(samples: [sample], anchor: Data([1]), cursorKey: "local-demo/body_mass", expectedScope: "local-demo")
        await store.refreshLocalHealth(markRead: true)
        XCTAssertEqual(store.summary?.metrics["body_mass"]?.value, 76.4)
        XCTAssertEqual(store.localHealthSampleCount, 1)
        XCTAssertTrue(store.pending.isEmpty, "Local-only reads must not enqueue cloud uploads")
        XCTAssertNil(store.cloudSummary)
        sample.deleted = true
        try await store.enqueueHealth(samples: [sample], anchor: Data([2]), cursorKey: "local-demo/body_mass", expectedScope: "local-demo")
        sample.deleted = false
        try await store.enqueueHealth(samples: [sample], anchor: Data([3]), cursorKey: "local-demo/body_mass", expectedScope: "local-demo")
        await store.refreshLocalHealth()
        XCTAssertNil(store.summary?.metrics["body_mass"]?.value)
        XCTAssertEqual(store.localHealthSampleCount, 0)
        XCTAssertNil(store.error)
        store.setHealthReading(false)
    }
    @MainActor func testHealthUploadRequiresSeparateConsent() async throws {
        let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: container); store.scope = "independent-read-test"; store.settings.healthConsent = false; store.setHealthReading(true); store.reload()
        let now = Date().addingTimeInterval(-5)
        let sample = HealthSample(healthkitUuid: newID(), type: "body_mass", value: 80, unit: "kg", startAt: now, endAt: now, sourceBundleId: "test.scale")
        try await store.enqueueHealth(samples: [sample], anchor: Data([1]), cursorKey: store.scope + "/body_mass", expectedScope: store.scope)
        try await store.enqueueLocalHealthForUpload(); store.reload(); XCTAssertTrue(store.pending.isEmpty)
        store.settings.healthConsent = true; try await store.enqueueLocalHealthForUpload(); XCTAssertEqual(store.pendingHealthCount, 1)
        store.scope = "another-account"; store.reload(); await store.refreshLocalHealth(); XCTAssertEqual(store.localHealthSampleCount, 0)
    }
    func testLocalSleepCrossesMidnightAndMissingIsNotZero() throws {
        let f = ISO8601DateFormatter(), now = ISO8601DateFormatter().date(from: "2026-09-22T10:00:00+08:00")!
        let sample = HealthSample(healthkitUuid: newID(), type: "sleep_analysis", unit: "category", category: "asleep_unspecified", startAt: f.date(from: "2026-09-21T23:00:00+08:00"), endAt: f.date(from: "2026-09-22T06:00:00+08:00"), sourceBundleId: "test.watch")
        let s = LocalHealthOverview.make(samples: [sample], zone: "Asia/Shanghai", now: now)
        XCTAssertEqual(s.metrics["sleep_total_minutes"]?.value, 420)
        XCTAssertNil(s.metrics["sleep_deep_minutes"]?.value)
        XCTAssertNil(s.metrics["hrv_sdnn"]?.value)
    }
    @MainActor func testLANAddressPolicy() {
        XCTAssertTrue(Network.permits(URL(string: "http://192.168.1.100:18089")!))
        XCTAssertTrue(Network.permits(URL(string: "https://health.example.com")!))
        XCTAssertFalse(Network.permits(URL(string: "http://health.example.com")!))
        XCTAssertFalse(Network.permits(URL(string: "http://192.168.1.100.example.com")!))
    }
    func testWorkoutSnapshotDoesNotFollowPlanEdit() throws {
        var plan = Plan.starter(); let workout = Workout(plan: plan, day: plan.days[0])
        plan.days[0].exercises[0].sets[0].weight = 999
        XCTAssertEqual(workout.exercises[0].sets[0].plannedWeight, 40)
        XCTAssertNotEqual(workout.exercises[0].id, plan.days[0].exercises[0].id)
        XCTAssertNil(workout.exercises[0].sets[0].actualWeight)
    }
    func testWireDatesAndIdentifiers() throws {
        let water = WaterLog(amountMl: 250)
        let data = try Wire.data(water); let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["amount_ml"] as? Int, 250)
        XCTAssertNotNil(object["drank_at"])
        let decoded: WaterLog = try Wire.read(data); XCTAssertEqual(decoded.id, water.id)
        let cloud = Data("{\"kind\":\"water\",\"id\":\"test\",\"version\":1,\"deleted\":false,\"payload\":{},\"updated_at\":\"2026-09-22T01:23:45.123456Z\"}".utf8)
        let _: CloudRecord = try Wire.read(cloud)
    }
    @MainActor func testLocalOutboxCoalescesAndScopesAccounts() throws {
        let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: container); store.scope = "test-user-a"; store.reload()
        var water = WaterLog(amountMl: 250); XCTAssertTrue(store.save(water, kind: "water", id: water.id))
        water.amountMl = 500; XCTAssertTrue(store.save(water, kind: "water", id: water.id))
        XCTAssertEqual(store.pending.count, 1); XCTAssertEqual(store.waters.first?.amountMl, 500)
        store.scope = "test-user-b"; store.reload(); XCTAssertTrue(store.waters.isEmpty); XCTAssertTrue(store.pending.isEmpty)
        store.scope = "test-user-a"; store.reload(); XCTAssertEqual(store.waters.count, 1)
    }

    @MainActor func testHealthQueueAndAnchorCommitTogether() async throws {
        let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: container); store.scope = "health-user"; store.settings.healthConsent = true; store.setHealthReading(true)
        let sample = HealthSample(healthkitUuid: newID(), type: "body_mass", value: 76.4, unit: "kg", startAt: Date(), endAt: Date(), sourceBundleId: "test.scale")
        try await store.enqueueHealth(samples: [sample], anchor: Data([1, 2, 3]), cursorKey: "health-user/body_mass", expectedScope: "health-user")
        let reopened = ModelContext(container)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<PendingChange>()).count, 1)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<HealthCursor>()).first?.anchor, Data([1, 2, 3]))
        do { try await store.enqueueHealth(samples: [sample], anchor: Data([4]), cursorKey: "other/body_mass", expectedScope: "other"); XCTFail("wrong account must be rejected") } catch { }
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<HealthCursor>()).count, 1)
    }

    @MainActor func testWorkoutEnergyEnrichesExistingWatchSample() async throws {
        let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let worker = HealthStorage(modelContainer: container)
        let observed = Date()
        var sample = HealthSample(healthkitUuid: newID(), type: "workout", unit: "workout", startAt: observed, endAt: observed.addingTimeInterval(60), sourceBundleId: "synthetic.watch")
        sample.metadataJson["watch_session_id"] = .string(newID())
        sample.workoutJson = ["duration_seconds": .number(60)]
        try await worker.persist(samples: [sample], anchor: nil, cursorKey: "test/watch", scope: "test", upload: false)
        sample.workoutJson = ["active_energy_kcal": .number(123.4)]
        try await worker.persist(samples: [sample], anchor: nil, cursorKey: "test/phone", scope: "test", upload: false)
        let rows = try ModelContext(container).fetch(FetchDescriptor<LocalHealthRecord>())
        let stored: HealthSample = try Wire.read(try XCTUnwrap(rows.first?.payload))
        if case .number(let duration)? = stored.workoutJson?["duration_seconds"] { XCTAssertEqual(duration, 60) }
        else { XCTFail("Watch duration was lost") }
        if case .number(let energy)? = stored.workoutJson?["active_energy_kcal"] { XCTAssertEqual(energy, 123.4) }
        else { XCTFail("measured energy enrichment was lost") }
    }

    func testWeightTrendKeepsOneSourceAndNeedsEnoughDays() throws {
        let zone = "Asia/Shanghai"
        let calendar = DayKey.calendar(zone)
        let today = calendar.startOfDay(for: Date())
        let readings: [WeightReading] = (0..<8).map { offset in
            let at = calendar.date(byAdding: .day, value: -offset, to: today)!.addingTimeInterval(1)
            return WeightReading(id: "scale-\(offset)", kg: 76 + Double(offset) * 0.1,
                                 observedAt: at, sourceName: "体重秤", sourceBundleId: "scale")
        } + [WeightReading(id: "manual", kg: 99, observedAt: today.addingTimeInterval(2),
                           sourceName: "手动", sourceBundleId: "manual")]
        XCTAssertEqual(WeightHistory.preferredSource(readings, zone: zone), "scale")
        let selected = WeightHistory.dailyLatest(readings, source: "scale", zone: zone,
                                                 from: calendar.date(byAdding: .day, value: -7, to: today)!, to: Date())
        XCTAssertEqual(selected.count, 8)
        XCTAssertTrue(selected.allSatisfy { $0.kg < 80 })
        XCTAssertNil(WeightHistory.sevenDayMeanChange(readings, source: "scale", zone: zone, now: Date()))
        let merged = WeightHistory.merge(local: [readings[0]], cloud: [readings[0], readings[1]])
        XCTAssertEqual(merged.count, 2)
    }

    @MainActor func testWeightHistoryStorageFiltersScopeTypeAndDeletion() async throws {
        let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let worker = HealthStorage(modelContainer: container)
        let at = Date().addingTimeInterval(-60)
        let valid = HealthSample(healthkitUuid: newID(), type: "body_mass", value: 76.4, unit: "kg", startAt: at, endAt: at, sourceBundleId: "scale")
        let heart = HealthSample(healthkitUuid: newID(), type: "heart_rate", value: 70, unit: "bpm", startAt: at, endAt: at, sourceBundleId: "watch")
        var deleted = HealthSample(healthkitUuid: newID(), type: "body_mass", value: 88, unit: "kg", startAt: at, endAt: at, sourceBundleId: "scale")
        try await worker.persist(samples: [valid, heart, deleted], anchor: nil, cursorKey: "owner/weight", scope: "owner", upload: false)
        try await worker.persist(samples: [valid], anchor: nil, cursorKey: "other/weight", scope: "other", upload: false)
        deleted.deleted = true
        try await worker.persist(samples: [deleted], anchor: nil, cursorKey: "owner/delete", scope: "owner", upload: false)
        let owner = try await worker.weightReadings(scope: "owner", since: at.addingTimeInterval(-1), now: Date())
        XCTAssertEqual(owner.map(\.kg), [76.4])
        let other = try await worker.weightReadings(scope: "other", since: at.addingTimeInterval(-1), now: Date())
        XCTAssertEqual(other.count, 1)
    }

    func testHRVTrendUsesDailyMedianAndRestingHeartUsesLastReading() {
        let zone = "Asia/Shanghai"
        let day = DayKey.calendar(zone).startOfDay(for: Date())
        let values = [30.0, 50.0, 100.0].enumerated().map { index, value in
            VitalReading(id: "v\(index)", value: value, observedAt: day.addingTimeInterval(Double(index + 1)),
                         sourceName: "手表", sourceBundleId: "watch")
        }
        let hrv = VitalHistory.dailyPoints(values, type: "hrv_sdnn", source: "watch", zone: zone, from: day, to: Date())
        XCTAssertEqual(hrv.count, 1)
        XCTAssertEqual(hrv.first?.value, 50)
        XCTAssertEqual(hrv.first?.samples, 3)
        let resting = VitalHistory.dailyPoints(values, type: "resting_heart_rate", source: "watch", zone: zone, from: day, to: Date())
        XCTAssertEqual(resting.first?.value, 100)
        XCTAssertEqual(VitalHistory.merge(local: [values[0]], cloud: values).count, 3)
    }

    @MainActor func testLiveClientSyncContract() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["AICORE_TEST_API"], let url = URL(string: endpoint) else { throw XCTSkip("AICORE_TEST_API required for local HTTP integration") }
        let client = Network(baseURL: url)
        let password = "test-" + newID()
        try await client.authenticate(email: newID() + "@example.test", password: password, register: true)
        do {
            let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let store = AppStore(container: container); store.network = client; store.scope = url.absoluteString + "/" + client.tokens!.userId; store.reload()
            let plan = Plan.starter(); XCTAssertTrue(store.save(plan, kind: "plan", id: plan.id))
            store.start(plan: plan, day: plan.days[0]); store.addWater(250)
            await store.synchronize()
            XCTAssertNil(store.error); XCTAssertTrue(store.pending.isEmpty)
            XCTAssertEqual(store.waterToday, 250); XCTAssertEqual(store.plans.first?.days[0].exercises[0].sets[0].weight, 40)
            XCTAssertEqual(store.summary?.metrics["water_ml"]?.value, 250)
            XCTAssertEqual(store.report?.status, "consent_required")
            let exported = try await client.request("/v1/export"); let root = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
            XCTAssertEqual((root["records"] as? [Any])?.count, 3)
            XCTAssertNotNil(store.records.first { $0.kind == "plan" && $0.recordId == plan.id })
            store.remove(kind: "plan", id: plan.id)
            XCTAssertTrue(store.error?.contains("请新增训练计划") == true)
            await store.synchronize()
            for _ in 0..<100 where store.syncing { try await Task.sleep(for: .milliseconds(30)) }
            await store.synchronize()
            for _ in 0..<100 where store.syncing { try await Task.sleep(for: .milliseconds(30)) }
            XCTAssertFalse(store.syncing); XCTAssertTrue(store.pending.isEmpty); XCTAssertEqual(store.plans.count, 1)
            XCTAssertEqual(store.workouts.count, 1)
            let after = try JSONSerialization.jsonObject(with: await client.request("/v1/records")) as! [String: Any]
            let deleted = (after["records"] as! [[String: Any]]).first { $0["id"] as? String == plan.id }
            XCTAssertEqual(deleted?["deleted"] as? Bool, false)
            _ = try await client.request("/v1/account", method: "DELETE", body: Wire.data(["password": password])); client.forget()
        } catch {
            _ = try? await client.request("/v1/account", method: "DELETE", body: Wire.data(["password": password])); client.forget(); throw error
        }
    }
}
