import SwiftUI
import SwiftData

@main struct AiHealthApp: App {
    @State private var store: AppStore
    private let health: HealthSync
    private let companion: CompanionPhone
    init() {
        let bar = UITabBarAppearance(); bar.configureWithOpaqueBackground(); bar.backgroundColor = UIColor(Theme.cream)
        for item in [bar.stackedLayoutAppearance, bar.inlineLayoutAppearance, bar.compactInlineLayoutAppearance] {
            item.normal.iconColor = UIColor(Theme.muted); item.normal.titleTextAttributes = [.foregroundColor: UIColor(Theme.muted)]
            item.selected.iconColor = UIColor(Theme.green); item.selected.titleTextAttributes = [.foregroundColor: UIColor(Theme.green)]
        }
        UITabBar.appearance().standardAppearance = bar; UITabBar.appearance().scrollEdgeAppearance = bar
        UITabBar.appearance().unselectedItemTintColor = UIColor(Theme.muted)
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: UIColor(Theme.ink)]
        UINavigationBar.appearance().largeTitleTextAttributes = [.foregroundColor: UIColor(Theme.ink)]
        do {
            var configuration = ModelConfiguration(cloudKitDatabase: .none)
            #if DEBUG
            if let run = ProcessInfo.processInfo.environment["AIHEALTH_UI_TEST_STORE"], UUID(uuidString: run) != nil {
                configuration = ModelConfiguration("UITest-" + run, cloudKitDatabase: .none)
            }
            #endif
            let container = try ModelContainer(for: LocalRecord.self, PendingChange.self, HealthCursor.self, LocalHealthRecord.self, HealthUploadCheckpoint.self, configurations: configuration)
            let state = AppStore(container: container); _store = State(initialValue: state)
            companion = CompanionPhone(store: state)
            health = HealthSync(); health.store = state; Notifications.shared.configure(store: state)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--planning-ui-test") {
                state.startDemo(); state.selectedTab = "diet"
                let date = DayKey.string(Date(),zone: state.settings.timezone)
                let meal = NutritionMeal(slot: "lunch",name: "午餐",foods: ["鸡肉、米饭、时蔬"],preparation: "做熟后食用",alternatives: ["可替换同类食材"])
                let cycle = PlanningCycle(name: "界面验证食谱",kind: "diet",startDate: date,endDate: date,timezone: state.settings.timezone,days: [CycleDay(date: date,meals: [meal])])
                state.save(cycle,kind: "cycle",id: cycle.id)
            }
            if ProcessInfo.processInfo.arguments.contains("--session-expired-ui-test") {
                state.scope = state.network.baseURL.absoluteString + "/ui-test-user"
                state.reload(); state.selectedTab = "coach"
                state.needsReauthentication = true; state.showReauthentication = true
            }
            if ProcessInfo.processInfo.arguments.contains("--energy-summary-ui-test") {
                state.startDemo(); state.selectedTab = "diet"
                var breakfast = MealLog(slot: "breakfast", description: "小笼包", eatenAt: Date(), timezone: state.settings.timezone)
                breakfast.energyMethod = "estimated_range"; breakfast.estimateMinKcal = 200; breakfast.estimateMaxKcal = 400; breakfast.nutritionSource = "AI 粗估"
                var lunch = MealLog(slot: "lunch", description: "泡面、虾、鸡蛋", eatenAt: Date(), timezone: state.settings.timezone)
                lunch.energyMethod = "estimated_range"; lunch.estimateMinKcal = 515; lunch.estimateMaxKcal = 950; lunch.nutritionSource = "AI 粗估"
                state.save(breakfast, kind: "meal", id: breakfast.id)
                state.save(lunch, kind: "meal", id: lunch.id)
            }
            if ProcessInfo.processInfo.arguments.contains("--food-share-ui-test") {
                state.scope = state.network.baseURL.absoluteString + "/ui-test-user"
                state.reload(); state.selectedTab = "diet"
            }
            if ProcessInfo.processInfo.arguments.contains("--sleep-ui-test") {
                state.startDemo(); state.setHealthReading(false); state.settings.timezone = "Asia/Shanghai"
                let end = Date().addingTimeInterval(-1)
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
                var samples: [HealthSample] = []
                for (index, hours) in [(0, 7.0), (1, 6.5), (3, 8.0), (4, 7.5), (5, 6.0), (8, 7.2), (12, 8.1), (16, 6.8), (20, 7.4), (24, 7.0), (27, 6.5)] {
                    let wake = calendar.date(byAdding: .day, value: -index, to: end)!
                    let start = wake.addingTimeInterval(-hours * 3600)
                    for (category, from, to) in [("asleep_core", 0.0, hours - 2.5), ("asleep_deep", hours - 2.5, hours - 1.5), ("asleep_rem", hours - 1.5, hours)] {
                        samples.append(HealthSample(healthkitUuid: newID(), type: "sleep_analysis", unit: "category", category: category, startAt: start.addingTimeInterval(from * 3600), endAt: start.addingTimeInterval(to * 3600), sourceName: "Synthetic sleep", sourceBundleId: "test.sleep"))
                    }
                }
                Task {
                    try? await state.healthStorage.value.persist(samples: samples, anchor: nil, cursorKey: "local-demo/synthetic-sleep", scope: "local-demo", upload: false)
                    await state.refreshLocalHealth(markRead: true)
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--watch-start-pair-test") {
                state.startDemo(); state.selectedTab = "training"
                var plan = Plan.starter(); plan.scheduledDate = DayKey.string(Date(), zone: state.settings.timezone)
                state.save(plan, kind: "plan", id: plan.id)
            }
            if ProcessInfo.processInfo.arguments.contains("--rest-day-ui-test") {
                state.startDemo(); state.selectedTab = "today"
                let date = DayKey.string(Date(), zone: state.settings.timezone)
                let cycle = PlanningCycle(name: "休息日验证", kind: "training", startDate: date, endDate: date,
                                          timezone: state.settings.timezone, days: [CycleDay(date: date, rest: true)])
                state.save(cycle, kind: "cycle", id: cycle.id)
            }
            if ProcessInfo.processInfo.arguments.contains("--watch-pair-test") {
                state.startDemo(); state.selectedTab = "training"
                if var fixture = state.activeWorkout { fixture.synthetic = true; state.save(fixture, kind: "workout", id: fixture.id) }
                if state.activeWorkout == nil { let plan = Plan.starter(); state.start(plan: plan, day: plan.days[0], synthetic: true) }
            }
            #endif
        } catch { fatalError("无法打开本地数据库，请保留 App 数据并联系支持：\(error)") }
    }
    var body: some Scene { WindowGroup { RootView(store: store, health: health).tint(Theme.green).foregroundStyle(Theme.ink).preferredColorScheme(.light) } }
}

