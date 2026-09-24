import SwiftUI
import Charts

struct VitalDetailView: View {
    @Bindable var store: AppStore
    let health: HealthSync
    let type: String
    @State private var period = 30
    @State private var selectedSource: String?
    @State private var readings: [VitalReading] = []
    @State private var loadedIdentity = ""
    @State private var cloudSyncedAt: Date?
    @State private var loading = false
    @State private var refreshing = false
    @State private var needsAuthorization = false
    @State private var note: String?

    private var title: String { type == "hrv_sdnn" ? "HRV" : "静息心率" }
    private var unit: String { type == "hrv_sdnn" ? "ms" : "bpm" }
    private var color: Color { type == "hrv_sdnn" ? Color(red: 0.43, green: 0.34, blue: 0.76) : Theme.green }
    private var zone: String { store.settings.timezone }
    private var calendar: Calendar { DayKey.calendar(zone) }
    private var today: Date { calendar.startOfDay(for: Date()) }
    private var since: Date { max(store.healthWindowStart, calendar.date(byAdding: .day, value: -364, to: today)!) }
    private var identity: String { "\(store.scope)|\(zone)|\(type)|\(store.healthHistoryWindow.rawValue)|\(DayKey.string(today, zone: zone))" }
    private var visibleReadings: [VitalReading] { loadedIdentity == identity ? readings : [] }
    private var sourceIDs: [String] { Array(Set(visibleReadings.map(\.sourceBundleId))).sorted { sourceName($0) < sourceName($1) } }
    private var source: String? {
        if let selectedSource, sourceIDs.contains(selectedSource) { return selectedSource }
        return VitalHistory.preferredSource(visibleReadings, zone: zone)
    }
    private var from: Date { max(since, calendar.date(byAdding: .day, value: 1 - period, to: today)!) }
    private var measurements: [VitalReading] {
        guard let source else { return [] }
        return visibleReadings.filter { $0.sourceBundleId == source && $0.observedAt >= from && $0.observedAt <= Date() }
            .sorted { $0.observedAt > $1.observedAt }
    }
    private var points: [VitalDayPoint] {
        guard let source else { return [] }
        return VitalHistory.dailyPoints(visibleReadings, type: type, source: source, zone: zone, from: from, to: Date())
    }

    var body: some View {
        List {
            Section("\(title)趋势") {
                Picker("显示范围", selection: $period) {
                    Text("7 天").tag(7); Text("30 天").tag(30)
                    Text("90 天").tag(90); Text("1 年").tag(365)
                }.pickerStyle(.segmented).accessibilityIdentifier("vital-period")
                if let latest = measurements.first {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(valueText(latest.value)).font(.largeTitle.bold()).monospacedDigit()
                        Text(unit).foregroundStyle(.secondary)
                    }
                    Text("最近记录：\(latest.observedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                } else if loading { ProgressView("正在读取\(title)记录…") }
                else { Text("所选范围暂无可读\(title)记录").foregroundStyle(.secondary) }
                if !points.isEmpty { trend.frame(height: 220).accessibilityIdentifier("vital-trend") }
                Text(type == "hrv_sdnn"
                     ? "曲线按同一来源每天的 HRV 中位数绘制；空白日期没有记录。单次 HRV 波动不能单独说明恢复状态。"
                     : "曲线按同一来源每天最后一次静息心率绘制；空白日期没有记录。")
                    .font(.caption).foregroundStyle(.secondary)
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
                            Text("\(valueText(item.value)) \(unit)").bold().monospacedDigit()
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
                if needsAuthorization { Label("尚未请求本机\(title)读取权限；已同步的云端历史仍可查看。", systemImage: "lock.shield").font(.caption).foregroundStyle(.orange) }
                Button("刷新本机\(title)") { Task { await refresh(authorize: false) } }.disabled(refreshing)
                Button("授权 / 补充本机\(title)读取") { Task { await refresh(authorize: true) } }.disabled(refreshing)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                Text("显示当前健康读取时间范围内的记录。未读到数据可能是尚未授权，或 Apple 健康限制了可读取的历史。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .environment(\.calendar, calendar).environment(\.timeZone, calendar.timeZone)
        .task(id: identity) {
            await load()
            let needed = await health.vitalAuthorizationNeedsRequest(type)
            needsAuthorization = !store.healthReadingEnabled || needed
            await health.refreshVital(type, automatic: true)
            await loadLocal()
        }
        .refreshable { await refresh(authorize: false) }
    }

    private var trend: some View {
        let values = points.map(\.value)
        let minimum = max(0, (values.min() ?? 0) - (type == "hrv_sdnn" ? 5 : 3))
        let maximum = max(minimum + 5, (values.max() ?? 0) + (type == "hrv_sdnn" ? 5 : 3))
        return Chart(points) { point in
            LineMark(x: .value("日期", point.observedAt, unit: .day), y: .value(unit, point.value))
                .foregroundStyle(color).interpolationMethod(.linear)
            PointMark(x: .value("日期", point.observedAt, unit: .day), y: .value(unit, point.value))
                .foregroundStyle(color)
                .accessibilityLabel("\(point.id)，\(valueText(point.value)) \(unit)")
        }
        .chartXScale(domain: from...calendar.date(byAdding: .day, value: 1, to: today)!)
        .chartYScale(domain: minimum...maximum)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: period <= 30 ? 5 : 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month().day()) } }
        .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine(); AxisValueLabel() } }
    }
    private func valueText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(type == "hrv_sdnn" ? 1 : 0)))
    }
    private func sourceName(_ id: String) -> String {
        visibleReadings.first(where: { $0.sourceBundleId == id && !$0.sourceName.isEmpty })?.sourceName ?? (id.isEmpty ? "未知来源" : id)
    }
    private func loadLocal() async {
        let expected = identity, owner = store.scope
        do {
            let local = try await store.healthStorage.value.vitalReadings(scope: owner, type: type, since: since, now: Date())
            guard identity == expected, !Task.isCancelled else { return }
            readings = VitalHistory.merge(local: local, cloud: readings)
            loadedIdentity = expected
        } catch { if identity == expected { note = "本机\(title)记录暂时无法读取。" } }
    }
    private func load() async {
        let expected = identity, owner = store.scope, start = since, end = today
        loading = true; defer { if identity == expected { loading = false } }
        readings = []; loadedIdentity = expected; cloudSyncedAt = nil; note = nil
        await loadLocal()
        guard identity == expected, store.settings.healthConsent, !store.isDemo else { return }
        do {
            let from = DayKey.string(start, zone: zone), to = DayKey.string(end, zone: zone)
            let reply: CloudVitalHistory = try Wire.read(await store.network.request("/v1/measurements/history?type=\(type)&from=\(from)&to=\(to)"))
            guard identity == expected, !Task.isCancelled, reply.timezone == zone, reply.type == type, reply.unit == unit else { return }
            readings = VitalHistory.merge(local: readings, cloud: reply.readings)
            cloudSyncedAt = reply.lastHealthSyncAt
            if reply.truncated { note = "云端记录超过 5000 条，仅显示最近的部分记录。" }
        } catch { if identity == expected { note = "云端\(title)历史暂时无法读取，已显示本机保存的记录。" } }
    }
    private func refresh(authorize: Bool) async {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        await health.refreshVital(type, requestAuthorization: authorize)
        let needed = await health.vitalAuthorizationNeedsRequest(type)
        needsAuthorization = !store.healthReadingEnabled || needed
        await load()
    }
}
