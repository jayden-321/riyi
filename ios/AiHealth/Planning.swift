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
    var id = newID(); var date: String; var rest = false; var recoveryActivity: String? = nil; var activity: TimedActivity? = nil; var plan: Plan?; var sessions: [TrainingBlock]? = nil; var meals: [NutritionMeal] = []
    var trainingBlocks: [TrainingBlock] {
        if let sessions { return sessions }
        if let plan { return [TrainingBlock(id: stableID(id + "/legacy-plan"), plan: plan)] }
        if let activity { return [TrainingBlock(id: stableID(id + "/legacy-activity"), activity: activity)] }
        return []
    }
    mutating func setTrainingBlocks(_ blocks: [TrainingBlock]) {
        sessions = blocks
        plan = nil; activity = nil; recoveryActivity = nil
        rest = blocks.isEmpty
    }
    mutating func setTrainingEnabled(_ enabled: Bool) {
        let existing = trainingBlocks
        rest = !enabled
        sessions = enabled ? existing : nil
        plan = nil; activity = nil
        if enabled { recoveryActivity = nil }
    }
}
struct TrainingBlock: Codable, Identifiable {
    var id = newID()
    var plan: Plan? = nil
    var activity: TimedActivity? = nil
    var name: String { plan?.days.first?.name ?? activity?.name ?? "训练项目" }
    var sport: String { plan?.resolvedCategory ?? activity?.resolvedSport ?? "other" }
    var editorPlan: Plan {
        if let plan { return plan }
        guard let activity else { return Plan.draft() }
        var result = Plan.draft()
        result.name = activity.name; result.category = activity.resolvedSport
        result.days = [PlanDay(name: activity.name, exercises: [], activity: activity)]
        return result
    }
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
func singleDayTrainingCycle(_ plan: Plan, date: String, timezone: String) -> PlanningCycle {
    var snapshot = plan
    snapshot.scheduledDate = date
    snapshot.days = Array(plan.days.prefix(1))
    return PlanningCycle(name: plan.name, kind: "training", startDate: date, endDate: date, timezone: timezone,
                         days: [CycleDay(date: date, sessions: [TrainingBlock(plan: snapshot)])])
}
func manualTrainingDays(from start: Date, through end: Date, timezone: String, preserving existing: [CycleDay] = []) -> [CycleDay] {
    let calendar = DayKey.calendar(timezone)
    let first = calendar.startOfDay(for: start), last = calendar.startOfDay(for: end)
    let count = (calendar.dateComponents([.day], from: first, to: last).day ?? -1) + 1
    guard (1...31).contains(count) else { return [] }
    let previous = Dictionary(uniqueKeysWithValues: existing.map { ($0.date, $0) })
    return (0..<count).compactMap { offset in
        guard let date = calendar.date(byAdding: .day, value: offset, to: first) else { return nil }
        let key = DayKey.string(date, zone: timezone)
        return previous[key] ?? CycleDay(date: key, rest: true)
    }
}
struct MealLog: Codable, Identifiable {
    var id = newID(); var slot = "snack"; var description = ""; var eatenAt = Date(); var timezone = TimeZone.current.identifier
    var planMealId: String?; var energyKcal: Double?; var energyMethod = "unknown"; var grams: Double?; var kcalPer100: Double?
    var foodProductId: String?; var nutritionSource: String?
    var quantity: Double?; var quantityUnit: String?
    var energyBasisUnit: String?; var estimateMinKcal: Double?; var estimateMaxKcal: Double?
    var proteinG: Double?; var proteinMinG: Double?; var proteinMaxG: Double?
    var fatG: Double?; var fatMinG: Double?; var fatMaxG: Double?
    var carbG: Double?; var carbMinG: Double?; var carbMaxG: Double?
    var macroSource: String?
    mutating func clearMacros() {
        proteinG = nil; proteinMinG = nil; proteinMaxG = nil
        fatG = nil; fatMinG = nil; fatMaxG = nil
        carbG = nil; carbMinG = nil; carbMaxG = nil; macroSource = nil
    }
    mutating func clearEstimatedMacros() {
        proteinMinG = nil; proteinMaxG = nil; fatMinG = nil; fatMaxG = nil; carbMinG = nil; carbMaxG = nil
    }
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
        for (exact, low, high) in [(proteinG, proteinMinG, proteinMaxG), (fatG, fatMinG, fatMaxG), (carbG, carbMinG, carbMaxG)] {
            if let exact, !exact.isFinite || !(0...10000).contains(exact) || low != nil || high != nil { return false }
            if (low == nil) != (high == nil) { return false }
            if let low, let high, !low.isFinite || !high.isFinite || !(0...10000).contains(low) || !(low...10000).contains(high) || macroSource?.isEmpty != false { return false }
        }
        if energyMethod == "estimated_range" { guard energyKcal == nil, grams == nil, kcalPer100 == nil, let low = estimateMinKcal, let high = estimateMaxKcal else { return false }; return low.isFinite && high.isFinite && (0...30000).contains(low) && (low...30000).contains(high) && nutritionSource?.isEmpty == false }
        if energyMethod == "unknown" { return energyKcal == nil && estimateMinKcal == nil && estimateMaxKcal == nil }
        if estimateMinKcal != nil || estimateMaxKcal != nil { return false }
        guard let energyKcal, energyKcal.isFinite, (0...30000).contains(energyKcal) else { return false }
        if energyMethod == "label" { guard let grams, let kcalPer100, grams.isFinite, kcalPer100.isFinite, (0.1...10000).contains(grams), (0...1000).contains(kcalPer100) else { return false }; return abs(energyKcal - grams * kcalPer100 / 100) < 0.01 }
        return ["manual", "estimated"].contains(energyMethod)
    }
}

