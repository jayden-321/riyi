import SwiftUI

struct CoachView: View {
    @Bindable var store: AppStore
    @State private var message = ""
    @State private var pendingMessage: String?
    @State private var editing: Plan?
    @State private var confirmClear = false
    @State private var planning = false
    @State private var planningKind = "training"
    @FocusState private var inputFocused: Bool
    private var canChat: Bool { !store.isDemo && store.settings.aiConsent }
    private var runs: [CoachRun] { Array((store.coach?.conversationRuns ?? []).reversed()) }
    private var conversationRevision: String { runs.map { $0.id + $0.status }.joined(separator: "/") }
    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if store.needsReauthentication {
                            Button("云端登录已过期 · 重新登录") { store.showReauthentication = true }.buttonStyle(.borderedProminent)
                        }
                        if store.isDemo {
                            Text("登录云端账号后，即可与教练讨论训练、生成计划和每日食谱。").foregroundStyle(.secondary)
                        } else if !store.settings.aiConsent {
                            Text("教练会将已同步的健康摘要、实际训练、主观反馈和你的对话交给账号所配置的 AI 服务分析。接口和密钥在「我的 → AI 分析」管理。")
                            Button("同意并启用 AI 教练") { Task { var value = store.settings; value.aiConsent = true; await store.updateSettings(value); await store.loadCoach() } }.buttonStyle(.borderedProminent)
                        } else {
                            if runs.isEmpty {
                                Text("了解你的记录，也听你怎么说。").font(.title2.bold())
                                Text("先告诉我你的目标、每周能练几天，以及有哪些器械。").foregroundStyle(.secondary)
                                HStack {
                                    Button("制定训练计划") { message = "请根据我的记录帮我制定训练计划。缺少的信息先问我。"; inputFocused = true }
                                    Button("今日食谱") { sendMessage(recipePrompt) }.disabled(store.coachBusy)
                                }.buttonStyle(.bordered).font(.subheadline)
                            }
                            ForEach(runs) { run in
                                if run.kind == "chat" { userBubble(run.message) }
                                CoachRunCard(store: store, run: run) { editing = $0 }
                            }
                            if let pendingMessage { userBubble(pendingMessage) }
                            if store.coachBusy || runs.contains(where: { $0.status == "running" }) {
                                HStack(spacing: 10) { ProgressView(); Text("正在等待 AI 教练安排，完成后会自动显示…").font(.subheadline).foregroundStyle(Theme.muted) }.padding(.vertical, 8)
                            }
                            if !store.needsReauthentication, let error = store.coachError { Text(error).font(.footnote).foregroundStyle(.red) }
                        }
                        Color.clear.frame(height: 1).id("coach-bottom")
                    }.padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .safeAreaInset(edge: .bottom, spacing: 0) { if canChat { composer } }
                .onChange(of: conversationRevision) { _, _ in scrollToLatest(reader) }
                .onChange(of: store.coachBusy) { _, _ in scrollToLatest(reader) }
                .onChange(of: inputFocused) { _, focused in if focused { scrollToLatest(reader) } }
                .task(id: store.scope) { await store.loadCoach(); scrollToLatest(reader) }
            }
            .background(Theme.cream).navigationTitle("AI 教练").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canChat {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink { CoachSettingsView(store: store, settings: store.coach?.settings ?? CoachSettings()) } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("教练资料与定时分析")
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("安排训练周期") { planningKind = "training"; planning = true }
                            Button("安排饮食周期") { planningKind = "diet"; planning = true }
                            Button("制定训练计划") { message = "请根据我的记录帮我制定训练计划。缺少的信息先问我。"; inputFocused = true }
                            Button("今日食谱") { sendMessage(recipePrompt) }.disabled(store.coachBusy)
                            Button("分析次日训练") { Task { await store.analyzeCoach("fitness") } }.disabled(store.coachBusy)
                            NavigationLink("分析记录") { CoachAnalysisHistoryView(store: store) }
                            Divider()
                            Button("清空对话", role: .destructive) { confirmClear = true }.disabled(store.coachBusy || !runs.contains(where: { $0.kind == "chat" }))
                            if (store.coach?.archivedChats ?? 0) > 0 { Button("恢复已清空对话") { Task { await store.clearCoachConversation(restore: true) } }.disabled(store.coachBusy) }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("更多教练功能")
                    }
                }
            }
            .sheet(item: $editing) { plan in PlanEditor(store: store, plan: plan) }
            .sheet(isPresented: $planning) { PlanningRequestView(store: store,kind: planningKind) }
            .onAppear { receiveDraft() }
            .onChange(of: store.coachPromptDraft) { _,_ in receiveDraft() }
            .confirmationDialog("清空教练对话？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空对话", role: .destructive) { message = ""; Task { await store.clearCoachConversation() } }.accessibilityIdentifier("confirm-clear-coach")
                Button("取消", role: .cancel) { }
            } message: { Text("聊天将移入已清空记录，可从菜单恢复。已保存的计划、健康档案和定时分析保留；新对话不再引用这些旧聊天。") }
        }
    }
    private func userBubble(_ text: String) -> some View {
        HStack { Spacer(minLength: 32); Text(text).padding(14).background(Theme.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 18)) }
    }
    private func receiveDraft() { if !store.coachPromptDraft.isEmpty { message = store.coachPromptDraft; store.coachPromptDraft = ""; inputFocused = true } }
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("问教练，或补充你的情况…", text: $message, axis: .vertical)
                .lineLimit(1...5).padding(.horizontal, 14).padding(.vertical, 12)
                .background(.white, in: RoundedRectangle(cornerRadius: 20))
                .focused($inputFocused).accessibilityIdentifier("coach-message-input")
            Button {
                sendMessage(message)
            } label: { Image(systemName: "arrow.up").font(.headline).frame(width: 42, height: 42) }
                .buttonStyle(.borderedProminent).buttonBorderShape(.circle).accessibilityLabel("发送")
                .disabled(store.coachBusy || runs.contains(where: { $0.status == "running" }) || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(.horizontal, 16).padding(.vertical, 10).background(Theme.cream)
    }
    private var recipePrompt: String {
        let profile = store.coach?.settings.profile
        let allergies = profile?.allergies.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preferences = profile?.foodPreferences.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "请为我推荐今天的食谱。\n过敏：\(allergies.isEmpty ? "无" : allergies)\n忌口：\(preferences.isEmpty ? "无" : preferences)"
    }
    private func sendMessage(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !store.coachBusy && !text.isEmpty else { return }
        message = ""; pendingMessage = text
        Task {
            let success = await store.sendCoach(text)
            pendingMessage = nil
            if !success && message.isEmpty { message = text }
        }
    }
    private func scrollToLatest(_ reader: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo("coach-bottom", anchor: .bottom) }
        }
    }
}

