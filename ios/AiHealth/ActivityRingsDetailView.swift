import SwiftUI
import HealthKit

struct ActivityDayDetail {
    var week: [String: HKActivitySummary]
    var summary: HKActivitySummary?
    var moveHours: [Double]?
    var exerciseHours: [Double]?
    var standHours: Set<Int>?
    var steps: Double?
    var distanceMeters: Double?
    var basalEnergyKcal: Double?
}

enum ActivityDetailReader {
    static func load(date: Date, timezone: String) async throws -> ActivityDayDetail {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--activity-rings-ui-test") {
            var move = Array(repeating: 0.0, count: 24), exercise = move
            move[7] = 35; move[19] = 78; exercise[19] = 11
            let summary = ActivityRingsReader.previewSummary()
            return ActivityDayDetail(week: [DayKey.string(date, zone: timezone): summary], summary: summary,
                                     moveHours: move, exerciseHours: exercise, standHours: Set(6...15),
                                     steps: 2559, distanceMeters: 1950, basalEnergyKcal: 1610)
        }
        #endif
        let store = HKHealthStore()
        guard HKHealthStore.isHealthDataAvailable() else { return ActivityDayDetail(week: [:]) }
        let types: Set<HKObjectType> = [HKObjectType.activitySummaryType(), HKQuantityType(.activeEnergyBurned),
                                        HKQuantityType(.appleMoveTime), HKQuantityType(.appleExerciseTime),
                                        HKCategoryType(.appleStandHour), HKQuantityType(.stepCount),
                                        HKQuantityType(.distanceWalkingRunning), HKQuantityType(.basalEnergyBurned)]
        try await store.requestAuthorization(toShare: [], read: types)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        calendar.firstWeekday = 2
        let queryCalendar = calendar
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? start
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        let week = (try? await summaries(store: store, from: weekStart, to: weekEnd, calendar: calendar, timezone: timezone)) ?? [:]
        let selected = week[DayKey.string(date, zone: timezone)]
        let moveType = HKQuantityType(selected?.activityMoveMode == .appleMoveTime ? .appleMoveTime : .activeEnergyBurned)
        let moveUnit: HKUnit = selected?.activityMoveMode == .appleMoveTime ? .minute() : .kilocalorie()
        async let moveHours = hourly(store: store, type: moveType, unit: moveUnit, from: start, to: end, calendar: queryCalendar)
        async let exerciseHours = hourly(store: store, type: HKQuantityType(.appleExerciseTime), unit: .minute(), from: start, to: end, calendar: queryCalendar)
        async let standHours = standing(store: store, from: start, to: end, calendar: queryCalendar)
        async let steps = total(store: store, type: HKQuantityType(.stepCount), unit: .count(), from: start, to: end)
        async let distanceMeters = total(store: store, type: HKQuantityType(.distanceWalkingRunning), unit: .meter(), from: start, to: end)
        async let basalEnergyKcal = total(store: store, type: HKQuantityType(.basalEnergyBurned), unit: .kilocalorie(), from: start, to: end)
        return ActivityDayDetail(
            week: week, summary: selected,
            moveHours: try? await moveHours,
            exerciseHours: try? await exerciseHours,
            standHours: try? await standHours,
            steps: try? await steps,
            distanceMeters: try? await distanceMeters,
            basalEnergyKcal: try? await basalEnergyKcal
        )
    }

    private static func summaries(store: HKHealthStore, from: Date, to: Date, calendar: Calendar, timezone: String) async throws -> [String: HKActivitySummary] {
        var first = calendar.dateComponents([.year, .month, .day], from: from)
        var last = calendar.dateComponents([.year, .month, .day], from: to)
        first.calendar = calendar; last.calendar = calendar
        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: first, end: last)
        let values: [HKActivitySummary] = try await withCheckedThrowingContinuation { continuation in
            let query = HKActivitySummaryQuery(predicate: predicate) { _, summaries, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: summaries ?? []) }
            }
            store.execute(query)
        }
        var result: [String: HKActivitySummary] = [:]
        for summary in values {
            let day = summary.dateComponents(for: calendar)
            guard let date = calendar.date(from: day), date >= from && date < to else { continue }
            result[DayKey.string(date, zone: timezone)] = summary
        }
        return result
    }

    private static func hourly(store: HKHealthStore, type: HKQuantityType, unit: HKUnit, from: Date, to: Date, calendar: Calendar) async throws -> [Double]? {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let collection: HKStatisticsCollection? = try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                    options: .cumulativeSum, anchorDate: from, intervalComponents: DateComponents(hour: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: collection) }
            }
            store.execute(query)
        }
        guard let collection else { return nil }
        var values = Array(repeating: 0.0, count: 24)
        var found = false
        collection.enumerateStatistics(from: from, to: to.addingTimeInterval(-0.001)) { stat, _ in
            if let sum = stat.sumQuantity() {
                let hour = calendar.component(.hour, from: stat.startDate)
                if (0..<24).contains(hour) { values[hour] += sum.doubleValue(for: unit); found = true }
            }
        }
        return found ? values : nil
    }

    private static func total(store: HKHealthStore, type: HKQuantityType, unit: HKUnit, from: Date, to: Date) async throws -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double?, Error>) in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stat, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: stat?.sumQuantity()?.doubleValue(for: unit)) }
            }
            store.execute(query)
        }
    }

    private static func standing(store: HKHealthStore, from: Date, to: Date, calendar: Calendar) async throws -> Set<Int>? {
        let type = HKCategoryType(.appleStandHour)
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            }
            store.execute(query)
        }
        guard !samples.isEmpty else { return nil }
        return Set(samples.compactMap { sample in
            guard let category = sample as? HKCategorySample, category.value == HKCategoryValueAppleStandHour.stood.rawValue else { return nil }
            return calendar.component(.hour, from: category.startDate)
        })
    }
}

