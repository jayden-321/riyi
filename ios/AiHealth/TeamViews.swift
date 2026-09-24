import SwiftUI

private struct TeamListReply: Decodable { var teams: [CheckinTeam] }

private struct CheckinTeam: Decodable, Identifiable {
    var id: String
    var name: String
    var timezone: String
    var isOwner: Bool
    var inviteCode: String
    var memberCount: Int
    var today: String
    var myCalorieTarget: Int
    var nextCalorieTarget: Int?
    var nextGoalWeek: String?
    var shareSleepScore: Bool
}

private struct TeamRank: Decodable, Identifiable {
    var memberId: String
    var displayName: String
    var trainingDays: Int
    var trainingPoints: Int
    var trainingSessions: Int?
    var trainingDetails: [TrainingScoreDetail]?
    var dietPoints: Int
    var sleepNights: Int
    var sleepPoints: Int
    var points: Int
    var rank: Int
    var isMe: Bool
    var id: String { memberId }
}

private struct TrainingScoreDetail: Decodable, Identifiable {
    var date: String
    var name: String
    var points: Int
    var basis: String
    var id: String { "\(date)|\(name)|\(basis)|\(points)" }
}

private struct TeamDetail: Decodable {
    var id: String
    var name: String
    var timezone: String
    var isOwner: Bool
    var inviteCode: String
    var memberCount: Int
    var today: String
    var myCalorieTarget: Int
    var nextCalorieTarget: Int?
    var nextGoalWeek: String?
    var shareSleepScore: Bool
    var weekStart: String
    var weekEnd: String
    var ranking: [TeamRank]
}

struct TodayTeamCard: View {
    @Bindable var store: AppStore
    let refreshRevision: Int
    @State private var teamCount = 0
    @State private var detail: TeamDetail?
    @State private var loadedScope = ""
    @State private var loading = false
    @State private var failed = false

    private var visibleDetail: TeamDetail? { loadedScope == store.scope ? detail : nil }
    private var visibleTeamCount: Int { loadedScope == store.scope ? teamCount : 0 }
    private var mine: TeamRank? { visibleDetail?.ranking.first(where: \.isMe) }
    private var refreshKey: String {
        "\(store.scope)|\(refreshRevision)|\(store.lastSync?.timeIntervalSince1970 ?? 0)"
    }

