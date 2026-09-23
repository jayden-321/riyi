import Foundation
#if !os(watchOS)
import SwiftData
#endif

func newID() -> String { UUID().uuidString.lowercased() }

enum HealthHistoryWindow: String, CaseIterable, Codable {
    case month = "month", year = "year"
    var title: String { self == .month ? "近 30 天" : "近 1 年" }
    func start(now: Date = Date(), zone: String = TimeZone.current.identifier) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone) ?? .current
        let day = calendar.startOfDay(for: now)
        return self == .month ? calendar.date(byAdding: .day, value: -30, to: day)! : calendar.date(byAdding: .year, value: -1, to: day)!
    }
}

enum Wire {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; e.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var value = encoder.singleValueContainer(); try value.encode(formatter.string(from: date))
        }
        e.outputFormatting = [.sortedKeys]; return e
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter(); standard.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = standard.date(from: value) ?? fractional.date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "无效日期"))
        }; return d
    }
    static func data<T: Encodable>(_ value: T) throws -> Data { try encoder().encode(value) }
    static func read<T: Decodable>(_ data: Data, as: T.Type = T.self) throws -> T { try decoder().decode(T.self, from: data) }
}

struct Plan: Codable, Identifiable {
    var id = newID(); var name = "我的训练计划"; var trainingGoal = "hypertrophy"; var setPattern = "straight"
    var category: String? = nil
    var days: [PlanDay] = [PlanDay()]
    var scheduledDate: String?
    var resolvedCategory: String { category ?? "strength" }
    static func draft() -> Plan { var p = Plan(); p.trainingGoal = "custom"; p.days = [PlanDay(name: "力量训练", exercises: [])]; return p }
    var validEditorDraft: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !days.isEmpty, days.count <= 14 else { return false }
        return days.allSatisfy { day in
            guard !day.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            if resolvedCategory != "strength" {
                guard let activity = day.activity else { return false }
                return activity.sport == resolvedCategory && activity.validConfiguration && day.exercises.isEmpty
            }
            return day.activity == nil && !day.exercises.isEmpty && validGroups(day.groups ?? [], exerciseIds: day.exercises.map(\.id)) &&
                (day.volumeTargetKg == nil || (1...1_000_000).contains(day.volumeTargetKg!)) &&
                day.exercises.allSatisfy { !$0.name.isEmpty && !$0.sets.isEmpty && $0.sets.allSatisfy { $0.weight >= 0 && $0.weight <= 2000 && $0.reps > 0 && $0.reps <= 1000 } }
        }
    }
    static func starter() -> Plan {
        var p = Plan(); p.name = "增肌计划 A"; p.days = [PlanDay(name: "胸 + 三头", exercises: [
            PlanExercise(exerciseId: "bench_press", name: "杠铃卧推", loadBasis: "total", sets: [PlanSet(weight: 40, reps: 12), PlanSet(weight: 50, reps: 10), PlanSet(weight: 55, reps: 8), PlanSet(weight: 55, reps: 8)]),
            PlanExercise(exerciseId: "incline_dumbbell_press", name: "上斜哑铃卧推", loadBasis: "per_hand"),
            PlanExercise(exerciseId: "triceps_pushdown", name: "绳索下压", loadBasis: "total")
        ])]; return p
    }
}
struct ExerciseGroup: Codable, Identifiable {
    var id = newID(); var name = "组合"; var style = "giant"; var exerciseIds: [String] = []
}
let patternOptions = [("straight", "等重组"), ("ascending", "递增组"), ("descending", "递减组"), ("pyramid", "金字塔组"), ("reverse_pyramid", "倒金字塔组"), ("custom", "自定义")]
let groupOptions = [("superset", "超级组"), ("triset", "三合组"), ("giant", "巨人组")]
func groupMinimum(_ style: String) -> Int { style == "giant" ? 4 : style == "triset" ? 3 : 2 }
func groupTitle(_ style: String) -> String { groupOptions.first { $0.0 == style }?.1 ?? "组合" }
func validGroups(_ groups: [ExerciseGroup], exerciseIds: [String]) -> Bool {
    var used = Set<String>()
    return groups.allSatisfy { group in
        groupOptions.contains { $0.0 == group.style } && !group.name.isEmpty &&
        group.exerciseIds.count >= groupMinimum(group.style) &&
        (group.style == "giant" || group.exerciseIds.count == groupMinimum(group.style)) &&
        group.exerciseIds.allSatisfy { exerciseIds.contains($0) && used.insert($0).inserted }
    }
}
struct PlanDay: Codable, Identifiable {
    var id = newID(); var name = "训练日"; var exercises: [PlanExercise] = [PlanExercise()]
    var activity: TimedActivity? = nil
    var volumeTargetKg: Double?; var groups: [ExerciseGroup]?
}
struct PlanExercise: Codable, Identifiable {
    var id = newID(); var exerciseId = "custom"; var name = "新动作"; var loadBasis = "total"
    var sets: [PlanSet] = [PlanSet(), PlanSet(), PlanSet()]
    var setPattern: String?; var loadCount: Int?
}
struct PlanSet: Codable, Identifiable { var id = newID(); var role = "working"; var weight: Double = 20; var reps = 10 }
struct TimedActivity: Codable {
    var name: String
    var targetMinutes: Int? = nil
    var sport: String? = nil
    var targetDistanceMeters: Double? = nil
    var targetEnergyKcal: Double? = nil
    var swimLocation: String? = nil
    var poolLengthMeters: Double? = nil
    var resolvedSport: String { sport ?? "walking" }
    var validConfiguration: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              targetMinutes == nil || (1...1440).contains(targetMinutes!),
              targetDistanceMeters == nil || (1...1_000_000).contains(targetDistanceMeters!),
              targetEnergyKcal == nil || (1...10_000).contains(targetEnergyKcal!) else { return false }
        if resolvedSport == "swimming" {
            if swimLocation == "open_water" { return poolLengthMeters == nil }
            return swimLocation == "pool" && poolLengthMeters.map { (5...100).contains($0) } == true
        }
        return swimLocation == nil && poolLengthMeters == nil
    }
}
let sportOptions: [(code: String, title: String, icon: String)] = [
    ("strength", "力量训练", "dumbbell"), ("pilates", "普拉提", "figure.pilates"),
    ("swimming", "游泳", "figure.pool.swim"), ("running", "跑步", "figure.run"),
    ("cycling", "骑行", "bicycle"), ("walking", "散步", "figure.walk"),
    ("yoga", "瑜伽", "figure.yoga"), ("hiking", "徒步", "figure.hiking"),
    ("rowing", "划船", "figure.rower"), ("elliptical", "椭圆机", "figure.elliptical"),
    ("other", "其他运动", "figure.mixed.cardio")
]
func sportTitle(_ code: String) -> String { sportOptions.first { $0.code == code }?.title ?? "其他运动" }
struct Workout: Codable, Identifiable {
    var synthetic: Bool?
    var activity: TimedActivity?
    var actualDistanceMeters: Double?
    var scheduledBlockId: String?
    var autoExpiredAt: Date?
    var restUntil: Date?
    var companionReceipts: [CompanionReceipt]?
    var id = newID(); var planId: String?; var name: String; var status = "in_progress"
    var startedAt = Date(); var finishedAt: Date?; var timezone = TimeZone.current.identifier
    var exercises: [WorkoutExercise]; var feedback = Feedback()
    var planDayId: String?
    var volumeTargetKg: Double?; var groups: [ExerciseGroup]?
    init(plan: Plan, day: PlanDay, scheduledBlockId: String? = nil) {
        planId = plan.id; name = day.name
        self.scheduledBlockId = scheduledBlockId
        planDayId = day.id
        volumeTargetKg = day.volumeTargetKg
        activity = day.activity
        exercises = day.exercises.map { e in WorkoutExercise(exerciseId: e.exerciseId, name: e.name, loadBasis: e.loadBasis, sets: e.sets.map { WorkoutSet(role: $0.role, plannedWeight: $0.weight, plannedReps: $0.reps) }, setPattern: e.setPattern ?? plan.setPattern, loadCount: e.loadCount) }
        let ids = Dictionary(uniqueKeysWithValues: zip(day.exercises.map(\.id), exercises.map(\.id)))
        groups = day.groups?.map { group in var copy = group; copy.id = newID(); copy.exerciseIds = group.exerciseIds.compactMap { ids[$0] }; return copy }
    }
    init(activity: TimedActivity, scheduledBlockId: String? = nil) {
        self.activity = activity
        self.scheduledBlockId = scheduledBlockId
        name = activity.name
        exercises = []
    }
    var completedSets: Int { exercises.flatMap(\.sets).filter { $0.status == "completed" }.count }
    var totalSets: Int { exercises.flatMap(\.sets).count }
    var completedVolumeKg: Double {
        exercises.reduce(0) { total, exercise in
            guard ["total", "per_hand", "added"].contains(exercise.loadBasis) else { return total }
            let count = exercise.loadBasis == "per_hand" ? (exercise.loadCount ?? 1) : 1
            return total + exercise.sets.filter { $0.status == "completed" && $0.role == "working" }.reduce(0) { $0 + ($1.actualWeight ?? 0) * Double($1.actualReps ?? 0) * Double(count) }
        }
    }
}
struct Feedback: Codable { var painBefore: Int?; var painDuring: Int?; var fatigue: Int?; var note = "" }
struct WorkoutExercise: Codable, Identifiable {
    var id = newID(); var exerciseId: String; var name: String; var loadBasis: String; var sets: [WorkoutSet]
    var setPattern: String?; var loadCount: Int?
}
struct WorkoutSet: Codable, Identifiable {
    var id = newID(); var role: String; var plannedWeight: Double; var plannedReps: Int
    var actualWeight: Double?; var actualReps: Int?; var status = "pending"
    var startedAt: Date?; var completedAt: Date?; var rpe: Double?; var note = ""
}
struct WaterLog: Codable, Identifiable {
    var id = newID(); var amountMl: Int; var drankAt = Date(); var timezone = TimeZone.current.identifier; var source = "manual"
}
struct Profile: Codable, Identifiable {
    var id = newID(); var heightCm: Double?; var waistCm: Double?; var measuredAt = Date(); var updatedAt = Date()
    var goal = "建立规律训练"; var restrictions = ""; var waterGoalMl = 2000; var timezone = TimeZone.current.identifier
}
struct Checkin: Codable, Identifiable {
    var id = newID(); var recordedAt = Date(); var timezone = TimeZone.current.identifier
    var fatigue: Int?; var pain: Int?; var sleepFeeling = ""; var relatedWorkoutId: String?; var note = ""
    var dietNote: String?
}
struct HealthSample: Codable {
    var healthkitUuid: String; var type: String; var value: Double?; var unit: String; var category: String?
    var startAt: Date?; var endAt: Date?; var sourceName = ""; var sourceBundleId = ""; var deviceName = ""
    var metadataJson: [String: JSONValue] = [:]; var workoutJson: [String: JSONValue]?; var deleted = false
}
enum JSONValue: Codable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .string(let s): try c.encode(s); case .number(let n): try c.encode(n); case .bool(let b): try c.encode(b); case .object(let o): try c.encode(o); case .array(let a): try c.encode(a); case .null: try c.encodeNil() }
    }
}

