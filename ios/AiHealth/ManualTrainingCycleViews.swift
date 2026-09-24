import SwiftUI

struct DailyTrainingScheduleView: View {
    @Bindable var store: AppStore
    let date: String
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var editing: TrainingBlock?
    @State private var removing: TrainingBlock?
    private var selectedDate: String { date.isEmpty ? store.calendarKey : date }
    private var blocks: [TrainingBlock] { store.trainingBlocks(on: selectedDate) }
    var body: some View {
        NavigationStack {
            List {
                Section("\(selectedDate) · 训练项目") {
                    if blocks.isEmpty { Text("这一天尚未安排训练").foregroundStyle(.secondary) }
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(index + 1). \(block.name)").font(.headline)
                                let sessions = store.workouts(for: block, on: selectedDate)
                                Text("\(sportTitle(block.sport)) · \(sessions.isEmpty ? "尚未开始" : "已练 \(sessions.count) 次")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("编辑") { editing = block }.buttonStyle(.borderless)
                            Button { removing = block } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).tint(.red)
                                .disabled(store.hasProtectedTrainingRecords(for: block, on: selectedDate))
                        }
                        if store.hasProtectedTrainingRecords(for: block, on: selectedDate) {
                            Text("已有完成或进行中的记录，不能删除；请新增训练项目。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button { adding = true } label: { Label("添加训练项目", systemImage: "plus.circle.fill") }
                        .accessibilityIdentifier("add-training-block")
                }
                let unmatched = store.workouts(on: selectedDate).filter { workout in
                    store.associatedBlockID(for: workout, on: selectedDate) == nil
                }
                if !unmatched.isEmpty {
                    Section("未关联安排的实际训练") {
                        ForEach(unmatched) { workout in
                            NavigationLink { WorkoutView(store: store, workout: workout) } label: {
                                Text("\(workout.name) · \(workout.status == "completed" ? "已完成" : "进行中")")
                            }
                        }
                    }
                }
            }.navigationTitle("安排当天训练")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .onAppear { if blocks.isEmpty { adding = true } }
        .sheet(isPresented: $adding) {
            PlanEditor(store: store, plan: Plan.draft(), oneDayOnly: true) { plan in
                try await store.upsertTrainingBlock(on: selectedDate, plan: plan)
            }
        }
        .sheet(item: $editing) { block in
            PlanEditor(store: store, plan: block.editorPlan, oneDayOnly: true) { plan in
                try await store.upsertTrainingBlock(on: selectedDate, blockID: block.id, plan: plan)
            }
        }
        .confirmationDialog("移除这一个训练项目？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("移除项目", role: .destructive) {
                if let removing { _ = store.deleteTrainingBlock(on: selectedDate, blockID: removing.id) }
                removing = nil
            }
        } message: { Text("只移除该日历项目，已记录的实际训练保留。") }
    }
}

struct TrainingCycleOptionsView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    private enum Route: Hashable { case manual }
    @State private var path: [Route] = []
    @State private var showingAI = false
    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: Route.manual) {
                        Label("手动编辑周期", systemImage: "calendar.badge.plus")
                    }.accessibilityIdentifier("manual-training-cycle")
                    Button { showingAI = true } label: {
                        Label("AI 健康安排", systemImage: "sparkles")
                    }.accessibilityIdentifier("ai-training-cycle")
                } footer: {
                    Text("手动安排每一天的训练或休息；AI 会结合已授权的健康与实际训练数据先生成草稿，确认后再写入日历。")
                }
            }.navigationTitle("安排训练周期")
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .manual: ManualTrainingCycleView(store: store, onCompleted: { dismiss() })
                    }
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }.sheet(isPresented: $showingAI) { PlanningRequestView(store: store, kind: "training", onContinue: { dismiss() }) }
    }
}

