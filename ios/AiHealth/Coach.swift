import Foundation

struct CoachProfile: Codable {
    var goal = ""; var experience = ""; var daysPerWeek = 0; var sessionMinutes = 0
    var exercisesPerSession = 0; var setsPerExercise = 0
    var equipment = ""; var limitations = ""; var allergies = ""; var foodPreferences = ""; var cookingConditions = ""
}
struct CoachSettings: Codable {
    var style = "balanced"; var profile = CoachProfile()
    var fitnessEnabled = false; var sleepEnabled = false; var autoAdopt = false
    var fitnessAnalysisMinute = 22 * 60 + 30; var fitnessReminderMinute = 8 * 60
    var sleepAnalysisMinute = 20 * 60; var sleepReminderMinute = 21 * 60
}
struct CoachMeal: Codable { var name: String; var foods: [String]; var preparation: String; var alternatives: [String] }
struct CoachMeals: Codable { var meals: [CoachMeal]; var notes: [String] }
struct CoachCompareAnswer: Codable {
    var message: String; var questions: [String]; var error: String?
}
struct CoachResult: Codable {
    var variantB: CoachCompareAnswer?
    var variantAError: String?
    var cycle: PlanningCycle?
    var frameworks: [String]?
    var message: String; var questions: [String]; var rationale: [String]; var dataQuality: [String]
    var profile: CoachProfile; var action: String; var plan: Plan?; var meals: CoachMeals?; var needsReview: Bool
    var dataCutoffAt: Date?; var lastHealthSyncAt: Date?
}
struct CoachRun: Codable, Identifiable {
    var id: String; var requestId: String? = nil; var kind: String; var targetDate: String; var timezone: String; var status: String
    var message: String; var result: CoachResult?; var model: String; var planId: String?; var errorCode: String
    var notifyAt: Date?; var createdAt: Date; var completedAt: Date?
}
struct CoachState: Codable {
    var settings = CoachSettings(); var runs: [CoachRun] = []; var archivedChats: Int?
    var conversationRuns: [CoachRun] { runs.filter { $0.kind == "chat" } }
    var analysisRuns: [CoachRun] { runs.filter { $0.kind != "chat" } }
}