#if !os(watchOS)
@Model final class LocalRecord {
    @Attribute(.unique) var key: String
    var scope: String; var kind: String; var recordId: String; var version: Int; @Attribute(originalName: "deleted") var tombstoned: Bool; var payload: Data; var updatedAt: Date
    init(scope: String, kind: String, id: String, payload: Data) {
        self.key = "\(scope)/\(kind)/\(id)"; self.scope = scope; self.kind = kind; recordId = id
        version = 0; tombstoned = false; self.payload = payload; updatedAt = Date()
    }
}
@Model final class PendingChange {
    @Attribute(.unique) var id: String
    var scope: String; var kind: String; var recordId: String; var payload: Data; @Attribute(originalName: "deleted") var tombstoned: Bool
    var baseVersion: Int; var createdAt: Date; var conflictData: Data?
    init(scope: String, kind: String, recordId: String, payload: Data, deleted: Bool = false, id: String = newID()) {
        self.id = id; self.scope = scope; self.kind = kind; self.recordId = recordId; self.payload = payload; self.tombstoned = deleted
        baseVersion = -1; createdAt = Date()
    }
}
@Model final class HealthCursor {
    @Attribute(.unique) var key: String
    var anchor: Data?; var updatedAt: Date
    init(key: String) { self.key = key; updatedAt = Date() }
}