struct ActivityRingsDetailView: View {
    let timezone: String
    @State private var selectedDate: Date
    @State private var detail: ActivityDayDetail?
    @State private var loading = true
    @State private var cachedDays: [String: ActivityDayDetail] = [:]
    @State private var selectingDate = false
    private var calendar: Calendar { DayKey.calendar(timezone) }
    private var selectedKey: String { DayKey.string(selectedDate, zone: timezone) }
    private var weekDates: [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start ?? selectedDate
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    init(date: Date, timezone: String) {
        self.timezone = timezone
        _selectedDate = State(initialValue: date)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(selectedDate, format: .dateTime.year().month().day().weekday(.wide)).font(.title2.bold())
                    Spacer()
                    Button("今天") { selectedDate = Date() }.buttonStyle(.bordered)
                    Button { selectingDate = true } label: { Image(systemName: "calendar") }.buttonStyle(.bordered).accessibilityLabel("选择日期")
                    Button("刷新") { Task { await load(force: true) } }.buttonStyle(.bordered).disabled(loading)
                }
                HStack {
                    Button { selectedDate = calendar.date(byAdding: .day, value: -7, to: selectedDate) ?? selectedDate } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("上一周")
                    Spacer()
                    Text(selectedDate, format: .dateTime.year().month()).font(.subheadline.bold())
                    Spacer()
                    Button { selectedDate = calendar.date(byAdding: .day, value: 7, to: selectedDate) ?? selectedDate } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("下一周")
                }.buttonStyle(.borderless)
                HStack(spacing: 3) {
                    ForEach(weekDates, id: \.self) { date in
                        let key = DayKey.string(date, zone: timezone)
                        Button { selectedDate = date } label: {
                            VStack(spacing: 4) {
                                Text(date, format: .dateTime.weekday(.narrow)).font(.caption)
                                if let summary = detail?.week[key] { NativeActivityRings(summary: summary).frame(width: 36, height: 36) }
                                else { Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 4).frame(width: 30, height: 30).padding(3) }
                                Text(date, format: .dateTime.day()).font(.caption.bold())
                            }.frame(maxWidth: .infinity).padding(.vertical, 5)
                                .background(key == selectedKey ? Theme.green.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).accessibilityIdentifier("activity-day-\(key)")
                    }
                }
                if loading { ProgressView("正在读取活动明细…") }
                if let summary = detail?.summary {
                    HStack(spacing: 16) {
                        NativeActivityRings(summary: summary).frame(width: 110, height: 110)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("苹果健康 · 全天进度").font(.headline)
                            Text("本日所有活动共同计入圆环").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 18))
                    let moveMinutes = summary.activityMoveMode == .appleMoveTime
                    metricCard("活动", value: moveMinutes ? summary.appleMoveTime.doubleValue(for: .minute()) : summary.activeEnergyBurned.doubleValue(for: .kilocalorie()),
                               goal: moveMinutes ? summary.appleMoveTimeGoal.doubleValue(for: .minute()) : summary.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()),
                               unit: moveMinutes ? "分钟" : "千卡", color: .red, hours: detail?.moveHours)
                    metricCard("锻炼", value: summary.appleExerciseTime.doubleValue(for: .minute()), goal: summary.appleExerciseTimeGoal.doubleValue(for: .minute()),
                               unit: "分钟", color: .green, hours: detail?.exerciseHours)
                    VStack(alignment: .leading, spacing: 9) {
                        Text("站立").font(.headline)
                        Text("\(Int(summary.appleStandHours.doubleValue(for: .count())))/\(Int(summary.appleStandHoursGoal.doubleValue(for: .count()))) 小时")
                            .font(.title2.bold()).foregroundStyle(.blue)
                        if let hours = detail?.standHours { StandHourBars(hours: hours) }
                        else { Text("暂无可读取的逐小时站立明细").font(.caption).foregroundStyle(.secondary) }
                    }.activityDetailCard()
                    HStack {
                        bottomMetric("步数", value: detail?.steps.map { Int($0.rounded()).formatted() } ?? "未读取")
                        bottomMetric("距离", value: detail?.distanceMeters.map { "\(($0 / 1000).formatted(.number.precision(.fractionLength(0...2)))) 公里" } ?? "未读取")
                    }.activityDetailCard()
                    if !moveMinutes, let basal = detail?.basalEnergyKcal {
                        Text("活动 + 静息能量约 \(Int((summary.activeEnergyBurned.doubleValue(for: .kilocalorie()) + basal).rounded())) 千卡")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("圆环总数以 Apple 活动汇总为准；小时分布、步数和距离来自获准读取的 HealthKit 样本，来源合并方式可能与 Fitness 图表不同。")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if !loading {
                    Text("这一天暂无可读取的苹果活动汇总；请检查日益的健康读取权限。")
                        .foregroundStyle(.secondary).activityDetailCard()
                }
            }.padding(16)
        }.background(Theme.cream).navigationTitle("活动详情")
            .task(id: selectedKey) { await load() }
            .sheet(isPresented: $selectingDate) {
                NavigationStack {
                    DatePicker("选择日期", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical).padding()
                        .navigationTitle("选择日期")
                        .toolbar { Button("完成") { selectingDate = false } }
                }.presentationDetents([.medium])
            }
    }
    private func load(force: Bool = false) async {
        if !force, let cached = cachedDays[selectedKey] { detail = cached; loading = false; return }
        loading = true
        let key = selectedKey
        let result = try? await ActivityDetailReader.load(date: selectedDate, timezone: timezone)
        guard key == selectedKey else { return }
        detail = result
        if let result { cachedDays[key] = result }
        loading = false
    }
    private func metricCard(_ title: String, value: Double, goal: Double, unit: String, color: Color, hours: [Double]?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline)
            Text("\(Int(value.rounded()))/\(Int(goal.rounded())) \(unit)").font(.title2.bold()).foregroundStyle(color)
            if let hours { HourlyActivityBars(values: hours, color: color) }
            else { Text("暂无可读取的逐小时记录").font(.caption).foregroundStyle(.secondary) }
        }.activityDetailCard()
    }
    private func bottomMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title3.bold()) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HourlyActivityBars: View {
    let values: [Double]
    let color: Color
    private var peak: Double { max(values.max() ?? 0, 1) }
    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    RoundedRectangle(cornerRadius: 2).fill(values[hour] > 0 ? color : color.opacity(0.18))
                        .frame(maxWidth: .infinity).frame(height: max(3, values[hour] / peak * 76))
                }
            }.frame(height: 78, alignment: .bottom)
            hourLabels
        }.accessibilityLabel("逐小时活动分布")
    }
    private var hourLabels: some View {
        HStack { Text("00:00"); Spacer(); Text("06:00"); Spacer(); Text("12:00"); Spacer(); Text("18:00") }
            .font(.caption2).foregroundStyle(.secondary)
    }
}

private struct StandHourBars: View {
    let hours: Set<Int>
    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    RoundedRectangle(cornerRadius: 3).fill(hours.contains(hour) ? Color.cyan : Color.cyan.opacity(0.16))
                        .frame(maxWidth: .infinity).frame(height: 76)
                }
            }.frame(height: 78)
            HStack { Text("00:00"); Spacer(); Text("06:00"); Spacer(); Text("12:00"); Spacer(); Text("18:00") }
                .font(.caption2).foregroundStyle(.secondary)
        }.accessibilityLabel("逐小时站立记录")
    }
}

private extension View {
    func activityDetailCard() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 18))
    }
}