private struct CoachAnalysisHistoryView: View {
    @Bindable var store: AppStore
    @State private var editing: Plan?
    private var runs: [CoachRun] { Array((store.coach?.analysisRuns ?? []).reversed()) }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if runs.isEmpty { Text("暂无定时分析记录").foregroundStyle(.secondary) }
                ForEach(runs) { run in CoachRunCard(store: store, run: run) { editing = $0 } }
            }.padding(20)
        }.background(Theme.cream).navigationTitle("分析记录").navigationBarTitleDisplayMode(.inline)
            .task(id: store.scope) { await store.loadCoach() }
            .sheet(item: $editing) { plan in PlanEditor(store: store, plan: plan) }
    }
}

struct CoachRunCard: View {
    let store: AppStore
    let run: CoachRun; let edit: (Plan) -> Void
    @State private var preview: PlanningCycle?
    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(run.kind == "fitness" ? "次日训练 · \(run.targetDate)" : run.kind == "sleep" ? "今晚睡眠 · \(run.targetDate)" : "教练对话", systemImage: run.kind == "sleep" ? "moon.stars" : "sparkles").font(.headline)
                    Spacer()
                }
                if let result = run.result {
                    #if DEBUG
                    if run.kind == "chat", result.variantB != nil {
                        Text("A · 日益当前方案").font(.subheadline.bold()).foregroundStyle(Theme.green)
                    }
                    #endif
                    Text(result.message).lineSpacing(4)
                    ForEach(Array(result.questions.enumerated()), id: \.offset) { _, question in Text("· \(question)").fontWeight(.medium) }
                    if let cycle = result.cycle {
                        Divider(); Text(cycle.name).font(.headline)
                        Text("\(cycle.startDate) — \(cycle.endDate) · \(cycle.days.count) 天").font(.subheadline)
                        Text("\(cycle.kind == "diet" ? "饮食" : "训练")草稿 · 查看并采用后进入日历").font(.caption).foregroundStyle(Theme.green)
                        Button("查看并安排\(cycle.kind == "diet" ? "饮食" : "训练")") { preview = cycle }.buttonStyle(.borderedProminent)
                    }
                    if let plan = result.plan {
                        Divider(); Text(plan.name).font(.headline)
                        ForEach(plan.days) { day in
                            Text("\(day.name) · \(day.exercises.count) 个动作").font(.subheadline)
                            ForEach(day.exercises) { exercise in
                                VStack(alignment: .leading, spacing: 4) {
                                    NavigationLink { ExerciseGuideView(store: store, exerciseId: exercise.exerciseId, name: exercise.name) } label: { Label(exercise.name, systemImage: "figure.strengthtraining.traditional") }.font(.subheadline)
                                    Text("\(ExerciseGuide.find(id: exercise.exerciseId, name: exercise.name)?.equipmentGroup ?? "器械待确认") · \(exercise.sets.count) 组")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(exercise.sets.enumerated().map { index, set in
                                        "\(index + 1)组 \(set.weight > 0 ? "\(set.weight.formatted()) kg" : "重量待确认") × \(set.reps)"
                                    }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text(run.planId == nil ? "计划草稿 · 可修改后保存" : "已自动加入训练计划").font(.caption).foregroundStyle(Theme.green)
                        Button("查看 / 编辑计划") { edit(plan) }.buttonStyle(.bordered)
                        Button("安排到训练日历") { preview = run.legacyCycle(kind: "training") }.buttonStyle(.borderedProminent)
                    }
                    if let menu = result.meals {
                        Divider(); Text("食谱建议").font(.headline)
                        ForEach(Array(menu.meals.enumerated()), id: \.offset) { _, meal in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(meal.name).fontWeight(.semibold)
                                Text(meal.foods.joined(separator: "、"))
                                Text(meal.preparation).font(.caption).foregroundStyle(.secondary)
                                if !meal.alternatives.isEmpty { Text("可替换：" + meal.alternatives.joined(separator: "；")).font(.caption) }
                            }
                        }
                        ForEach(Array(menu.notes.enumerated()), id: \.offset) { _, note in Text(note).font(.caption).foregroundStyle(.secondary) }
                        Button("采用到饮食日历") { preview = run.legacyCycle(kind: "diet") }.buttonStyle(.borderedProminent)
                    }
                    #if DEBUG
                    if run.kind == "chat", let answer = result.variantB {
                        Divider()
                        Text("B · 完整 Skill 参考").font(.subheadline.bold()).foregroundStyle(Theme.green)
                        if let error = answer.error, !error.isEmpty {
                            Text(error).foregroundStyle(.secondary)
                        } else {
                            Text(answer.message).lineSpacing(4)
                            ForEach(Array(answer.questions.enumerated()), id: \.offset) { _, question in Text("· \(question)").fontWeight(.medium) }
                        }
                    }
                    #endif
                } else { Text(run.status == "running" ? "AI 教练正在安排，完成后会自动显示。" : "本次分析未完成，可重新发送。") }
                Text("\(run.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(run.timezone)").font(.caption2).foregroundStyle(.secondary)
            }
        }.sheet(item: $preview) { cycle in CyclePreviewView(store: store,cycle: cycle) }
    }
}

