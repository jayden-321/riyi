import Foundation
import HealthKit
import Observation

@MainActor @Observable final class WatchWorkoutHealth: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    var bpm: Double?
    var distanceMeters: Double?
    var observedAt: Date?
    var status = "训练开始后自动记录心率"
    var needsAuthorization = false
    var zoneText: String?
    var active = false
    @ObservationIgnored var samples: ((String, String, [HealthSample], Data?) -> Bool)?
    @ObservationIgnored var anchor: ((String, String) -> Data?)?
    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var query: HKAnchoredObjectQuery?
    @ObservationIgnored private var rawTask: Task<Void, Never>?
    @ObservationIgnored private var rawFailed = false
    @ObservationIgnored private var binding = ""
    @ObservationIgnored private var workout: Workout?
    @ObservationIgnored private var collectionStartedAt: Date?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var finishing = false
    @ObservationIgnored private var expectedEnd = false
    @ObservationIgnored private var desired: Context?
    @ObservationIgnored private var nextAttempt = Date.distantPast
    private let heart = HKQuantityType(.heartRate)
    private let unit = HKUnit.count().unitDivided(by: .minute())
    private func distanceType(for workout: Workout) -> HKQuantityType? {
        switch workout.activity?.resolvedSport {
        case "swimming": HKQuantityType(.distanceSwimming)
        case "cycling": HKQuantityType(.distanceCycling)
        case "walking", "running", "hiking": HKQuantityType(.distanceWalkingRunning)
        default: nil
        }
    }
    private var contextURL: URL { URL.applicationSupportDirectory.appendingPathComponent("active-workout.json") }
    struct Context: Codable { var binding: String; var workout: Workout; var stoppedAt: Date?; var collectionStartedAt: Date? }
    func start(binding: String, workout: Workout) async {
        guard !active, !starting, !finishing, workout.synthetic == false, Date() >= nextAttempt else { return }
        starting = true; defer { starting = false }
        guard HKHealthStore.isHealthDataAvailable() else { status = "此设备无法读取心率"; return }
        do {
            var writable: Set<HKSampleType> = [HKObjectType.workoutType(), HKQuantityType(.activeEnergyBurned)]
            var readable: Set<HKObjectType> = [heart, HKObjectType.workoutType()]
            if let distanceType = distanceType(for: workout) { writable.insert(distanceType); readable.insert(distanceType) }
            try await store.requestAuthorization(toShare: writable, read: readable)
            guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
                needsAuthorization = true; nextAttempt = Date().addingTimeInterval(60); status = "需要在健康权限中允许记录训练"; return
            }
            guard desired?.binding == binding, desired?.workout.id == workout.id else { return }
            needsAuthorization = false
            self.binding = binding; self.workout = workout; distanceMeters = nil; collectionStartedAt = Date()
            try FileManager.default.createDirectory(at: contextURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Wire.data(Context(binding: binding, workout: workout, collectionStartedAt: collectionStartedAt)).write(to: contextURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let config = healthWorkoutConfiguration(for: workout)
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            configure(session)
            session.prepare()
            let start = collectionStartedAt ?? Date(); session.startActivity(with: start)
            try await builder!.beginCollection(at: start)
            var metadata: [String: Any] = [HKMetadataKeyExternalUUID: workout.id, "riyi_session_id": workout.id]
            if workout.activity?.resolvedSport == "swimming" {
                let location: HKWorkoutSwimmingLocationType = workout.activity?.swimLocation == "pool" ? .pool : .openWater
                metadata[HKMetadataKeySwimmingLocationType] = NSNumber(value: location.rawValue)
                if let length = workout.activity?.poolLengthMeters { metadata[HKMetadataKeyLapLength] = HKQuantity(unit: .meter(), doubleValue: length) }
            }
            try await builder!.addMetadata(metadata)
            active = true; status = "等待心率样本（以系统授权为准）"; observeRaw()
        } catch { nextAttempt = Date().addingTimeInterval(20); status = "心率启动失败：\(error.localizedDescription)"; session?.end(); session = nil; builder = nil }
    }
    private func configure(_ session: HKWorkoutSession) {
        self.session = session; expectedEnd = false; session.delegate = self
        let builder = session.associatedWorkoutBuilder(); self.builder = builder; builder.delegate = self
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: session.workoutConfiguration)
    }
    func recover() {
        guard !active, !starting, FileManager.default.fileExists(atPath: contextURL.path) else { return }
        starting = true
        store.recoverActiveWorkoutSession { [weak self] recovered, error in
            Task { @MainActor in
                guard let self else { return }
                defer { self.starting = false; if let desired = self.desired { self.reconcile(binding: desired.binding, workout: desired.workout) } }
                guard let data = try? Data(contentsOf: self.contextURL), let context: Context = try? Wire.read(data) else {
                    recovered?.end(); self.status = "恢复训练缺少关联信息，请重新开始心率记录"; return
                }
                self.binding = context.binding; self.workout = context.workout; self.collectionStartedAt = context.collectionStartedAt
                if let recovered {
                    self.configure(recovered); self.active = true; self.status = "已恢复心率记录"; self.observeRaw()
                    if recovered.state == .stopped { await self.finish(at: context.stoppedAt ?? Date()) }
                } else {
                    self.observeRaw(end: context.stoppedAt ?? Date())
                    self.status = "已恢复原始心率待同步记录"
                }
            }
        }
    }
    func reconcile(binding: String, workout: Workout?) {
        desired = workout.flatMap { $0.status == "in_progress" && $0.synthetic == false ? Context(binding: binding, workout: $0) : nil }
        if workout?.synthetic == true { status = "合成训练演示，不读取健康数据" }
        if active {
            guard let desired, self.binding == desired.binding, self.workout?.id == desired.workout.id else {
                session?.stopActivity(with: Date()); return
            }
            self.workout = workout
            if rawFailed { observeRaw() }
        } else if let desired {
            Task { await start(binding: desired.binding, workout: desired.workout) }
        }
    }
    func retryAuthorization() { nextAttempt = .distantPast; if let desired { reconcile(binding: desired.binding, workout: desired.workout) } }
    func stop() {
        if session?.state == .stopped { Task { await finish(at: session?.endDate ?? Date()) } }
        else { session?.stopActivity(with: Date()) }
    }
    private func finish(at date: Date) async {
        guard !finishing, let builder, let session else { return }; finishing = true
        defer { finishing = false }
        do {
            if let workout {
                try Wire.data(Context(binding: binding, workout: workout, stoppedAt: date, collectionStartedAt: collectionStartedAt)).write(to: contextURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            try await builder.endCollection(at: date)
            if let saved = try await builder.finishWorkout(), let workout {
                var sample = HealthSample(healthkitUuid: saved.uuid.uuidString.lowercased(), type: "workout", unit: "workout", startAt: saved.startDate, endAt: saved.endDate,
                                          sourceName: saved.sourceRevision.source.name, sourceBundleId: saved.sourceRevision.source.bundleIdentifier, deviceName: saved.device?.name ?? "")
                sample.metadataJson["watch_session_id"] = .string(workout.id)
                sample.workoutJson = ["activity_type": .number(Double(saved.workoutActivityType.rawValue)), "duration_seconds": .number(saved.duration)]
                if let distanceType = distanceType(for: workout), let distance = saved.statistics(for: distanceType)?.sumQuantity() {
                    sample.workoutJson?["distance_meters"] = .number(distance.doubleValue(for: .meter()))
                }
                if #available(watchOS 27.0, *), let group = saved.zoneGroupsByType?[heart] {
                    sample.metadataJson["heart_rate_zone_source"] = .string(String(describing: group.configuration.source))
                    sample.metadataJson["heart_rate_zones"] = .array(group.zoneDurations.map { duration in
                        .object(["index": .number(Double(duration.zone.index)),
                                 "minimum_bpm": duration.zone.minimum.map { .number($0.doubleValue(for: unit)) } ?? .null,
                                 "maximum_bpm": duration.zone.maximum.map { .number($0.doubleValue(for: unit)) } ?? .null,
                                 "duration_seconds": .number(duration.duration)])
                    })
                }
                if samples?(binding, workout.id, [sample], nil) != true { status = "训练已在健康保存；关联传输需重试" }
            }
            expectedEnd = true; session.end(); active = false; status = "心率记录已保存"
            // Query final persisted samples after builder has flushed the workout.
            observeRaw(end: date)
        } catch { status = "健康训练保存失败，请重试结束：\(error.localizedDescription)" }
    }
    private func observeRaw(end: Date? = nil) {
        if let query { store.stop(query) }
        rawFailed = false
        guard let workout else { return }
        let binding = self.binding, sessionID = workout.id
        let predicate = HKQuery.predicateForSamples(withStart: collectionStartedAt ?? workout.startedAt, end: end, options: [])
        let handler: @Sendable (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, added, deleted, newAnchor, error in
            Task { @MainActor in
                guard let self else { return }
                let previous = self.rawTask
                self.rawTask = Task {
                await previous?.value
                guard !self.rawFailed else { return }
                if let error { self.rawFailed = true; self.status = "原始心率稍后重试：\(error.localizedDescription)"; return }
                var values: [HealthSample] = []
                for case let sample as HKQuantitySample in added ?? [] {
                    var value = HealthSample(healthkitUuid: sample.uuid.uuidString.lowercased(), type: "heart_rate",
                                             value: sample.quantity.doubleValue(for: self.unit), unit: "bpm", startAt: sample.startDate, endAt: sample.endDate,
                                             sourceName: sample.sourceRevision.source.name, sourceBundleId: sample.sourceRevision.source.bundleIdentifier, deviceName: sample.device?.name ?? "")
                    value.metadataJson["watch_session_id"] = .string(sessionID)
                    value.metadataJson["quantity_count"] = .number(Double(sample.count))
                    // Keep parent UUID for dedup; series points retain their own original intervals.
                    if sample.count > 1 {
                        do { value.metadataJson["quantity_series"] = .array(try await self.series(sample)) }
                        catch { self.rawFailed = true; self.status = "细分心率读取失败，稍后重试"; return }
                    }
                    values.append(value)
                }
                for deleted in deleted ?? [] {
                    values.append(HealthSample(healthkitUuid: deleted.uuid.uuidString.lowercased(), type: "heart_rate", unit: "bpm", deleted: true))
                }
                let anchorData = newAnchor.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
                if self.samples?(binding, sessionID, values, anchorData) != true { self.rawFailed = true; self.status = "心率未能保存，将在恢复时重读"; return }
                if end != nil { try? FileManager.default.removeItem(at: self.contextURL) }
                }
            }
        }
        // The raw sample outbox and cursor are atomically saved together by WatchStore.
        let savedAnchor = anchor?(binding, sessionID).flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
        let query = HKAnchoredObjectQuery(type: heart, predicate: predicate, anchor: savedAnchor, limit: HKObjectQueryNoLimit, resultsHandler: handler)
        if end == nil { query.updateHandler = handler }
        self.query = query; store.execute(query)
    }
    private func series(_ sample: HKQuantitySample) async throws -> [JSONValue] {
        try await withCheckedThrowingContinuation { continuation in
            var points: [JSONValue] = []
            let query = HKQuantitySeriesSampleQuery(quantityType: heart, predicate: HKQuery.predicateForObject(with: sample.uuid)) { _, quantity, interval, _, done, error in
                if let error { continuation.resume(throwing: error); return }
                if let quantity, let interval {
                    points.append(.object(["value": .number(quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))),
                                           "start_epoch_seconds": .number(interval.start.timeIntervalSince1970), "end_epoch_seconds": .number(interval.end.timeIntervalSince1970)]))
                }
                if done { continuation.resume(returning: points) }
            }
            store.execute(query)
        }
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor [weak self] in
            guard let self, self.session === workoutSession else { return }
            if toState == .stopped { await self.finish(at: date) }
            if toState == .ended {
                self.active = false
                if !self.expectedEnd {
                    if let query = self.query { self.store.stop(query) }
                    self.status = "心率会话已由系统结束，可重新开启"
                }
            }
        }
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.session === workoutSession else { return }
            self.active = false; if let query = self.query { self.store.stop(query) }; self.status = "心率会话中断：\(error.localizedDescription)"
        }
    }
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        Task { @MainActor [weak self] in
            guard let self, self.builder === workoutBuilder else { return }
            if collectedTypes.contains(self.heart), let statistics = workoutBuilder.statistics(for: self.heart),
               let quantity = statistics.mostRecentQuantity() {
                self.bpm = quantity.doubleValue(for: self.unit)
                self.observedAt = statistics.mostRecentQuantityDateInterval()?.end
                self.status = "正在记录心率"
            }
            if let workout = self.workout, let distanceType = self.distanceType(for: workout), collectedTypes.contains(distanceType),
               let value = workoutBuilder.statistics(for: distanceType)?.sumQuantity() {
                self.distanceMeters = value.doubleValue(for: .meter())
            }
        }
    }
    @available(watchOS 27.0, *)
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didUpdateWorkoutZone zoneUpdate: HKLiveWorkoutZoneUpdate) {
        guard let group = zoneUpdate.zoneGroup, group.configuration.quantityType == HKQuantityType(.heartRate) else { return }
        let index = zoneUpdate.currentZoneDuration?.zone.index
        Task { @MainActor [weak self] in self?.zoneText = index.map { "心率区间 \($0 + 1) · 首选配置" } }
        // HealthKit persists the exact configuration and durations on HKWorkout.
        // No app-defined thresholds or synthetic zone duration interpolation.
    }
}
