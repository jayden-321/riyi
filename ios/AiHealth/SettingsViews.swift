import SwiftUI

struct WaterView: View {
    @Bindable var store: AppStore
    @State private var custom = 300; @State private var date = Date(); @State private var reminders = false
    @State private var start = 8; @State private var end = 22; @State private var interval = 2
    @State private var reminderStatus = ""
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("今天已记录", systemImage: "drop.fill").foregroundStyle(Theme.green)
                        HStack(alignment: .firstTextBaseline) { Text("\(store.waterToday)").font(.system(size: 48, weight: .bold, design: .rounded)); Text("/ \(store.profile.waterGoalMl) ml").foregroundStyle(.secondary) }
                        ProgressView(value: min(Double(store.waterToday) / Double(store.profile.waterGoalMl), 1))
                        HStack { Button("+ 250 ml") { store.addWater(250) }; Spacer(); Button("+ 500 ml") { store.addWater(500) } }.buttonStyle(.borderedProminent)
                        Text("未登记不代表未喝水；目标可在个人档案中调整。").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
                Section("自定义 / 补记") {
                    HStack { Text("饮水量"); TextField("ml", value: $custom, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing); Text("ml") }
                    DatePicker("饮水时间", selection: $date, in: ...Date())
                    Button("记录这次饮水") { store.addWater(custom, date: date); date = Date() }.disabled(custom < 1 || custom > 5000)
                }
                Section("提醒") {
                    Stepper("开始：\(start):00", value: $start, in: 0...22)
                    Stepper("结束：\(end):00", value: $end, in: 1...23)
                    Stepper("每 \(interval) 小时", value: $interval, in: 1...8)
                    Button("保存并开启提醒") { Task { do { try await Notifications.shared.schedule(start: start, end: end, interval: interval); reminderStatus = "已安排 \(start):00–\(end):00 的每日提醒" } catch { store.error = error.localizedDescription } } }.disabled(start >= end)
                    Button("关闭提醒") { Task { await Notifications.shared.cancelWater(); reminderStatus = "提醒已关闭" } }
                    if !reminderStatus.isEmpty { Text(reminderStatus).font(.caption).foregroundStyle(.secondary) }
                }
                Section("最近记录 · 左滑可删除") {
                    ForEach(Array(store.waters.prefix(50))) { w in
                        HStack { Label("\(w.amountMl) ml", systemImage: "drop"); Spacer(); Text(w.drankAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                            .swipeActions { Button("删除", role: .destructive) { store.remove(kind: "water", id: w.id) } }
                    }
                }
            }.navigationTitle("饮水").onAppear {
                let settings = Notifications.shared.savedSettings(); start = settings.start; end = settings.end; interval = settings.interval
                reminderStatus = settings.enabled ? "已安排 \(start):00–\(end):00 的每日提醒" : "提醒尚未开启"
            }
        }
    }
}