struct MealMacroTotal {
    let exactG: Double
    let exactCount: Int
    let minG: Double
    let maxG: Double
    let rangeCount: Int
    let unknownCount: Int
    var midpointG: Double { exactG + (minG + maxG) / 2 }
    var hasEstimates: Bool { rangeCount > 0 }
    var hasData: Bool { exactCount + rangeCount > 0 }
    init(_ logs: [MealLog], exact: KeyPath<MealLog, Double?>, low: KeyPath<MealLog, Double?>, high: KeyPath<MealLog, Double?>) {
        var exactTotal = 0.0, minTotal = 0.0, maxTotal = 0.0, unknown = 0, ranges = 0, singles = 0
        for log in logs {
            if let value = log[keyPath: exact], value.isFinite, value >= 0 { exactTotal += value; singles += 1 }
            else if let minimum = log[keyPath: low], let maximum = log[keyPath: high], minimum.isFinite, maximum.isFinite, minimum >= 0, maximum >= minimum {
                minTotal += minimum; maxTotal += maximum; ranges += 1
            } else { unknown += 1 }
        }
        exactG = exactTotal; exactCount = singles; minG = minTotal; maxG = maxTotal; rangeCount = ranges; unknownCount = unknown
    }
}

struct ProteinTarget {
    let weightKg: Double
    let factor: Double
    var grams: Double { weightKg * factor }
    static func make(weightKg: Double?, goal: String, chosenFactor: Double?) -> ProteinTarget? {
        guard let weightKg, weightKg.isFinite, (20...400).contains(weightKg) else { return nil }
        let factor: Double
        if let chosenFactor { factor = chosenFactor }
        else if goal.contains("减脂") || goal.contains("减重") { factor = 1.8 }
        else if goal.contains("增肌") || goal.contains("力量") { factor = 1.6 }
        else { factor = 1.4 }
        guard (1.4...2.0).contains(factor) else { return nil }
        return ProteinTarget(weightKg: weightKg, factor: factor)
    }
}

struct DailyNutritionTargets {
    let energyKcal: Double?
    let proteinG: Double?
    let fatG: Double?
    let carbG: Double?
    let energySource: String

