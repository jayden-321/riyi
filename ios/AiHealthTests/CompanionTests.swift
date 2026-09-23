import XCTest
import SwiftData
@testable import AiHealth

final class CompanionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000.123)
    func fixture() -> Workout {
        let plan = Plan.starter(); var workout = Workout(plan: plan, day: plan.days[0]); workout.startedAt = now.addingTimeInterval(-60); return workout
    }
    func event(_ workout: Workout, _ action: String, at: Date? = nil, index: Int = 0) -> CompanionEvent {
        let e = workout.exercises[0], s = e.sets[index]
        return CompanionEvent(binding: "paired", sessionId: workout.id, exerciseId: e.id, setId: s.id, expectedSet: CompanionCore.token(s), action: action, observedAt: at ?? now, weight: 42.5, reps: 8)
    }
    func testRetryAfterLostAcknowledgementAndRestartDoesNotDuplicate() throws {
        var w = fixture(); let start = event(w, "start")
        let first = CompanionCore.apply(start, binding: "paired", to: &w, now: now)
        w = try Wire.read(Wire.data(w))
        let repeated = CompanionCore.apply(start, binding: "paired", to: &w, now: now.addingTimeInterval(10))
        XCTAssertEqual(first.outcome, "applied"); XCTAssertEqual(repeated.committedAt, first.committedAt)
        XCTAssertEqual(w.companionReceipts?.count, 1)
        var altered = start; altered.action = "skip"
        XCTAssertEqual(CompanionCore.apply(altered, binding: "paired", to: &w, now: now).outcome, "id_reused")
        XCTAssertEqual(w.exercises[0].sets[0].status, "pending")
    }
    func testOfflineStartCompleteQueueSurvivesSerialization() throws {
        var replica = CompanionReplica(snapshot: CompanionSnapshot(binding: "paired", revision: 1, workout: fixture()))
        replica.events.append(event(replica.projected!, "start"))
        replica.events.append(event(replica.projected!, "complete", at: now.addingTimeInterval(12)))
        replica = try Wire.read(Wire.data(replica))
        var phone = replica.snapshot!.workout!
        for command in replica.events {
            let ack = CompanionCore.apply(command, binding: "paired", to: &phone, now: now.addingTimeInterval(20))
            XCTAssertEqual(ack.outcome, "applied")
            replica.acknowledge(ack)
        }
        XCTAssertTrue(replica.events.isEmpty); XCTAssertEqual(phone.completedSets, 1)
        XCTAssertEqual(phone.exercises[0].sets[0].actualWeight, 42.5)
        XCTAssertEqual(phone.exercises[0].sets[0].plannedWeight, 40)
        XCTAssertEqual(CompanionCore.remaining(phone, now: now.addingTimeInterval(40)), 62)
        XCTAssertEqual(CompanionCore.remaining(phone, now: now.addingTimeInterval(200)), 0)
    }
    func testConcurrentCompletionSkipFirstConfirmationWins() {
        var w = fixture(); _ = CompanionCore.apply(event(w, "start"), binding: "paired", to: &w, now: now)
        let finish = event(w, "complete", at: now.addingTimeInterval(10)), skip = event(w, "skip", at: now.addingTimeInterval(11))
        XCTAssertEqual(CompanionCore.apply(finish, binding: "paired", to: &w, now: now.addingTimeInterval(12)).outcome, "applied")
        XCTAssertEqual(CompanionCore.apply(skip, binding: "paired", to: &w, now: now.addingTimeInterval(12)).outcome, "conflict")
        XCTAssertEqual(w.exercises[0].sets[0].actualReps, 8)
    }
    func testDifferentSetEditsMergeButOnlyOneSetRuns() {
        var w = fixture(); let one = event(w, "start"), two = event(w, "start", index: 1), skip = event(w, "skip", index: 2)
        XCTAssertEqual(CompanionCore.apply(one, binding: "paired", to: &w, now: now).outcome, "applied")
        XCTAssertEqual(CompanionCore.apply(two, binding: "paired", to: &w, now: now).outcome, "conflict")
        XCTAssertEqual(CompanionCore.apply(skip, binding: "paired", to: &w, now: now).outcome, "applied")
    }
    func testLateEventCannotReopenEndedWorkoutOrCrossAccount() {
        var w = fixture(); let start = event(w, "start")
        XCTAssertEqual(CompanionCore.apply(start, binding: "other", to: &w, now: now).outcome, "wrong_account")
        XCTAssertNil(w.companionReceipts)
        w.status = "completed"; w.finishedAt = now
        XCTAssertEqual(CompanionCore.apply(start, binding: "paired", to: &w, now: now).outcome, "session_finished")
    }
    func testInvalidTimestampAndMissingActualCannotBecomeZero() {
        var w = fixture()
        XCTAssertEqual(CompanionCore.apply(event(w, "start", at: now.addingTimeInterval(60)), binding: "paired", to: &w, now: now).outcome, "invalid_time")
        _ = CompanionCore.apply(event(w, "start"), binding: "paired", to: &w, now: now)
        var missing = event(w, "complete"); missing.weight = nil
        XCTAssertEqual(CompanionCore.apply(missing, binding: "paired", to: &w, now: now).outcome, "invalid_result")
        XCTAssertNil(w.exercises[0].sets[0].actualWeight)
    }
    func testOutOfOrderSnapshotsAndUnknownAcknowledgementsIgnored() {
        var replica = CompanionReplica(snapshot: CompanionSnapshot(binding: "paired", revision: 20, workout: fixture()))
        let pending = event(replica.projected!, "start"); replica.events = [pending]
        replica.receive(CompanionSnapshot(binding: "old", revision: 19, workout: nil))
        XCTAssertEqual(replica.snapshot?.binding, "paired")
        var altered = pending; altered.reps = 99
        replica.acknowledge(CompanionReceipt(event: altered, outcome: "applied", committedAt: now))
        XCTAssertEqual(replica.events.count, 1)
        replica.receive(CompanionSnapshot(binding: "different", revision: 21, workout: nil))
        XCTAssertEqual(replica.events.count, 1); XCTAssertNil(replica.projected)
    }
    func testHeartSampleUsesObservedTimeAndHalfOpenIntervals() {
        var w = fixture(); _ = CompanionCore.apply(event(w, "start"), binding: "paired", to: &w, now: now)
        _ = CompanionCore.apply(event(w, "complete", at: now.addingTimeInterval(10)), binding: "paired", to: &w, now: now.addingTimeInterval(10))
        var sample = HealthSample(healthkitUuid: newID(), type: "heart_rate", value: 120, unit: "bpm", startAt: now.addingTimeInterval(5), endAt: now.addingTimeInterval(5))
        XCTAssertEqual(CompanionCore.associations(sample: sample, workout: w).first?.1, w.exercises[0].sets[0].id)
        sample.startAt = now.addingTimeInterval(10)
        XCTAssertTrue(CompanionCore.associations(sample: sample, workout: w).isEmpty)
    }
    @MainActor func testStalePhoneFormCannotOverwriteWatchResult() throws {
        let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: container); store.scope = "local-demo"
        let base = fixture(); var watched = base
        _ = CompanionCore.apply(event(watched, "start"), binding: "paired", to: &watched, now: now)
        _ = CompanionCore.apply(event(watched, "complete"), binding: "paired", to: &watched, now: now)
        XCTAssertTrue(store.save(watched, kind: "workout", id: watched.id))
        var stale = base; stale.exercises[0].sets[0].status = "skipped"
        store.saveWorkoutEdits(base: base, proposed: stale)
        XCTAssertEqual(store.workouts.first?.exercises[0].sets[0].status, "completed")
        XCTAssertEqual(store.workouts.first?.exercises[0].sets[0].actualWeight, 42.5)
        XCTAssertNotNil(store.error)
    }
    func testHealthKitReflowDedupMetadataEnrichmentAndDeleteWins() async throws {
        let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let worker = HealthStorage(modelContainer: container)
        let id = newID(); var sample = HealthSample(healthkitUuid: id, type: "heart_rate", value: 123, unit: "bpm", startAt: now, endAt: now, sourceBundleId: "test.synthetic")
        try await worker.persist(samples: [sample], anchor: nil, cursorKey: "a/hk", scope: "a", upload: false)
        sample.metadataJson["watch_session_id"] = .string("synthetic")
        try await worker.persist(samples: [sample], anchor: nil, cursorKey: "a/watch", scope: "a", upload: false)
        try await worker.persist(samples: [sample], anchor: nil, cursorKey: "a/hk", scope: "a", upload: false)
        let summary = try await worker.overview(scope: "a", zone: "UTC", now: now, water: 0, since: now.addingTimeInterval(-60))
        XCTAssertEqual(summary.count, 1)
        XCTAssertNotNil(summary.latest.first?.metadataJson["watch_session_id"])
        var deletion = sample; deletion.deleted = true
        try await worker.persist(samples: [deletion, sample], anchor: nil, cursorKey: "a/watch", scope: "a", upload: false)
        let deleted = try await worker.overview(scope: "a", zone: "UTC", now: now, water: 0, since: now.addingTimeInterval(-60))
        XCTAssertEqual(deleted.count, 0)
    }
    func testOldUploadAcknowledgementDoesNotHideNewWatchContext() async throws {
        let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let worker = HealthStorage(modelContainer: container)
        var sample = HealthSample(healthkitUuid: newID(), type: "heart_rate", value: 123, unit: "bpm", startAt: now, endAt: now, sourceBundleId: "test.synthetic")
        let since = now.addingTimeInterval(-60)
        try await worker.persist(samples: [sample], anchor: nil, cursorKey: "a/hk", scope: "a", upload: true)
        _ = try await worker.startBackfill(scope: "a", restart: false, since: since)
        let old = try await worker.nextUpload(scope: "a", since: since)!
        sample.metadataJson["watch_session_id"] = .string("synthetic")
        try await worker.persist(samples: [sample], anchor: nil, cursorKey: "a/watch", scope: "a", upload: false)
        _ = try await worker.acknowledge(scope: "a", batch: old)
        _ = try await worker.prepareNextBatch(scope: "a", since: since)
        let next = try await worker.nextUpload(scope: "a", since: since)
        XCTAssertEqual(next?.count, 1)
        let payload: [String: [HealthSample]] = try Wire.read(next!.payload)
        XCTAssertNotNil(payload["samples"]?.first?.metadataJson["watch_session_id"])
    }

    func testLegacyDateEncodingCanFinishUploadAfterWatchUpgrade() async throws {
        let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let worker = HealthStorage(modelContainer: container)
        let time = Date(timeIntervalSince1970: 1_790_000_000)
        let sample = HealthSample(healthkitUuid: newID(), type: "heart_rate", value: 123, unit: "bpm", startAt: time, endAt: time, sourceBundleId: "test.synthetic")
        let encoder = Wire.encoder(); encoder.dateEncodingStrategy = .iso8601
        let context = ModelContext(container)
        context.insert(LocalHealthRecord(scope: "legacy", sample: sample, payload: try encoder.encode(sample))); try context.save()
        _ = try await worker.startBackfill(scope: "legacy", restart: false, since: time.addingTimeInterval(-1))
        _ = try await worker.prepareNextBatch(scope: "legacy", since: time.addingTimeInterval(-1))
        let batch = try await worker.nextUpload(scope: "legacy", since: time.addingTimeInterval(-1))!
        _ = try await worker.acknowledge(scope: "legacy", batch: batch)
        let progress = try await worker.prepareNextBatch(scope: "legacy", since: time.addingTimeInterval(-1))
        XCTAssertTrue(progress.finished); XCTAssertEqual(progress.pendingBatches, 0)
    }

}