enum Theme {
    static let green = Color(red: 0.12, green: 0.37, blue: 0.30)
    static let cream = Color(red: 0.96, green: 0.97, blue: 0.94)
    static let muted = Color(red: 0.40, green: 0.47, blue: 0.43)
    static let ink = Color(red: 0.13, green: 0.28, blue: 0.24)
}
struct RootView: View {
    @Bindable var store: AppStore; let health: HealthSync
    @Environment(\.scenePhase) private var phase
    @State private var refreshingScope: String?
    var body: some View {
        Group {
            if store.signedIn {
                TabView(selection: $store.selectedTab) {
                    TodayView(health: health, store: store).tabItem { Label("今天", systemImage: "sun.max") }.tag("today")
                    TrainingCalendarView(store: store).tabItem { Label("训练", systemImage: "dumbbell") }.tag("training")
                    CoachView(store: store).tabItem { Label("教练", systemImage: "sparkles") }.tag("coach")
                    DietView(store: store).tabItem { Label("饮食", systemImage: "fork.knife") }.tag("diet")
                    AccountView(store: store, health: health).tabItem { Label("我的", systemImage: "person.crop.circle") }.tag("account")
                }
            } else { WelcomeView(store: store) }
        }
        .alert("提示", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("知道了") { store.error = nil } } message: { Text(store.error ?? "") }
        .sheet(isPresented: $store.showReauthentication) { ReauthenticationView(store: store) }
        .task(id: store.scope) { await refresh() }
        .onChange(of: phase) { _, value in if value == .active { Task { await refresh() } } }
    }
    private func refresh() async {
        let owner = store.scope
        guard refreshingScope != owner else { return }
        refreshingScope = owner
        defer { if refreshingScope == owner { refreshingScope = nil } }
        store.expireOvernightWorkouts()
        store.companionRefreshRequested?()
        async let coach: () = store.loadCoach()
        await health.syncAll()
        await health.activate()
        guard store.scope == owner else { return }
        await store.synchronize(showErrors: false)
        await store.refreshLocalHealth()
        await coach
        if store.scope == owner { store.companionRefreshRequested?() }
    }
}