    var body: some View {
        Group {
            if let detail = visibleDetail, visibleTeamCount == 1 {
                NavigationLink { TeamDetailView(store: store, teamID: detail.id).id(store.scope).onDisappear { Task { await load() } } } label: { content }
            } else {
                NavigationLink { TeamHubView(store: store).id(store.scope).onDisappear { Task { await load() } } } label: { content }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("today-team-card")
        .task(id: refreshKey) { await load() }
    }

    private var content: some View {
        Surface {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("团队本周排名", systemImage: "person.3.fill").font(.headline).foregroundStyle(Theme.green)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                }
                if store.isDemo {
                    Text("登录云端账号后，可以和队友一起看训练、饮食与睡眠排名。")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if let detail = visibleDetail, let mine {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(detail.name).font(.subheadline).foregroundStyle(.secondary)
                            Text("第 \(mine.rank) 名").font(.title2.bold())
                        }
                        Spacer()
                        Text("\(mine.points) 分").font(.title2.bold()).foregroundStyle(Theme.green)
                    }
                    Text("训练 \(mine.trainingPoints)（\(mine.trainingSessions ?? 0) 场）· 饮食 \(mine.dietPoints) · 睡眠 \(mine.sleepPoints)")
                        .font(.caption).foregroundStyle(.secondary)
                    if visibleTeamCount > 1 { Text("另有 \(visibleTeamCount - 1) 个团队 · 查看全部").font(.caption).foregroundStyle(Theme.green) }
                } else if loading {
                    ProgressView("正在读取团队排名")
                } else if failed {
                    Text("排名暂时无法读取，点开查看团队").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("还没有团队，创建团队或输入邀请码加入。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load() async {
        guard store.signedIn, !store.isDemo else { detail = nil; teamCount = 0; loadedScope = store.scope; failed = false; return }
        let owner = store.scope
        if loadedScope != owner { loadedScope = owner; detail = nil; teamCount = 0; failed = false }
        loading = true
        defer { loading = false }
        do {
            let reply: TeamListReply = try Wire.read(await store.network.request("/v1/teams"))
            let value: TeamDetail?
            if let first = reply.teams.first { value = try Wire.read(await store.network.request("/v1/teams/\(first.id)")) }
            else { value = nil }
            guard store.scope == owner, !Task.isCancelled else { return }
            teamCount = reply.teams.count; detail = value; failed = false
        } catch {
            guard store.scope == owner, !Task.isCancelled else { return }
            detail = nil; teamCount = 0; failed = true
        }
    }
}

struct TeamHubView: View {
    @Bindable var store: AppStore
    @State private var teams: [CheckinTeam] = []
    @State private var loadedScope = ""
    @State private var loading = false
    @State private var showingCreate = false
    @State private var showingJoin = false
    private var visibleTeams: [CheckinTeam] { loadedScope == store.scope ? teams : [] }

    var body: some View {
        List {
            Section {
                Text("完成训练、饮食热量和已上传的睡眠记录会自动计入本周排名。队友只能看到队内昵称和三项分数。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if store.isDemo {
                Section { Text("登录云端账号后可以创建或加入团队。") }
            } else {
                Section {
                    Button { showingCreate = true } label: { Label("创建团队", systemImage: "person.3.fill") }
                    Button { showingJoin = true } label: { Label("输入邀请码加入", systemImage: "ticket.fill") }
                }
                Section("我的团队") {
                    if loading && visibleTeams.isEmpty { ProgressView() }
                    if !loading && visibleTeams.isEmpty { Text("还没有加入团队").foregroundStyle(.secondary) }
                    ForEach(visibleTeams) { team in
                        NavigationLink {
                            TeamDetailView(store: store, teamID: team.id).id(store.scope)
                                .onDisappear { Task { await load() } }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(team.name).font(.headline)
                                Text("\(team.memberCount) 人 · \(team.isOwner ? "我创建的" : "已加入")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("组团打卡")
        .task(id: store.scope) { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showingCreate) { TeamEntrySheet(store: store, mode: .create) { await load() } }
        .sheet(isPresented: $showingJoin) { TeamEntrySheet(store: store, mode: .join) { await load() } }
    }

    private func load() async {
        guard !store.isDemo, store.signedIn else { teams = []; loadedScope = store.scope; return }
        let owner = store.scope
        if loadedScope != owner { loadedScope = owner; teams = [] }
        loading = true
        defer { loading = false }
        do {
            let reply: TeamListReply = try Wire.read(await store.network.request("/v1/teams"))
            if store.scope == owner { teams = reply.teams }
        } catch { if store.scope == owner { store.error = error.localizedDescription } }
    }
}

private struct TeamEntrySheet: View {
    enum Mode: Equatable { case create, join }
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AppStore
    let mode: Mode
    let onComplete: () async -> Void
    @State private var teamName = ""
    @State private var displayName = ""
    @State private var inviteCode = ""
    @State private var calorieTarget = 0
    @State private var shareSleepScore = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                if mode == .create {
                    Section("团队名称") { TextField("例如：一起练", text: $teamName).textInputAutocapitalization(.never) }
                } else {
                    Section("邀请码") { TextField("粘贴队长发来的邀请码", text: $inviteCode).textInputAutocapitalization(.never).autocorrectionDisabled() }
                }
                Section("队内昵称") {
                    HStack { Text("显示名称"); Spacer(); TextField("队友看到的名字", text: $displayName).multilineTextAlignment(.trailing) }
                    Text("队友不会看到你的邮箱、训练详情或饮食内容。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("我的每日热量目标") {
                    HStack { Text("目标热量"); Spacer(); TextField("数值", value: $calorieTarget, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing); Text("千卡") }
                    Text("按个人目标比较已记录的实际摄入：过多或明显不足都会少得分。请填写适合自己的目标，不要为了排名刻意少吃。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("睡眠得分") {
                    Toggle("让队友看到我的睡眠得分", isOn: $shareSleepScore)
                    Text("仅共享每周得分和有记录的夜晚数；不共享原始睡眠时间、阶段或健康数据。需要另行开启 Apple 健康云端同步才有分数；不分享则睡眠分为 0，总排名可能较低。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button(mode == .create ? "创建团队" : "加入团队") { Task { await submit() } }
                        .disabled(busy || !(1200...4500).contains(calorieTarget) || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (mode == .create ? teamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    if busy { ProgressView() }
                }
            }
            .navigationTitle(mode == .create ? "创建团队" : "加入团队")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        do {
            let owner = store.scope
            let body: Data
            let path: String
            if mode == .create {
                path = "/v1/teams"
                body = try JSONSerialization.data(withJSONObject: ["name": teamName.trimmingCharacters(in: .whitespacesAndNewlines), "display_name": displayName.trimmingCharacters(in: .whitespacesAndNewlines), "calorie_target": calorieTarget, "share_sleep_score": shareSleepScore])
            } else {
                path = "/v1/teams/join"
                body = try JSONSerialization.data(withJSONObject: ["invite_code": inviteCode.trimmingCharacters(in: .whitespacesAndNewlines), "display_name": displayName.trimmingCharacters(in: .whitespacesAndNewlines), "calorie_target": calorieTarget, "share_sleep_score": shareSleepScore])
            }
            let _: CheckinTeam = try Wire.read(await store.network.request(path, method: "POST", body: body))
            guard store.scope == owner else { return }
            await onComplete()
            dismiss()
        } catch { store.error = error.localizedDescription }
    }
}

private struct TeamDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AppStore
    let teamID: String
    @State private var detail: TeamDetail?
    @State private var loading = false
    @State private var confirmExit = false
    @State private var busy = false
    @State private var targetDraft = 2000

    var body: some View {
        List {
            if let detail {
                Section("本周排名 · \(detail.weekStart) 至 \(detail.weekEnd)") {
                    ForEach(detail.ranking) { member in
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(member.rank)").font(.headline).frame(width: 30, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(member.displayName + (member.isMe ? "（我）" : ""))
                                Text("训练 \(member.trainingPoints) · 饮食 \(member.dietPoints) · 睡眠 \(member.sleepPoints)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(member.points) 分").bold().foregroundStyle(Theme.green)
                        }
                    }
                }
                if let mine = detail.ranking.first(where: \.isMe), let sessions = mine.trainingDetails, !sessions.isEmpty {
                    Section("我的训练积分明细") {
                        ForEach(Array(sessions.enumerated()), id: \.offset) { _, session in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text("\(session.date) · \(session.name)"); Spacer(); Text("+\(session.points) 分").bold() }
                                Text(session.basis).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("计分规则") {
                    Text("训练按实际完成量累计，同一天多场也加分。力量训练按正式组、实际次数与记录的负重容量；游泳、HIIT 等按实际时长，游泳等有实际距离时额外计分。单场最多 40 分、每天最多 60 分；未完成、仅计划或过短的记录不计分。")
                    Text("饮食：当天已记录的热量合计越接近个人目标，最多得 10 分；偏高或偏低都会减分。睡眠：有足够睡眠样本的夜晚，按记录时长最多得 10 分。按本周总分排名，同分并列。")
                    Text("没有饮食记录、热量未知或睡眠未上传，都不会获得对应分数；这不代表当天没吃或没睡。照片粗估按区间保守计分。只统计加入团队后的云端记录，按团队时区 \(detail.timezone) 的周一至周日计算。")
                }.font(.subheadline).foregroundStyle(.secondary)
                Section("我的饮食目标") {
                    Text("本周每天 \(detail.myCalorieTarget) 千卡；队友看不到这个数字。")
                    if let next = detail.nextCalorieTarget, let week = detail.nextGoalWeek { Text("下周 \(week) 起：\(next) 千卡").font(.caption).foregroundStyle(.secondary) }
                    HStack { Text("调整目标"); Spacer(); TextField("数值", value: $targetDraft, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing); Text("千卡") }
                    Button("下周开始使用新目标") { Task { await scheduleGoal() } }
                        .disabled(busy || !(1200...4500).contains(targetDraft) || targetDraft == detail.myCalorieTarget)
                    Text("本周目标固定，调整后从下周一生效。目标应按个人情况设定，分数只反映记录与目标的接近程度。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("我的睡眠分享") {
                    Toggle("计入睡眠得分", isOn: Binding(get: { detail.shareSleepScore }, set: { value in Task { await setSleepSharing(value) } })).disabled(busy)
                    Text("关闭后睡眠分为 0，总排名可能降低；训练和饮食分不受影响。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if detail.isOwner {
                    Section("邀请队友") {
                        Text(detail.inviteCode).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        ShareLink("发送邀请码", item: "来日益加入「\(detail.name)」一起训练、记录饮食。本团队邀请码：\(detail.inviteCode)")
                        Text("队友在「我的 → 组团打卡 → 输入邀请码加入」填写邀请码。最多 100 人。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(detail.isOwner ? "解散团队" : "退出团队", role: .destructive) { confirmExit = true }
                        .disabled(busy)
                }
            } else if loading { ProgressView() }
        }
        .navigationTitle(detail?.name ?? "团队")
        .task(id: teamID) { await load() }
        .refreshable { await load() }
        .confirmationDialog(detail?.isOwner == true ? "解散后，所有队友将失去这个团队的排名和邀请码。" : "退出后，将从团队排名中移除。", isPresented: $confirmExit) {
            Button(detail?.isOwner == true ? "解散团队" : "退出团队", role: .destructive) { Task { await exitTeam() } }
        }
    }

    private func load() async {
        let owner = store.scope
        loading = true
        defer { loading = false }
        do {
            let value: TeamDetail = try Wire.read(await store.network.request("/v1/teams/\(teamID)"))
            if store.scope == owner { detail = value; targetDraft = value.nextCalorieTarget ?? value.myCalorieTarget }
        } catch { if store.scope == owner { store.error = error.localizedDescription } }
    }

    private func scheduleGoal() async {
        busy = true
        defer { busy = false }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["calorie_target": targetDraft])
            _ = try await store.network.request("/v1/teams/\(teamID)/goal", method: "PUT", body: body)
            await load()
        } catch { store.error = error.localizedDescription }
    }

    private func setSleepSharing(_ enabled: Bool) async {
        busy = true
        defer { busy = false }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["enabled": enabled])
            _ = try await store.network.request("/v1/teams/\(teamID)/sleep-sharing", method: "PUT", body: body)
            await load()
        } catch { store.error = error.localizedDescription }
    }

    private func exitTeam() async {
        guard let detail else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await store.network.request("/v1/teams/\(teamID)" + (detail.isOwner ? "" : "/membership"), method: "DELETE")
            dismiss()
        } catch { store.error = error.localizedDescription }
    }
}
