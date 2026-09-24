import SwiftUI
import Charts

struct WeightDetailView: View {
    @Bindable var store: AppStore
    let health: HealthSync
    @State private var period = 30
    @State private var selectedSource: String?
    @State private var readings: [WeightReading] = []
    @State private var loadedIdentity = ""
    @State private var cloudSyncedAt: Date?
    @State private var loading = false
    @State private var refreshing = false
    @State private var note: String?
    @State private var needsAuthorization = false

    private var zone: String { store.settings.timezone }
    private var calendar: Calendar { DayKey.calendar(zone) }
    private var today: Date { calendar.startOfDay(for: Date()) }
    private var since: Date {
        max(store.healthWindowStart, calendar.date(byAdding: .day, value: -364, to: today)!)
    }
    private var identity: String { "\(store.scope)|\(zone)|\(store.healthHistoryWindow.rawValue)|\(DayKey.string(today, zone: zone))" }
    private var visibleReadings: [WeightReading] { loadedIdentity == identity ? readings : [] }
    private var sourceIDs: [String] {
        Array(Set(visibleReadings.map(\.sourceBundleId))).sorted { sourceName($0) < sourceName($1) }
    }
    private var source: String? {
        if let selectedSource, sourceIDs.contains(selectedSource) { return selectedSource }
        return WeightHistory.preferredSource(visibleReadings, zone: zone)
    }
    private var from: Date { max(since, calendar.date(byAdding: .day, value: 1 - period, to: today)!) }
    private var points: [WeightReading] {
        guard let source else { return [] }
        return WeightHistory.dailyLatest(visibleReadings, source: source, zone: zone, from: from, to: Date())
    }
    private var measurements: [WeightReading] {
        guard let source else { return [] }
        return visibleReadings.filter { $0.sourceBundleId == source && $0.observedAt >= from && $0.observedAt <= Date() }
            .sorted { $0.observedAt > $1.observedAt }
    }
    private var latest: WeightReading? { points.last }
    private var change: Double? {
        guard let source else { return nil }
        return WeightHistory.sevenDayMeanChange(visibleReadings, source: source, zone: zone, now: Date())
    }

