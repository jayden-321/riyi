import Foundation

/// Versioned, credential-free WCSession protocol. iPhone is the commit authority.
struct CompanionEvent: Codable, Identifiable {
    var id = newID()
    var binding: String
    var sessionId: String
    var exerciseId: String
    var setId: String
    var expectedSet: String
    var action: String
    var observedAt: Date
    var weight: Double?
    var reps: Int?
}
struct CompanionReceipt: Codable {
    var event: CompanionEvent
    var outcome: String
    var committedAt: Date
}
struct CompanionStartOffer: Codable {
    var date: String
    var timezone: String
    var plan: Plan
    var day: PlanDay
}
struct CompanionStartRequest: Codable, Identifiable {
    var id = newID()
    var binding: String
    var date: String
    var planId: String
    var dayId: String
    var observedAt: Date
}
struct CompanionStartReceipt: Codable {
    var requestId: String
    var outcome: String
    var workoutId: String?
}
struct CompanionSnapshot: Codable {
    var binding: String
    var revision: Int
    var workout: Workout?
    var offer: CompanionStartOffer? = nil
    var timezone: String? = nil
    var today: CompanionDayStatus? = nil
}
struct CompanionDayStatus: Codable, Equatable {
    var date: String
    var timezone: String
    var kind: String // rest, training, or unplanned
    var activityName: String? = nil
}
struct CompanionHeartBatch: Codable, Identifiable {
    var id = newID()
    var binding: String
    var sessionId: String
    var samples: [HealthSample]
}
struct CompanionPacket: Codable {
    var protocolVersion = 1
    var snapshot: CompanionSnapshot?
    var event: CompanionEvent?
    var receipt: CompanionReceipt?
    var heart: CompanionHeartBatch?
    var heartAck: String?
    var startRequest: CompanionStartRequest?
    var startReceipt: CompanionStartReceipt?
    var request = false
}

