import Foundation
import CryptoKit
import SwiftData

func stableID(_ text: String) -> String {
    let bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    let a = Array(hex); return [String(a[0..<8]), String(a[8..<12]), String(a[12..<16]), String(a[16..<20]), String(a[20..<32])].joined(separator: "-")
}
enum DayKey {
    static func calendar(_ zone: String) -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone) ?? .current; c.firstWeekday = 2; return c }
    static func string(_ date: Date, zone: String) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar(zone); f.timeZone = f.calendar.timeZone; f.dateFormat = "yyyy-MM-dd"; return f.string(from: date) }
    static func date(_ text: String, zone: String) -> Date? { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar(zone); f.timeZone = f.calendar.timeZone; f.dateFormat = "yyyy-MM-dd"; f.isLenient = false; return f.date(from: text) }
}
let mealSlots = [("breakfast", "早餐"), ("lunch", "午餐"), ("dinner", "晚餐"), ("snack", "加餐"), ("drink", "饮料")]
func mealSlot(_ name: String) -> String { mealSlots.first { name.contains($0.1) }?.0 ?? "snack" }
struct NutritionMeal: Codable, Identifiable {
    var id = newID(); var slot = "snack"; var name: String; var foods: [String]; var preparation: String; var alternatives: [String]
}
struct CycleDay: Codable, Identifiable {
    var id = newID(); var date: String; var rest = false; var plan: Plan?; var meals: [NutritionMeal] = []
}
struct PlanningCycle: Codable, Identifiable {
    var id = newID(); var name: String; var kind: String; var startDate: String; var endDate: String; var timezone: String
    var sourceRunId: String?; var days: [CycleDay]
    mutating func shift(to date: Date) {
        guard let old = DayKey.date(startDate, zone: timezone) else { return }
        let c = DayKey.calendar(timezone); let offset = c.dateComponents([.day], from: old, to: c.startOfDay(for: date)).day ?? 0
        for i in days.indices { if let d = DayKey.date(days[i].date, zone: timezone), let changed = c.date(byAdding: .day, value: offset, to: d) { days[i].date = DayKey.string(changed, zone: timezone) } }
        startDate = days.map(\.date).min() ?? startDate; endDate = days.map(\.date).max() ?? endDate
    }
}
struct MealLog: Codable, Identifiable {
    var id = newID(); var slot = "snack"; var description = ""; var eatenAt = Date(); var timezone = TimeZone.current.identifier
    var planMealId: String?; var energyKcal: Double?; var energyMethod = "unknown"; var grams: Double?; var kcalPer100: Double?
    var foodProductId: String?; var nutritionSource: String?
    var quantity: Double?; var quantityUnit: String?
    var energyBasisUnit: String?; var estimateMinKcal: Double?; var estimateMaxKcal: Double?
    mutating func calculateEnergy() {
        if energyMethod == "unknown" {
            energyKcal = nil; grams = nil; kcalPer100 = nil; estimateMinKcal = nil; estimateMaxKcal = nil
            foodProductId = nil; nutritionSource = nil; energyBasisUnit = nil
        } else if energyMethod == "estimated_range" {
            energyKcal = nil; grams = nil; kcalPer100 = nil; foodProductId = nil; energyBasisUnit = nil
        } else {
            estimateMinKcal = nil; estimateMaxKcal = nil
            if energyMethod == "label", let grams, let kcalPer100 { energyKcal = grams * kcalPer100 / 100 }
            if energyMethod != "label" { grams = nil; kcalPer100 = nil; foodProductId = nil; nutritionSource = nil; energyBasisUnit = nil }
        }
    }
    var valid: Bool {
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, description.utf8.count <= 2000, eatenAt <= Date(), mealSlots.contains(where: { $0.0 == slot }) else { return false }
        if energyMethod == "estimated_range" { guard energyKcal == nil, grams == nil, kcalPer100 == nil, let low = estimateMinKcal, let high = estimateMaxKcal else { return false }; return low.isFinite && high.isFinite && (0...30000).contains(low) && (low...30000).contains(high) && nutritionSource?.isEmpty == false }
        if energyMethod == "unknown" { return energyKcal == nil && estimateMinKcal == nil && estimateMaxKcal == nil }
        if estimateMinKcal != nil || estimateMaxKcal != nil { return false }
        guard let energyKcal, energyKcal.isFinite, (0...30000).contains(energyKcal) else { return false }
        if energyMethod == "label" { guard let grams, let kcalPer100, grams.isFinite, kcalPer100.isFinite, (0.1...10000).contains(grams), (0...1000).contains(kcalPer100) else { return false }; return abs(energyKcal - grams * kcalPer100 / 100) < 0.01 }
        return ["manual", "estimated"].contains(energyMethod)
    }
}

func mealEntryTime(for selectedDate: Date, zone: String, now: Date = Date()) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone) ?? .current
    if calendar.isDate(selectedDate, inSameDayAs: now) { return now }
    let clock = calendar.dateComponents([.hour, .minute, .second], from: now)
    return min(calendar.date(bySettingHour: clock.hour ?? 12, minute: clock.minute ?? 0, second: clock.second ?? 0, of: selectedDate) ?? selectedDate, now)
}

struct MealEnergySummary {
    let singleCount: Int
    let singleKcal: Double
    let rangeCount: Int
    let rangeMinKcal: Double
    let rangeMaxKcal: Double
    let unknownCount: Int
    var totalMinKcal: Double { singleKcal + rangeMinKcal }
    var totalMaxKcal: Double { singleKcal + rangeMaxKcal }

