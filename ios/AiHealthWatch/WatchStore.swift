import SwiftUI
import Observation

@MainActor @Observable final class WatchStore {
    static let shared = WatchStore()
    var replica = CompanionReplica()
    var error: String?
    var health = WatchWorkoutHealth()
    @ObservationIgnored private let transport = CompanionTransport()
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var retry: Timer?
    @ObservationIgnored var demo = false
    @ObservationIgnored var startRequested = false
    var displayWorkout: Workout? {
        guard let snapshot = replica.snapshot, let workout = replica.projected else { return nil }
        return CompanionCore.isCurrentWorkout(workout, zone: snapshot.timezone ?? workout.timezone, now: Date()) ? workout : nil
    }
    var todayStatus: CompanionDayStatus? {
        guard let status = replica.snapshot?.today,
              status.date == CompanionCore.dayKey(Date(), zone: status.timezone) else { return nil }
        return status
    }
    var todayOffer: CompanionStartOffer? {
        guard let offer = replica.snapshot?.offer,
              offer.date == CompanionCore.dayKey(Date(), zone: offer.timezone) else { return nil }
        return offer
    }
    var canStartToday: Bool { !demo && displayWorkout?.status != "in_progress" && replica.pendingStart == nil && todayOffer != nil }
    func startToday() {
        guard canStartToday, let snapshot = replica.snapshot, let offer = todayOffer else { return }
        let request = CompanionStartRequest(binding: snapshot.binding, date: offer.date,
                                            planId: offer.plan.id, dayId: offer.day.id, observedAt: Date())
        var next = replica; next.pendingStart = request; next.message = "已发送开始请求，等待 iPhone 确认"
        if commit(next) { flush() }
    }
    @ObservationIgnored private var testActionPerformed = false
    @ObservationIgnored private var testHeartPerformed = false
    #if DEBUG
    private var deferSending: Bool { ProcessInfo.processInfo.arguments.contains("--watch-defer-send") }
    #else
    private var deferSending: Bool { false }
    #endif
    private init() {
        file = URL.applicationSupportDirectory.appendingPathComponent("companion-state.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) { replica = try Wire.read(Data(contentsOf: file)) }
        } catch { self.error = "训练记录读取失败，请保留 App 数据" }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--watch-rest-demo") {
            demo = true
            let plan = Plan.starter()
            var old = Workout(plan: plan, day: plan.days[0])
            old.startedAt = Date().addingTimeInterval(-86400); old.status = "cancelled"
            let today = CompanionDayStatus(date: CompanionCore.dayKey(Date(), zone: old.timezone), timezone: old.timezone, kind: "rest")
            replica = CompanionReplica(snapshot: CompanionSnapshot(binding: "synthetic", revision: 1, workout: old, today: today))
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--watch-demo") {
            demo = true
            let plan = Plan.starter(); var workout = Workout(plan: plan, day: plan.days[0])
            workout.startedAt = Date().addingTimeInterval(-90)
            replica = CompanionReplica(snapshot: CompanionSnapshot(binding: "synthetic", revision: 1, workout: workout))
            replica.message = "合成数据演示 · 未连接健康数据"
            return
        }
        #endif
        transport.receive = { [weak self] in self?.receive($0) }
        transport.ready = { [weak self] in self?.flush() }
        transport.failure = { [weak self] in self?.error = $0 }
        health.samples = { [weak self] binding, session, samples, anchor in self?.enqueue(binding: binding, session: session, samples: samples, anchor: anchor) ?? false }
        health.anchor = { [weak self] binding, session in self?.replica.healthAnchors?[binding + "/" + session] }
        transport.activate(); health.recover()
        retry = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in self?.flush() } }
    }
    @discardableResult private func commit(_ next: CompanionReplica) -> Bool {
        if demo { replica = next; return true }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Wire.data(next).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            replica = next; return true
        } catch { self.error = "记录保存失败，请勿退出：\(error.localizedDescription)"; return false }
    }
    func act(_ action: String, weight: Double? = nil, reps: Int? = nil) {
        guard let snapshot = replica.snapshot, let workout = replica.projected,
              workout.status == "in_progress", let (exercise, set) = CompanionCore.current(workout) else { return }
        let event = CompanionEvent(binding: snapshot.binding, sessionId: workout.id, exerciseId: exercise.id,
                                   setId: set.id, expectedSet: CompanionCore.token(set), action: action, observedAt: Date(), weight: weight, reps: reps)
        var next = replica
        if demo {
            var work = workout; let receipt = CompanionCore.apply(event, binding: snapshot.binding, to: &work, now: Date())
            next.snapshot?.workout = work; next.message = receipt.outcome == "applied" ? "演示：操作已保存" : receipt.outcome
        } else { next.events.append(event); next.message = "已保存到手表，等待 iPhone 确认" }
        if commit(next) { flush() }
    }
    func flush() {
        guard !demo else { return }
        if let snapshot = replica.snapshot { health.reconcile(binding: snapshot.binding, workout: displayWorkout) }
        transport.send(CompanionPacket(request: true), latest: true)
        guard let binding = replica.snapshot?.binding else { return }
        // One event in flight guarantees dependency order even if WC delivery paths race.
        if let start = replica.pendingStart, start.binding == binding { transport.send(CompanionPacket(startRequest: start)) }
        if !deferSending, let first = replica.events.first(where: { $0.binding == binding }) { transport.send(CompanionPacket(event: first)) }
        if let first = replica.hearts.first(where: { $0.binding == binding }) { transport.send(CompanionPacket(heart: first)) }
    }
    private func receive(_ packet: CompanionPacket) {
        var next = replica
        if let snapshot = packet.snapshot { next.receive(snapshot) }
        if let receipt = packet.receipt { next.acknowledge(receipt) }
        if let receipt = packet.startReceipt { next.acknowledgeStart(receipt) }
        if let id = packet.heartAck { next.hearts.removeAll { $0.id == id }; next.lastHealthAcknowledgementId = id }
        guard commit(next) else { return }
        if let snapshot = next.snapshot {
            health.reconcile(binding: snapshot.binding, workout: displayWorkout)
            startRequested = false
        }
        if packet.receipt != nil || packet.heartAck != nil || packet.startReceipt != nil { flush() }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if !testHeartPerformed, args.contains("--watch-test-heart"), let snapshot = replica.snapshot, let workout = snapshot.workout {
            testHeartPerformed = true
            let observed = (workout.exercises.first?.sets.first?.startedAt ?? workout.startedAt).addingTimeInterval(2)
            let sample = HealthSample(healthkitUuid: "00000000-0000-4000-8000-000000000007", type: "heart_rate", value: 123, unit: "bpm", startAt: observed, endAt: observed, sourceName: "Synthetic Watch Test", sourceBundleId: "test.synthetic.watch", deviceName: "Simulator")
            _ = enqueue(binding: snapshot.binding, session: workout.id, samples: [sample], anchor: nil)
        }
        if !testActionPerformed, let index = args.firstIndex(of: "--watch-test-action"), index + 1 < args.count,
           let workout = replica.projected, workout.status == "in_progress", CompanionCore.current(workout) != nil {
            testActionPerformed = true; act(args[index + 1], weight: 42.5, reps: 8)
        }
        #endif
    }
    private func enqueue(binding: String, session: String, samples: [HealthSample], anchor: Data?) -> Bool {
        var next = replica
        for offset in stride(from: 0, to: samples.count, by: 50) {
            next.hearts.append(CompanionHeartBatch(binding: binding, sessionId: session, samples: Array(samples[offset..<min(offset + 50, samples.count)])))
        }
        if let anchor { var anchors = next.healthAnchors ?? [:]; anchors[binding + "/" + session] = anchor; next.healthAnchors = anchors }
        let saved = commit(next); if saved { flush() }; return saved
    }
    func enableHealth() async {
        guard !demo, let snapshot = replica.snapshot, let workout = snapshot.workout, workout.status == "in_progress" else { return }
        health.reconcile(binding: snapshot.binding, workout: workout); health.retryAuthorization()
    }
}