struct AccountView: View {
    @Bindable var store: AppStore; let health: HealthSync
    @State private var editProfile = false; @State private var healthConsent = false; @State private var aiConsent = false
    @State private var exportURL: URL?; @State private var deleteSheet = false; @State private var logoutConfirm = false
    var body: some View {
        NavigationStack {
            List {
                if !store.isDemo {
                    Button { store.showReauthentication = true } label: {
                        Label(store.needsReauthentication ? "登录已过期 · 重新登录" : "重新登录云端账号", systemImage: "person.crop.circle.badge.checkmark")
                    }.accessibilityIdentifier("account-reauth")
                }
                NavigationLink { profilePage } label: { Label("我的健康档案", systemImage: "person.crop.circle") }.accessibilityIdentifier("account-profile")
                NavigationLink { healthPage } label: { Label("Apple 健康", systemImage: "heart.text.clipboard") }.accessibilityIdentifier("account-health")
                NavigationLink { imagesPage } label: { Label("动作图片", systemImage: "figure.strengthtraining.traditional") }.accessibilityIdentifier("account-images")
                NavigationLink { aiPage } label: { Label("AI 分析", systemImage: "sparkles") }.accessibilityIdentifier("account-ai")
                NavigationLink { syncPage } label: { Label("同步", systemImage: "arrow.triangle.2.circlepath") }.accessibilityIdentifier("account-sync")
                NavigationLink { dataPage } label: { Label("数据", systemImage: "square.and.arrow.up") }.accessibilityIdentifier("account-data")
            }.navigationTitle("我的").accessibilityIdentifier("account-menu")
        }
                .sheet(isPresented: $editProfile) { ProfileEditor(store: store, profile: store.profile) }
                .sheet(isPresented: $deleteSheet) { DeleteAccountView(store: store) }
                .alert("同意健康数据上传？", isPresented: $healthConsent) {
                    Button("取消", role: .cancel) { }
                    Button("同意上传") { Task { var s = store.settings; s.healthConsent = true; await store.updateSettings(s); await store.synchronize() } }
                } message: { Text("你允许 App 将已授权读取的健康样本、来源和时间上传到你配置的服务器，用于保存、汇总和导出。此设置独立于本机读取，也不代表同意发送给 AI。") }
                .alert("同意发送数据给 OpenAI？", isPresented: $aiConsent) {
                    Button("取消", role: .cancel) { }
                    Button("同意开启") { Task { var s = store.settings; s.aiConsent = true; await store.updateSettings(s) } }
                } message: { Text("服务器会将健康汇总、训练明细、身体反馈和相关档案发送给你配置的 AI 接口，不发送账号邮箱。若配置第三方兼容服务，该服务也会接收这些数据，留存按其规则执行。你可以关闭后续分析、导出数据或删除账号。") }
                .alert("退出当前空间？", isPresented: $logoutConfirm) {
                    Button("取消", role: .cancel) { }
                    Button("退出") { Task { await health.stop(); await store.logout() } }
                } message: { Text("本机未同步记录会保留在当前账号空间，重新登录后可继续同步；饮水提醒将关闭。") }
    }
    private var profilePage: some View {
        List {
                Section {
                    Label(store.isDemo ? "本地体验 · 健康概况" : "健康概况", systemImage: "person.crop.circle.fill").font(.headline)
                    Text(store.profile.goal).foregroundStyle(.secondary)
                    HealthProfileMeasurements(store: store)
                    Button("补充身高、腰围与目标") { editProfile = true }
                    NavigationLink("身体反馈记录") {
                        List(store.checkins) { c in VStack(alignment: .leading, spacing: 6) { Text(c.recordedAt, format: .dateTime.month().day().hour().minute()); Text("疲劳：\(c.fatigue.map(String.init) ?? "未填") · 疼痛：\(c.pain.map(String.init) ?? "未填")").font(.caption); Text(c.sleepFeeling); Text(c.note) } }.navigationTitle("身体反馈")
                    }
                }
            Section { Text("体脂率是脂肪占比；BMI 由体重和身高计算，两者分别记录。").font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("我的健康档案")
    }
    private var healthPage: some View {
        List {
                Section("Apple 健康") {
                    Picker("读取与上传范围", selection: Binding(get: { store.healthHistoryWindow }, set: { value in Task { await health.changeWindow(value) } })) {
                        ForEach(HealthHistoryWindow.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("health-history-window")
                    Text(store.healthAuthorizationNote).font(.caption).foregroundStyle(.secondary)
                    Text("已增加身高与腰围读取；如未显示，请重新授权这两项。未读到的数据可能未授权、没有记录或不在所选范围内。").font(.caption).foregroundStyle(.secondary)
                    Button("补充身高与腰围授权") { Task { await health.requestProfileAndSync() } }
                    Button("授权并读取苹果健康") { Task { await health.requestAndSync() } }.accessibilityIdentifier("read-local-health")
                    Text("无需登录或连接服务器。由你在系统授权页选择数据类型，读取后先保存在本机。").font(.caption).foregroundStyle(.secondary)
                    if store.healthReadingEnabled { Button("刷新本机健康数据") { Task { await health.syncAll(force: true); await store.synchronize(showErrors: false) } }; Button("停止本机自动读取") { store.setHealthReading(false); Task { await health.stop() } } }
                    Text(store.healthStatus).font(.caption).foregroundStyle(.secondary)
                    NavigationLink("\(store.healthHistoryWindow.title)内 \(store.localHealthSampleCount) 条 · 查看来源") { LocalHealthDataView(store: store) }
                    if let date = store.localHealthReadAt { Text("最近读取：\(date.formatted())").font(.caption).foregroundStyle(.secondary) }
                    if !store.isDemo {
                        Toggle("上传健康数据到云端", isOn: Binding(get: { store.settings.healthConsent }, set: { value in if value { healthConsent = true } else { Task { var s = store.settings; s.healthConsent = false; await store.updateSettings(s) } } }))
                            .disabled(store.changingSettings)
                        if store.changingSettings { ProgressView("正在保存设置…") }
                        if store.settings.healthConsent {
                            Text(store.healthUploadStatus).font(.caption).foregroundStyle(Theme.green).accessibilityIdentifier("health-upload-progress")
                            if store.healthUploadPaused { Button("继续上传") { Task { await store.resumeHealthUpload() } } }
                            else if store.syncing { Button("暂停上传") { store.pauseHealthUpload() } }
                            Text("每批最多 500 条，断网或退出后继续。旧范围的本机记录保留，不自动删除。").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("上传单独授权；关闭上传仍可在本机读取和查看。").font(.caption).foregroundStyle(.secondary)
                    }
                }
        }.navigationTitle("Apple 健康").task { await store.refreshLocalHealth() }
    }
    private var imagesPage: some View {
        List {
            Section {
                NavigationLink("动作库 · 图解与要点") { ExerciseLibraryView(store: store) }.accessibilityIdentifier("exercise-library-entry")
                NavigationLink("图片缓存与下载") { ExerciseCacheSettingsView() }
            }
        }.navigationTitle("动作图片")
    }
    private var aiPage: some View {
        List {
            if store.isDemo { Section { Text("登录云端账号后可以配置 AI 模型并开启每日分析。").foregroundStyle(.secondary) } }
            else {
                    Section("AI 分析") {
                        NavigationLink("接口地址、密钥与模型") { AIConfigurationView(store: store) }.accessibilityIdentifier("ai-config-link")
                        Toggle("开启每日 AI 报告", isOn: Binding(get: { store.settings.aiConsent }, set: { value in if value { aiConsent = true } else { Task { var s = store.settings; s.aiConsent = false; await store.updateSettings(s) } } }))
                        Text("开启后由服务器每日 09:00 后分析；数据更新时可手动重算，最多每 15 分钟尝试一次。关闭不影响记录功能。").font(.caption).foregroundStyle(.secondary)
                    }
            }
        }.navigationTitle("AI 分析")
    }
    private var syncPage: some View {
        List {
            if store.isDemo { Section { Text("本地体验记录只保存在这台设备，不进行云端同步。").foregroundStyle(.secondary) } }
            else {
                    Section("同步") {
                        NavigationLink("统计时区：\(store.settings.timezone)") { TimezoneEditor(store: store) }
                        Text("待同步 \(store.pendingCount) 项")
                        Button { Task { await store.synchronize() } } label: { HStack { Text("立即同步"); if store.syncing { ProgressView() } } }.disabled(store.syncing)
                        if let date = store.lastSync { Text("本机最近同步：\(date.formatted())").font(.caption).foregroundStyle(.secondary) }
                        if !store.conflicts.isEmpty { NavigationLink("处理 \(store.conflicts.count) 项冲突") { ConflictView(store: store) } }
                    }
            }
        }.navigationTitle("同步")
    }
    private var dataPage: some View {
        List {
                Section("数据") {
                    Button("导出结构化数据") { Task { exportURL = await store.export() } }
                    if let exportURL { ShareLink("保存 / 分享导出文件", item: exportURL) }
                    NavigationLink("隐私与数据说明") { PrivacyView() }
                    Button(store.isDemo ? "退出本地体验" : "退出登录") { logoutConfirm = true }
                    if !store.isDemo { Button("删除账号与数据", role: .destructive) { deleteSheet = true } }
                }
            Section { Text("日益 0.1 · 开发版").foregroundStyle(.secondary); Text("训练、饮食与饮水可离线保存。健康后台更新由系统调度，无法保证准点完成。").font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle("数据")
    }
}

struct LocalHealthDataView: View {
    @Bindable var store: AppStore
    var body: some View {
        List {
            Section { Text("以下为每类最新的可读记录。未列出的类型可能未授权、暂无记录或尚未读取，不能据此判断为零。").font(.footnote) }
            ForEach(store.recentHealthSamples, id: \.type) { sample in
                Section(LocalHealthOverview.names[sample.type] ?? sample.type) {
                    if let value = sample.value { Text("\(value.formatted(.number.precision(.fractionLength(0...2)))) \(sample.unit)").font(.headline) }
                    else if let category = sample.category { Text(category) }
                    else { Text("已读取训练记录") }
                    if let date = sample.endAt { Text(date, format: .dateTime.year().month().day().hour().minute()) }
                    Text("来源：\(sample.sourceName.isEmpty ? sample.sourceBundleId : sample.sourceName)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("本机健康记录")
    }
}

struct TimezoneEditor: View {
    @Bindable var store: AppStore; @State private var search = ""; @Environment(\.dismiss) var dismiss
    var zones: [String] { TimeZone.knownTimeZoneIdentifiers.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        List {
            Section { Text("每日活动、饮水和 AI 报告按此时区分日；原始记录的时间与时区保持不变。").font(.footnote) }
            ForEach(zones, id: \.self) { zone in Button { Task { var s = store.settings; s.timezone = zone; await store.updateSettings(s); if store.settings.timezone == zone { await store.synchronize(); dismiss() } } } label: { HStack { Text(zone); Spacer(); if zone == store.settings.timezone { Image(systemName: "checkmark") } } } }
        }.searchable(text: $search, prompt: "搜索，例如 Shanghai").navigationTitle("统计时区")
    }
}

struct AIConfigurationView: View {
    @Bindable var store: AppStore
    @State private var baseURL = ""; @State private var model = ""; @State private var key = ""
    @State private var keyConfigured = false; @State private var allowedHosts: [String] = []
    @State private var source = ""; @State private var busy = false; @State private var message = ""
    private struct Config: Codable { var baseUrl: String; var model: String; var keyConfigured: Bool; var source: String; var allowedHosts: [String] }
    var body: some View {
        Form {
            Section("OpenAI 兼容接口") {
                TextField("https://api.example.com/v1", text: $baseURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("模型名称", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                AccountSecureField(placeholder: keyConfigured ? "密钥已配置；留空保持不变" : "输入 API 密钥", text: $key, contentType: nil).frame(height: 36)
                Label(keyConfigured ? "密钥已配置" : "尚未配置密钥", systemImage: keyConfigured ? "checkmark.shield" : "key").foregroundStyle(keyConfigured ? Theme.green : .secondary)
            }
            Section {
                Button("保存配置") { Task { await save(test: false) } }
                Button("保存并测试连接") { Task { await save(test: true) } }
                if busy { ProgressView("正在处理…") }
                if !message.isEmpty { Text(message).font(.subheadline).foregroundStyle(Theme.green) }
            }.disabled(busy || baseURL.isEmpty || model.isEmpty)
            Section("保存方式") {
                Text("密钥由服务器保管，读取配置不会返回原值。在此填写的新密钥会加密保存。测试连接只发送合成数据，不发送你的健康记录。").font(.footnote)
                Text(source == "account" ? "当前使用此账号的配置" : "当前使用服务器默认配置").font(.caption).foregroundStyle(.secondary)
                if !allowedHosts.isEmpty { Text("可用接口域名：\(allowedHosts.joined(separator: "、"))").font(.caption).foregroundStyle(.secondary) }
                Button("恢复服务器默认配置") { Task { busy = true; defer { busy = false }; do { let data = try await store.network.request("/v1/ai/config", method: "DELETE"); try apply(data); message = "已恢复服务器默认配置" } catch { store.error = error.localizedDescription } } }.disabled(busy)
            }
        }.navigationTitle("AI 服务配置").task {
            do { try apply(await store.network.request("/v1/ai/config")) } catch { store.error = error.localizedDescription }
        }
    }
    private func apply(_ data: Data) throws {
        let c: Config = try Wire.read(data); baseURL = c.baseUrl; model = c.model; keyConfigured = c.keyConfigured; source = c.source; allowedHosts = c.allowedHosts; key = ""
    }
    private func save(test: Bool) async {
        dismissInputKeyboard()
        busy = true; message = ""; defer { busy = false }
        do {
            let payload = try Wire.data(["base_url": baseURL.trimmingCharacters(in: .whitespacesAndNewlines), "model": model.trimmingCharacters(in: .whitespacesAndNewlines), "api_key": key])
            try apply(await store.network.request("/v1/ai/config", method: "PUT", body: payload))
            message = "配置已保存"
            if test {
                let data = try await store.network.request("/v1/ai/test", method: "POST", body: Data("{}".utf8))
                struct Result: Decodable { var message: String }
                let result: Result = try Wire.read(data); message = result.message
            }
        } catch { key = ""; store.error = error.localizedDescription }
    }
}

struct ProfileEditor: View {
    @Bindable var store: AppStore; @State var profile: Profile; @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("已有健康数据") { HealthProfileMeasurements(store: store) }
                Section("手动补充测量（可留空）") {
                    TextField("身高（cm，可不填）", value: $profile.heightCm, format: .number).keyboardType(.decimalPad)
                    TextField("腰围（cm，可不填）", value: $profile.waistCm, format: .number).keyboardType(.decimalPad)
                    DatePicker("测量日期", selection: $profile.measuredAt, in: ...Date(), displayedComponents: .date)
                    Text("每次保存产生新档案记录，历史测量不会被覆盖。").font(.caption).foregroundStyle(.secondary)
                }
                Section("目标与运动限制") {
                    TextField("当前目标", text: $profile.goal)
                    TextField("自述运动限制或医生建议（可选）", text: $profile.restrictions, axis: .vertical)
                    Stepper("每日饮水目标 \(profile.waterGoalMl) ml", value: $profile.waterGoalMl, in: 100...10000, step: 100)
                }
            }.navigationTitle("基础档案").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") {
                    guard profile.heightCm == nil || (50...250).contains(profile.heightCm!), profile.waistCm == nil || (20...300).contains(profile.waistCm!) else { store.error = "请检查身高和腰围的单位与数值"; return }
                    profile.id = newID(); profile.updatedAt = Date(); if store.save(profile, kind: "profile", id: profile.id) { dismiss() }
                } }
            }
        }
    }
}

struct HealthProfileMeasurements: View {
    @Bindable var store: AppStore
    private let types = ["height_cm", "body_mass", "waist_cm", "body_fat_percentage", "bmi", "lean_body_mass"]
    var body: some View {
        ForEach(types, id: \.self) { type in
            let metric = store.profileMetric(type)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(LocalHealthOverview.names[type] ?? type)
                    Spacer()
                    if let value = metric?.value {
                        Text("\(value.formatted(.number.precision(.fractionLength(0...1)))) \(type == "bmi" ? "" : metric?.unit ?? "")").fontWeight(.semibold)
                    } else { Text("未读取").foregroundStyle(.secondary) }
                }
                if let metric, metric.value != nil {
                    let source = metric.method == "manual_profile_measurement" ? "手动记录" : "Apple 健康 · \(store.recentHealthSamples.first(where: { $0.type == type && $0.sourceBundleId == metric.source })?.sourceName ?? metric.source)"
                    Text("\(source) · \(metric.observedAt?.formatted(date: .abbreviated, time: .omitted) ?? "时间未知")").font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 3)
        }
    }
}

struct ConflictView: View {
    @Bindable var store: AppStore
    var body: some View {
        List {
            Text("同一记录在另一端发生修改。两份内容均已保留，请比较后选择。").font(.subheadline)
            ForEach(store.conflicts, id: \.id) { q in
                Section("\(q.kind) · \(q.recordId.prefix(8))") {
                    DisclosureGroup("本机记录") { Text(String(data: store.records.first(where: { $0.kind == q.kind && $0.recordId == q.recordId })?.payload ?? q.payload, encoding: .utf8) ?? "").font(.caption).textSelection(.enabled) }
                    DisclosureGroup("云端记录") { Text(String(data: q.conflictData ?? Data(), encoding: .utf8) ?? "").font(.caption).textSelection(.enabled) }
                    Button("保留本机，重新提交") { store.resolve(q, keepLocal: true) }
                    Button("采用云端记录") { store.resolve(q, keepLocal: false) }
                }
            }
        }.navigationTitle("同步冲突")
    }
}

struct DeleteAccountView: View {
    @Bindable var store: AppStore; @State private var password = ""; @State private var confirm = false; @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Text("删除账号将删除服务器中的训练、健康样本、报告和当前设备的账号记录，无法恢复。不会删除 Apple 健康中的原始数据。")
                AccountSecureField(placeholder: "输入当前账号密码", text: $password).frame(height: 36)
                Button("永久删除", role: .destructive) { dismissInputKeyboard(); confirm = true }.disabled(password.isEmpty)
            }.navigationTitle("删除账号").toolbar { Button("取消") { dismiss() } }
                .confirmationDialog("确认永久删除账号及数据？", isPresented: $confirm) { Button("确认删除", role: .destructive) { Task { await store.deleteAccount(password: password); if !store.signedIn { dismiss() } } } }
        }
    }
}

struct PrivacyView: View {
    var body: some View {
        List {
            Section("记录的保存位置") { Text("训练、饮水和身体反馈先保存到本机；登录云端账号后同步到所配置的服务器。本地体验的数据不会上传。SwiftData 未启用 CloudKit。") }
            Section("健康数据") { Text("只读取白名单类型。云端上传和 AI 处理分别征得同意。没有查询到数据不能判断你是否授权或是否存在记录。关闭同步会停止后续上传，不自动删除既有副本。") }
            Section("AI 数据处理") { Text("仅在开启 AI 分析后发送相关汇总、训练和反馈。不发送邮箱、令牌及全部原始健康样本。目标为你配置的 AI 接口；第三方兼容服务也会接收数据，其规则可能与 OpenAI 不同。服务器设置 store=false，但这不等于零留存。测试连接只发送合成数据。") }
            Section("导出与删除") { Text("可导出结构化 JSON。删除账号清除当前服务器中的账号关联数据及本机账号空间；已导出文件、其他设备的离线副本和服务商留存需分别处理。开发版尚未配置服务器备份。") }
            Section("分析边界") { Text("仅解释已记录数据，不进行疾病诊断、不自动增加训练重量、不计算缺少饮食依据的热量缺口。") }
        }.navigationTitle("数据说明")
    }
}

struct ExerciseCacheSettingsView: View {
    @State private var bytes = 0
    @State private var message: String?
    @State private var clearing = false
    var body: some View {
        List {
            Section {
                LabeledContent("已缓存图片", value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                Text("列表仅下载缩略图，打开动作详情时下载大图。缓存最多占用 80 MB，空间不足时自动清理最久未查看的图片。")
                Text("缓存保留期间可离线查看；清理后下次查看会重新下载。训练记录和动作文字不会被删除。")
            }
            Section {
                Button(clearing ? "正在清理…" : "清理图片缓存") {
                    clearing = true
                    Task {
                        do { try await ExerciseMediaCache.shared.clear(); bytes = await ExerciseMediaCache.shared.byteCount(); message = "图片缓存已清理" }
                        catch { message = "清理未完成，请稍后重试" }
                        clearing = false
                    }
                }.disabled(clearing)
                if let message { Text(message).foregroundStyle(.secondary) }
            }
        }.navigationTitle("图片缓存与下载").navigationBarTitleDisplayMode(.inline)
            .task { bytes = await ExerciseMediaCache.shared.byteCount() }
    }
}