    init(_ logs: [MealLog]) {
        var singles = 0, ranges = 0, unknown = 0
        var singleTotal = 0.0, lowTotal = 0.0, highTotal = 0.0
        for log in logs {
            if let kcal = log.energyKcal, kcal.isFinite, kcal >= 0 {
                singles += 1; singleTotal += kcal
            } else if let low = log.estimateMinKcal, let high = log.estimateMaxKcal,
                      low.isFinite, high.isFinite, low >= 0, high >= low {
                ranges += 1; lowTotal += low; highTotal += high
            } else { unknown += 1 }
        }
        singleCount = singles; singleKcal = singleTotal
        rangeCount = ranges; rangeMinKcal = lowTotal; rangeMaxKcal = highTotal
        unknownCount = unknown
    }
}
struct AdoptCycleRequest: Codable { var requestId: String; var cycle: PlanningCycle; var replace: Bool; var versions: [String: Int] }
struct AdoptCycleReply: Codable { var records: [CloudRecord]; var adopted: Int; var kept: Int }

extension CoachRun {
    func legacyCycle(kind: String) -> PlanningCycle? {
        guard let result else { return nil }
        let zone = timezone, start = result.plan?.scheduledDate ?? targetDate
        var days: [CycleDay] = []
        if kind == "diet", let menu = result.meals {
            days = [CycleDay(id: stableID(id + "/diet/day"), date: start, meals: menu.meals.enumerated().map { index, meal in NutritionMeal(id: stableID(id + "/meal/\(index)"), slot: mealSlot(meal.name), name: meal.name, foods: meal.foods, preparation: meal.preparation, alternatives: meal.alternatives) })]
        } else if kind == "training", let p = result.plan, let day = DayKey.date(start, zone: zone) {
            days = p.days.enumerated().map { index, d in
                var plan = p; plan.id = stableID(id + "/training/\(index)"); plan.days = [d]
                return CycleDay(id: stableID(id + "/training/day/\(index)"), date: DayKey.string(DayKey.calendar(zone).date(byAdding: .day, value: index, to: day)!, zone: zone), plan: plan)
            }
        }
        guard !days.isEmpty else { return nil }
        return PlanningCycle(id: stableID(id + "/" + kind), name: kind == "diet" ? "饮食安排" : result.plan?.name ?? "训练安排", kind: kind, startDate: days.first!.date, endDate: days.last!.date, timezone: zone, sourceRunId: id, days: days)
    }
}
extension AppStore {
    var cycles: [PlanningCycle] { values("cycle") }
    var mealLogs: [MealLog] { values("meal") }
    var calendarKey: String { DayKey.string(calendarDate, zone: settings.timezone) }
    func scheduled(_ kind: String, date: String) -> (PlanningCycle, CycleDay)? {
        for c in cycles where c.kind == kind { if let d = c.days.first(where: { $0.date == date }) { return (c,d) } }; return nil
    }
    func meals(on date: String) -> [MealLog] { mealLogs.filter { DayKey.string($0.eatenAt, zone: settings.timezone) == date }.sorted { $0.eatenAt < $1.eatenAt } }
    func workouts(on date: String) -> [Workout] { workouts.filter { DayKey.string($0.startedAt, zone: settings.timezone) == date } }
    func water(on date: String) -> Int { waters.filter { DayKey.string($0.drankAt, zone: settings.timezone) == date }.reduce(0) { $0 + $1.amountMl } }
    func openPlanningChat(kind: String, start: Date, end: Date) {
        let from = DayKey.string(start, zone: settings.timezone), until = DayKey.string(end, zone: settings.timezone)
        var text = "请为我制定 \(from) 到 \(until)（含首尾日期）的\(kind == "diet" ? "饮食" : "训练")周期计划，按每天分别安排。"
        if kind == "diet" { let p = coach?.settings.profile; text += "\n过敏：\(p?.allergies.isEmpty == false ? p!.allergies : "无")\n忌口：\(p?.foodPreferences.isEmpty == false ? p!.foodPreferences : "无")" }
        else { text += "安排适当休息日，已有信息不要重复问；不清楚的条件先跟我沟通。" }
        coachPromptDraft = text; selectedTab = "coach"
    }
    func adoptCycle(_ proposed: PlanningCycle, replace: Bool, requestId: String) async throws -> String {
        guard !isDemo else { throw AppError.message("采用周期计划需要登录云端账号；本地仍可登记训练和饮食。") }
        guard !pending.contains(where: { $0.kind == "cycle" }) else { throw AppError.message("请先完成已有计划同步，再采用新安排") }
        let owner = scope, client = network
        let versions = Dictionary(uniqueKeysWithValues: records.filter { $0.kind == "cycle" }.map { ($0.recordId, $0.version) })
        let reply: AdoptCycleReply = try Wire.read(await client.request("/v1/planning/adopt", method: "POST", body: Wire.data(AdoptCycleRequest(requestId: requestId, cycle: proposed, replace: replace, versions: versions))))
        guard scope == owner else { throw AppError.message("账号已经切换，请返回当前账号查看") }
        do {
            for c in reply.records {
                let r = records.first { $0.kind == c.kind && $0.recordId == c.id } ?? LocalRecord(scope: owner, kind: c.kind, id: c.id, payload: Data())
                if r.modelContext == nil { context.insert(r) }; r.payload = try Wire.data(c.payload); r.version = c.version; r.tombstoned = c.deleted; r.updatedAt = c.updatedAt
            }
            try context.save(); reload()
        } catch { context.rollback(); reload(); throw error }
        calendarDate = DayKey.date(proposed.startDate, zone: proposed.timezone) ?? Date()
        selectedTab = proposed.kind == "diet" ? "diet" : "training"
        return "已采用 \(reply.adopted) 天，保留 \(reply.kept) 天已有或已开始的安排。"
    }
}