enum CompanionCore {
    static func dayKey(_ date: Date, zone: String) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(identifier: zone) ?? .current
        formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date)
    }
    static func lastActivity(_ workout: Workout) -> Date {
        max(workout.startedAt, workout.exercises.flatMap(\.sets).flatMap { [$0.startedAt, $0.completedAt] }.compactMap { $0 }.max() ?? workout.startedAt)
    }
    /// A new calendar day always gets its own task, including on the Watch.
    static func isOvernightStale(_ workout: Workout, zone: String, now: Date) -> Bool {
        workout.status == "in_progress" && dayKey(workout.startedAt, zone: zone) < dayKey(now, zone: zone)
    }
    static func isCurrentWorkout(_ workout: Workout, zone: String, now: Date) -> Bool {
        dayKey(workout.startedAt, zone: zone) == dayKey(now, zone: zone)
    }
    static func startOutcome(_ request: CompanionStartRequest, offer: CompanionStartOffer?, binding: String,
                             active: Workout?, now: Date) -> String {
        guard request.binding == binding else { return "wrong_account" }
        guard let offer, request.date == dayKey(now, zone: offer.timezone), request.date == offer.date,
              request.planId == offer.plan.id, request.dayId == offer.day.id else { return "stale_plan" }
        guard request.observedAt <= now.addingTimeInterval(30), now.timeIntervalSince(request.observedAt) <= 10 * 60 else { return "expired" }
        guard active == nil else { return "already_active" }
        return "start"
    }
    /// Replay Watch actions saved offline before an automatic overnight close.
    /// Explicitly ended sessions remain immutable; an already running new session stays active.
    static func applyLateEvent(_ event: CompanionEvent, binding: String, to workout: inout Workout,
                               zone: String, anotherActive: Bool, now: Date) -> CompanionReceipt {
        guard workout.status == "cancelled", workout.autoExpiredAt != nil,
              workout.companionReceipts?.contains(where: { $0.event.id == event.id }) != true else {
            return apply(event, binding: binding, to: &workout, now: now)
        }
        let finished = workout.finishedAt, expired = workout.autoExpiredAt
        workout.status = "in_progress"; workout.finishedAt = nil; workout.autoExpiredAt = nil
        let receipt = apply(event, binding: binding, to: &workout, now: now)
        if receipt.outcome == "applied" {
            if workout.status == "in_progress" && (anotherActive || isOvernightStale(workout, zone: zone, now: now)) {
                workout.status = "cancelled"; workout.finishedAt = lastActivity(workout); workout.autoExpiredAt = now; workout.restUntil = nil
            }
        } else {
            workout.status = "cancelled"; workout.finishedAt = finished; workout.autoExpiredAt = expired
        }
        return receipt
    }
    static func token(_ set: WorkoutSet) -> String { (try? Wire.data(set).base64EncodedString()) ?? "invalid" }
    static func remaining(_ workout: Workout, now: Date) -> Int {
        max(0, Int(ceil((workout.restUntil ?? now).timeIntervalSince(now))))
    }
    /// Grouped exercises advance round-by-round, matching the phone's training page.
    static func orderedSets(_ workout: Workout) -> [(WorkoutExercise, WorkoutSet)] {
        var result: [(WorkoutExercise, WorkoutSet)] = []
        for exercise in workout.exercises {
            if let group = workout.groups?.first(where: { $0.exerciseIds.contains(exercise.id) }) {
                guard group.exerciseIds.first == exercise.id else { continue }
                let exercises = group.exerciseIds.compactMap { id in workout.exercises.first { $0.id == id } }
                for round in 0..<(exercises.map { $0.sets.count }.max() ?? 0) {
                    for e in exercises where round < e.sets.count { result.append((e, e.sets[round])) }
                }
            } else { result += exercise.sets.map { (exercise, $0) } }
        }
        return result
    }
    static func current(_ workout: Workout) -> (WorkoutExercise, WorkoutSet)? {
        let ordered = orderedSets(workout)
        return ordered.first { $0.1.status == "pending" && $0.1.startedAt != nil } ?? ordered.first { $0.1.status == "pending" }
    }
    /// First confirmed edit wins for a set. Unrelated sets can merge while offline.
    /// A receipt and the resulting workout are saved in the same local/cloud record.
    static func apply(_ event: CompanionEvent, binding: String, to workout: inout Workout, now: Date) -> CompanionReceipt {
        if let old = workout.companionReceipts?.first(where: { $0.event.id == event.id }) {
            if (try? Wire.data(old.event)) == (try? Wire.data(event)) { return old }
            return CompanionReceipt(event: event, outcome: "id_reused", committedAt: now)
        }
        var outcome = "conflict"
        if event.binding != binding { outcome = "wrong_account" }
        else if event.sessionId != workout.id { outcome = "wrong_session" }
        else if workout.status != "in_progress" { outcome = "session_finished" }
        else if event.observedAt < workout.startedAt || event.observedAt > now.addingTimeInterval(30) { outcome = "invalid_time" }
        else if event.action == "finish_activity", workout.activity != nil,
                event.exerciseId.isEmpty, event.setId.isEmpty, event.expectedSet.isEmpty,
                event.observedAt > workout.startedAt {
            workout.status = "completed"; workout.finishedAt = event.observedAt; workout.restUntil = nil; outcome = "applied"
        }
        else if let i = workout.exercises.firstIndex(where: { $0.id == event.exerciseId }),
                let j = workout.exercises[i].sets.firstIndex(where: { $0.id == event.setId }) {
            var set = workout.exercises[i].sets[j]
            if token(set) == event.expectedSet && set.status == "pending" {
                switch event.action {
                case "start":
                    if set.startedAt == nil && !workout.exercises.flatMap(\.sets).contains(where: { $0.status == "pending" && $0.startedAt != nil }) {
                        set.startedAt = event.observedAt; workout.restUntil = nil; outcome = "applied"
                    }
                case "complete":
                    if let start = set.startedAt, start <= event.observedAt,
                       let weight = event.weight, weight.isFinite, (0...2000).contains(weight),
                       let reps = event.reps, (0...1000).contains(reps) {
                        set.actualWeight = weight; set.actualReps = reps; set.completedAt = event.observedAt
                        set.status = "completed"; workout.restUntil = event.observedAt.addingTimeInterval(90); outcome = "applied"
                    } else { outcome = "invalid_result" }
                case "skip":
                    if set.startedAt == nil || set.startedAt! <= event.observedAt {
                        set.status = "skipped"; set.completedAt = event.observedAt; outcome = "applied"
                    } else { outcome = "invalid_time" }
                default: outcome = "unsupported_action"
                }
                if outcome == "applied" { workout.exercises[i].sets[j] = set }
            }
        }
        let receipt = CompanionReceipt(event: event, outcome: outcome, committedAt: now)
        if event.binding == binding && event.sessionId == workout.id {
            workout.companionReceipts = (workout.companionReceipts ?? []) + [receipt]
        }
        return receipt
    }
    /// Association is derived from observed sample time, never message arrival time.
    /// Half-open set windows prevent assigning a boundary sample twice. Rest is session-only.
    static func associations(sample: HealthSample, workout: Workout) -> [(String, String)] {
        guard let time = sample.startAt, time >= workout.startedAt,
              workout.finishedAt == nil || time < workout.finishedAt! else { return [] }
        return workout.exercises.flatMap { exercise in
            exercise.sets.compactMap { set in
                guard let start = set.startedAt, let end = set.completedAt,
                      start <= time && time < end else { return nil }
                return (exercise.id, set.id)
            }
        }
    }
}