    var body: some View {
        List {
            Section("体重趋势") {
                Picker("显示范围", selection: $period) {
                    Text("7 天").tag(7); Text("30 天").tag(30)
                    Text("90 天").tag(90); Text("1 年").tag(365)
                }.pickerStyle(.segmented).accessibilityIdentifier("weight-period")
                if let latest {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(latest.kg.formatted(.number.precision(.fractionLength(1)))).font(.largeTitle.bold()).monospacedDigit()
                        Text("kg").foregroundStyle(.secondary)
                    }
                    Text("最近测量：\(latest.observedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                } else if loading { ProgressView("正在读取体重记录…") }
                else if let metric = store.summary?.metrics["body_mass"], let kg = metric.value {
                    Text("首页最近体重 \(kg.formatted(.number.precision(.fractionLength(1)))) kg")
                    Text("当前还没有可用于绘图的逐条记录；摘要值不会冒充历史测量。")
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text("所选范围暂无可读体重记录").foregroundStyle(.secondary) }
                if !points.isEmpty { trend.frame(height: 220).accessibilityIdentifier("weight-trend") }
                Text("曲线按所选来源每天最后一次测量绘制；空白日期没有按 0 kg 处理。连线只连接已有测量点。")
                    .font(.caption).foregroundStyle(.secondary)
                if let change {
                    Text("近 7 天日均较前 7 天 \(change >= 0 ? "+" : "")\(change.formatted(.number.precision(.fractionLength(1)))) kg")
                        .font(.subheadline).foregroundStyle(Theme.green)
                } else {
                    Text("两段 7 天各需至少 3 个测量日，才计算周均变化。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !measurements.isEmpty {
                Section("最近测量 · \(measurements.count) 次 / \(points.count) 天") {
                    ForEach(measurements.prefix(30)) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.observedAt.formatted(date: .abbreviated, time: .shortened))
                                Text(sourceName(item.sourceBundleId)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(item.kg.formatted(.number.precision(.fractionLength(1)))) kg").bold().monospacedDigit()
                        }
                    }
                }
            }
            Section("来源与更新") {
                if sourceIDs.count > 1 {
                    Picker("测量来源", selection: Binding(get: { source ?? "" }, set: { selectedSource = $0 })) {
                        ForEach(sourceIDs, id: \.self) { id in Text(sourceName(id)).tag(id) }
                    }
                } else if let source { Text("来源：\(sourceName(source))").font(.subheadline) }
                if let cloudSyncedAt { Text("最近云端健康同步：\(cloudSyncedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                if needsAuthorization {
                    Label("尚未向日益请求本机体重读取权限；已同步的云端历史仍可查看。", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("刷新本机体重") { Task { await refresh(authorize: false) } }
                    .disabled(refreshing).accessibilityIdentifier("refresh-weight")
                Button("授权 / 补充本机体重读取") { Task { await refresh(authorize: true) } }
                    .disabled(refreshing)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                Text("显示当前健康读取时间范围内的记录。没有记录也可能是尚未授权，或 Apple 健康限制了可读取的历史。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("体重")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.calendar, calendar).environment(\.timeZone, calendar.timeZone)
        .task(id: identity) {
            await load()
            let needsRequest = await health.weightAuthorizationNeedsRequest()
            needsAuthorization = !store.healthReadingEnabled || needsRequest
            await health.refreshWeight(automatic: true)
            await loadLocal()
        }
        .refreshable { await refresh(authorize: false) }
    }

    private var trend: some View {
        let values = points.map(\.kg)
        let minimum = max(0, (values.min() ?? 0) - 1)
        let maximum = max(minimum + 2, (values.max() ?? 0) + 1)
        return Chart(points) { point in
            LineMark(x: .value("日期", point.observedAt, unit: .day), y: .value("kg", point.kg))
                .foregroundStyle(Theme.green).interpolationMethod(.linear)
            PointMark(x: .value("日期", point.observedAt, unit: .day), y: .value("kg", point.kg))
                .foregroundStyle(Theme.green)
                .accessibilityLabel("\(DayKey.string(point.observedAt, zone: zone))，\(point.kg.formatted(.number.precision(.fractionLength(1)))) 公斤")
        }
        .chartXScale(domain: from...calendar.date(byAdding: .day, value: 1, to: today)!)
        .chartYScale(domain: minimum...maximum)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: period <= 30 ? 5 : 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month().day()) } }
        .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine(); AxisValueLabel() } }
    }

    private func sourceName(_ id: String) -> String {
        visibleReadings.first(where: { $0.sourceBundleId == id && !$0.sourceName.isEmpty })?.sourceName ?? (id.isEmpty ? "未知来源" : id)
    }
    private func loadLocal() async {
        let expected = identity, owner = store.scope
        do {
            let local = try await store.healthStorage.value.weightReadings(scope: owner, since: since, now: Date())
            guard identity == expected, !Task.isCancelled else { return }
            readings = WeightHistory.merge(local: local, cloud: readings)
            loadedIdentity = expected
        } catch { if identity == expected { note = "本机体重记录暂时无法读取。" } }
    }
    private func load() async {
        let expected = identity, owner = store.scope, start = since, end = today
        loading = true; defer { if identity == expected { loading = false } }
        readings = []; loadedIdentity = expected; cloudSyncedAt = nil; note = nil
        await loadLocal()
        guard identity == expected, store.settings.healthConsent, !store.isDemo else { return }
        do {
            let from = DayKey.string(start, zone: zone), to = DayKey.string(end, zone: zone)
            let response: CloudWeightHistory = try Wire.read(await store.network.request("/v1/weight/history?from=\(from)&to=\(to)"))
            guard identity == expected, !Task.isCancelled, response.timezone == zone else { return }
            readings = WeightHistory.merge(local: readings, cloud: response.readings)
            cloudSyncedAt = response.lastHealthSyncAt
            if response.truncated { note = "云端历史记录超过 5000 条，仅显示最近的部分记录。" }
        } catch {
            if identity == expected { note = "云端体重历史暂时无法读取，已显示本机保存的记录。" }
        }
    }
    private func refresh(authorize: Bool) async {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        await health.refreshWeight(requestAuthorization: authorize)
        let needsRequest = await health.weightAuthorizationNeedsRequest()
        needsAuthorization = !store.healthReadingEnabled || needsRequest
        await load()
    }
}