struct ReauthenticationView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("重新登录云端账号") {
                    Text("登录已过期。用原账号重新登录后，继续同步这台设备上的记录。")
                    Text("服务器：\(store.network.baseURL.absoluteString)").font(.caption).foregroundStyle(.secondary)
                    TextField("原账号邮箱", text: $email).textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).accessibilityIdentifier("reauth-email")
                    AccountSecureField(placeholder: "密码", text: $password, contentType: .password).frame(height: 36)
                    Button("重新登录") {
                        dismissInputKeyboard()
                        Task { if await store.reauthenticate(email: email, password: password) { dismiss() } }
                    }.disabled(store.reauthenticating || email.isEmpty || password.isEmpty).accessibilityIdentifier("reauth-submit")
                }
                Section { Text("本机记录和待上传数据会保留在原账号空间。登录其他账号不会覆盖它们。") .font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("云端账号").toolbar { Button("稍后") { dismiss() } }
        }
    }
}

struct WelcomeView: View {
    @Bindable var store: AppStore
    @State private var url = UserDefaults.standard.string(forKey: "serverURL") ?? Network.defaultURL
    @State private var email = ""; @State private var password = ""; @State private var register = true
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Image(systemName: "leaf.circle.fill").font(.system(size: 64)).foregroundStyle(Theme.green)
                    VStack(alignment: .leading, spacing: 10) { Text("日益").font(.largeTitle.bold()); Text("让每一次训练，\n成为看得见的积累。").font(.title2).foregroundStyle(Theme.muted) }
                    VStack(spacing: 14) {
                        TextField("服务器地址", text: $url).textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
                        TextField("邮箱", text: $email).textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        AccountSecureField(placeholder: "密码（12–72 字节）", text: $password, contentType: register ? nil : .password).frame(height: 36)
                    }.textFieldStyle(.roundedBorder)
                    Button { dismissInputKeyboard(); Task { await store.authenticate(url: url, email: email, password: password, register: register) } } label: {
                        HStack { Spacer(); if store.syncing { ProgressView().tint(.white) }; Text(register ? "创建账号，开始记录" : "登录").bold(); Spacer() }.padding(.vertical, 10)
                    }.buttonStyle(.borderedProminent).disabled(store.syncing || email.isEmpty || password.isEmpty)
                    Button(register ? "已有账号？登录" : "没有账号？注册") { register.toggle() }
                    Divider()
                    Button("先体验本地记录") { store.startDemo() }
                    Text("本地体验的数据只保存在这台设备，不上传、不调用 AI；与云端账号的数据分开保存。").font(.footnote).foregroundStyle(.secondary)
                }.padding(28)
            }.background(Theme.cream)
        }
    }
}

struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 22)) }
}