private struct ManualBlockEditor: Identifiable {
    var id = newID()
    var dayID: String
    var blockID: String?
    var plan: Plan
}
private struct ManualBlockRow: View {
    let index: Int
    let block: TrainingBlock
    let edit: () -> Void
    let remove: () -> Void
    var body: some View {
        HStack {
            Text("\(index + 1). \(block.name) · \(sportTitle(block.sport))").font(.subheadline)
            Spacer()
            Button("编辑", action: edit).buttonStyle(.borderless)
            Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless).tint(.red)
        }
    }
}
private struct ManualCycleDaySection: View {
    @Binding var day: CycleDay
    let templates: [Plan]
    let edit: (TrainingBlock?) -> Void
    let remove: (String) -> Void
    let use: (Plan, PlanDay) -> Void
    var body: some View {
        Section(day.date) {
            Toggle("安排训练", isOn: Binding(get: { !day.rest }, set: { enabled in
                var updated = day
                updated.setTrainingEnabled(enabled)
                day = updated
            })).accessibilityIdentifier("manual-day-toggle-\(day.date)")
            if !day.rest {
                ForEach(Array(day.trainingBlocks.enumerated()), id: \.element.id) { index, block in
                    ManualBlockRow(index: index, block: block, edit: { edit(block) }, remove: { remove(block.id) })
                }
                Button("添加训练项目") { edit(nil) }.accessibilityIdentifier("edit-cycle-day-\(day.date)")
                if !templates.isEmpty {
                    Menu("从已有计划选一天") {
                        ForEach(templates) { template in
                            ForEach(template.days) { templateDay in
                                Button("\(template.name) · \(templateDay.name)") { use(template, templateDay) }
                            }
                        }
                    }.accessibilityIdentifier("manual-day-template-\(day.date)")
                }
            } else { Text("休息日").foregroundStyle(.secondary) }
        }
    }
}