struct CoachSettingsView: View {
    @Bindable var store: AppStore; @State var settings: CoachSettings
    @State private var reminders = false; @State private var saving = false; @State private var status: String?
    @Environment(\.dismiss) private var dismiss
    func timeBinding(_ path: WritableKeyPath<CoachSettings, Int>) -> Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: settings[keyPath: path] / 60, minute: settings[keyPath: path] % 60, second: 0, of: Date())! }, set: { settings[keyPath: path] = Calendar.current.component(.hour, from: $0) * 60 + Calendar.current.component(.minute, from: $0) })
    }
    var body: some View {
        Form {
            Section("教练重点") {
                Picker("侧重点", selection: $settings.style) { Text("综合训练与恢复").tag("balanced"); Text("动作质量").tag("technique"); Text("量化进步").tag("measured"); Text("饮食与恢复").tag("nutrition") }
            }
            Section("你的训练条件") {
                TextField("目标（如增肌、建立规律训练）", text: $settings.profile.goal, axis: .vertical)
                TextField("训练经验", text: $settings.profile.experience)
                Stepper(settings.profile.daysPerWeek == 0 ? "每周天数 · 待补充" : "每周 \(settings.profile.daysPerWeek) 天", value: $settings.profile.daysPerWeek, in: 0...7)
                Stepper(settings.profile.sessionMinutes == 0 ? "单次时长 · 待补充" : "单次 \(settings.profile.sessionMinutes) 分钟", value: $settings.profile.sessionMinutes, in: 0...240, step: 15)
                Stepper(settings.profile.exercisesPerSession == 0 ? "每次动作数 · 由教练安排" : "每次 \(settings.profile.exercisesPerSession) 个动作", value: $settings.profile.exercisesPerSession, in: 0...8)
                Stepper(settings.profile.setsPerExercise == 0 ? "每个动作组数 · 由教练安排" : "每个动作 \(settings.profile.setsPerExercise) 组", value: $settings.profile.setsPerExercise, in: 0...8)
                Text("这两项保存在云端账号资料中；改为 3 个动作后，后续力量计划按新设置生成。0 表示不固定。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("器械与训练场地", text: $settings.profile.equipment, axis: .vertical)
                TextField("运动限制或伤痛（无也请说明）", text: $settings.profile.limitations, axis: .vertical)
            }
            Section("食谱条件") {
                TextField("食物过敏与特殊饮食限制（无也请说明）", text: $settings.profile.allergies, axis: .vertical)
                TextField("口味、忌口与偏好", text: $settings.profile.foodPreferences, axis: .vertical)
                TextField("做饭或外食条件、预算", text: $settings.profile.cookingConditions, axis: .vertical)
            }
            Section("健身 · 晚上分析，早上提醒") {
                Toggle("开启健身定时分析", isOn: $settings.fitnessEnabled)
                DatePicker("晚间分析", selection: timeBinding(\.fitnessAnalysisMinute), displayedComponents: .hourAndMinute)
                DatePicker("次日提醒", selection: timeBinding(\.fitnessReminderMinute), displayedComponents: .hourAndMinute)
                Toggle("自动采用可沿用的次日方案", isOn: $settings.autoAdopt)
                Text("已有可校准训练记录、且无需提高负荷的方案可自动加入计划。新动作或待确认的重量保留为草稿；已开始的训练不变。").font(.caption).foregroundStyle(.secondary)
            }
            Section("睡眠 · 晚间准备") {
                Toggle("开启睡眠定时分析", isOn: $settings.sleepEnabled)
                DatePicker("分析时间", selection: timeBinding(\.sleepAnalysisMinute), displayedComponents: .hourAndMinute)
                DatePicker("提醒时间", selection: timeBinding(\.sleepReminderMinute), displayedComponents: .hourAndMinute)
                Text("分析最近已记录的睡眠及当天情况，给出今晚的作息建议。").font(.caption).foregroundStyle(.secondary)
            }
            Section("这台手机的提醒") {
                Toggle("定时提醒我查看", isOn: $reminders)
                Text("当前为本机定时提醒，打开 App 后获取服务器最新结果。远程推送将在接入苹果推送服务后启用。时间按 \(store.settings.timezone) 计算。").font(.caption).foregroundStyle(.secondary)
            }
            if let status { Section { Text(status).foregroundStyle(.red) } }
        }.navigationTitle("教练设置")
            .onAppear { reminders = UserDefaults.standard.bool(forKey: "coachReminders.\(store.scope)") }
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "保存中…" : "保存") {
                    dismissInputKeyboard(); saving = true
                    Task {
                        defer { saving = false }
                        guard await store.saveCoachSettings(settings) else { status = store.coachError; return }
                        do { try await Notifications.shared.scheduleCoach(settings, enabled: reminders); dismiss() }
                        catch { status = "服务器设置已保存；本机提醒未启用：\(error.localizedDescription)" }
                    }
                }.disabled(saving || settings.sleepReminderMinute <= settings.sleepAnalysisMinute)
            } }
    }
}
