import Foundation
import HealthKit
import SwiftData

@MainActor final class HealthSync {
    struct Spec {
        let type: HKSampleType; let name: String; let unit: HKUnit?; let wireUnit: String; var scale: Double = 1
    }
    let health = HKHealthStore()
    weak var store: AppStore?
    private var observers: [HKObserverQuery] = []
    private var running = Set<String>()
    private var dirty = Set<String>()
    private var observerScope: String?
    private var generation = 0
    private var requesting = false
    private var activating = false
    private var activationRequestedAgain = false
    private var readingAll = false
    private var reloadAfterRead = false
    private var limitedDates: [HKObjectType: Date] = [:]
    var specs: [Spec] {
        let countPerMinute = HKUnit.count().unitDivided(by: .minute())
        let quantities: [(HKQuantityTypeIdentifier, String, HKUnit, String, Double)] = [
            (.height, "height_cm", .meterUnit(with: .centi), "cm", 1),
            (.waistCircumference, "waist_cm", .meterUnit(with: .centi), "cm", 1),
            (.bodyMass, "body_mass", .gramUnit(with: .kilo), "kg", 1),
            (.bodyFatPercentage, "body_fat_percentage", .percent(), "%", 100),
            (.bodyMassIndex, "bmi", .count(), "count", 1),
            (.leanBodyMass, "lean_body_mass", .gramUnit(with: .kilo), "kg", 1),
            (.heartRate, "heart_rate", countPerMinute, "bpm", 1),
            (.restingHeartRate, "resting_heart_rate", countPerMinute, "bpm", 1),
            (.heartRateVariabilitySDNN, "hrv_sdnn", .secondUnit(with: .milli), "ms", 1),
            (.respiratoryRate, "respiratory_rate", countPerMinute, "count/min", 1),
            (.oxygenSaturation, "oxygen_saturation", .percent(), "%", 100),
            (.vo2Max, "vo2_max", HKUnit.literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo)).unitDivided(by: .minute()), "ml/kg/min", 1),
            (.stepCount, "step_count", .count(), "count", 1),
            (.distanceWalkingRunning, "walking_running_distance", .meter(), "m", 1),
            (.activeEnergyBurned, "active_energy", .kilocalorie(), "kcal", 1),
            (.basalEnergyBurned, "basal_energy", .kilocalorie(), "kcal", 1),
            (.appleExerciseTime, "exercise_time", .minute(), "min", 1),
            (.flightsClimbed, "flights_climbed", .count(), "count", 1)
        ]
        var result = quantities.compactMap { id, name, unit, wire, scale in HKQuantityType.quantityType(forIdentifier: id).map { Spec(type: $0, name: name, unit: unit, wireUnit: wire, scale: scale) } }
        if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { result.append(Spec(type: sleep, name: "sleep_analysis", unit: nil, wireUnit: "category")) }
        result.append(Spec(type: HKObjectType.workoutType(), name: "workout", unit: nil, wireUnit: "workout")); return result
    }
    private func authorizationRequestStatus(for type: HKObjectType) async throws -> HKAuthorizationRequestStatus {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HKAuthorizationRequestStatus, Error>) in
            health.getRequestStatusForAuthorization(toShare: [], read: [type]) { status, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: status) }
            }
        }
    }
    func sleepAuthorizationNeedsRequest() async -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--sleep-auth-reminder-ui-test") { return true }
        if ProcessInfo.processInfo.arguments.contains("--sleep-ui-test") { return false }
        #endif
        guard HKHealthStore.isHealthDataAvailable(), let sleep = specs.first(where: { $0.name == "sleep_analysis" }) else { return false }
        return (try? await authorizationRequestStatus(for: sleep.type)) == .shouldRequest
    }
    func weightAuthorizationNeedsRequest() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable(), let weight = specs.first(where: { $0.name == "body_mass" }) else { return false }
        return (try? await authorizationRequestStatus(for: weight.type)) == .shouldRequest
    }

    /// Refreshes only body mass; opening the history screen does not trigger
    /// the all-type historical import that made large HealthKit libraries slow.
    func refreshWeight(requestAuthorization: Bool = false, automatic: Bool = false) async {
        guard let store, store.signedIn, HKHealthStore.isHealthDataAvailable(),
              let spec = specs.first(where: { $0.name == "body_mass" }) else { return }
        let owner = store.scope
        let checkKey = "weightCheck.\(owner).\(store.healthHistoryWindow.rawValue)"
        if automatic, let last = UserDefaults.standard.object(forKey: checkKey) as? Date,
           Date() >= last, Date().timeIntervalSince(last) < 30 * 60 { return }
        do {
            if requestAuthorization {
                guard !requesting else { return }; requesting = true
                defer { requesting = false }
                try await health.requestAuthorization(toShare: [], read: [spec.type])
                guard store.scope == owner else { return }
                store.setHealthReading(true)
                await stop()
                if #available(iOS 27.0, *), let boundaries = try? await health.earliestAuthorizedSampleDate(for: [spec.type]) { limitedDates[spec.type] = boundaries[spec.type] }
                try await store.healthStorage.value.resetAnchor(key: owner + "/" + store.healthHistoryWindow.rawValue + "/body_mass")
            }
            guard store.healthReadingEnabled, store.scope == owner else { return }
            if !requestAuthorization {
                guard try await authorizationRequestStatus(for: spec.type) == .unnecessary else { return }
            }
            try await pull(spec)
            guard store.scope == owner else { return }
            UserDefaults.standard.set(Date(), forKey: checkKey)
            await store.refreshLocalHealth(markRead: true)
            if requestAuthorization { await activate() }
            if store.settings.healthConsent && !store.isDemo && !automatic { await store.synchronize(showErrors: false) }
        } catch {
            if requestAuthorization { await activate() }
            guard store.scope == owner else { return }
            if !automatic { store.error = "体重读取未完成：\(error.localizedDescription)" }
        }
    }
    func vitalAuthorizationNeedsRequest(_ type: String) async -> Bool {
        guard ["resting_heart_rate", "hrv_sdnn"].contains(type),
              HKHealthStore.isHealthDataAvailable(), let spec = specs.first(where: { $0.name == type }) else { return false }
        return (try? await authorizationRequestStatus(for: spec.type)) == .shouldRequest
    }
    func refreshVital(_ type: String, requestAuthorization: Bool = false, automatic: Bool = false) async {
        guard ["resting_heart_rate", "hrv_sdnn"].contains(type),
              let store, store.signedIn, HKHealthStore.isHealthDataAvailable(),
              let spec = specs.first(where: { $0.name == type }) else { return }
        let owner = store.scope
        let checkKey = "vitalCheck.\(owner).\(store.healthHistoryWindow.rawValue).\(type)"
        if automatic, let last = UserDefaults.standard.object(forKey: checkKey) as? Date,
           Date() >= last, Date().timeIntervalSince(last) < 30 * 60 { return }
        do {
            if requestAuthorization {
                guard !requesting else { return }; requesting = true
                defer { requesting = false }
                try await health.requestAuthorization(toShare: [], read: [spec.type])
                guard store.scope == owner else { return }
                store.setHealthReading(true)
                await stop()
                if #available(iOS 27.0, *), let boundaries = try? await health.earliestAuthorizedSampleDate(for: [spec.type]) { limitedDates[spec.type] = boundaries[spec.type] }
                try await store.healthStorage.value.resetAnchor(key: owner + "/" + store.healthHistoryWindow.rawValue + "/" + type)
            }
            guard store.healthReadingEnabled, store.scope == owner else { return }
            if !requestAuthorization {
                guard try await authorizationRequestStatus(for: spec.type) == .unnecessary else { return }
            }
            try await pull(spec)
            guard store.scope == owner else { return }
            UserDefaults.standard.set(Date(), forKey: checkKey)
            await store.refreshLocalHealth(markRead: true)
            if requestAuthorization { await activate() }
            if store.settings.healthConsent && !store.isDemo && !automatic { await store.synchronize(showErrors: false) }
        } catch {
            if requestAuthorization { await activate() }
            guard store.scope == owner else { return }
            if !automatic { store.error = "\(LocalHealthOverview.names[type] ?? type)读取未完成：\(error.localizedDescription)" }
        }
    }
    func requestAndSync() async {
        guard let store else { return }
        guard !requesting else { return }; requesting = true; defer { requesting = false }
        guard HKHealthStore.isHealthDataAvailable() else { store.healthStatus = "此设备不支持 HealthKit"; return }
        guard store.signedIn else { store.error = "请先进入本机记录或登录账号"; return }
        do {
            try await health.requestAuthorization(toShare: [], read: Set(specs.map(\.type)))
            store.setHealthReading(true)
            // Explicitly revisiting authorization can expand access to OLD samples.
            // Reimport accessible history on this user action only; normal foreground sync retains anchors.
            await stop()
            try await store.resetHealthAnchors()
            if #available(iOS 27.0, *) {
                if let boundaries = try? await health.earliestAuthorizedSampleDate(for: Set(specs.map(\.type))) { limitedDates = boundaries; store.healthAuthorizationNote = boundaries.isEmpty ? "实际读取范围以系统授权为准" : "系统限制了 \(boundaries.count) 类数据的历史范围" }
            }
            // Completion means the authorization sheet finished; it does not establish read permission.
            await syncAll(force: true); await activate(); await store.synchronize(showErrors: false)
        } catch { store.error = "健康授权未完成：\(error.localizedDescription)" }
    }
    /// Explicit sleep refresh does not wait behind a first-time year of heart-rate history.
    func refreshSleep(requestAuthorization: Bool = false, invalidateCache: Bool = false, automatic: Bool = false) async {
        guard let store, store.signedIn, HKHealthStore.isHealthDataAvailable(),
              let spec = specs.first(where: { $0.name == "sleep_analysis" }) else { return }
        let owner = store.scope
        let checkKey = "sleepCheck.\(owner).\(store.healthHistoryWindow.rawValue)"
        if automatic, let last = UserDefaults.standard.object(forKey: checkKey) as? Date,
           Date() >= last, Date().timeIntervalSince(last) < 30 * 60 { return }
        do {
            if requestAuthorization {
                guard !requesting else { return }; requesting = true
                defer { requesting = false }
                try await health.requestAuthorization(toShare: [], read: [spec.type])
                guard store.scope == owner else { return }
                store.setHealthReading(true)
                await stop()
                if #available(iOS 27.0, *), let boundaries = try? await health.earliestAuthorizedSampleDate(for: [spec.type]) { limitedDates[spec.type] = boundaries[spec.type] }
                let key = owner + "/" + store.healthHistoryWindow.rawValue + "/sleep_analysis"
                try await store.healthStorage.value.resetAnchor(key: key)
                try await store.healthStorage.value.clearSleepCache(scope: owner)
            }
            guard store.healthReadingEnabled, store.scope == owner else {
                if !automatic { store.healthStatus = "请先点“授权 / 补充本机睡眠读取”；云端已有记录仍可查看" }
                return
            }
            if !requestAuthorization {
                let status = try await authorizationRequestStatus(for: spec.type)
                guard status == .unnecessary else {
                    store.healthStatus = status == .shouldRequest ? "新日益尚未请求睡眠读取权限，请点“授权 / 补充本机睡眠读取”" : "暂时无法确认睡眠授权状态，请稍后重试"
                    return
                }
            }
            let oldRevision = store.sleepRevision
            try await pull(spec)
            guard store.scope == owner else { return }
            UserDefaults.standard.set(Date(), forKey: checkKey)
            if invalidateCache && !requestAuthorization {
                try await store.healthStorage.value.clearSleepCache(scope: owner, zone: store.settings.timezone, date: DayKey.string(Date(), zone: store.settings.timezone))
            }
            await store.refreshLocalHealth(markRead: true)
            if !readingAll && running.isEmpty {
                store.healthStatus = store.localSummary?.metrics["sleep_total_minutes"]?.value != nil ? "已更新本机可访问的昨晚睡眠" : "暂未读到今天醒来的本机睡眠，请检查日益的睡眠读取权限"
            }
            if requestAuthorization { await activate() }
            if store.settings.healthConsent && !store.isDemo && (!automatic || store.sleepRevision != oldRevision) { await store.synchronize(showErrors: false) }
        } catch {
            if requestAuthorization { await activate() }
            guard store.scope == owner else { return }
            if (error as? HKError)?.code == .errorAuthorizationNotDetermined {
                store.healthStatus = "睡眠读取需要先授权，请点“授权 / 补充本机睡眠读取”；云端记录仍可查看"
            } else if automatic {
                store.healthStatus = "本机睡眠自动读取待重试；云端记录仍可查看"
            } else { store.error = "睡眠读取未完成：\(error.localizedDescription)" }
        }
    }
    func requestProfileAndSync() async {
        guard let store, store.signedIn, !requesting, HKHealthStore.isHealthDataAvailable() else { return }
        requesting = true; defer { requesting = false }
        let body = specs.filter { ["height_cm", "waist_cm"].contains($0.name) }
        let owner = store.scope
        do {
            try await health.requestAuthorization(toShare: [], read: Set(body.map(\.type)))
            guard store.scope == owner else { return }
            store.setHealthReading(true)
            for spec in body {
                let key = owner + "/" + store.healthHistoryWindow.rawValue + "/" + spec.name
                try await store.healthStorage.value.resetAnchor(key: key)
                try await pull(spec)
            }
            await store.refreshLocalHealth(markRead: true)
            store.healthStatus = "已更新可访问的档案测量；未显示的项目可能暂无记录或不在授权范围内"
            await activate()
            if store.settings.healthConsent && !store.isDemo { await store.synchronize(showErrors: false) }
        } catch { store.error = "档案读取未完成：\(error.localizedDescription)" }
    }
    func activate() async {
        if activating { activationRequestedAgain = true; return }
        activating = true
        defer {
            activating = false
            if activationRequestedAgain {
                activationRequestedAgain = false
                Task { await self.activate() }
            }
        }
        guard let store, store.signedIn, store.healthReadingEnabled, HKHealthStore.isHealthDataAvailable() else { await stop(); return }
        let observerKey = store.scope + "/" + store.healthHistoryWindow.rawValue
        if observerScope == observerKey { return }
        await stop()
        guard store.scope + "/" + store.healthHistoryWindow.rawValue == observerKey && store.healthReadingEnabled else { return }
        observerScope = observerKey
        let epoch = generation
        for spec in specs {
            guard generation == epoch && store.scope + "/" + store.healthHistoryWindow.rawValue == observerKey && store.healthReadingEnabled else { return }
            guard (try? await authorizationRequestStatus(for: spec.type)) == .unnecessary else { continue }
            let query = HKObserverQuery(sampleType: spec.type, predicate: nil) { [weak self] _, completion, error in
                Task { @MainActor in
                    guard let self else { completion(); return }
                    if let error { self.store?.healthStatus = "后台读取暂未完成：\(error.localizedDescription)"; completion(); return }
                    do { try await self.pull(spec); await self.store?.refreshLocalHealth(markRead: true) } catch { self.store?.healthStatus = "后台读取待重试：\(error.localizedDescription)" }
                    // Data and new anchor are durable locally; cloud upload is independently retryable.
                    completion()
                    if self.store?.settings.healthConsent == true && self.store?.isDemo == false { await self.store?.synchronize(showErrors: false) }
                }
            }
            observers.append(query); health.execute(query)
            do { try await health.enableBackgroundDelivery(for: spec.type, frequency: .hourly) }
            catch { store.healthStatus = "后台更新不可用，回到 App 时仍会同步" }
        }
    }
    func changeWindow(_ window: HealthHistoryWindow) async {
        await stop()
        await store?.changeHealthWindow(window)
        if readingAll { reloadAfterRead = true; return }
        await syncAll(force: true); await activate(); await store?.synchronize(showErrors: false)
    }
    func stop() async {
        generation += 1
        for observer in observers { health.stop(observer) }; observers = []; observerScope = nil
        // Do not clear anchors or pending data when revoking consent.
        if HKHealthStore.isHealthDataAvailable() { try? await health.disableAllBackgroundDelivery() }
    }
    func syncAll(force: Bool = false) async {
        guard let store, store.healthReadingEnabled, store.signedIn, !readingAll, HKHealthStore.isHealthDataAvailable() else { return }
        let sweepKey = "healthSweep.\(store.scope).\(store.healthHistoryWindow.rawValue)"
        let lastSweep = UserDefaults.standard.object(forKey: sweepKey) as? Date ?? store.localHealthReadAt
        if !force, let lastSweep, Date().timeIntervalSince(lastSweep) < 6 * 3600 && Date() >= lastSweep { return }
        readingAll = true
        defer { readingAll = false; if reloadAfterRead { reloadAfterRead = false; Task { await self.syncAll(force: true); await self.activate(); await self.store?.synchronize(showErrors: false) } } }
        do { try await store.prepareLocalHealthCache() } catch { store.error = "无法准备本机健康缓存：\(error.localizedDescription)"; return }
        let scope = store.scope, selectedWindow = store.healthHistoryWindow; store.healthStatus = "正在读取可访问的健康记录…"
        let epoch = generation
        var failed: [String] = []
        var needsAuthorization = false
        let ordered = specs.filter { $0.name == "sleep_analysis" } + specs.filter { $0.name != "sleep_analysis" }
        for spec in ordered {
            guard scope == store.scope && store.healthReadingEnabled && store.healthHistoryWindow == selectedWindow && generation == epoch else { return }
            do {
                guard try await authorizationRequestStatus(for: spec.type) == .unnecessary else { needsAuthorization = true; continue }
            } catch { failed.append("\(LocalHealthOverview.names[spec.name] ?? spec.name)：暂时无法确认授权"); continue }
            do { try await pull(spec) } catch { failed.append("\(LocalHealthOverview.names[spec.name] ?? spec.name)：\(error.localizedDescription)") }
            if spec.name == "body_mass" || spec.name == "sleep_analysis" { await store.refreshLocalHealth() }
        }
        guard store.scope == scope && generation == epoch else { return }
        await store.refreshLocalHealth(markRead: true)
        UserDefaults.standard.set(Date(), forKey: sweepKey)
        let localResult = store.localHealthSampleCount > 0 ? "本机已保存 \(store.localHealthSampleCount) 条健康记录" : "未读到可访问记录，请检查系统健康授权；这不代表没有健康数据"
        store.healthStatus = (failed.isEmpty ? localResult : localResult + "；部分类型待重试：" + failed.joined(separator: "；")) + (needsAuthorization ? "；部分类型尚未请求读取权限" : "")
    }
    private func pull(_ spec: Spec) async throws {
        guard let store, store.healthReadingEnabled, store.signedIn else { return }
        let scope = store.scope; let key = scope + "/" + store.healthHistoryWindow.rawValue + "/" + spec.name
        let from = max(store.healthWindowStart, limitedDates[spec.type] ?? .distantPast)
        let epoch = generation; let runKey = key + "#\(epoch)"
        guard !running.contains(runKey) else { dirty.insert(runKey); return }; running.insert(runKey); defer { running.remove(runKey); dirty.remove(runKey) }
        var anchor: HKQueryAnchor?
        var sleepChanged = false
        if let data = try await store.healthAnchor(key: key) { anchor = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data) }
        while true {
            let (added, deleted, next) = try await page(spec.type, anchor: anchor, from: from)
            guard next != nil || added.isEmpty && deleted.isEmpty else { throw AppError.message("HealthKit 未返回同步锚点，保留原位置稍后重试") }
            guard store.scope == scope && store.healthReadingEnabled && generation == epoch else { return }
            var samples = added.compactMap { convert($0, spec: spec) }
            samples += deleted.map { HealthSample(healthkitUuid: $0.uuid.uuidString.lowercased(), type: spec.name, unit: spec.wireUnit, deleted: true) }
            let data = try next.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
            let changed = try await store.enqueueHealth(samples: samples, anchor: data, cursorKey: key, expectedScope: scope)
            if spec.name == "sleep_analysis" && changed { sleepChanged = true }
            store.healthStatus = "正在读取\(LocalHealthOverview.names[spec.name] ?? spec.name)…"
            anchor = next
            if added.count + deleted.count < 300 && !dirty.contains(runKey) { break }
            dirty.remove(runKey)
        }
        if sleepChanged && store.scope == scope && generation == epoch { store.sleepRevision += 1 }
    }
    private func page(_ type: HKSampleType, anchor: HKQueryAnchor?, from: Date) async throws -> ([HKSample], [HKDeletedObject], HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: type, predicate: HKQuery.predicateForSamples(withStart: from, end: nil, options: []), anchor: anchor, limit: 300) { _, samples, deleted, newAnchor, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (samples ?? [], deleted ?? [], newAnchor)) }
            }; health.execute(query)
        }
    }
    private func convert(_ sample: HKSample, spec: Spec) -> HealthSample? {
        var result = HealthSample(healthkitUuid: sample.uuid.uuidString.lowercased(), type: spec.name, unit: spec.wireUnit, startAt: sample.startDate, endAt: sample.endDate, sourceName: sample.sourceRevision.source.name, sourceBundleId: sample.sourceRevision.source.bundleIdentifier, deviceName: sample.device?.name ?? "")
        if let q = sample as? HKQuantitySample, let unit = spec.unit { result.value = q.quantity.doubleValue(for: unit) * spec.scale }
        if let c = sample as? HKCategorySample {
            switch c.value {
            case HKCategoryValueSleepAnalysis.inBed.rawValue: result.category = "in_bed"
            case HKCategoryValueSleepAnalysis.awake.rawValue: result.category = "awake"
            case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: result.category = "asleep_unspecified"
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue: result.category = "asleep_core"
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: result.category = "asleep_deep"
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue: result.category = "asleep_rem"
            default: return nil
            }
        }
        if let w = sample as? HKWorkout {
            if let sessionID = w.metadata?[HKMetadataKeyExternalUUID] as? String,
               store?.workouts.contains(where: { $0.id == sessionID }) == true {
                store?.markHealthWorkoutSaved(sessionID)
            }
            result.workoutJson = ["activity_type": .number(Double(w.workoutActivityType.rawValue)), "duration_seconds": .number(w.duration)]
            let distanceType: HKQuantityType? = switch w.workoutActivityType {
            case .swimming: HKQuantityType(.distanceSwimming)
            case .cycling: HKQuantityType(.distanceCycling)
            case .walking, .running, .hiking: HKQuantityType(.distanceWalkingRunning)
            default: nil
            }
            if let distanceType, let distance = w.statistics(for: distanceType)?.sumQuantity() {
                result.workoutJson?["distance_meters"] = .number(distance.doubleValue(for: .meter()))
            }
            if let energy = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() { result.workoutJson?["active_energy_kcal"] = .number(energy.doubleValue(for: .kilocalorie())) }
            // Workout energy is preserved but never added again to daily active energy.
        }
        if let v = sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool { result.metadataJson["was_user_entered"] = .bool(v) }
        if let v = sample.metadata?[HKMetadataKeyTimeZone] as? String { result.metadataJson["timezone"] = .string(v) }
        return result
    }
}
