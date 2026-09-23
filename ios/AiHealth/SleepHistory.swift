import Foundation

struct SleepSegment: Identifiable, Sendable, Codable {
    var id: Date { start }
    let start: Date
    var end: Date
    let category: String
}
struct SleepNight: Identifiable, Sendable, Codable {
    var id: String { date }
    let date: String
    let minutes: Double
    let stages: [String: Double]
    let segments: [SleepSegment]
    let observedAt: Date
    let source: String
    var cloud = false
    var cutoff: Date?
}

/// Date assignment uses complete source-local episodes, including following-day fragments.
/// Unknown nights/stages remain absent; duplicate and overlapping samples are unioned.
enum SleepHistory {
    static let priorities = ["in_bed": -1, "awake": 0, "asleep_unspecified": 1, "asleep_core": 2, "asleep_rem": 3, "asleep_deep": 4]
    static func nights(samples: [HealthSample], zone: String, days: [Date], now: Date) -> [SleepNight] {
        let valid = samples.filter { !$0.deleted && $0.type == "sleep_analysis" && $0.startAt != nil && $0.endAt != nil && $0.startAt! < $0.endAt! && $0.endAt! <= now }
        let calendar = DayKey.calendar(zone)
        return days.compactMap { day in
            let chosen = LocalHealthOverview.sleepForWakeDay(valid, calendar: calendar, day: day)
            let bounds = Set(chosen.flatMap { [$0.startAt!, $0.endAt!] }).sorted()
            var segments: [SleepSegment] = [], stages: [String: Double] = [:]
            for index in bounds.indices.dropFirst() {
                let start = bounds[index - 1], end = bounds[index]
                let category = chosen.filter { $0.startAt! <= start && $0.endAt! >= end }.compactMap(\.category).filter { priorities[$0] != nil }.max { priorities[$0]! < priorities[$1]! }
                guard let category, category != "in_bed" else { continue }
                stages[category, default: 0] += end.timeIntervalSince(start) / 60
                if let last = segments.last, last.category == category, last.end == start { segments[segments.count - 1].end = end }
                else { segments.append(SleepSegment(start: start, end: end, category: category)) }
            }
            let total = stages.filter { $0.key.hasPrefix("asleep_") }.values.reduce(0, +)
            guard total > 0, let observed = chosen.compactMap(\.endAt).max() else { return nil }
            return SleepNight(date: DayKey.string(day, zone: zone), minutes: total, stages: stages, segments: segments, observedAt: observed, source: chosen.first?.sourceBundleId ?? "")
        }
    }
    static func cloudNight(_ summary: DailySummary, date: String, zone: String, now: Date) -> SleepNight? {
        guard summary.date == date, summary.timezone == zone,
              let total = summary.metrics["sleep_total_minutes"], let value = total.value, value.isFinite, value > 0,
              let observed = total.observedAt, observed <= now, DayKey.string(observed, zone: zone) == date else { return nil }
        var stages: [String: Double] = [:]
        for (key, category) in [("sleep_deep_minutes", "asleep_deep"), ("sleep_rem_minutes", "asleep_rem")] {
            if let metric = summary.metrics[key], metric.source == total.source, let value = metric.value, value.isFinite, value >= 0,
               let at = metric.observedAt, at <= now, DayKey.string(at, zone: zone) == date { stages[category] = value }
        }
        return SleepNight(date: date, minutes: value, stages: stages, segments: [], observedAt: observed, source: total.source, cloud: true, cutoff: summary.dataCutoffAt)
    }
    static func average(_ nights: [SleepNight]) -> Double? {
        nights.isEmpty ? nil : nights.map(\.minutes).reduce(0, +) / Double(nights.count)
    }
}
