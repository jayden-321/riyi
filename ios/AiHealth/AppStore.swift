import Foundation
import SwiftData
import Observation

#if os(macOS)
@MainActor final class WorkoutHealthWriter {
    var hasPairedWatch: Bool { false }
    func write(_ workout: Workout, automatic: Bool) async throws -> Bool { false }
}
#endif

@MainActor @Observable final class AppStore {
    @ObservationIgnored var companionChanged: (() -> Void)?
    @ObservationIgnored var companionRefreshRequested: (() -> Void)?
    @ObservationIgnored var companionStarted: (() -> Void)?
    @ObservationIgnored let container: ModelContainer
    @ObservationIgnored let context: ModelContext
    @ObservationIgnored var network: Network
    @ObservationIgnored let healthStorage: Task<HealthStorage, Never>
    @ObservationIgnored let workoutHealth = WorkoutHealthWriter()
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var overviewTask: Task<Void, Never>?
    @ObservationIgnored private var overviewRequested = false
    @ObservationIgnored private var settingsRevision = 0
    var healthHistoryWindow: HealthHistoryWindow = .year
    var selectedTab = "today"
    var needsReauthentication = false
    var showReauthentication = false
    var reauthenticating = false
    var sleepRevision = 0
    var calendarDate = Date()
    var coachPromptDraft = ""
    var coachState: CoachState?; var coachOwner = ""; var coachBusy = false; var coachError: String?
    @ObservationIgnored var coachPendingID = newID()
    @ObservationIgnored var coachPendingMessage = ""
    @ObservationIgnored var coachPendingOwner = ""
    @ObservationIgnored var coachRevision = 0
    @ObservationIgnored var coachPollTask: Task<Void, Never>?
    @ObservationIgnored var coachPollOwner = ""
    @ObservationIgnored var coachPollRunID = ""
    var healthUploadPaused = false
    var healthUploadStatus = "尚未开始上传"
    var healthUploadProgress: HealthUploadProgress?
    var pendingHealthCount = 0
    var pendingCount: Int { pending.count + pendingHealthCount }
    var changingSettings = false
    var healthWindowStart: Date { healthHistoryWindow.start(zone: settings.timezone) }
    var scope = ""; var records: [LocalRecord] = []; var pending: [PendingChange] = []
    var settings = CloudSettings(); var cloudSummary: DailySummary?; var localSummary: DailySummary?; var report: DailyReport?
    var summary: DailySummary? { localSummary ?? cloudSummary }
    func sleepMetric(_ key: String, now: Date = Date()) -> HealthMetric? {
        let day = DayKey.string(now, zone: settings.timezone)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: settings.timezone) ?? .current
        func current(_ value: HealthMetric?) -> Bool {
            guard let value, value.value != nil, let observed = value.observedAt else { return false }
            return observed <= now && calendar.isDate(observed, inSameDayAs: now)
        }
        // Keep total and stages in one summary/source cohort; never fill missing local stages from another source.
        if let local = localSummary, local.date == day, local.timezone == settings.timezone,
           current(local.metrics["sleep_total_minutes"]) { return current(local.metrics[key]) ? local.metrics[key] : nil }
        if let cloud = cloudSummary, cloud.date == day, cloud.timezone == settings.timezone,
           current(cloud.metrics["sleep_total_minutes"]), var metric = cloud.metrics[key], current(metric) {
            metric.method = "cloud_fallback_" + metric.method; return metric
        }
        return nil
    }
    var healthReadingEnabled = false
    var sleepAuthReminderShown = false
    var localHealthReadAt: Date?
    var localHealthSampleCount = 0
    var recentHealthSamples: [HealthSample] = []
    var error: String?; var syncing = false; var reportLoading = false; var lastSync: Date?
    var healthExportMessage: String?
    var healthStatus = "尚未读取健康数据"
    var healthAuthorizationNote = "实际读取范围以系统授权为准"
    var isDemo: Bool { scope == "local-demo" }
    var signedIn: Bool { !scope.isEmpty }
    var plans: [Plan] { values("plan") }
    var workouts: [Workout] { values("workout").sorted { $0.startedAt > $1.startedAt } }
    var waters: [WaterLog] { values("water").sorted { $0.drankAt > $1.drankAt } }
    var checkins: [Checkin] { values("checkin").sorted { $0.recordedAt > $1.recordedAt } }
    var profile: Profile { (values("profile") as [Profile]).max { $0.updatedAt < $1.updatedAt } ?? Profile() }
    func profileMetric(_ type: String) -> HealthMetric? {
        let local = localSummary?.metrics[type]
        let health = local?.value == nil ? cloudSummary?.metrics[type] : local
        let manualRecord = (values("profile") as [Profile]).filter { type == "height_cm" ? $0.heightCm != nil : type == "waist_cm" && $0.waistCm != nil }.max { $0.measuredAt == $1.measuredAt ? $0.updatedAt < $1.updatedAt : $0.measuredAt < $1.measuredAt }
        let manual = type == "height_cm" ? manualRecord?.heightCm : type == "waist_cm" ? manualRecord?.waistCm : nil
        if let manual, let manualRecord, health?.value == nil || manualRecord.measuredAt >= (health?.observedAt ?? .distantPast) {
            return HealthMetric(value: manual, unit: "cm", observedAt: manualRecord.measuredAt, source: "手动记录", samples: 1, coverage: "logged_only", method: "manual_profile_measurement")
        }
        return health
    }
    var conflicts: [PendingChange] { pending.filter { $0.conflictData != nil } }
    var waterToday: Int {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: settings.timezone) ?? .current
        return waters.filter { calendar.isDate($0.drankAt, inSameDayAs: Date()) }.reduce(0) { $0 + $1.amountMl }
    }
    var activeWorkout: Workout? { workouts.first { $0.status == "in_progress" } }
    private func healthWorkoutKey(_ id: String) -> String { "healthWorkoutSaved.\(scope).\(id)" }
    func healthWorkoutSaved(_ id: String) -> Bool { UserDefaults.standard.bool(forKey: healthWorkoutKey(id)) }
    func markHealthWorkoutSaved(_ id: String) { UserDefaults.standard.set(true, forKey: healthWorkoutKey(id)); healthExportMessage = "已写入 Apple 健康" }
    func writeWorkoutToHealth(_ workout: Workout, automatic: Bool = false) async {
        guard signedIn, !isDemo, workout.status == "completed", workout.finishedAt != nil, !healthWorkoutSaved(workout.id) else { return }
        do {
            let saved = try await workoutHealth.write(workout, automatic: automatic)
            if saved { markHealthWorkoutSaved(workout.id) }
        } catch {
            if !automatic { healthExportMessage = "写入 Apple 健康失败：\(error.localizedDescription)" }
        }
    }
    var lastOvernightClosure: String?
    /// End a previous-day session at its last recorded action, preserving every set.
    func expireOvernightWorkouts(now: Date = Date()) {
        for original in workouts where CompanionCore.isOvernightStale(original, zone: settings.timezone, now: now) {
            var ended = original; ended.status = "cancelled"; ended.finishedAt = CompanionCore.lastActivity(original); ended.autoExpiredAt = now; ended.restUntil = nil
            if save(ended, kind: "workout", id: ended.id) { lastOvernightClosure = "昨天未结束的训练已按最后记录时间结束，已完成的组仍保留。" }
        }
    }


    init(container: ModelContainer) {
        self.container = container; context = ModelContext(container); context.autosaveEnabled = false
        healthStorage = Task.detached { HealthStorage(modelContainer: container) }
        let url = UserDefaults.standard.string(forKey: "serverURL") ?? Network.defaultURL
        network = Network(baseURL: URL(string: url) ?? URL(string: "http://localhost:18089")!)
        observeSessionExpiry()
        if let t = network.tokens { scope = network.baseURL.absoluteString + "/" + t.userId }
        else if UserDefaults.standard.bool(forKey: "localDemo") { scope = "local-demo" }
        restoreSettings(); reload(); promoteWalkingRecovery(); Task { [weak self] in await self?.refreshLocalHealth() }
    }
    private func observeSessionExpiry() {
        network.onSessionExpired = { [weak self] in
            guard let self, self.signedIn, !self.isDemo else { return }
            self.needsReauthentication = true
            self.showReauthentication = true
        }
    }
    func reauthenticate(email: String, password: String) async -> Bool {
        guard signedIn, !isDemo, !reauthenticating else { return false }
        let owner = scope
        guard owner.hasPrefix(network.baseURL.absoluteString + "/") else { error = "账号空间与服务器地址不一致"; return false }
        let userID = String(owner.dropFirst(network.baseURL.absoluteString.count + 1))
        reauthenticating = true
        defer { reauthenticating = false }
        do {
            try await network.authenticate(email: email, password: password, register: false, expectedUserID: userID)
            guard scope == owner else { return false }
            needsReauthentication = false; showReauthentication = false
            error = nil
            Task { await synchronize(showErrors: false) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func values<T: Decodable>(_ kind: String) -> [T] { records.filter { $0.kind == kind && !$0.tombstoned }.compactMap { try? Wire.read($0.payload) } }
    func reload() {
        defer { companionChanged?() }
        do {
            let owner = scope
            records = try context.fetch(FetchDescriptor<LocalRecord>(predicate: #Predicate { $0.scope == owner }))
            pending = try context.fetch(FetchDescriptor<PendingChange>(predicate: #Predicate { $0.scope == owner && $0.kind != "health" }, sortBy: [SortDescriptor(\.createdAt)]))
            pendingHealthCount = try context.fetchCount(FetchDescriptor<PendingChange>(predicate: #Predicate { $0.scope == owner && $0.kind == "health" }))
        } catch { self.error = "无法读取本地记录：\(error.localizedDescription)" }
    }
    private func restoreSettings() {
        coachPollTask?.cancel(); coachPollTask = nil; coachPollOwner = ""; coachPollRunID = ""
        coachState = nil; coachOwner = ""; coachError = nil; selectedTab = "today"
        sleepAuthReminderShown = false
        settings = CloudSettings()
        if let data = UserDefaults.standard.data(forKey: "settings.\(scope)"), let value: CloudSettings = try? Wire.read(data) { settings = value }
        // Cloud upload consent belongs to the account. A newly signed app has
        // its own HealthKit authorization and must not infer local read access.
        healthReadingEnabled = UserDefaults.standard.bool(forKey: "healthReading.\(scope)")
        localHealthReadAt = UserDefaults.standard.object(forKey: "healthReadAt.\(scope)") as? Date
        healthHistoryWindow = HealthHistoryWindow(rawValue: UserDefaults.standard.string(forKey: "healthWindow.\(scope)") ?? "year") ?? .year
        healthUploadPaused = UserDefaults.standard.bool(forKey: "healthUploadPaused.\(scope)")
        healthUploadProgress = nil
    }
    func authenticate(url: String, email: String, password: String, register: Bool) async {
        guard !syncing else { return }
        guard let base = URL(string: url), Network.permits(base) else {
            error = "请输入 HTTPS 地址，或同一局域网内的 HTTP 开发地址"; return
        }
        syncing = true; defer { syncing = false }
        do {
            let client = Network(baseURL: base); try await client.authenticate(email: email, password: password, register: register)
            network = client; observeSessionExpiry(); scope = base.absoluteString + "/" + client.tokens!.userId
            needsReauthentication = false; showReauthentication = false
            UserDefaults.standard.set(base.absoluteString, forKey: "serverURL"); UserDefaults.standard.set(false, forKey: "localDemo")
            cloudSummary = nil; localSummary = nil; report = nil; lastSync = nil; restoreSettings(); reload(); Task { [weak self] in await self?.refreshLocalHealth() }
            settings = try Wire.read(await client.request("/v1/settings")); persistSettings()
            syncing = false; await synchronize()
        } catch { self.error = error.localizedDescription }
    }
    func startDemo() {
        needsReauthentication = false; showReauthentication = false
        scope = "local-demo"; UserDefaults.standard.set(true, forKey: "localDemo"); restoreSettings(); reload(); Task { [weak self] in await self?.refreshLocalHealth() }
        if !records.contains(where: { $0.kind == "plan" }) { let p = Plan.starter(); save(p, kind: "plan", id: p.id) }
    }
    func leave() {
        guard !syncing else { error = "同步进行中，请稍后退出"; return }
        Notifications.shared.cancel()
        coachPollTask?.cancel(); coachPollTask = nil; coachPollOwner = ""; coachPollRunID = ""
        coachState = nil; coachOwner = ""; coachError = nil; selectedTab = "today"
        network.forget(); needsReauthentication = false; showReauthentication = false; UserDefaults.standard.set(false, forKey: "localDemo"); scope = ""; cloudSummary = nil; localSummary = nil; report = nil
        lastSync = nil; settings = CloudSettings(); healthReadingEnabled = false; localHealthReadAt = nil; localHealthSampleCount = 0; recentHealthSamples = []; reload()
    }
    func logout() async {
        guard !syncing else { error = "同步进行中，请稍后退出"; return }
        if !isDemo { _ = try? await network.request("/v1/auth/logout", method: "POST", body: Data("{}".utf8), retry: false, timeout: 5) }
        leave()
    }
    func persistSettings() { if let data = try? Wire.data(settings) { UserDefaults.standard.set(data, forKey: "settings.\(scope)") } }
    func updateSettings(_ proposed: CloudSettings) async {
        guard !changingSettings else { return }
        changingSettings = true; defer { changingSettings = false }
        settingsRevision += 1
        let owner = scope, wasUploading = settings.healthConsent
        if !proposed.healthConsent && wasUploading { pauseHealthUpload(); settings.healthConsent = false }
        do {
            let saved: CloudSettings = isDemo ? proposed : try Wire.read(await network.request("/v1/settings", method: "PUT", body: Wire.data(proposed)))
            guard scope == owner else { return }
            settings = saved; persistSettings()
            if !wasUploading && settings.healthConsent && !isDemo {
                healthUploadPaused = false; UserDefaults.standard.set(false, forKey: "healthUploadPaused.\(scope)")
                healthUploadStatus = "正在准备上传进度…"
                let worker = await healthStorage.value
                updateHealthProgress(try await worker.startBackfill(scope: owner, restart: true, since: healthWindowStart))
            }
            if !settings.aiConsent { report = nil; Notifications.shared.cancelCoach() }
        } catch { self.error = error.localizedDescription }
    }
    func pauseHealthUpload() {
        healthUploadPaused = true; UserDefaults.standard.set(true, forKey: "healthUploadPaused.\(scope)")
        healthUploadStatus = "已暂停，当前请求完成后保留断点"
    }
    func resumeHealthUpload() async {
        healthUploadPaused = false; UserDefaults.standard.set(false, forKey: "healthUploadPaused.\(scope)")
        await synchronize()
    }
    private func updateHealthProgress(_ progress: HealthUploadProgress) {
        healthUploadProgress = progress; pendingHealthCount = progress.pendingBatches
        if !healthUploadPaused { healthUploadStatus = "本轮已上传 \(progress.uploaded) 条 · 待上传 \(progress.pendingBatches) 批" }
    }
    @discardableResult func save<T: Encodable>(_ value: T, kind: String, id: String) -> Bool {
        do { try write(kind: kind, id: id, payload: Wire.data(value), deleted: false); return true }
        catch { context.rollback(); reload(); self.error = "保存失败：\(error.localizedDescription)"; return false }
    }
    func remove(kind: String, id: String) {
        guard let r = records.first(where: { $0.kind == kind && $0.recordId == id }) else { return }
        do {
            try write(kind: kind, id: id, payload: r.payload, deleted: true)
            if !isDemo { let owner = scope; Task { if self.scope == owner { await self.synchronize(showErrors: true) } } }
        }
        catch { context.rollback(); reload(); self.error = error.localizedDescription }
    }
    private func write(kind: String, id: String, payload: Data, deleted: Bool) throws {
        guard signedIn else { throw AppError.message("请先选择账号或本地体验") }
        let r = records.first { $0.kind == kind && $0.recordId == id } ?? LocalRecord(scope: scope, kind: kind, id: id, payload: payload)
        if r.modelContext == nil { context.insert(r) }; r.payload = payload; r.tombstoned = deleted; r.updatedAt = Date()
        if !isDemo {
            if let q = pending.last(where: { $0.kind == kind && $0.recordId == id && $0.baseVersion == -1 && $0.conflictData == nil }) { q.payload = payload; q.tombstoned = deleted }
            else { context.insert(PendingChange(scope: scope, kind: kind, recordId: id, payload: payload, deleted: deleted)) }
        }
        try context.save(); reload()
    }
    func addWater(_ amount: Int, date: Date = Date(), source: String = "manual", id: String = newID()) {
        guard amount > 0 && amount <= 5000 else { error = "饮水量需为 1–5000 ml"; return }
        if records.contains(where: { $0.kind == "water" && $0.recordId == id }) { return }
        var water = WaterLog(amountMl: amount, drankAt: date, source: source); water.id = id
        save(water, kind: "water", id: water.id)
    }
    func start(plan: Plan, day: PlanDay, synthetic: Bool = false, scheduledBlockId: String? = nil) {
        expireOvernightWorkouts()
        guard activeWorkout == nil else { error = "请先完成当前训练"; return }
        var workout = Workout(plan: plan, day: day, scheduledBlockId: scheduledBlockId); workout.synthetic = synthetic; if save(workout, kind: "workout", id: workout.id) { companionStarted?() }
    }
    func start(activity: TimedActivity, scheduledBlockId: String? = nil) {
        expireOvernightWorkouts()
        guard activeWorkout == nil else { error = "请先完成当前训练"; return }
        let workout = Workout(activity: activity, scheduledBlockId: scheduledBlockId)
        if save(workout, kind: "workout", id: workout.id) { companionStarted?() }
    }
    func synchronize(showErrors: Bool = true) async {
        guard signedIn && !isDemo else { return }
        if syncing { syncAgain = true; return }
        syncing = true
        defer {
            syncing = false
            if syncAgain { syncAgain = false; Task { [weak self] in await self?.synchronize(showErrors: false) } }
        }
        let expected = scope; let client = network
        do {
            // Settings are server authoritative; a second device can revoke cloud consent.
            let revision = settingsRevision
            let remoteSettings: CloudSettings = try Wire.read(await client.request("/v1/settings"))
            if revision == settingsRevision && !changingSettings { settings = remoteSettings; persistSettings() }
            reload(); promoteWalkingRecovery()
            for q in pending {
                guard scope == expected else { return }
                if pending.contains(where: { $0.kind == q.kind && $0.recordId == q.recordId && $0.conflictData != nil }) { continue }
                if q.baseVersion < 0 { q.baseVersion = records.first { $0.kind == q.kind && $0.recordId == q.recordId }?.version ?? 0; try context.save() }
                let raw = try JSONSerialization.jsonObject(with: q.payload)
                let payload: [String: Any] = ["id": q.id, "kind": q.kind, "record_id": q.recordId, "base_version": q.baseVersion, "deleted": q.tombstoned, "payload": raw]
                let reply: SyncReply = try Wire.read(await client.request("/v1/sync", method: "POST", body: JSONSerialization.data(withJSONObject: payload)))
                if reply.status == "conflict" { q.conflictData = try Wire.data(reply.record) }
                else { if let r = records.first(where: { $0.kind == q.kind && $0.recordId == q.recordId }) { r.version = reply.record.version }; context.delete(q) }
                try context.save(); reload()
            }
            let worker = await healthStorage.value
            var uploadedHealth = false
            if settings.healthConsent && !healthUploadPaused {
                updateHealthProgress(try await worker.startBackfill(scope: expected, restart: false, since: healthWindowStart))
                while scope == expected && settings.healthConsent && !healthUploadPaused {
                    let window = healthHistoryWindow
                    if let batch = try await worker.nextUpload(scope: expected, since: healthWindowStart) {
                        guard scope == expected && settings.healthConsent && !healthUploadPaused else { break }
                        if window != healthHistoryWindow { continue }
                        if batch.count > 0 { _ = try await client.request("/v1/health/sync", method: "POST", body: batch.payload); uploadedHealth = true }
                        let progress = try await worker.acknowledge(scope: expected, batch: batch)
                        if scope == expected { updateHealthProgress(progress) }
                    } else {
                        let progress = try await worker.prepareNextBatch(scope: expected, since: healthWindowStart)
                        updateHealthProgress(progress)
                        if progress.finished && progress.pendingBatches == 0 { healthUploadStatus = "所选范围的健康记录已上传"; break }
                    }
                    await Task.yield()
                }
                if uploadedHealth && !healthUploadPaused && pendingHealthCount == 0 && healthUploadProgress?.finished == true {
                    _ = try await client.request("/v1/health/complete", method: "POST", body: Data("{}".utf8))
                }
            }
            struct Pull: Decodable { var records: [CloudRecord] }
            let pull: Pull = try Wire.read(await client.request("/v1/records"))
            reload()
            for c in pull.records {
                if pending.contains(where: { $0.kind == c.kind && $0.recordId == c.id }) { continue }
                if let current = records.first(where: { $0.kind == c.kind && $0.recordId == c.id }), current.version > c.version { continue }
                let payload = try Wire.data(c.payload)
                let r = records.first { $0.kind == c.kind && $0.recordId == c.id } ?? LocalRecord(scope: scope, kind: c.kind, id: c.id, payload: payload)
                if r.modelContext == nil { context.insert(r) }; r.payload = payload; r.version = c.version; r.tombstoned = c.deleted; r.updatedAt = c.updatedAt
            }
            try context.save(); reload(); lastSync = Date()
            if error?.hasPrefix("同步未完成") == true { error = nil }
            // The outbox has already committed. A summary or AI report failure
            // must not be presented as a failed record upload.
            do { cloudSummary = try Wire.read(await client.request("/v1/summary")) }
            catch { if showErrors { self.error = "记录已同步，今日概览暂未更新：\(error.localizedDescription)" } }
            do { report = try Wire.read(await client.request("/v1/report")) }
            catch { if showErrors { self.error = "记录已同步，AI 报告暂未更新：\(error.localizedDescription)" } }
        } catch { context.rollback(); reload(); healthUploadStatus = "上传待重试，已保存断点：\(error.localizedDescription)"; if showErrors { self.error = "同步未完成，记录已留在本机：\(error.localizedDescription)" } }
    }
    func resolve(_ change: PendingChange, keepLocal: Bool) {
        do {
            guard let raw = change.conflictData else { return }; let cloud: CloudRecord = try Wire.read(raw)
            guard let local = records.first(where: { $0.kind == change.kind && $0.recordId == change.recordId }) else { return }
            let localPayload = local.payload; let deleted = local.tombstoned
            for q in pending where q.kind == change.kind && q.recordId == change.recordId { context.delete(q) }
            local.version = cloud.version
            if keepLocal { context.insert(PendingChange(scope: scope, kind: local.kind, recordId: local.recordId, payload: localPayload, deleted: deleted)) }
            else { local.payload = try Wire.data(cloud.payload); local.tombstoned = cloud.deleted }
            try context.save(); reload()
        } catch { context.rollback(); reload(); self.error = error.localizedDescription }
    }
    @discardableResult func enqueueHealth(samples: [HealthSample], anchor: Data?, cursorKey: String, expectedScope: String) async throws -> Bool {
        guard scope == expectedScope && signedIn && healthReadingEnabled else { throw AppError.message("当前空间或本机健康读取设置已变化") }
        let worker = await healthStorage.value
        return try await worker.persist(samples: samples, anchor: anchor, cursorKey: cursorKey, scope: expectedScope, upload: settings.healthConsent && !isDemo)
    }
    func setHealthReading(_ enabled: Bool) {
        healthReadingEnabled = enabled; UserDefaults.standard.set(enabled, forKey: "healthReading.\(scope)")
        if !enabled { healthStatus = "已停止本机健康读取；已有记录仍保留" }
    }
    func resetHealthAnchors() async throws { try await healthStorage.value.resetAnchors(scope: scope) }
    func healthAnchor(key: String) async throws -> Data? { try await healthStorage.value.anchor(key: key) }
    func prepareLocalHealthCache() async throws {
        let marker = "localHealthCacheV1.\(scope)"
        guard !UserDefaults.standard.bool(forKey: marker) else { return }
        try await resetHealthAnchors(); UserDefaults.standard.set(true, forKey: marker)
    }
    func changeHealthWindow(_ value: HealthHistoryWindow) async {
        healthHistoryWindow = value; UserDefaults.standard.set(value.rawValue, forKey: "healthWindow.\(scope)")
        do {
            let worker = await healthStorage.value
            updateHealthProgress(try await worker.startBackfill(scope: scope, restart: true, since: healthWindowStart))
            await refreshLocalHealth()
        } catch { self.error = error.localizedDescription }
    }
    func refreshLocalHealth(markRead: Bool = false) async {
        guard signedIn else { return }
        if markRead { localHealthReadAt = Date(); UserDefaults.standard.set(localHealthReadAt, forKey: "healthReadAt.\(scope)") }
        overviewRequested = true
        if let current = overviewTask { await current.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.overviewTask = nil }
            while self.overviewRequested && self.signedIn {
                self.overviewRequested = false
                let owner = self.scope, window = self.healthHistoryWindow
                do {
                    let worker = await self.healthStorage.value
                    let result = try await worker.overview(scope: owner, zone: self.settings.timezone, now: Date(), water: self.waterToday, since: self.healthWindowStart)
                    guard self.scope == owner && self.healthHistoryWindow == window else { continue }
                    self.localHealthSampleCount = result.count; self.recentHealthSamples = result.latest
                    self.localSummary = result.count > 0 || self.healthReadingEnabled ? result.summary : nil
                    if self.localHealthReadAt != nil && self.healthStatus == "尚未读取健康数据" { self.healthStatus = result.count > 0 ? "所选范围内已保存 \(result.count) 条健康记录" : "上次未读到可访问记录，请检查系统健康授权" }
                    self.reload()
                } catch { self.error = "本机健康概览读取失败：\(error.localizedDescription)" }
            }
        }
        overviewTask = task; await task.value
    }
    func enqueueLocalHealthForUpload() async throws {
        guard settings.healthConsent && !isDemo else { return }
        let worker = await healthStorage.value
        updateHealthProgress(try await worker.startBackfill(scope: scope, restart: true, since: healthWindowStart))
        updateHealthProgress(try await worker.prepareNextBatch(scope: scope, since: healthWindowStart))
    }
    func generateReport() async {
        guard !isDemo else { error = "本地体验不调用云端 AI"; return }
        reportLoading = true; defer { reportLoading = false }
        do { report = try Wire.read(await network.request("/v1/report", method: "POST", body: Data("{}".utf8))) }
        catch { self.error = error.localizedDescription }
    }
    func export() async -> URL? {
        do {
            let data: Data
            if isDemo {
                let values = try records.map { r -> [String: Any] in ["kind": r.kind, "id": r.recordId, "deleted": r.tombstoned, "payload": try JSONSerialization.jsonObject(with: r.payload)] }
                let owner = scope
                let health = try context.fetch(FetchDescriptor<LocalHealthRecord>(predicate: #Predicate { $0.scope == owner })).map { try JSONSerialization.jsonObject(with: $0.payload) }
                data = try JSONSerialization.data(withJSONObject: ["manifest": ["format_version": 1, "scope": "local_only", "timezone": settings.timezone, "exported_at": ISO8601DateFormatter().string(from: Date())], "records": values, "health_samples": health], options: [.prettyPrinted, .sortedKeys])
            } else { await synchronize(); guard pendingCount == 0 && (healthUploadProgress?.finished ?? true) else { throw AppError.message("还有待同步或冲突记录，请先处理后导出云端完整数据") }; data = try await network.request("/v1/export") }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("日益-\(newID()).json")
            try data.write(to: url, options: [.atomic, .completeFileProtection]); return url
        } catch { self.error = error.localizedDescription; return nil }
    }
    func deleteAccount(password: String) async {
        guard !isDemo && !syncing else { return }
        do {
            _ = try await network.request("/v1/account", method: "DELETE", body: Wire.data(["password": password]))
            let oldScope = scope
            UserDefaults.standard.removeObject(forKey: "coach.\(oldScope)"); UserDefaults.standard.removeObject(forKey: "coachReminders.\(oldScope)")
            for r in records { context.delete(r) }; for q in pending { context.delete(q) }
            try context.save()
            try await healthStorage.value.remove(scope: oldScope)
            UserDefaults.standard.removeObject(forKey: "settings.\(oldScope)"); UserDefaults.standard.removeObject(forKey: "healthReading.\(oldScope)"); UserDefaults.standard.removeObject(forKey: "healthReadAt.\(oldScope)")
            UserDefaults.standard.removeObject(forKey: "healthBackfillVerifiedV14.\(oldScope)")
            for window in HealthHistoryWindow.allCases {
                UserDefaults.standard.removeObject(forKey: "healthSweep.\(oldScope).\(window.rawValue)")
                UserDefaults.standard.removeObject(forKey: "sleepCheck.\(oldScope).\(window.rawValue)")
            }
            leave()
        } catch { self.error = error.localizedDescription }
    }
}