extension CompanionTests {
    func testWatchStartRequestValidatesCurrentPlanAccountAndActiveSession() {
        let plan = Plan.starter(), day = plan.days[0]
        let startTime = ISO8601DateFormatter().date(from: "2026-09-23T09:00:00+08:00")!
        let offer = CompanionStartOffer(date: "2026-09-23", timezone: "Asia/Shanghai", plan: plan, day: day)
        let request = CompanionStartRequest(binding: "paired", date: offer.date, planId: plan.id, dayId: day.id, observedAt: startTime)
        XCTAssertEqual(CompanionCore.startOutcome(request, offer: offer, binding: "paired", active: nil, now: startTime), "start")
        XCTAssertEqual(CompanionCore.startOutcome(request, offer: offer, binding: "other", active: nil, now: startTime), "wrong_account")
        XCTAssertEqual(CompanionCore.startOutcome(request, offer: nil, binding: "paired", active: nil, now: startTime), "stale_plan")
        XCTAssertEqual(CompanionCore.startOutcome(request, offer: offer, binding: "paired", active: fixture(), now: startTime), "already_active")
        XCTAssertEqual(CompanionCore.startOutcome(request, offer: offer, binding: "paired", active: nil, now: startTime.addingTimeInterval(601)), "expired")
        var wrongDay = request; wrongDay.date = "2026-09-22"
        XCTAssertEqual(CompanionCore.startOutcome(wrongDay, offer: offer, binding: "paired", active: nil, now: startTime), "stale_plan")
    }
    func testWatchStartOutboxSurvivesRestartAndClearsOnlyMatchingReceipt() throws {
        let plan = Plan.starter()
        let request = CompanionStartRequest(binding: "paired", date: "2026-09-23", planId: plan.id, dayId: plan.days[0].id, observedAt: now)
        var replica = CompanionReplica(snapshot: CompanionSnapshot(binding: "paired", revision: 2, workout: nil))
        replica.pendingStart = request
        replica = try Wire.read(Wire.data(replica))
        replica.acknowledgeStart(CompanionStartReceipt(requestId: newID(), outcome: "started", workoutId: request.id))
        XCTAssertEqual(replica.pendingStart?.id, request.id)
        replica.acknowledgeStart(CompanionStartReceipt(requestId: request.id, outcome: "started", workoutId: request.id))
        XCTAssertNil(replica.pendingStart)
    }
    @MainActor func testOvernightAbandonedWorkoutClosesAtLastActionAndAllowsToday() throws {
        let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = AppStore(container: container); store.scope = "local-demo"; store.settings.timezone = "Asia/Shanghai"
        let plan = Plan.starter(); var old = Workout(plan: plan, day: plan.days[0])
        let begin = ISO8601DateFormatter().date(from: "2026-09-22T20:00:00+08:00")!
        let last = ISO8601DateFormatter().date(from: "2026-09-22T21:00:00+08:00")!
        let today = ISO8601DateFormatter().date(from: "2026-09-23T09:00:00+08:00")!
        old.startedAt = begin; old.exercises[0].sets[0].status = "completed"
        old.exercises[0].sets[0].startedAt = begin; old.exercises[0].sets[0].completedAt = last
        XCTAssertTrue(store.save(old, kind: "workout", id: old.id))
        store.expireOvernightWorkouts(now: today)
        let ended = try XCTUnwrap(store.workouts.first { $0.id == old.id })
        XCTAssertEqual(ended.status, "cancelled")
        XCTAssertEqual(ended.finishedAt, last)
        XCTAssertEqual(ended.completedSets, 1)
        XCTAssertEqual(ended.exercises[0].sets[1].status, "pending")
        XCTAssertNil(store.activeWorkout)
        // Starting with a new deterministic request ID creates a distinct today session.
        var new = Workout(plan: plan, day: plan.days[0]); new.id = newID(); new.startedAt = today
        XCTAssertTrue(store.save(new, kind: "workout", id: new.id))
        XCTAssertEqual(store.activeWorkout?.id, new.id)
    }
    func testRealCrossMidnightActivityIsNotClosed() {
        let plan = Plan.starter(); var workout = Workout(plan: plan, day: plan.days[0])
        workout.startedAt = ISO8601DateFormatter().date(from: "2026-09-22T23:40:00+08:00")!
        workout.exercises[0].sets[0].startedAt = ISO8601DateFormatter().date(from: "2026-09-23T00:05:00+08:00")!
        let now = ISO8601DateFormatter().date(from: "2026-09-23T00:20:00+08:00")!
        XCTAssertFalse(CompanionCore.isOvernightStale(workout, zone: "Asia/Shanghai", now: now))
    }
}