@Model final class LocalHealthRecord {
    @Attribute(.unique) var key: String
    var scope: String; var sampleId: String; var type: String
    var startAt: Date?; var endAt: Date?; @Attribute(originalName: "deleted") var tombstoned: Bool; var payload: Data
    var cloudUploaded: Bool = false
    init(scope: String, sample: HealthSample, payload: Data) {
        self.key = scope + "/" + sample.healthkitUuid; self.scope = scope
        sampleId = sample.healthkitUuid; type = sample.type; startAt = sample.startAt; endAt = sample.endAt
        tombstoned = sample.deleted; self.payload = payload
    }
}

@Model final class HealthUploadCheckpoint {
    @Attribute(.unique) var scope: String
    var cursor = ""
    var finished = false
    var uploaded = 0
    var target = 0
    init(scope: String) { self.scope = scope }
}

#endif

struct CloudRecord: Codable { var kind: String; var id: String; var version: Int; var deleted: Bool; var payload: JSONValue; var updatedAt: Date }
struct SyncReply: Codable { var operationId: String; var status: String; var record: CloudRecord }
struct Tokens: Codable { var accessToken: String; var refreshToken: String; var userId: String; var expiresIn: Int }
struct CloudSettings: Codable { var timezone = TimeZone.current.identifier; var healthConsent = false; var aiConsent = false }
struct HealthMetric: Codable { var value: Double?; var unit: String; var observedAt: Date?; var source: String; var samples: Int; var coverage: String; var method: String }
struct DailySummary: Codable {
    var date: String; var timezone: String; var activityDate: String; var dataCutoffAt: Date?; var lastHealthSyncAt: Date?
    var metrics: [String: HealthMetric]; var dataQuality: [String]; var training: [Workout]
}
struct ReportBody: Codable {
    var summary: String; var sleepAnalysis: String; var recoveryAnalysis: String; var trainingAnalysis: String
    var bodyTrend: String; var todaySuggestions: [String]; var dataQuality: [String]
}
struct DailyReport: Codable { var status: String; var body: ReportBody?; var generatedAt: Date?; var inputHash: String; var model: String; var stale: Bool; var errorCode: String }

let loadNames = ["total": "合计重量", "per_hand": "每只重量", "added": "额外负重", "assisted": "辅助重量", "bodyweight": "自重"]