struct ManualTrainingCycleView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var onCompleted: (() -> Void)? = nil
    @State private var name = "我的训练周期"
    @State private var start = Date()
    @State private var end = Date()
    @State private var days: [CycleDay] = []
    @State private var editingExistingID: String?
    @State private var editingBlock: ManualBlockEditor?
    @State private var replace = false
    @State private var saving = false
    @State private var message: String?
    @State private var requestID = newID()

    private var zone: String { store.settings.timezone }
    private var calendar: Calendar { DayKey.calendar(zone) }
    private var count: Int { (calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? -1) + 1 }
    private var valid: Bool {
        (1...31).contains(count) && days.count == count && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        days.contains(where: { !$0.rest }) && days.allSatisfy { day in
            if day.rest { return day.trainingBlocks.isEmpty }
            let blocks = day.trainingBlocks
            return (1...8).contains(blocks.count) && blocks.allSatisfy { block in
                if let plan = block.plan { return plan.days.count == 1 && plan.validEditorDraft }
                return block.activity?.validConfiguration == true
            }
        }
    }
    private var revision: String {
        name + "|" + DayKey.string(start, zone: zone) + "|" + DayKey.string(end, zone: zone) + "|" + ((try? Wire.data(days).base64EncodedString()) ?? "")
    }
    var body: some View {
        Form {
            Section("周期") {
                HStack { Text("周期名称"); Spacer(); TextField("输入名称", text: $name).multilineTextAlignment(.trailing) }
                DatePicker("开始日期", selection: $start, displayedComponents: .date)
                DatePicker("结束日期", selection: $end, in: start..., displayedComponents: .date)
                Text("\(count) 天 · 每一天可分别安排训练或休息").font(.caption).foregroundStyle(.secondary)
                Text("至少安排一天训练；其余日期可保持休息日。").font(.caption).foregroundStyle(.secondary)
                if count > 31 { Text("一次最多编辑 31 天；更长周期可分段安排。").font(.caption).foregroundStyle(.red) }
            }
            ForEach($days) { $day in
                ManualCycleDaySection(day: $day, templates: store.plans,
                                      edit: { block in editingBlock = ManualBlockEditor(dayID: day.id, blockID: block?.id, plan: block?.editorPlan ?? Plan.draft()) },
                                      remove: { self.remove($0, from: day.id) },
                                      use: { template, templateDay in use(template, day: templateDay, for: day.id) })
            }
            Section("已有安排") {
                Toggle("替换尚未开始的日历安排", isOn: $replace)
                Text("已开始或已结束的实际训练会保留。").font(.caption).foregroundStyle(.secondary)
            }
            if let message { Section { Text(message).foregroundStyle(.red) } }
        }.navigationTitle("手动编辑周期")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") { Task { await save() } }
                        .disabled(!valid || saving)
                        .accessibilityIdentifier("save-manual-training-cycle")
                }
            }
            .onAppear {
                guard days.isEmpty else { return }
                if let (existing, _) = store.scheduled("training", date: store.calendarKey), existing.days.count <= 31,
                   let first = DayKey.date(existing.startDate, zone: zone), let last = DayKey.date(existing.endDate, zone: zone) {
                    name = existing.name
                    start = first; end = last
                    editingExistingID = existing.id
                    replace = true
                    days = existing.days.map { original in
                        var day = original
                        if !day.rest { day.setTrainingBlocks(day.trainingBlocks) }
                        return day
                    }
                    return
                }
                start = store.calendarDate
                end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
                rebuildDays()
            }
            .onChange(of: start) { _, _ in if end < start { end = start }; rebuildDays() }
            .onChange(of: end) { _, _ in rebuildDays() }
            .onChange(of: revision) { _, _ in requestID = newID() }
            .sheet(item: $editingBlock) { entry in
                PlanEditor(store: store, plan: entry.plan, oneDayOnly: true) { plan in
                    guard let index = days.firstIndex(where: { $0.id == entry.dayID }) else { throw AppError.message("这一天已从周期中移除") }
                    var blocks = days[index].trainingBlocks
                    if let blockID = entry.blockID {
                        guard let item = blocks.firstIndex(where: { $0.id == blockID }) else { throw AppError.message("训练项目已变化") }
                        blocks[item] = TrainingBlock(id: blockID, plan: plan)
                    } else {
                        guard blocks.count < 8 else { throw AppError.message("同一天最多 8 个训练项目") }
                        blocks.append(TrainingBlock(plan: plan))
                    }
                    days[index].setTrainingBlocks(blocks)
                }
            }
    }

    private func rebuildDays() {
        days = manualTrainingDays(from: start, through: end, timezone: zone, preserving: days)
    }
    private func use(_ template: Plan, day: PlanDay, for id: String) {
        guard let index = days.firstIndex(where: { $0.id == id }) else { return }
        var blocks = days[index].trainingBlocks
        guard blocks.count < 8 else { message = "同一天最多 8 个训练项目"; return }
        var snapshot = template
        snapshot.id = newID()
        snapshot.days = [day]
        snapshot.scheduledDate = days[index].date
        blocks.append(TrainingBlock(plan: snapshot))
        days[index].setTrainingBlocks(blocks)
    }
    private func remove(_ blockID: String, from dayID: String) {
        guard let index = days.firstIndex(where: { $0.id == dayID }) else { return }
        days[index].setTrainingBlocks(days[index].trainingBlocks.filter { $0.id != blockID })
    }
    private func save() async {
        guard valid else { return }
        saving = true; message = nil
        defer { saving = false }
        let cycle = PlanningCycle(id: store.isDemo ? (editingExistingID ?? newID()) : newID(),
                                  name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: "training",
                                  startDate: DayKey.string(start, zone: zone), endDate: DayKey.string(end, zone: zone),
                                  timezone: zone, days: days)
        if store.isDemo {
            guard days.allSatisfy({ day in
                guard let (existing, _) = store.scheduled("training", date: day.date) else { return true }
                return existing.id == editingExistingID
            }) else { message = "某些日期属于其他周期，请调整日期"; return }
            if store.save(cycle, kind: "cycle", id: cycle.id) { if let onCompleted { onCompleted() } else { dismiss() } }
            else { message = store.error ?? "周期未保存" }
            return
        }
        do {
            _ = try await store.adoptCycle(cycle, replace: replace, requestId: requestID, minimumAdopted: 1)
            if let onCompleted { onCompleted() } else { dismiss() }
        } catch { message = error.localizedDescription }
    }
}