extension AppStore {
    var coach: CoachState? { coachOwner == scope ? coachState : nil }
    var coachTodayPlan: Plan? {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = TimeZone(identifier: settings.timezone)
        let today = formatter.string(from: Date())
        guard let run = coach?.runs.first(where: { $0.kind == "fitness" && $0.targetDate == today && $0.status == "completed" }), let id = run.planId else { return nil }
        return plans.first { $0.id == id }
    }
    var todayPlan: Plan? {
        let key = DayKey.string(Date(), zone: settings.timezone)
        if let (_, day) = scheduled("training", date: key) {
            if day.rest { return nil }
            return day.trainingBlocks.first(where: { block in
                block.plan != nil && !["completed", "cancelled"].contains(workout(for: block, on: key)?.status ?? "")
            })?.plan
        }
        if let plan = coachTodayPlan { return plan }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = TimeZone(identifier: settings.timezone)
        let today = formatter.string(from: Date())
        return plans.first { $0.scheduledDate == today }
    }
    func loadCoach() async {
        guard signedIn && !isDemo else { return }
        let owner = scope, client = network, revision = coachRevision
        if coachOwner != owner, let data = UserDefaults.standard.data(forKey: "coach.\(owner)"), let cached = try? Wire.read(data, as: CoachState.self) { coachState = cached; coachOwner = owner }
        do {
            let value: CoachState = try Wire.read(await client.request("/v1/coach"))
            guard scope == owner && coachRevision == revision else { return }
            let encoded = try Wire.data(value)
            if coachOwner != owner || (coachState.flatMap { try? Wire.data($0) }) != encoded {
                coachState = value
                UserDefaults.standard.set(encoded, forKey: "coach.\(owner)")
            }
            coachOwner = owner
            scheduleCoachPolling()
            if coachError?.hasPrefix("教练数据暂未更新") == true { coachError = nil }
        } catch { if scope == owner && coachRevision == revision { coachError = "教练数据暂未更新：\(error.localizedDescription)" } }
    }
    private func scheduleCoachPolling() {
        guard let run = coach?.runs.first(where: { $0.status == "running" }) else {
            coachPollTask?.cancel(); coachPollTask = nil; coachPollOwner = ""; coachPollRunID = ""
            return
        }
        let owner = scope, id = run.id
        if coachPollTask != nil && coachPollOwner == owner && coachPollRunID == id { return }
        coachPollTask?.cancel(); coachPollOwner = owner; coachPollRunID = id
        coachPollTask = Task { [weak self] in
            var attempts = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(attempts < 12 ? 3 : 12)) } catch { return }
                guard let self, self.scope == owner, !Task.isCancelled else { return }
                await self.loadCoach()
                guard self.scope == owner else { return }
                let state = self.coach?.runs.first(where: { $0.id == id })?.status
                if state == "failed" { self.coachPendingID = newID(); self.coachError = "AI 教练本次未完成，可重新发送你的问题。" }
                if state != "running" { return }
                attempts += 1
            }
        }
    }
    func sendCoach(_ message: String, analysisDate: String? = nil) async -> Bool {
        guard signedIn && !isDemo && settings.aiConsent && !coachBusy else { return false }
        coachBusy = true; coachError = nil; defer { coachBusy = false }
        let owner = scope, client = network
        let requestIdentity = message + "\nanalysis_date=" + (analysisDate ?? "")
        if coachPendingMessage != requestIdentity || coachPendingOwner != owner { coachPendingID = newID(); coachPendingMessage = requestIdentity; coachPendingOwner = owner }
        let submittedID = coachPendingID
        do {
            var body = ["request_id": coachPendingID, "message": message]
            if let analysisDate { body["analysis_date"] = analysisDate }
            #if DEBUG
            body["compare"] = "ab"
            #endif
            let run: CoachRun = try Wire.read(await client.request("/v1/coach/message", method: "POST", body: Wire.data(body)))
            guard scope == owner else { return false }
            if run.status == "failed" { coachPendingID = newID(); coachError = "上次生成未完成，请点发送重试。"; await loadCoach(); return false }
            await loadCoach()
            if run.status == "running" { scheduleCoachPolling(); return true }
            coachPendingID = newID(); return true
        } catch {
            guard scope == owner else { return false }
            if needsReauthentication { coachError = "云端登录已过期，请重新登录。"; return false }
            // A lost POST response does not mean the server lost the request.
            // Check the durable request ID before making another generation.
            for attempt in 0..<5 {
                await loadCoach()
                guard scope == owner else { return false }
                if let run = coach?.runs.first(where: { $0.requestId == submittedID }) {
                    if run.status == "running" { coachError = nil; scheduleCoachPolling(); return true }
                    if run.status == "completed" { coachPendingID = newID(); coachError = nil; return true }
                    coachPendingID = newID()
                    coachError = "AI 教练本次未完成，原问题已保留，可稍后重试。"
                    return false
                }
                if attempt < 4 { try? await Task.sleep(for: .seconds(2)) }
            }
            coachError = "连接暂时中断，尚未确认教练是否收到；重发时会使用同一请求号，避免重复生成。"
            return false
        }
    }
    func analyzeCoach(_ kind: String) async {
        guard !coachBusy && !isDemo && settings.aiConsent else { return }
        coachBusy = true; coachError = nil; defer { coachBusy = false }
        let owner = scope, client = network
        do {
            let _: CoachRun = try Wire.read(await client.request("/v1/coach/analyze", method: "POST", body: Wire.data(["request_id": newID(), "kind": kind])))
            guard scope == owner else { return }; await loadCoach(); await synchronize(showErrors: false)
        } catch { if scope == owner { coachError = error.localizedDescription; await loadCoach() } }
    }
    func saveCoachSettings(_ value: CoachSettings) async -> Bool {
        let owner = scope, client = network
        do {
            let _: CoachSettings = try Wire.read(await client.request("/v1/coach/settings", method: "PUT", body: Wire.data(value)))
            guard scope == owner else { return false }; await loadCoach(); return true
        } catch { if scope == owner { coachError = error.localizedDescription }; return false }
    }
    func clearCoachConversation(restore: Bool = false) async {
        guard signedIn && !isDemo && !coachBusy else { return }
        coachBusy = true; coachError = nil; coachRevision += 1
        coachPollTask?.cancel(); coachPollTask = nil; coachPollOwner = ""; coachPollRunID = ""
        defer { coachBusy = false }
        let owner = scope, client = network
        do {
            struct Reply: Decodable { var affected: Int }
            let reply: Reply = try Wire.read(await client.request("/v1/coach/conversation/" + (restore ? "restore" : "clear"), method: "POST", body: Data("{}".utf8)))
            guard scope == owner else { return }
            coachPendingID = newID(); coachPendingMessage = ""
            if !restore, var visible = coach {
                visible.runs.removeAll { $0.kind == "chat" }
                visible.archivedChats = (visible.archivedChats ?? 0) + reply.affected
                coachState = visible; coachOwner = owner
                if let data = try? Wire.data(visible) { UserDefaults.standard.set(data, forKey: "coach.\(owner)") }
            }
            await loadCoach()
        } catch { if scope == owner { coachError = error.localizedDescription } }
    }
}