struct TodayView: View {
    let health: HealthSync
    @Bindable var store: AppStore; @State private var feedback = false
    @State private var training: Workout?
    @State private var teamRefreshRevision = 0
    let columns = [GridItem(.flexible()), GridItem(.flexible())]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { VStack(alignment: .leading, spacing: 5) { Text(Date(), format: .dateTime.month().day().weekday()).font(.subheadline).foregroundStyle(Theme.muted); Text("今天，照顾好自己").font(.title2.bold()) }; Spacer(); Image(systemName: "sun.max.fill").font(.title).foregroundStyle(.orange) }
                    if store.isDemo { Text("本机模式 · 可读取苹果健康，数据不上传").font(.footnote).foregroundStyle(Theme.muted) }
                    if let note = store.lastOvernightClosure { Text(note).font(.footnote).foregroundStyle(Theme.muted) }
                    Surface {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("训练日记", systemImage: "dumbbell.fill").font(.subheadline).foregroundStyle(Theme.green)
                            if let w = store.activeWorkout {
                                Text(w.name).font(.title.bold())
                                Text(w.activity == nil ? "已完成 \(w.completedSets) / \(w.totalSets) 组" : "正在记录运动时长").foregroundStyle(.secondary)
                                NavigationLink("继续训练") { WorkoutView(store: store, workout: w) }.buttonStyle(.borderedProminent)
                            } else if let (_, scheduled) = store.scheduled("training", date: DayKey.string(Date(), zone: store.settings.timezone)) {
                                if scheduled.rest {
                                    if let activity = scheduled.recoveryActivity, !activity.isEmpty {
                                        Text(activity).font(.title.bold())
                                        Text("今日休息安排").foregroundStyle(.secondary)
                                    } else {
                                        Text("今天是休息日").font(.title.bold())
                                        Text("训练日历已安排休息。").foregroundStyle(.secondary)
                                    }
                                    NavigationLink("查看／调整今天安排") { ScheduledRestDayView(store: store, date: scheduled.date) }.buttonStyle(.bordered)
                                } else {
                                    Text("今天安排 \(scheduled.trainingBlocks.count) 项训练").font(.title3.bold())
                                    ForEach(Array(scheduled.trainingBlocks.enumerated()), id: \.element.id) { index, block in
                                        HStack(alignment: .top) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text("\(index + 1). \(block.name)").font(.headline)
                                                Text(sportTitle(block.sport)).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            if let workout = store.workout(for: block, on: scheduled.date) {
                                                if workout.status == "in_progress" {
                                                    Button("继续") { training = workout }.buttonStyle(.bordered)
                                                } else {
                                                    Text("已完成").font(.caption).foregroundStyle(.secondary)
                                                }
                                            } else if let plan = block.plan, let day = plan.days.first {
                                                Button("开始") { store.start(plan: plan, day: day, scheduledBlockId: block.id) }.buttonStyle(.bordered)
                                            } else if let activity = block.activity {
                                                Button("开始") { store.start(activity: activity, scheduledBlockId: block.id) }.buttonStyle(.bordered)
                                            }
                                        }
                                    }
                                    Button("调整今天安排") { store.calendarDate = Date(); store.selectedTab = "training" }.buttonStyle(.bordered)
                                }
                            } else if let p = store.todayPlan, let d = p.days.first {
                                Text(d.name).font(.title.bold())
                                Text(d.activity == nil ? "\(d.exercises.count) 个动作 · \(d.exercises.reduce(0) { $0 + $1.sets.count }) 组计划" : "\(sportTitle(d.activity!.resolvedSport)) · \(d.activity!.targetMinutes.map { "目标 \($0) 分钟" } ?? "按时长记录")").foregroundStyle(.secondary)
                                Button("开始训练") { store.start(plan: p, day: d) }.buttonStyle(.borderedProminent)
                            } else if !store.workouts(on: DayKey.string(Date(), zone: store.settings.timezone)).isEmpty {
                                Text("今日已记录训练").font(.title3.bold())
                                ForEach(store.workouts(on: DayKey.string(Date(), zone: store.settings.timezone))) { workout in
                                    NavigationLink("\(workout.name) · \(workout.status == "completed" ? "已完成" : workout.status == "in_progress" ? "进行中" : "已结束")") {
                                        WorkoutView(store: store, workout: workout)
                                    }.buttonStyle(.bordered)
                                }
                                Button("继续安排训练") { store.calendarDate = Date(); store.selectedTab = "training" }.buttonStyle(.bordered)
                            } else if !store.plans.isEmpty {
                                Text("今天还没有安排训练").font(.title3.bold())
                                Text("已有 \(store.plans.count) 份计划模板，可在训练日历里选择训练日和日期。").foregroundStyle(.secondary)
                                Button("安排今天的训练") { store.calendarDate = Date(); store.selectedTab = "training" }.buttonStyle(.borderedProminent)
                            } else { Text("从一份训练计划开始").font(.title3.bold()); Text("在「训练」中登记动作和计划组。").foregroundStyle(.secondary) }
                        }
                    }
                    TodayTeamCard(store: store, refreshRevision: teamRefreshRevision)
                    LazyVGrid(columns: columns, spacing: 12) {
                        metric("最近体重", key: "body_mass", unit: "kg", icon: "scalemass")
                        NavigationLink {
                            SleepDetailView(store: store, health: health)
                        } label: { metric("昨晚睡眠", key: "sleep_total_minutes", unit: "分钟", icon: "moon") }
                        .buttonStyle(.plain).accessibilityIdentifier("sleep-summary")
                        metric("昨日静息心率", key: "resting_heart_rate", unit: "bpm", icon: "heart")
                        metric("昨日 HRV", key: "hrv_sdnn", unit: "ms", icon: "waveform.path.ecg")
                    }
                    if let date = store.localHealthReadAt { Text("最近本机健康读取：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    if !store.healthReadingEnabled {
                        NavigationLink("本机健康尚未授权 · 去查看睡眠读取权限") { SleepDetailView(store: store, health: health) }
                            .font(.footnote).foregroundStyle(Theme.green)
                    }
                    Surface {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Label("AI 每日报告", systemImage: "sparkles").font(.headline); Spacer(); if store.report?.stale == true { Text("数据已更新").font(.caption).foregroundStyle(.orange) } }
                            if let body = store.report?.body {
                                Text(body.summary).lineSpacing(5)
                                NavigationLink("查看完整报告") { ReportView(report: body, summary: store.cloudSummary, stale: store.report?.stale ?? false) }
                            } else { Text(reportMessage).font(.subheadline).foregroundStyle(.secondary) }
                            if store.settings.aiConsent && !store.isDemo {
                                Button { Task { await store.generateReport() } } label: { if store.reportLoading { ProgressView() } else { Text("生成 / 更新日报") } }.disabled(store.reportLoading)
                            }
                            if let s = store.cloudSummary {
                                Divider(); timestamp("云端数据截至", s.dataCutoffAt); timestamp("最近健康数据上传", s.lastHealthSyncAt)
                                Text("活动日：\(s.activityDate) · \(s.timezone)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button { feedback = true } label: { Label("记录今天的身体感受", systemImage: "square.and.pencil").frame(maxWidth: .infinity).padding(8) }.buttonStyle(.bordered)
                    Text(store.isDemo ? "数据保存在本机" : "待同步 \(store.pendingCount) 项 · 冲突 \(store.conflicts.count) 项").font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.background(Theme.cream).navigationTitle("今天").navigationBarTitleDisplayMode(.inline)
                .navigationDestination(isPresented: Binding(get: { training != nil }, set: { if !$0 { training = nil } })) {
                    if let training { WorkoutView(store: store, workout: training) }
                }
                .refreshable { await health.refreshSleep(invalidateCache: true); if !store.settings.healthConsent { await store.synchronize(showErrors: false) }; teamRefreshRevision += 1 }
                .sheet(isPresented: $feedback) { CheckinView(store: store) }
        }
    }
    var reportMessage: String {
        if store.isDemo { return "连接自己的云端后，可选择开启每日分析。" }
        switch store.report?.status { case "not_configured": return "服务器尚未配置 OpenAI API，健康记录仍可正常使用。"; case "failed": return "本次分析未完成，稍后可重试。原始记录已保留。"; case "generating": return "报告生成中，稍后刷新查看。"; default: return store.settings.aiConsent ? "尚无报告。数据不足时，报告会明确说明局限。" : "在「我的」中了解并开启 AI 分析。" }
    }
    func metric(_ title: String, key: String, unit: String, icon: String) -> some View {
        let m = key.hasPrefix("sleep_") ? store.sleepMetric(key) : store.summary?.metrics[key]
        return Surface {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: icon).font(.caption).foregroundStyle(Theme.muted)
                HStack(alignment: .firstTextBaseline, spacing: 4) { Text(m?.value.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "—").font(.title.bold()).monospacedDigit(); Text(unit).font(.caption).foregroundStyle(.secondary) }
                if let date = m?.observedAt { Text(date, format: .dateTime.month().day()).font(.caption2).foregroundStyle(.secondary) }
                else { Text("\(m?.value == nil ? "暂无可读记录" : "覆盖情况未知")").font(.caption2).foregroundStyle(.secondary) }
                if key == "body_mass", let change = store.summary?.metrics["body_mass_7d_change"]?.value { Text("周均变化 \(change >= 0 ? "+" : "")\(change.formatted(.number.precision(.fractionLength(1)))) kg").font(.caption2).foregroundStyle(Theme.muted) }
            }
        }
    }
    func timestamp(_ label: String, _ date: Date?) -> some View { Text("\(label)：\(date?.formatted(date: .abbreviated, time: .shortened) ?? "尚无记录")").font(.caption).foregroundStyle(.secondary) }
}

struct ReportView: View {
    let report: ReportBody; let summary: DailySummary?; let stale: Bool
    var body: some View {
        List {
            if stale { Section { Text("此报告基于较早数据，请更新后再查看结论。").foregroundStyle(.orange) } }
            Section("概览") { Text(report.summary) }
            Section("数据情况") { ForEach(summary?.dataQuality ?? [], id: \.self) { Text($0) }; ForEach(report.dataQuality, id: \.self) { Text($0) } }
            Section("睡眠") { Text(report.sleepAnalysis) }; Section("恢复") { Text(report.recoveryAnalysis) }
            Section("训练") { Text(report.trainingAnalysis) }; Section("体重趋势") { Text(report.bodyTrend) }
            Section("接下来的小调整") { ForEach(report.todaySuggestions, id: \.self) { Text($0) } }
            Section { Text("根据已记录数据提供解释，不作为疾病诊断或治疗依据。").font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("每日报告")
    }
}