/// Watch durable state. Pending events are kept until an explicit application receipt.
struct CompanionReplica: Codable {
    var snapshot: CompanionSnapshot?
    var events: [CompanionEvent] = []
    var hearts: [CompanionHeartBatch] = []
    var healthAnchors: [String: Data]?
    var lastHealthAcknowledgementId: String?
    var pendingStart: CompanionStartRequest?
    var message = "等待 iPhone 同步今日任务"
    var projected: Workout? {
        guard let snapshot, var workout = snapshot.workout else { return nil }
        for event in events where event.binding == snapshot.binding && event.sessionId == workout.id && event.action != "finish_activity" {
            _ = CompanionCore.apply(event, binding: snapshot.binding, to: &workout, now: max(Date(), event.observedAt))
        }
        return workout
    }
    mutating func receive(_ incoming: CompanionSnapshot) {
        if let current = snapshot, incoming.revision <= current.revision { return }
        if snapshot?.binding != incoming.binding {
            // Quarantine rather than cross-upload old account data. No further retry under a new binding.
            message = events.isEmpty && hearts.isEmpty ? "已连接 iPhone" : "账号已切换；旧账号待同步记录已隔离"
        }
        snapshot = incoming
        if incoming.workout == nil && events.isEmpty && hearts.isEmpty && pendingStart == nil {
            if incoming.today?.kind == "rest" { message = "今日休息，已与 iPhone 同步" }
            else if incoming.today?.kind == "unplanned" { message = "今日暂无训练安排，已与 iPhone 同步" }
        }
    }
    var displayMessage: String {
        if message.contains("（conflict）") { return "该组已有更新，请按当前进度继续" }
        return message
    }
    mutating func acknowledgeStart(_ receipt: CompanionStartReceipt) {
        guard pendingStart?.id == receipt.requestId else { return }
        pendingStart = nil
        switch receipt.outcome {
        case "started": message = "今日训练已开始"
        case "already_active": message = "手机已有训练，请先核对"
        case "stale_plan": message = "今日计划已变化，请刷新后重试"
        case "expired": message = "开始请求已过期，请重新点击"
        case "wrong_account": message = "账号已变化，请在手机确认"
        default: message = "训练未开始，请重试"
        }
    }
    mutating func acknowledge(_ receipt: CompanionReceipt) {
        guard let index = events.firstIndex(where: { $0.id == receipt.event.id }),
              (try? Wire.data(events[index])) == (try? Wire.data(receipt.event)) else { return }
        events.remove(at: index)
        switch receipt.outcome {
        case "applied": message = "已同步"
        case "conflict":
            let set = snapshot?.workout?.exercises.flatMap(\.sets).first { $0.id == receipt.event.setId }
            if set?.status == "completed" { message = "本组结果已保存，请核对当前记录" }
            else if set?.status == "skipped" { message = "本组已跳过，请继续下一组" }
            else if receipt.event.action == "start", set?.startedAt != nil { message = "本组已经开始，做完后点完成本组" }
            else { message = "该组已在另一端更新，请核对当前结果" }
        case "session_finished": message = "训练已结束，本次操作未保存"
        case "wrong_account": message = "账号已切换，请在手机确认当前账号"
        case "wrong_session": message = "手机未找到这次训练，请打开手机核对"
        case "invalid_time": message = "操作时间不一致，请检查两台设备时间后重试"
        case "invalid_result": message = "本组未保存，请检查开始状态、重量和次数"
        default: message = "本次操作未保存，请核对手机进度后重试"
        }
    }
}
