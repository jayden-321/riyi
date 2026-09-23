import Foundation

extension AppStore {
    /// Three-way merge protects confirmed Watch results from an open phone form's stale copy.
    func saveWorkoutEdits(base: Workout, proposed: Workout) {
        guard var current = workouts.first(where: { $0.id == proposed.id }), current.status == "in_progress" else { return }
        var conflict = false
        for i in proposed.exercises.indices {
            for j in proposed.exercises[i].sets.indices {
                let old = base.exercises[i].sets[j], edited = proposed.exercises[i].sets[j]
                guard CompanionCore.token(old) != CompanionCore.token(edited),
                      let ci = current.exercises.firstIndex(where: { $0.id == proposed.exercises[i].id }),
                      let cj = current.exercises[ci].sets.firstIndex(where: { $0.id == edited.id }) else { continue }
                guard CompanionCore.token(current.exercises[ci].sets[cj]) == CompanionCore.token(old) else { conflict = true; continue }
                if old.status == "pending", edited.status != old.status || edited.startedAt != old.startedAt {
                    let action = edited.status == "completed" ? "complete" : edited.status == "skipped" ? "skip" : "start"
                    let event = CompanionEvent(binding: "phone", sessionId: current.id, exerciseId: current.exercises[ci].id, setId: old.id,
                                               expectedSet: CompanionCore.token(old), action: action,
                                               observedAt: action == "skip" ? (proposed.finishedAt ?? edited.completedAt ?? Date()) : (edited.completedAt ?? edited.startedAt ?? Date()),
                                               weight: edited.actualWeight, reps: edited.actualReps)
                    let receipt = CompanionCore.apply(event, binding: "phone", to: &current, now: Date())
                    if receipt.outcome != "applied" { conflict = true }
                } else if old.status == "pending" {
                    current.exercises[ci].sets[cj] = edited
                } else {
                    current.exercises[ci].sets[cj].note = edited.note
                    current.exercises[ci].sets[cj].rpe = edited.rpe
                }
            }
        }
        if (try? Wire.data(base.feedback)) != (try? Wire.data(proposed.feedback)) { current.feedback = proposed.feedback }
        if base.actualDistanceMeters != proposed.actualDistanceMeters { current.actualDistanceMeters = proposed.actualDistanceMeters }
        if base.volumeTargetKg != proposed.volumeTargetKg { current.volumeTargetKg = proposed.volumeTargetKg }
        if proposed.status != base.status {
            if conflict { error = "手表刚更新了训练，请核对后再次结束" }
            else {
                for i in current.exercises.indices { for j in current.exercises[i].sets.indices where current.exercises[i].sets[j].status == "pending" {
                    current.exercises[i].sets[j].status = "skipped"; current.exercises[i].sets[j].completedAt = proposed.finishedAt ?? Date()
                } }
                current.status = proposed.status; current.finishedAt = proposed.finishedAt; current.restUntil = nil
            }
        }
        if conflict { error = "该组已在另一端更新，已保留确认后的结果，请核对" }
        if save(current, kind: "workout", id: current.id), current.status == "completed" {
            Task { await writeWorkoutToHealth(current, automatic: true) }
        }
    }
}

