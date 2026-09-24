import SwiftUI
import Charts

private enum SleepStyle {
    static let purple = Color(red: 0.43, green: 0.34, blue: 0.76)
    static let stageNames = [("awake", "清醒"), ("asleep_rem", "REM 睡眠"), ("asleep_core", "核心睡眠"), ("asleep_deep", "深度睡眠"), ("asleep_unspecified", "未细分阶段")]
    static func color(_ stage: String) -> Color {
        switch stage { case "awake": .orange; case "asleep_rem": .cyan; case "asleep_core": .blue; case "asleep_deep": .indigo; default: purple.opacity(0.6) }
    }
    static func duration(_ minutes: Double) -> String {
        let value = Int(minutes.rounded()); return value >= 60 ? "\(value / 60) 小时 \(value % 60) 分钟" : "\(value) 分钟"
    }
    static func date(_ date: Date, zone: String, format: String = "M月d日") -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: zone); formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
private struct SleepDay: Identifiable, Hashable {
    let date: Date
    let id: String
}

/// The Today card enters a period overview; every date leads to its own night.
struct SleepDetailView: View {
    @Bindable var store: AppStore
    let health: HealthSync
    @State private var period = 7
    @State private var offset = 0
    @State private var nights: [String: SleepNight] = [:]
    @State private var loadedIdentity = ""
    @State private var cloudPending: Set<String> = []
    @State private var busy = false
    @State private var note: String?
    @State private var needsSleepAuthorization = false
    @State private var showAuthorizationPrompt = false
    private var zone: String { store.settings.timezone }
    private var calendar: Calendar { DayKey.calendar(zone) }
    private var today: Date { calendar.startOfDay(for: Date()) }
    private var lastDay: Date { calendar.date(byAdding: .day, value: offset * period, to: today)! }
    private var days: [SleepDay] {
        (0..<period).reversed().compactMap { index in
            let date = calendar.date(byAdding: .day, value: -index, to: lastDay)!
            guard date >= calendar.startOfDay(for: store.healthWindowStart) else { return nil }
            return SleepDay(date: date, id: DayKey.string(date, zone: zone))
        }
    }
    private var identity: String { "\(store.scope)|\(zone)|\(period)|\(offset)|\(store.healthHistoryWindow.rawValue)|\(DayKey.string(today, zone: zone))" }
    private var visibleNights: [SleepNight] { loadedIdentity == identity ? days.compactMap { nights[$0.id] } : [] }
    private var average: Double? { SleepHistory.average(visibleNights) }
    private var canGoBack: Bool {
        guard let first = days.first else { return false }
        return first.date > calendar.startOfDay(for: store.healthWindowStart)
    }
    var body: some View {
        List {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--sleep-ui-test") { Text("合成测试数据").font(.caption).foregroundStyle(.secondary) }
            #endif
            Section {
                Picker("显示范围", selection: $period) { Text("周").tag(7); Text("月").tag(30) }
                    .pickerStyle(.segmented).accessibilityIdentifier("sleep-period")
                HStack {
                    Button { offset -= 1 } label: { Image(systemName: "chevron.left") }.disabled(!canGoBack).accessibilityLabel("上一时段")
                    Spacer()
                    if let first = days.first, let last = days.last { Text("\(SleepStyle.date(first.date, zone: zone)) — \(SleepStyle.date(last.date, zone: zone))").font(.subheadline.weight(.medium)) }
                    Spacer()
                    Button { offset += 1 } label: { Image(systemName: "chevron.right") }.disabled(offset == 0).accessibilityLabel("下一时段")
                }.buttonStyle(.borderless)
                VStack(alignment: .leading, spacing: 5) {
                    Text("平均睡眠时长").font(.subheadline).foregroundStyle(.secondary)
                    Text(average.map(SleepStyle.duration) ?? "暂无记录").font(.title.bold()).foregroundStyle(SleepStyle.purple).accessibilityIdentifier("sleep-average")
                    Text("已记录 \(visibleNights.count) / \(days.count) 晚").font(.caption).foregroundStyle(.secondary)
                }
                if needsSleepAuthorization {
                    Label("尚未向日益请求本机睡眠读取权限；云端历史仍可查看。", systemImage: "lock.shield")
                        .font(.subheadline).foregroundStyle(.orange)
                    Button("现在授权睡眠读取") { Task { await refresh(authorize: true); await checkSleepAuthorization() } }
                        .disabled(busy).accessibilityIdentifier("sleep-auth-reminder-action")
                }
                trend.frame(height: 185)
                Text("点击柱形或下方日期，查看那一晚。空白表示尚未读到记录，不计入平均时长。").font(.caption).foregroundStyle(.secondary)
            } header: { Text(period == 7 ? "7 天睡眠" : "30 天睡眠") }
            Section("每晚睡眠 · 按醒来日期") {
                ForEach(days.reversed()) { day in
                    NavigationLink { SleepNightDetailView(store: store, health: health, wakeDate: day.id, prefetched: nights[day.id]) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(SleepStyle.date(day.date, zone: zone, format: "M月d日 EEEE"))
                                if day.date == today { Text("昨晚睡眠").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Text(loadedIdentity == identity ? nights[day.id].map { SleepStyle.duration($0.minutes) } ?? (cloudPending.contains(day.id) ? "云端读取中…" : "暂无记录") : "读取中…")
                                .font(.subheadline).foregroundStyle(SleepStyle.purple)
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("sleep-night-\(day.id)")
                }
            }
            Section("读取与更新") {
                Button("刷新睡眠记录") { Task { await refresh(authorize: false) } }.disabled(busy)
                Button("授权 / 补充本机睡眠读取") { Task { await refresh(authorize: true); await checkSleepAuthorization() } }.disabled(busy)
                    .accessibilityIdentifier("authorize-local-sleep")
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                Text("显示当前健康读取范围内的记录。若苹果健康中已有数据，请确认已允许“日益”读取睡眠。\nApple 尚未向第三方开放睡眠评分读取；这里展示时长和阶段。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("睡眠").navigationBarTitleDisplayMode(.inline)
        .environment(\.calendar, calendar).environment(\.timeZone, calendar.timeZone)
        .onChange(of: period) { _, _ in offset = 0 }
        .task(id: identity + "|" + String(store.sleepRevision)) { await load() }
        .task { await health.refreshSleep(automatic: true) }
        .task(id: store.scope + "|" + String(store.healthReadingEnabled)) { await checkSleepAuthorization() }
        .refreshable { await refresh(authorize: false) }
        .alert("授权本机睡眠读取", isPresented: $showAuthorizationPrompt) {
            Button("稍后", role: .cancel) { }
            Button("去授权") { Task { await refresh(authorize: true); await checkSleepAuthorization() } }
        } message: { Text("这台 iPhone 尚未向日益请求 Apple 健康的睡眠读取权限。授权后才能读取新的本机睡眠；已同步的云端历史仍可查看。") }
    }
    private func checkSleepAuthorization() async {
        let owner = store.scope
        let needed = await health.sleepAuthorizationNeedsRequest()
        guard store.scope == owner, !Task.isCancelled else { return }
        needsSleepAuthorization = needed
        if needed && !store.sleepAuthReminderShown {
            store.sleepAuthReminderShown = true
            showAuthorizationPrompt = true
        }
    }
    private var trend: some View {
        Chart(visibleNights) { night in
            if let date = DayKey.date(night.date, zone: zone) {
                BarMark(x: .value("醒来日期", date, unit: .day), y: .value("小时", night.minutes / 60))
                    .foregroundStyle(SleepStyle.purple.gradient).cornerRadius(3)
                    .accessibilityLabel("\(night.date)，\(SleepStyle.duration(night.minutes))")
            }
        }
        .chartXScale(domain: (days.first?.date ?? today)...calendar.date(byAdding: .day, value: 1, to: lastDay)!)
        .chartYScale(domain: 0...max(10, (visibleNights.map(\.minutes).max() ?? 0) / 60 + 1))
        .chartXAxis { AxisMarks(values: .stride(by: .day, count: period == 7 ? 1 : 5)) { _ in AxisValueLabel(format: .dateTime.day()); AxisGridLine() } }
        .chartYAxis { AxisMarks(position: .trailing) { value in AxisGridLine(); AxisValueLabel { if let hours = value.as(Double.self) { Text("\(Int(hours))时") } } } }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let frame = proxy.plotFrame {
                    let plot = geometry[frame]
                    HStack(spacing: 0) {
                        ForEach(days) { day in
                            NavigationLink { SleepNightDetailView(store: store, health: health, wakeDate: day.id, prefetched: nights[day.id]) } label: {
                                Color.clear.contentShape(Rectangle())
                            }.buttonStyle(.plain).navigationLinkIndicatorVisibility(.hidden)
                                .accessibilityLabel("查看 \(day.id) 睡眠")
                                .accessibilityIdentifier("sleep-bar-\(day.id)")
                        }
                    }.frame(width: plot.width, height: plot.height).offset(x: plot.minX, y: plot.minY)
                }
            }
        }
        .accessibilityIdentifier("sleep-trend")
    }
    private func load(forceCloud: Bool = false) async {
        let expected = identity, owner = store.scope, timezone = zone, visibleDays = days, since = store.healthWindowStart
        defer { if identity == expected { cloudPending = [] } }
        do {
            let data = try await store.healthStorage.value.sleepHistory(scope: owner, zone: timezone, days: visibleDays.map(\.date), since: since, now: Date())
            guard identity == expected, !Task.isCancelled else { return }
            var values = Dictionary(uniqueKeysWithValues: data.map { ($0.date, $0) })
            let current = DayKey.string(Date(), zone: timezone)
            if values[current] == nil, visibleDays.contains(where: { $0.id == current }), let cloud = store.cloudSummary,
               let night = SleepHistory.cloudNight(cloud, date: current, zone: timezone, now: Date()) { values[current] = night }
            nights = values; loadedIdentity = expected; note = nil
            guard !store.isDemo, store.settings.healthConsent, let first = visibleDays.first, let last = visibleDays.last else { return }
            var missing: [String] = []
            for day in visibleDays where values[day.id] == nil {
                if forceCloud { missing.append(day.id); continue }
                let cached = try await store.healthStorage.value.cachedCloudNight(scope: owner, zone: timezone, date: day.id, lastSync: store.cloudSummary?.lastHealthSyncAt, now: Date())
                guard identity == expected, !Task.isCancelled else { return }
                if cached.0 { if let night = cached.1 { values[day.id] = night } }
                else { missing.append(day.id) }
            }
            nights = values
            guard !missing.isEmpty else { return }
            cloudPending = Set(missing)
            let response: CloudSleepHistory = try Wire.read(await store.network.request("/v1/sleep/history?from=\(first.id)&to=\(last.id)"))
            guard identity == expected, !Task.isCancelled, response.timezone == timezone else { return }
            let received = Dictionary(uniqueKeysWithValues: response.nights.filter { night in visibleDays.contains(where: { day in day.id == night.date }) }.map { ($0.date, $0) })
            try await store.healthStorage.value.saveCloudNights(scope: owner, zone: timezone, dates: missing, nights: received)
            for date in missing { if let night = received[date], values[date] == nil { values[date] = night } }
            nights = values
        } catch {
            guard identity == expected else { return }
            if loadedIdentity != expected { nights = [:]; loadedIdentity = expected }
            note = "云端睡眠列表暂时无法读取，已显示本机记录；稍后可刷新。"
        }
    }
    private func refresh(authorize: Bool) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        await health.refreshSleep(requestAuthorization: authorize, invalidateCache: true); await load(forceCloud: true)
    }
}

private struct SleepNightDetailView: View {
    @Bindable var store: AppStore
    let health: HealthSync
    let wakeDate: String
    let prefetched: SleepNight?
    @State private var night: SleepNight?
    @State private var loadedIdentity = ""
    @State private var loading = false
    @State private var busy = false
    @State private var note: String?
    @State private var report: DailyReport?
    @State private var reportIdentity = ""
    private var identity: String { "\(store.scope)|\(store.settings.timezone)|\(wakeDate)|\(store.healthHistoryWindow.rawValue)" }
    private var current: SleepNight? { loadedIdentity == identity ? night : nil }
    private var calendar: Calendar { DayKey.calendar(store.settings.timezone) }
    var body: some View {
        List {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--sleep-ui-test") { Text("合成测试数据").font(.caption).foregroundStyle(.secondary) }
            #endif
            Section {
                Text("\(wakeDate) 醒来").font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("sleep-selected-date")
                if let current {
                    Text(SleepStyle.duration(current.minutes)).font(.largeTitle.bold()).foregroundStyle(SleepStyle.purple).accessibilityIdentifier("sleep-duration")
                    Text("实际睡眠时长").font(.subheadline).foregroundStyle(.secondary)
                    if let first = current.segments.first, let last = current.segments.last {
                        HStack {
                            VStack(alignment: .leading) { Text("首段记录").font(.caption); Text(timestamp(first.start)) }
                            Spacer()
                            VStack(alignment: .trailing) { Text("末段记录").font(.caption); Text(timestamp(last.end)) }
                        }.font(.subheadline)
                    }
                } else if loading { ProgressView("正在读取这一晚…") }
                else { Text("尚未读到这晚睡眠").font(.headline); Text("没有记录不代表没有睡眠，也不会按零分钟分析。").font(.subheadline).foregroundStyle(.secondary) }
            }
            if let current {
                Section("睡眠阶段") {
                    if !current.segments.isEmpty {
                        Chart(current.segments) { segment in
                            BarMark(xStart: .value("开始", segment.start), xEnd: .value("结束", segment.end), y: .value("阶段", stageName(segment.category)))
                                .foregroundStyle(SleepStyle.color(segment.category)).cornerRadius(3)
                        }.chartYScale(domain: SleepStyle.stageNames.filter { current.stages[$0.0] != nil }.map(\.1))
                        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.hour().minute()) } }
                            .frame(height: 160).accessibilityIdentifier("sleep-stages")
                    }
                    ForEach(SleepStyle.stageNames, id: \.0) { key, name in
                        if key != "asleep_unspecified" || current.stages[key] != nil {
                            HStack { Circle().fill(SleepStyle.color(key)).frame(width: 9, height: 9); Text(name); Spacer(); Text(current.stages[key].map(SleepStyle.duration) ?? "暂无记录").foregroundStyle(.secondary) }.font(.subheadline)
                        }
                    }
                }
                Section("记录来源") {
                    Text(current.cloud ? "云端已同步的 Apple 健康记录" : "本机已读取的 Apple 健康记录").font(.subheadline)
                    Text("记录截至 \(timestamp(current.observedAt)) · \(store.settings.timezone)").font(.caption).foregroundStyle(.secondary)
                    if current.cloud, let cutoff = current.cutoff { Text("云端摘要截至 \(timestamp(cutoff))").font(.caption).foregroundStyle(.secondary) }
                    Text("按醒来日期归属，多来源选择单一来源，重叠时段不重复累计。阶段缺失不代表零。Apple 尚未向第三方开放睡眠评分读取。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("这晚睡眠分析") {
                Text("只回顾 \(wakeDate) 这晚的睡眠，并结合截至当天的恢复与训练记录。").font(.subheadline)
                if store.isDemo { Text("登录并开启健康同步、AI 分析后可生成回顾。").font(.caption).foregroundStyle(.secondary) }
                else if !store.settings.healthConsent || !store.settings.aiConsent { Text("请在“我的”开启健康数据云同步和 AI 分析。").font(.caption).foregroundStyle(.secondary) }
                if reportIdentity == identity, let report {
                    if let body = report.body, !body.sleepAnalysis.isEmpty {
                        Text(body.sleepAnalysis).accessibilityIdentifier("selected-night-analysis")
                        if !body.recoveryAnalysis.isEmpty { Text(body.recoveryAnalysis).font(.subheadline).foregroundStyle(.secondary) }
                        if report.stale { Text("分析依据已更新，这份报告待刷新。").font(.caption).foregroundStyle(.orange) }
                        if let generated = report.generatedAt { Text("报告生成于 \(timestamp(generated))").font(.caption).foregroundStyle(.secondary) }
                    } else if report.status == "generating" { ProgressView("正在分析这晚睡眠…") }
                    else if report.status == "failed" { Text("分析暂未完成，可稍后重试。").font(.caption).foregroundStyle(.secondary) }
                    else { Text("暂无这晚的分析。每天同步后会自动生成，也可以手动分析。").font(.caption).foregroundStyle(.secondary) }
                }
                Button { Task { await analyze() } } label: {
                    if busy { HStack { ProgressView(); Text("正在分析这晚睡眠…") } }
                    else { Label(reportIdentity == identity && report?.body != nil ? "更新这晚分析" : "分析这晚睡眠", systemImage: "sparkles") }
                }.disabled(current == nil || busy || store.isDemo || !store.settings.healthConsent || !store.settings.aiConsent)
                    .accessibilityIdentifier("analyze-selected-night")
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            Section { Button("刷新这晚记录") { Task { await refresh() } }.disabled(busy || loading) }
        }.navigationTitle("当晚睡眠").navigationBarTitleDisplayMode(.inline)
            .environment(\.calendar, calendar).environment(\.timeZone, calendar.timeZone)
            .task(id: identity) { await load(); await loadReport() }.refreshable { await refresh() }
    }
    private func stageName(_ key: String) -> String { SleepStyle.stageNames.first { $0.0 == key }?.1 ?? key }
    private func timestamp(_ date: Date) -> String { SleepStyle.date(date, zone: store.settings.timezone, format: "M月d日 HH:mm") }
    private func load(forceCloud: Bool = false) async {
        let expected = identity, owner = store.scope, zone = store.settings.timezone, since = store.healthWindowStart, client = store.network
        guard let date = DayKey.date(wakeDate, zone: zone), date >= calendar.startOfDay(for: since), date <= Date() else { return }
        loading = true; defer { if identity == expected { loading = false } }
        do {
            let local = try await store.healthStorage.value.sleepHistory(scope: owner, zone: zone, days: [date], since: since, now: Date()).first
            guard identity == expected, !Task.isCancelled else { return }
            night = local ?? (prefetched?.date == wakeDate ? prefetched : nil); loadedIdentity = expected; note = nil
            if local == nil, (prefetched == nil || forceCloud), !store.isDemo, store.settings.healthConsent {
                if !forceCloud {
                    let cached = try await store.healthStorage.value.cachedCloudNight(scope: owner, zone: zone, date: wakeDate, lastSync: store.cloudSummary?.lastHealthSyncAt, now: Date())
                    guard identity == expected, !Task.isCancelled else { return }
                    if cached.0 { night = cached.1; return }
                }
                let summary: DailySummary = try Wire.read(await client.request("/v1/summary?date=\(wakeDate)"))
                guard identity == expected, !Task.isCancelled else { return }
                night = SleepHistory.cloudNight(summary, date: wakeDate, zone: zone, now: Date())
                try await store.healthStorage.value.saveCloudNight(scope: owner, zone: zone, date: wakeDate, night: night)
            }
        } catch { guard identity == expected else { return }; note = "这晚记录暂时读取失败，请稍后刷新。" }
    }
    private func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        await health.refreshSleep(invalidateCache: true); await load(forceCloud: true); await loadReport()
    }
    private func loadReport() async {
        let expected = identity
        guard !store.isDemo, store.settings.healthConsent, store.settings.aiConsent else { return }
        do {
            let value: DailyReport = try Wire.read(await store.network.request("/v1/report?date=\(wakeDate)"))
            guard identity == expected, !Task.isCancelled else { return }
            report = value; reportIdentity = expected
        } catch { if identity == expected { note = "分析暂时无法读取，请稍后重试。" } }
    }
    private func analyze() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let expected = identity, zone = store.settings.timezone, client = store.network
        guard !store.healthUploadPaused else { note = "健康上传已暂停，请恢复后再分析。"; return }
        guard !store.syncing, store.pendingHealthCount == 0, store.healthUploadProgress?.finished != false else { note = "健康记录仍在同步，请等上传完成后再分析。"; return }
        do {
            // Keep historical results local to this view; today's cloudSummary remains untouched.
            let summary: DailySummary = try Wire.read(await client.request("/v1/summary?date=\(wakeDate)"))
            guard identity == expected else { return }
            guard SleepHistory.cloudNight(summary, date: wakeDate, zone: zone, now: Date()) != nil else { note = "云端尚未收到这晚睡眠，请先完成读取和同步。"; return }
            let value: DailyReport = try Wire.read(await client.request("/v1/report?date=\(wakeDate)", method: "POST"))
            guard identity == expected else { return }
            report = value; reportIdentity = expected
            note = value.status == "failed" ? "本次分析未完成，请稍后重试。" : nil
        } catch { if identity == expected { note = "云端记录暂时无法确认，请稍后重试。" } }
    }
}
