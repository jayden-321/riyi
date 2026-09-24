import Foundation

struct VitalReading: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let value: Double
    let observedAt: Date
    let sourceName: String
    let sourceBundleId: String

    init?(sample: HealthSample, type: String) {
        guard !sample.deleted, sample.type == type,
              let value = sample.value, value.isFinite, value > 0,
              let observedAt = sample.endAt, observedAt <= Date() else { return nil }
        id = sample.healthkitUuid; self.value = value; self.observedAt = observedAt
        sourceName = sample.sourceName; sourceBundleId = sample.sourceBundleId
    }
    init(id: String, value: Double, observedAt: Date, sourceName: String, sourceBundleId: String) {
        self.id = id; self.value = value; self.observedAt = observedAt
        self.sourceName = sourceName; self.sourceBundleId = sourceBundleId
    }
}

struct CloudVitalHistory: Codable {
    let type: String
    let unit: String
    let timezone: String
    let lastHealthSyncAt: Date?
    let readings: [VitalReading]
    let truncated: Bool
}

struct VitalDayPoint: Identifiable {
    let id: String
    let observedAt: Date
    let value: Double
    let samples: Int
}

enum VitalHistory {
    static func merge(local: [VitalReading], cloud: [VitalReading]) -> [VitalReading] {
        var byID = Dictionary(uniqueKeysWithValues: cloud.map { ($0.id, $0) })
        for reading in local { byID[reading.id] = reading }
        return byID.values.sorted { $0.observedAt == $1.observedAt ? $0.id < $1.id : $0.observedAt < $1.observedAt }
    }
    static func preferredSource(_ readings: [VitalReading], zone: String) -> String? {
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
    static func dailyPoints(_ readings: [VitalReading], type: String, source: String, zone: String, from: Date, to: Date) -> [VitalDayPoint] {
        let calendar = DayKey.calendar(zone)
        let selected = readings.filter { $0.sourceBundleId == source && $0.observedAt >= from && $0.observedAt <= to }
        let groups = Dictionary(grouping: selected, by: { calendar.startOfDay(for: $0.observedAt) })
        return groups.keys.sorted().compactMap { day in
            guard let values = groups[day], let last = values.max(by: { $0.observedAt < $1.observedAt }) else { return nil }
            let amount: Double
            if type == "hrv_sdnn" {
                let sorted = values.map(\.value).sorted()
                let middle = sorted.count / 2
                amount = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            } else { amount = last.value }
            return VitalDayPoint(id: DayKey.string(day, zone: zone), observedAt: last.observedAt, value: amount, samples: values.count)
        }
    }
}