extension CompanionTests {
    func testLateOfflineWatchResultSurvivesAutomaticOvernightClose() {
        var workout = fixture()
        let start = event(workout, "start", at: now)
        let closeTime = now.addingTimeInterval(4 * 3600)
        workout.status = "cancelled"; workout.finishedAt = now; workout.autoExpiredAt = closeTime
        let started = CompanionCore.applyLateEvent(start, binding: "paired", to: &workout,
            zone: "UTC", anotherActive: true, now: closeTime)
        XCTAssertEqual(started.outcome, "applied")
        XCTAssertEqual(workout.status, "cancelled")
        let finish = event(workout, "complete", at: now.addingTimeInterval(10))
        let completed = CompanionCore.applyLateEvent(finish, binding: "paired", to: &workout,
            zone: "UTC", anotherActive: true, now: closeTime)
        XCTAssertEqual(completed.outcome, "applied")
        XCTAssertEqual(workout.completedSets, 1)
        XCTAssertEqual(workout.finishedAt, now.addingTimeInterval(10))
        let repeated = CompanionCore.applyLateEvent(finish, binding: "paired", to: &workout,
            zone: "UTC", anotherActive: true, now: closeTime.addingTimeInterval(5))
        XCTAssertEqual(repeated.outcome, "applied")
        XCTAssertEqual(workout.completedSets, 1)
        workout.autoExpiredAt = nil
        XCTAssertEqual(CompanionCore.applyLateEvent(event(workout, "skip", index: 1), binding: "paired", to: &workout,
            zone: "UTC", anotherActive: true, now: closeTime).outcome, "session_finished")
    }
}