#if os(iOS)
import HealthKit
import Network
@MainActor final class CompanionPhone {
    private weak var store: AppStore?
    private let transport = CompanionTransport()
    private let pathMonitor = NWPathMonitor()
    private var lastPayload: Data?
    private var lastOfferPayload: Data?
    private var lastDayStatusPayload: Data?
    private var current: CompanionSnapshot?
    private var binding = ""
    private var lastScope: String?
    private var inFlightHealth = Set<String>()
    private var uploadTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    init(store: AppStore) {
        self.store = store
        transport.receive = { [weak self] in self?.receive($0) }
        transport.ready = { [weak self] in self?.publish(force: true) }
        transport.failure = { [weak store] in store?.error = "手表同步：" + $0 }
        store.companionChanged = { [weak self] in self?.publish() }
        store.companionRefreshRequested = { [weak self] in self?.publish(force: true) }
        store.companionStarted = { [weak self] in self?.launchWatch() }
        transport.activate(); publish()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, let store = self.store, store.signedIn, !store.isDemo else { return }
                self.scheduleUpload(scope: store.scope)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.aijiankang.watch-upload-connectivity"))
    }
    func publish(force: Bool = false) {
        guard let store else { return }
        store.expireOvernightWorkouts()
        if lastScope != store.scope {
            // Stable opaque binding allows an old account to resume its quarantined outbox on return.
            let key = "companion.binding." + store.scope
            binding = defaults.string(forKey: key) ?? newID()
            defaults.set(binding, forKey: key)
            lastScope = store.scope
        }
        let today = CompanionCore.dayKey(Date(), zone: store.settings.timezone)
        let offer = todayOffer(store: store)
        let scheduled = store.scheduled("training", date: today)?.1
        let pendingActivity = scheduled?.trainingBlocks.first(where: { block in
            block.activity != nil && store.workout(for: block, on: today) == nil
        })?.activity
        var workout = store.signedIn ? (store.activeWorkout ?? (offer == nil && pendingActivity == nil ? store.workouts.first {
            CompanionCore.dayKey($0.startedAt, zone: store.settings.timezone) == today
        } : nil)) : nil
        workout?.companionReceipts = nil // Receipts travel individually, never inflate snapshots.
        // Legacy guest/demo fixtures are not consent to start a real HealthKit workout.
        if workout?.synthetic == nil { workout?.synthetic = store.isDemo }
        let rest = scheduled?.rest ?? false
        let dayStatus = store.signedIn ? CompanionDayStatus(date: today, timezone: store.settings.timezone,
            kind: rest ? "rest" : scheduled?.trainingBlocks.isEmpty == false || offer != nil ? "training" : "unplanned",
            activityName: pendingActivity?.name) : nil
        let payload = try? Wire.data(workout), offerPayload = try? Wire.data(offer), dayPayload = try? Wire.data(dayStatus)
        let changed = payload != lastPayload || offerPayload != lastOfferPayload || dayPayload != lastDayStatusPayload || current?.binding != binding
        if changed {
            let revision = max(defaults.integer(forKey: "companion.revision") + 1, Int(Date().timeIntervalSince1970 * 1000))
            defaults.set(revision, forKey: "companion.revision")
            current = CompanionSnapshot(binding: binding, revision: revision, workout: workout, offer: offer, timezone: store.settings.timezone, today: dayStatus)
            lastPayload = payload; lastOfferPayload = offerPayload; lastDayStatusPayload = dayPayload
        }
        if force || changed { transport.send(CompanionPacket(snapshot: current), latest: true) }
    }
    private func todayOffer(store: AppStore) -> CompanionStartOffer? {
        guard store.signedIn else { return nil }
        let date = DayKey.string(Date(), zone: store.settings.timezone)
        if let (_, scheduled) = store.scheduled("training", date: date), scheduled.rest { return nil }
        guard let plan = store.todayPlan, let day = plan.days.first else { return nil }
        let blockID = store.trainingBlocks(on: date).first(where: { $0.plan?.id == plan.id && store.workout(for: $0, on: date) == nil })?.id
        return CompanionStartOffer(date: date, timezone: store.settings.timezone, plan: plan, day: day, blockId: blockID)
    }
    private func receive(_ packet: CompanionPacket) {
        guard let store else { return }
        if let request = packet.startRequest { handleStart(request, store: store) }
        if packet.request { publish(force: true) }
        if let event = packet.event {
            guard store.signedIn, event.binding == binding else {
                transport.send(CompanionPacket(receipt: CompanionReceipt(event: event, outcome: "wrong_account", committedAt: Date()))); return
            }
            guard var workout = store.workouts.first(where: { $0.id == event.sessionId }) else {
                transport.send(CompanionPacket(receipt: CompanionReceipt(event: event, outcome: "wrong_session", committedAt: Date()))); return
            }
            let receipt = CompanionCore.applyLateEvent(event, binding: binding, to: &workout,
                zone: store.settings.timezone, anotherActive: store.activeWorkout?.id != workout.id && store.activeWorkout != nil,
                now: Date())
            // save() commits workout + receipt + existing server outbox atomically before ACK.
            guard store.save(workout, kind: "workout", id: workout.id) else { return }
            if event.action == "finish_activity", receipt.outcome == "applied" {
                Task { await store.writeWorkoutToHealth(workout, automatic: true) }
            }
            publish(force: true)
            transport.send(CompanionPacket(snapshot: current, receipt: receipt))
        }
        if let batch = packet.heart, batch.binding == binding, store.signedIn,
           store.workouts.contains(where: { $0.id == batch.sessionId }), !inFlightHealth.contains(batch.id) {
            guard batch.samples.count <= 100, batch.samples.allSatisfy({ sample in
                guard ["heart_rate", "workout"].contains(sample.type), UUID(uuidString: sample.healthkitUuid) != nil else { return false }
                if sample.deleted { return true }
                return (sample.type == "workout" || sample.value?.isFinite == true) && sample.startAt != nil && sample.endAt != nil && sample.startAt! <= sample.endAt! && !sample.sourceBundleId.isEmpty
            }) else { return }
            let scope = store.scope, upload = store.settings.healthConsent && !store.isDemo && !store.healthUploadPaused
            inFlightHealth.insert(batch.id)
            if batch.samples.contains(where: { $0.type == "workout" }) { store.markHealthWorkoutSaved(batch.sessionId) }
            Task { [weak self] in
                defer { self?.inFlightHealth.remove(batch.id) }
                do {
                    let worker = await store.healthStorage.value
                    guard store.scope == scope, self?.binding == batch.binding else { return }
                    try await worker.persist(samples: batch.samples, anchor: nil, cursorKey: scope + "/watch-heart", scope: scope, upload: upload)
                    self?.transport.send(CompanionPacket(heartAck: batch.id))
                    // Persist locally before ACK; cloud upload runs independently and keeps its own retry outbox.
                    if store.scope == scope && upload { self?.scheduleUpload(scope: scope) }
                } catch { store.error = "手表心率保存失败，将保留并重试" }
            }
        }
    }
    private func handleStart(_ request: CompanionStartRequest, store: AppStore) {
        // The deterministic workout ID is the idempotency key across WC retries and app relaunches.
        if request.binding == binding, let existing = store.workouts.first(where: { $0.id == request.id }) {
            transport.send(CompanionPacket(startReceipt: CompanionStartReceipt(requestId: request.id, outcome: "started", workoutId: existing.id)))
            publish(force: true); return
        }
        store.expireOvernightWorkouts()
        let offer = todayOffer(store: store)
        let outcome = CompanionCore.startOutcome(request, offer: offer, binding: binding,
                                                 active: store.activeWorkout, now: Date())
        guard outcome == "start", let offer else {
            transport.send(CompanionPacket(startReceipt: CompanionStartReceipt(requestId: request.id, outcome: outcome, workoutId: nil)))
            publish(force: true); return
        }
        var workout = Workout(plan: offer.plan, day: offer.day, scheduledBlockId: offer.blockId)
        workout.id = request.id; workout.synthetic = store.isDemo
        guard store.save(workout, kind: "workout", id: workout.id) else { return } // No ACK before durable commit.
        publish(force: true)
        transport.send(CompanionPacket(snapshot: current,
            startReceipt: CompanionStartReceipt(requestId: request.id, outcome: "started", workoutId: workout.id)))
    }
    private func scheduleUpload(scope: String) {
        guard uploadTask == nil else { return }
        uploadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self else { return }; self.uploadTask = nil
            guard let store = self.store, store.scope == scope, !store.isDemo,
                  store.settings.healthConsent, !store.healthUploadPaused else { return }
            await store.synchronize(showErrors: false)
        }
    }
    private func launchWatch() {
        publish(force: true)
        guard let store, store.activeWorkout?.synthetic != true else { return }
        guard let workout = store.activeWorkout else { return }
        let config = healthWorkoutConfiguration(for: workout)
        HKHealthStore().startWatchApp(with: config) { [weak store] success, error in
            if !success { Task { @MainActor in store?.error = "手表未自动打开：\(error?.localizedDescription ?? "请在手表打开日益")。训练已在手机保存，手表打开后会同步。" } }
        }
    }
}
#endif
