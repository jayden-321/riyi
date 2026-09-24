import Foundation

struct WeightReading: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let kg: Double
    let observedAt: Date
    let sourceName: String
    let sourceBundleId: String

    init(id: String, kg: Double, observedAt: Date, sourceName: String, sourceBundleId: String) {
        self.id = id; self.kg = kg; self.observedAt = observedAt
        self.sourceName = sourceName; self.sourceBundleId = sourceBundleId
    }
    init?(sample: HealthSample) {
        guard !sample.deleted, sample.type == "body_mass", sample.unit == "kg",
              let kg = sample.value, kg.isFinite, kg > 0, let date = sample.endAt,
              date <= Date() else { return nil }
        self.init(id: sample.healthkitUuid, kg: kg, observedAt: date,
                  sourceName: sample.sourceName, sourceBundleId: sample.sourceBundleId)
    }
}

struct CloudWeightHistory: Codable {
    let timezone: String
    let lastHealthSyncAt: Date?
    let readings: [WeightReading]
    let truncated: Bool
}

enum WeightHistory {
    static func merge(local: [WeightReading], cloud: [WeightReading]) -> [WeightReading] {
        var byID = Dictionary(uniqueKeysWithValues: cloud.map { ($0.id, $0) })
        for reading in local { byID[reading.id] = reading }
        return byID.values.sorted { $0.observedAt == $1.observedAt ? $0.id < $1.id : $0.observedAt < $1.observedAt }
    }

    static func preferredSource(_ readings: [WeightReading], zone: String) -> String? {
        let groups = Dictionary(grouping: readings, by: \.sourceBundleId)
        return groups.keys.sorted { a, b in
            let aDays = Set(groups[a, default: []].map { DayKey.string($0.observedAt, zone: zone) }).count
            let bDays = Set(groups[b, default: []].map { DayKey.string($0.observedAt, zone: zone) }).count
            if aDays != bDays { return aDays > bDays }
            let aLatest = groups[a, default: []].map(\.observedAt).max() ?? .distantPast
            let bLatest = groups[b, default: []].map(\.observedAt).max() ?? .distantPast
            return aLatest == bLatest ? a < b : aLatest > bLatest
        }.first
    }

    static func dailyLatest(_ readings: [WeightReading], source: String, zone: String, from: Date, to: Date) -> [WeightReading] {
        let calendar = DayKey.calendar(zone)
        let filtered = readings.filter { $0.sourceBundleId == source && $0.observedAt >= from && $0.observedAt <= to }
        let byDay = Dictionary(grouping: filtered, by: { calendar.startOfDay(for: $0.observedAt) })
        return byDay.keys.sorted().compactMap { day in
            byDay[day]?.max { $0.observedAt == $1.observedAt ? $0.id < $1.id : $0.observedAt < $1.observedAt }
        }
    }

    // Same two-window rule as the home summary: daily last observation,
    // at least three observed dates in each non-overlapping seven-day window.
    static func sevenDayMeanChange(_ readings: [WeightReading], source: String, zone: String, now: Date) -> Double? {
        let calendar = DayKey.calendar(zone)
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -13, to: today)!
        let daily = dailyLatest(readings, source: source, zone: zone, from: start, to: now)
        let split = calendar.date(byAdding: .day, value: -6, to: today)!
        let current = daily.filter { $0.observedAt >= split }
        let previous = daily.filter { $0.observedAt < split }
        guard current.count >= 3, previous.count >= 3 else { return nil }
        return current.map(\.kg).reduce(0, +) / Double(current.count) - previous.map(\.kg).reduce(0, +) / Double(previous.count)
    }
}
