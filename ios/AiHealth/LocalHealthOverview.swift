import Foundation

/// A local view of authorized records. It never infers read permission or full-day coverage.
enum LocalHealthOverview {
    static let names = ["height_cm": "身高", "waist_cm": "腰围", "body_mass": "体重", "body_fat_percentage": "体脂率", "bmi": "BMI", "lean_body_mass": "去脂体重", "sleep_analysis": "睡眠", "heart_rate": "心率", "resting_heart_rate": "静息心率", "hrv_sdnn": "HRV", "respiratory_rate": "呼吸频率", "oxygen_saturation": "血氧", "vo2_max": "最大摄氧量", "step_count": "步数", "walking_running_distance": "步行/跑步距离", "active_energy": "活动能量", "basal_energy": "静息能量", "exercise_time": "锻炼时间", "flights_climbed": "爬楼层数", "workout": "训练"]

    static func make(samples: [HealthSample], zone: String, now: Date = Date(), water: Int = 0) -> DailySummary {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone) ?? .current
        let today = calendar.startOfDay(for: now), yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"
        let valid = samples.filter { !$0.deleted && $0.endAt != nil && $0.endAt! <= now }
        let groups = Dictionary(grouping: valid, by: \.type)
        var metrics: [String: HealthMetric] = [:]
        func metric(_ list: [HealthSample], unit: String, method: String, compute: ([HealthSample]) -> Double) -> HealthMetric {
            let chosen = primary(list)
            return HealthMetric(value: chosen.isEmpty ? nil : compute(chosen), unit: unit, observedAt: chosen.compactMap(\.endAt).max(), source: chosen.first?.sourceBundleId ?? "", samples: chosen.count, coverage: "unknown", method: method)
        }
        for (type, unit) in [("height_cm", "cm"), ("waist_cm", "cm"), ("body_mass", "kg"), ("body_fat_percentage", "%"), ("bmi", "count"), ("lean_body_mass", "kg"), ("vo2_max", "ml/kg/min")] {
            let all = (groups[type] ?? []).filter { $0.value != nil }
            let latestDay = all.compactMap(\.endAt).max()
            let recent = all.filter { if let date = $0.endAt, let latestDay { return calendar.isDate(date, inSameDayAs: latestDay) }; return false }
            metrics[type] = metric(recent, unit: unit, method: "local_latest_observation") { sorted($0).last!.value! }
        }
        for (type, unit) in [("heart_rate", "bpm"), ("resting_heart_rate", "bpm"), ("hrv_sdnn", "ms"), ("respiratory_rate", "count/min"), ("oxygen_saturation", "%")] {
            let day = (groups[type] ?? []).filter { $0.value != nil && $0.endAt! >= yesterday && $0.endAt! < today }
            metrics[type] = metric(day, unit: unit, method: "local_previous_day_sample_mean") { $0.compactMap(\.value).reduce(0, +) / Double($0.count) }
        }
        for (type, unit) in [("step_count", "count"), ("active_energy", "kcal"), ("basal_energy", "kcal"), ("walking_running_distance", "m"), ("exercise_time", "min"), ("flights_climbed", "count")] {
            let day = (groups[type] ?? []).filter { $0.value != nil && $0.startAt != nil && $0.endAt! >= yesterday && $0.startAt! < today }
            metrics[type] = metric(day, unit: unit, method: "local_previous_day_single_source_interval_estimate") { intervalSum($0, from: yesterday, to: today) }
        }
        let sleepStart = calendar.date(byAdding: .day, value: -2, to: today)!
        let wakeDay = sleepForWakeDay((groups["sleep_analysis"] ?? []).filter { $0.startAt != nil && $0.endAt! >= sleepStart }, calendar: calendar, day: today)
        let priority = ["asleep_unspecified": 1, "asleep_core": 2, "asleep_rem": 3, "asleep_deep": 4]
        let bounds = Set(wakeDay.flatMap { [$0.startAt!, $0.endAt!] }).sorted()
        var minutes: [String: Double] = [:]
        if bounds.count > 1 {
            for i in 1..<bounds.count {
                let a = bounds[i-1], b = bounds[i]
                let category = wakeDay.filter { $0.startAt! <= a && $0.endAt! >= b }.compactMap(\.category).max { (priority[$0] ?? 0) < (priority[$1] ?? 0) }
                if let category, priority[category] != nil { minutes[category, default: 0] += b.timeIntervalSince(a) / 60 }
            }
        }
        for (key, category) in [("sleep_total_minutes", "all"), ("sleep_deep_minutes", "asleep_deep"), ("sleep_rem_minutes", "asleep_rem")] {
            let value: Double? = category == "all" ? (minutes.isEmpty ? nil : minutes.values.reduce(0, +)) : minutes[category]
            metrics[key] = HealthMetric(value: value, unit: "min", observedAt: wakeDay.compactMap(\.endAt).max(), source: wakeDay.first?.sourceBundleId ?? "", samples: wakeDay.count, coverage: "unknown", method: "local_wake_date_episode_interval_union")
        }
        let weightStart = calendar.date(byAdding: .day, value: -13, to: today)!
        let split = calendar.date(byAdding: .day, value: -6, to: today)!
        let weight = primary((groups["body_mass"] ?? []).filter { $0.value != nil && $0.endAt! >= weightStart })
        let daily = Dictionary(grouping: sorted(weight), by: { calendar.startOfDay(for: $0.endAt!) }).mapValues { $0.last!.value! }
        let recent = daily.keys.sorted().filter { $0 >= split }.compactMap { daily[$0] }
        let previous = daily.keys.sorted().filter { $0 < split }.compactMap { daily[$0] }
        let change = recent.count >= 3 && previous.count >= 3 ? recent.reduce(0, +) / Double(recent.count) - previous.reduce(0, +) / Double(previous.count) : nil
        metrics["body_mass_7d_change"] = HealthMetric(value: change, unit: "kg", observedAt: weight.compactMap(\.endAt).max(), source: weight.first?.sourceBundleId ?? "", samples: daily.count, coverage: "partial", method: "local_two_7_day_means_min_3_days_each")
        metrics["water_ml"] = HealthMetric(value: Double(water), unit: "ml", source: "app", samples: 0, coverage: "logged_only", method: "today_logged_sum")
        return DailySummary(date: f.string(from: today), timezone: zone, activityDate: f.string(from: yesterday), dataCutoffAt: valid.compactMap(\.endAt).max(), lastHealthSyncAt: nil, metrics: metrics, dataQuality: ["本机可访问健康记录；覆盖情况未知，缺失不等于零。", "睡眠按醒来日期归属，心率和活动统计前一自然日。", "多来源采用单一来源，重叠区间估算可能与 Apple 健康汇总不同。"], training: [])
    }
    /// Select a source only after source-local episodes have been assigned to their wake day.
    /// Older or awake-only sources must not suppress a current night's real sleep stages.
    static func sleepForWakeDay(_ samples: [HealthSample], calendar: Calendar, day: Date) -> [HealthSample] {
        var candidates: [String: [HealthSample]] = [:]
        for (source, records) in Dictionary(grouping: samples, by: \.sourceBundleId) {
            var episode: [HealthSample] = []; var end: Date?
            func finish() {
                if let end, calendar.isDate(end, inSameDayAs: day), episode.contains(where: { $0.category?.hasPrefix("asleep_") == true }) {
                    candidates[source, default: []].append(contentsOf: episode)
                }
            }
            for sample in records.sorted(by: { $0.startAt! < $1.startAt! }) {
                if let previousEnd = end, sample.startAt!.timeIntervalSince(previousEnd) > 90 * 60 { finish(); episode = []; end = nil }
                episode.append(sample); end = max(end ?? sample.endAt!, sample.endAt!)
            }
            finish()
        }
        let source = candidates.keys.sorted { a, b in
            let ac = candidates[a]!.filter { $0.category?.hasPrefix("asleep_") == true }.count
            let bc = candidates[b]!.filter { $0.category?.hasPrefix("asleep_") == true }.count
            return ac == bc ? a < b : ac > bc
        }.first
        return source.flatMap { candidates[$0] } ?? []
    }
    private static func sorted(_ samples: [HealthSample]) -> [HealthSample] { samples.sorted { $0.endAt == $1.endAt ? $0.healthkitUuid < $1.healthkitUuid : $0.endAt! < $1.endAt! } }
    private static func primary(_ samples: [HealthSample]) -> [HealthSample] {
        let groups = Dictionary(grouping: samples, by: \.sourceBundleId)
        let source = groups.keys.sorted { groups[$0]!.count == groups[$1]!.count ? $0 < $1 : groups[$0]!.count > groups[$1]!.count }.first
        return source.flatMap { groups[$0] } ?? []
    }
    private static func intervalSum(_ samples: [HealthSample], from: Date, to: Date) -> Double {
        let points = Dictionary(grouping: samples.filter { $0.startAt == $0.endAt && $0.endAt! >= from && $0.endAt! < to }, by: { $0.endAt! })
        var total = points.values.compactMap { $0.compactMap(\.value).max() }.reduce(0, +)
        let bounds = Set([from, to] + samples.flatMap { [$0.startAt!, $0.endAt!] }.filter { $0 > from && $0 < to }).sorted()
        for i in 1..<bounds.count {
            let a = bounds[i-1], b = bounds[i]
            let rate = samples.filter { $0.startAt! <= a && $0.endAt! >= b && $0.endAt! > $0.startAt! }.map { $0.value! / $0.endAt!.timeIntervalSince($0.startAt!) }.max() ?? 0
            total += rate * b.timeIntervalSince(a)
        }; return total
    }
}