    static func make(profile: Profile, weightKg: Double?, energyBaselineKcal: Double?, energyBaselineDays: Int) -> Self {
        let energy: Double?
        let energySource: String
        if let manual = profile.energyGoalKcal {
            energy = manual; energySource = "手动目标"
        } else if let baseline = energyBaselineKcal, energyBaselineDays >= 3 {
            let factor = profile.goal.contains("减脂") || profile.goal.contains("减重") ? 0.9 : profile.goal.contains("增肌") || profile.goal.contains("增重") ? 1.1 : 1.0
            energy = (baseline * factor / 10).rounded() * 10
            energySource = "Apple 健康近\(energyBaselineDays)日消耗参考"
        } else { energy = nil; energySource = "等待健康数据" }
        let protein = profile.proteinGoalG ?? ProteinTarget.make(weightKg: weightKg, goal: profile.goal, chosenFactor: profile.proteinFactor)?.grams
        let fat = profile.fatGoalG ?? energy.map { ($0 * 0.3 / 9).rounded() }
        let carb = profile.carbGoalG ?? {
            guard let energy, let protein, let fat else { return nil }
            let remaining = energy - protein * 4 - fat * 9
            guard remaining > 0 else { return nil }
            return (remaining / 4).rounded()
        }()
        return Self(energyKcal: energy, proteinG: protein, fatG: fat, carbG: carb, energySource: energySource)
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
    var totalMidpointKcal: Double { (totalMinKcal + totalMaxKcal) / 2 }

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
    func trainingBlocks(on date: String) -> [TrainingBlock] {
        if let (_, day) = scheduled("training", date: date) { return day.trainingBlocks }
        if let legacy = plans.first(where: { $0.scheduledDate == date }) {
            return [TrainingBlock(id: stableID("legacy-template/" + legacy.id + "/" + date), plan: legacy)]
        }
        return []
    }
    func associatedBlockID(for workout: Workout, on date: String) -> String? {
        let blocks = trainingBlocks(on: date)
        if let id = workout.scheduledBlockId { return blocks.contains(where: { $0.id == id }) ? id : nil }
        if let planID = workout.planId {
            let matching = blocks.filter { $0.plan?.id == planID }
            if matching.count == 1 { return matching[0].id }
        }
        // Historical timed activities can predate the calendar plan. Infer a
        // display grouping only when that sport has exactly one planned block.
        guard let activity = workout.activity else { return nil }
        let sameSport = blocks.filter { $0.sport == activity.resolvedSport }
        return sameSport.count == 1 ? sameSport[0].id : nil
    }
    func workouts(for block: TrainingBlock, on date: String) -> [Workout] {
        workouts(on: date).filter { associatedBlockID(for: $0, on: date) == block.id }
    }
    func workout(for block: TrainingBlock, on date: String) -> Workout? {
        workouts(for: block, on: date).first
    }
    func hasProtectedTrainingRecords(for block: TrainingBlock, on date: String) -> Bool {
        workouts(for: block, on: date).contains { $0.status == "completed" || $0.status == "in_progress" }
    }
    func upsertTrainingBlock(on date: String, blockID: String? = nil, plan: Plan) async throws {
        guard plan.validEditorDraft, plan.days.count == 1 else { throw AppError.message("请先完成这一个训练项目") }
        var snapshot = plan; snapshot.scheduledDate = date
        if let (cycle, day) = scheduled("training", date: date), let dayIndex = cycle.days.firstIndex(where: { $0.id == day.id }) {
            var blocks = day.trainingBlocks
            if let blockID {
                guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { throw AppError.message("训练项目已变化，请重新打开这一天") }
                blocks[index] = TrainingBlock(id: blockID, plan: snapshot)
            } else {
                guard blocks.count < 8 else { throw AppError.message("同一天最多安排 8 个训练项目") }
                blocks.append(TrainingBlock(plan: snapshot))
            }
            var changed = cycle; changed.days[dayIndex].setTrainingBlocks(blocks)
            guard save(changed, kind: "cycle", id: cycle.id) else { throw AppError.message(error ?? "训练安排未保存") }
            if !isDemo { await synchronize(showErrors: true) }
        } else {
            var blocks = trainingBlocks(on: date)
            if let blockID {
                guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { throw AppError.message("训练项目已变化，请重新打开这一天") }
                blocks[index] = TrainingBlock(id: blockID, plan: snapshot)
            } else {
                guard blocks.count < 8 else { throw AppError.message("同一天最多安排 8 个训练项目") }
                blocks.append(TrainingBlock(plan: snapshot))
            }
            let cycle = PlanningCycle(name: snapshot.name, kind: "training", startDate: date, endDate: date, timezone: settings.timezone,
                                      days: [CycleDay(date: date, sessions: blocks)])
            if isDemo {
                guard save(cycle, kind: "cycle", id: cycle.id) else { throw AppError.message(error ?? "训练安排未保存") }
            } else if !workouts(on: date).isEmpty {
                // The user is adding a plan after an actual workout already exists.
                // AI adoption protects recorded days, but an explicit user addition
                // must be allowed without changing or deleting that workout.
                guard save(cycle, kind: "cycle", id: cycle.id) else { throw AppError.message(error ?? "训练安排未保存") }
                await synchronize(showErrors: true)
            } else {
                _ = try await adoptCycle(cycle, replace: false, requestId: newID(), minimumAdopted: 1)
            }
            if var legacy = plans.first(where: { $0.scheduledDate == date }) {
                legacy.scheduledDate = nil
                _ = save(legacy, kind: "plan", id: legacy.id)
                if !isDemo { await synchronize(showErrors: true) }
            }
        }
    }
    @discardableResult func deleteTrainingBlock(on date: String, blockID: String) -> Bool {
        guard let target = trainingBlocks(on: date).first(where: { $0.id == blockID }) else {
            error = "训练项目已变化，请刷新后重试"; return false
        }
        guard !hasProtectedTrainingRecords(for: target, on: date) else {
            error = "这项训练已有完成或进行中的记录，不能删除。请新增训练项目。"; return false
        }
        guard let (cycle, day) = scheduled("training", date: date) else {
            if var legacy = plans.first(where: { $0.scheduledDate == date && stableID("legacy-template/" + $0.id + "/" + date) == blockID }) {
                legacy.scheduledDate = nil
                guard save(legacy, kind: "plan", id: legacy.id) else { return false }
                if !isDemo { Task { await synchronize(showErrors: true) } }
                return true
            }
            error = "训练项目已变化，请刷新后重试"; return false
        }
        guard
              let dayIndex = cycle.days.firstIndex(where: { $0.id == day.id }),
              day.trainingBlocks.contains(where: { $0.id == blockID }) else { error = "训练项目已变化，请刷新后重试"; return false }
        var changed = cycle
        let remaining = day.trainingBlocks.filter { $0.id != blockID }
        if !remaining.isEmpty { changed.days[dayIndex].setTrainingBlocks(remaining) }
        else if changed.days.count == 1 { remove(kind: "cycle", id: cycle.id); return scheduled("training", date: date) == nil }
        else {
            changed.days.remove(at: dayIndex)
            changed.startDate = changed.days.map(\.date).min() ?? cycle.startDate
            changed.endDate = changed.days.map(\.date).max() ?? cycle.endDate
        }
        guard save(changed, kind: "cycle", id: cycle.id) else { return false }
        if !isDemo { Task { await synchronize(showErrors: true) } }
        return true
    }
    func promoteWalkingRecovery() {
        for cycle in cycles where cycle.kind == "training" {
            var changed = cycle
            var needsSave = false
            for index in changed.days.indices {
                let day = changed.days[index]
                guard day.rest, day.activity == nil,
                      let title = day.recoveryActivity?.trimmingCharacters(in: .whitespacesAndNewlines),
                      title.contains("散步") else { continue }
                changed.days[index].rest = false
                changed.days[index].recoveryActivity = nil
                changed.days[index].activity = TimedActivity(name: title, sport: "walking")
                needsSave = true
            }
            if needsSave { _ = save(changed, kind: "cycle", id: cycle.id) }
        }
    }
    @discardableResult func setRestDayRecovery(on date: String, activity: String) -> Bool {
        let value = activity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 240 else { error = "恢复活动最多填写 240 字"; return false }
        guard let (cycle, day) = scheduled("training", date: date), day.rest,
              let index = cycle.days.firstIndex(where: { $0.id == day.id }) else { error = "这一天没有可修改的休息安排"; return false }
        var changed = cycle; changed.days[index].recoveryActivity = value.isEmpty ? nil : value
        guard save(changed, kind: "cycle", id: cycle.id) else { return false }
        if !isDemo { Task { await synchronize(showErrors: true) } }
        return true
    }
    @discardableResult func convertRestToActivity(on date: String, name: String, targetMinutes: Int?) -> Bool {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120, targetMinutes == nil || (1...1440).contains(targetMinutes!) else { error = "请填写活动名称；目标时长须为 1–1440 分钟"; return false }
        guard let (cycle, day) = scheduled("training", date: date), day.rest,
              let index = cycle.days.firstIndex(where: { $0.id == day.id }) else { error = "这一天没有可修改的休息安排"; return false }
        var changed = cycle
        changed.days[index].rest = false
        changed.days[index].recoveryActivity = nil
        changed.days[index].activity = TimedActivity(name: title, targetMinutes: targetMinutes, sport: "walking")
        guard save(changed, kind: "cycle", id: cycle.id) else { return false }
        if !isDemo { Task { await synchronize(showErrors: true) } }
        return true
    }
    @discardableResult func deleteRestDay(on date: String) -> Bool {
        guard let (cycle, day) = scheduled("training", date: date), day.rest else { error = "这一天没有可删除的休息安排"; return false }
        if cycle.days.count == 1 {
            remove(kind: "cycle", id: cycle.id)
            return scheduled("training", date: date) == nil
        }
        var changed = cycle; changed.days.removeAll { $0.id == day.id }
        changed.startDate = changed.days.map(\.date).min() ?? cycle.startDate
        changed.endDate = changed.days.map(\.date).max() ?? cycle.endDate
        guard save(changed, kind: "cycle", id: cycle.id) else { return false }
        if !isDemo { Task { await synchronize(showErrors: true) } }
        return true
    }
    @discardableResult func updateActivity(on date: String, activity: TimedActivity, blockID: String? = nil) -> Bool {
        let name = activity.name
        let sport = activity.resolvedSport
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120, sportOptions.contains(where: { $0.code == sport && sport != "strength" }), activity.validConfiguration else { error = "请检查运动类型、目标及游泳地点／泳池长度"; return false }
        guard let (cycle, day) = scheduled("training", date: date),
              let index = cycle.days.firstIndex(where: { $0.id == day.id }) else { error = "这一天没有可修改的活动"; return false }
        var changed = cycle; var updated = activity; updated.name = title
        if let blockID {
            var blocks = day.trainingBlocks
            guard let blockIndex = blocks.firstIndex(where: { $0.id == blockID && $0.activity != nil }) else { error = "训练项目已变化"; return false }
            blocks[blockIndex].activity = updated
            changed.days[index].setTrainingBlocks(blocks)
        } else {
            guard day.activity != nil else { error = "这一天没有可修改的活动"; return false }
            changed.days[index].activity = updated
        }
        guard save(changed, kind: "cycle", id: cycle.id) else { return false }
        if !isDemo { Task { await synchronize(showErrors: true) } }
        return true
    }
    @discardableResult func deleteActivity(on date: String) -> Bool {
        guard let (cycle, day) = scheduled("training", date: date), day.activity != nil else { error = "这一天没有可删除的活动"; return false }
        if let target = day.trainingBlocks.first, hasProtectedTrainingRecords(for: target, on: date) {
            error = "这项训练已有完成或进行中的记录，不能删除。请新增训练项目。"; return false
        }
        if cycle.days.count == 1 { remove(kind: "cycle", id: cycle.id); return scheduled("training", date: date) == nil }
        var changed = cycle; changed.days.removeAll { $0.id == day.id }
        changed.startDate = changed.days.map(\.date).min() ?? cycle.startDate
        changed.endDate = changed.days.map(\.date).max() ?? cycle.endDate
        guard save(changed, kind: "cycle", id: cycle.id) else { return false }
        if !isDemo { Task { await synchronize(showErrors: true) } }
        return true
    }
    @discardableResult func deleteScheduledTraining(on date: String, planID: String? = nil) -> Bool {
        if let (_, day) = scheduled("training", date: date),
           let block = day.trainingBlocks.first(where: { $0.plan != nil && (planID == nil || $0.plan?.id == planID) }) {
            return deleteTrainingBlock(on: date, blockID: block.id)
        }
        if var legacy = plans.first(where: { $0.scheduledDate == date && (planID == nil || $0.id == planID) }) {
            if let target = trainingBlocks(on: date).first(where: { $0.plan?.id == legacy.id }), hasProtectedTrainingRecords(for: target, on: date) {
                error = "这项训练已有完成或进行中的记录，不能删除。请新增训练项目。"; return false
            }
            legacy.scheduledDate = nil
            guard save(legacy, kind: "plan", id: legacy.id) else { return false }
            if !isDemo { Task { await synchronize(showErrors: true) } }
            return true
        }
        error = "这一天没有可删除的训练安排"
        return false
    }
    func updateScheduledTraining(_ plan: Plan, on date: String) async throws {
        guard plan.days.count == 1, plan.validEditorDraft else { throw AppError.message("请先完成当天训练项目") }
        if let (_, day) = scheduled("training", date: date), let block = day.trainingBlocks.first(where: { $0.plan?.id == plan.id }) {
            try await upsertTrainingBlock(on: date, blockID: block.id, plan: plan)
        } else if isDemo, plans.contains(where: { $0.id == plan.id }) {
            var changed = plan; changed.scheduledDate = date
            guard save(changed, kind: "plan", id: plan.id) else { throw AppError.message(error ?? "安排未保存") }
        } else {
            try await upsertTrainingBlock(on: date, plan: plan)
        }
    }
    func meals(on date: String) -> [MealLog] { mealLogs.filter { DayKey.string($0.eatenAt, zone: settings.timezone) == date }.sorted { $0.eatenAt < $1.eatenAt } }
    func workouts(on date: String) -> [Workout] { workouts.filter { DayKey.string($0.startedAt, zone: settings.timezone) == date } }
    func waters(on date: String) -> [WaterLog] { waters.filter { DayKey.string($0.drankAt, zone: settings.timezone) == date } }
    func water(on date: String) -> Int { waters(on: date).reduce(0) { $0 + $1.amountMl } }
    func openPlanningChat(kind: String, start: Date, end: Date) {
        let from = DayKey.string(start, zone: settings.timezone), until = DayKey.string(end, zone: settings.timezone)
        var text = "请为我制定 \(from) 到 \(until)（含首尾日期）的\(kind == "diet" ? "饮食" : "训练")周期计划，按每天分别安排。"
        if kind == "diet" { let p = coach?.settings.profile; text += "\n过敏：\(p?.allergies.isEmpty == false ? p!.allergies : "无")\n忌口：\(p?.foodPreferences.isEmpty == false ? p!.foodPreferences : "无")" }
        else { text += "安排适当休息日，已有信息不要重复问；不清楚的条件先跟我沟通。" }
        coachPromptDraft = text; selectedTab = "coach"
    }
    func adoptCycle(_ proposed: PlanningCycle, replace: Bool, requestId: String, minimumAdopted: Int = 0) async throws -> String {
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
        if reply.adopted < minimumAdopted { throw AppError.message("这一天已有受保护的训练记录，原安排已保留；请选择其他日期") }
        return "已采用 \(reply.adopted) 天，保留 \(reply.kept) 天已有或已开始的安排。"
    }
}
