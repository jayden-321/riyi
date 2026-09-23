import SwiftUI

struct TrainingView: View {
    @Bindable var store: AppStore; @State private var editing: Plan?; @State private var training: Workout?
    var body: some View {
        NavigationStack {
            List {
                if let active = store.activeWorkout { Section("正在训练") { NavigationLink { WorkoutView(store: store, workout: active) } label: { Label("\(active.name) · \(active.completedSets)/\(active.totalSets) 组", systemImage: "play.circle.fill") } } }
                ForEach(store.plans) { plan in
                    Section(plan.name) {
                        ForEach(plan.days) { day in
                            HStack {
                                VStack(alignment: .leading) { Text(day.name); Text(day.activity == nil ? "\(day.exercises.count) 个动作" : "\(sportTitle(day.activity!.resolvedSport)) · 按时长记录").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                if let active = store.activeWorkout {
                                    if active.planId == plan.id && (active.planDayId == day.id || active.planDayId == nil && active.name == day.name) {
                                        Button("继续训练") { training = active }.buttonStyle(.bordered)
                                    } else { Text("其他训练进行中").font(.caption).foregroundStyle(.secondary) }
                                } else {
                                    Button("开始") { store.start(plan: plan, day: day); training = store.activeWorkout }.buttonStyle(.bordered)
                                }
                            }
                        }
                        Button("编辑计划") { editing = plan }
                        Button("删除计划", role: .destructive) { store.remove(kind: "plan", id: plan.id) }.accessibilityIdentifier("delete-plan-\(plan.id)")
                    }
                }
                Section("新计划") {
                    Button { editing = Plan.draft() } label: { Label("新建训练计划", systemImage: "plus") }
                    if store.plans.isEmpty { Button("从示例模板开始") { editing = Plan.starter() }; Text("示例重量仅供编辑，请按自己的实际计划调整。").font(.caption).foregroundStyle(.secondary) }
                }
                Section("训练记录") {
                    if store.workouts.isEmpty { Text("完成的每一组，都会留在这里。").foregroundStyle(.secondary) }
                    ForEach(store.workouts) { w in
                        NavigationLink { WorkoutView(store: store, workout: w) } label: {
                            VStack(alignment: .leading, spacing: 5) { Text(w.name).font(.headline); Text("\(w.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(w.activity == nil ? "\(w.completedSets) 组 · " : "")\(w.status == "completed" ? "已完成" : w.status == "cancelled" ? "已结束" : "进行中")").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }.navigationTitle("训练").navigationDestination(isPresented: Binding(get: { training != nil }, set: { if !$0 { training = nil } })) { if let training { WorkoutView(store: store, workout: training) } }.sheet(item: $editing) { p in PlanEditor(store: store, plan: p) }
        }
    }
}

struct PlanEditor: View {
    @Bindable var store: AppStore; @State var plan: Plan; @Environment(\.dismiss) var dismiss
    var oneDayOnly = false
    var onSave: ((Plan) async throws -> Void)? = nil
    @State private var selectingDayID: String?
    @State private var replacingExerciseID: String?
    @State private var requestedCategory: String?
    @State private var confirmCategoryChange = false
    @State private var saving = false
    @State private var saveError: String?
    private var strength: Bool { plan.resolvedCategory == "strength" }
    private var distanceSport: Bool { ["swimming", "running", "cycling", "walking", "hiking", "rowing"].contains(plan.resolvedCategory) }
    var valid: Bool { plan.validEditorDraft }
    var body: some View {
        NavigationStack {
            Form {
                Section("第一步 · 选择运动大类") {
                    Picker("运动大类", selection: Binding(get: { plan.resolvedCategory }, set: { changeCategory($0) })) {
                        ForEach(sportOptions, id: \.code) { option in Label(option.title, systemImage: option.icon).tag(option.code) }
                    }.accessibilityIdentifier("plan-sport-category")
                }
                Section("训练项目") {
                    TextField("名称", text: $plan.name)
                    if strength { Text("选择动作后，在每个动作中填写组数、重量、次数和组模式。").font(.caption).foregroundStyle(.secondary) }
                    else { Text("\(sportTitle(plan.resolvedCategory))按实际运动时长记录；游泳、跑步等也可设距离目标。").font(.caption).foregroundStyle(.secondary) }
                }
                ForEach($plan.days) { $day in
                    Section(day.name) {
                        TextField("训练日名称", text: $day.name)
                        if strength {
                            if day.exercises.isEmpty { Text("先从动作库选择动作").font(.caption).foregroundStyle(.secondary) }
                            Button { selectingDayID = day.id; replacingExerciseID = nil } label: { Label("从动作库选择动作", systemImage: "square.grid.2x2") }
                                .accessibilityIdentifier("choose-library-exercise")
                            Text(day.plannedVolumeKg > 0 ? "计划容量 \((day.plannedVolumeKg / 1000).formatted(.number.precision(.fractionLength(0...2)))) 吨 · 按下方正式组自动计算" : "填写正式组重量和次数后，自动计算计划容量")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            TextField("目标分钟数（可选）", value: Binding(get: { day.activity?.targetMinutes }, set: { day.activity?.targetMinutes = $0 }), format: .number).keyboardType(.numberPad)
                            if distanceSport {
                                TextField("目标距离（米，可选）", value: Binding(get: { day.activity?.targetDistanceMeters }, set: { day.activity?.targetDistanceMeters = $0 }), format: .number).keyboardType(.decimalPad)
                            }
                            TextField("目标消耗（千卡，可选）", value: Binding(get: { day.activity?.targetEnergyKcal }, set: { day.activity?.targetEnergyKcal = $0 }), format: .number).keyboardType(.decimalPad)
                            if plan.resolvedCategory == "swimming" {
                                Picker("游泳地点", selection: Binding(get: { day.activity?.swimLocation ?? "" }, set: { value in day.activity?.swimLocation = value.isEmpty ? nil : value; if value != "pool" { day.activity?.poolLengthMeters = nil } })) {
                                    Text("请选择").tag(""); Text("泳池游泳").tag("pool"); Text("开放水域游泳").tag("open_water")
                                }
                                if day.activity?.swimLocation == "pool" {
                                    TextField("泳池长度（米）", value: Binding(get: { day.activity?.poolLengthMeters }, set: { day.activity?.poolLengthMeters = $0 }), format: .number).keyboardType(.decimalPad)
                                }
                                if !day.activity!.validConfiguration { Text("泳池游泳需填写实际泳池长度；开放水域不用填写泳池长度。").font(.caption).foregroundStyle(.orange) }
                            }
                        }
                        if !oneDayOnly { Button("删除训练日", role: .destructive) { plan.days.removeAll { $0.id == day.id } } }
                    }
                    if strength {
                        ForEach($day.exercises) { $exercise in
                            Section(exercise.name) {
                                if exercise.exerciseId == "custom" { TextField("自定义动作名称", text: $exercise.name) }
                                else { Text(exercise.name).font(.headline) }
                                Button("从动作库更换动作") { selectingDayID = day.id; replacingExerciseID = exercise.id }
                                NavigationLink { ExerciseGuideView(store: store, exerciseId: exercise.exerciseId, name: exercise.name) } label: { Label("动作图解与说明", systemImage: "figure.strengthtraining.traditional") }
                                Picker("重量口径", selection: $exercise.loadBasis) { ForEach(loadNames.keys.sorted(), id: \.self) { Text(loadNames[$0]!).tag($0) } }
                                if exercise.loadBasis == "per_hand" { Picker("容量计算", selection: Binding(get: { exercise.loadCount ?? 1 }, set: { exercise.loadCount = $0 })) { Text("单只 / 单侧").tag(1); Text("双只 / 双侧").tag(2) } }
                                Picker("组模式", selection: Binding(get: { exercise.setPattern ?? "" }, set: { exercise.setPattern = $0.isEmpty ? nil : $0 })) {
                                    Text("使用默认 · \(patternOptions.first { $0.0 == plan.setPattern }?.1 ?? "等重组")").tag("")
                                    ForEach(patternOptions, id: \.0) { Text($0.1).tag($0.0) }
                                }
                                ForEach($exercise.sets) { $set in
                                    HStack {
                                        Picker("组类型", selection: $set.role) { Text("正式").tag("working"); Text("热身").tag("warmup") }.pickerStyle(.menu).buttonStyle(.borderless).labelsHidden().frame(width: 85)
                                        TextField("kg", value: $set.weight, format: .number).keyboardType(.decimalPad).frame(minWidth: 45)
                                        Text("kg ×").foregroundStyle(.secondary)
                                        TextField("次数", value: $set.reps, format: .number).keyboardType(.numberPad).frame(minWidth: 30)
                                        Button { exercise.sets.removeAll { $0.id == set.id } } label: { Image(systemName: "minus.circle").foregroundStyle(.red) }.buttonStyle(.borderless)
                                    }
                                }
                                HStack { Button("添加一组") { exercise.sets.append(PlanSet()) }; Spacer(); Button("删除动作", role: .destructive) { day.exercises.removeAll { $0.id == exercise.id } } }.buttonStyle(.borderless)
                            }
                        }
                        if day.exercises.count >= 2 || !(day.groups ?? []).isEmpty { GroupEditor(day: $day) }
                    }
                }
                if !oneDayOnly { Button("添加训练日") { plan.days.append(strength ? PlanDay(name: "力量训练", exercises: []) : PlanDay(name: sportTitle(plan.resolvedCategory), exercises: [], activity: TimedActivity(name: sportTitle(plan.resolvedCategory), sport: plan.resolvedCategory))) } }
                if let saveError { Section { Text(saveError).foregroundStyle(.red) } }
            }.navigationTitle(oneDayOnly ? "编辑训练项目" : "编辑训练计划")
                .sheet(isPresented: Binding(get: { selectingDayID != nil }, set: { if !$0 { selectingDayID = nil } })) {
                    NavigationStack {
                        ExerciseLibraryView(store: store, onSelect: { guide in
                            guard let dayID = selectingDayID, let index = plan.days.firstIndex(where: { $0.id == dayID }) else { return }
                            if let replacingExerciseID, let old = plan.days[index].exercises.firstIndex(where: { $0.id == replacingExerciseID }) {
                                plan.days[index].exercises[old].exerciseId = guide.id
                                plan.days[index].exercises[old].name = guide.name
                                plan.days[index].exercises[old].loadBasis = guide.equipmentGroup == "自重" ? "bodyweight" : "total"
                            } else {
                                var exercise = PlanExercise(exerciseId: guide.id, name: guide.name, loadBasis: guide.equipmentGroup == "自重" ? "bodyweight" : "total")
                                exercise.sets = [PlanSet(weight: 0, reps: 12)]
                                plan.days[index].exercises.append(exercise)
                            }
                            selectingDayID = nil; replacingExerciseID = nil
                        }, selectRepBasedOnly: true).toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { selectingDayID = nil; replacingExerciseID = nil } } }
                    }
                }.toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") {
                        if let onSave {
                            saving = true; saveError = nil
                            Task { defer { saving = false }; do { try await onSave(plan.withCalculatedVolume()); dismiss() } catch { saveError = error.localizedDescription } }
                        } else if store.save(plan.withCalculatedVolume(), kind: "plan", id: plan.id) { dismiss() }
                    }.disabled(!valid || saving || oneDayOnly && plan.days.count != 1)
                }
            }
            .confirmationDialog("更换运动大类会重置此计划的训练日，继续吗？", isPresented: $confirmCategoryChange) {
                Button("更换运动大类", role: .destructive) { if let requestedCategory { applyCategory(requestedCategory) }; requestedCategory = nil }
                Button("取消", role: .cancel) { requestedCategory = nil }
            }
        }
    }
    private func changeCategory(_ category: String) {
        guard category != plan.resolvedCategory else { return }
        if plan.days.contains(where: { !$0.exercises.isEmpty || $0.activity != nil }) { requestedCategory = category; confirmCategoryChange = true }
        else { applyCategory(category) }
    }
    private func applyCategory(_ category: String) {
        plan.category = category
        if category != "strength" { plan.trainingGoal = "custom"; plan.setPattern = "straight" }
        plan.days = [category == "strength" ? PlanDay(name: "力量训练", exercises: []) : PlanDay(name: sportTitle(category), exercises: [], activity: TimedActivity(name: sportTitle(category), sport: category))]
    }
}

struct GroupEditor: View {
    @Binding var day: PlanDay
    private var groups: Binding<[ExerciseGroup]> { Binding(get: { day.groups ?? [] }, set: { day.groups = $0 }) }
    var body: some View {
        Group {
            Section("动作组合（可选）") {
                Text("从上面已选动作中组合，不会新增动作。超级组 2 个、三合组 3 个、巨人组至少 4 个；训练时按顺序轮流完成。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(groupOptions, id: \.0) { style, name in
                    Button("组合为\(name)") { addGroup(style: style, name: name) }
                        .disabled(day.exercises.filter { exercise in !(day.groups ?? []).contains { $0.exerciseIds.contains(exercise.id) } }.count < groupMinimum(style))
                }
            }
            ForEach(groups) { $group in
                Section("\(group.name) · \(groupTitle(group.style))") {
                    TextField("组合名称", text: $group.name)
                    ForEach(day.exercises) { exercise in
                        Toggle(exercise.name, isOn: Binding(get: { group.exerciseIds.contains(exercise.id) }, set: { selected in
                            if selected { group.exerciseIds.append(exercise.id) }
                            else { group.exerciseIds.removeAll { $0 == exercise.id } }
                        })).disabled((day.groups ?? []).contains { $0.id != group.id && $0.exerciseIds.contains(exercise.id) })
                    }
                    Text("按上面勾选的顺序训练 · 已选 \(group.exerciseIds.count) 个动作")
                        .font(.caption).foregroundColor(group.exerciseIds.count < groupMinimum(group.style) ? .orange : .secondary)
                    Button("移除组合", role: .destructive) { day.groups?.removeAll { $0.id == group.id } }
                }
            }
        }
    }
    private func addGroup(style: String, name: String) {
        let available = day.exercises.filter { exercise in !(day.groups ?? []).contains { $0.exerciseIds.contains(exercise.id) } }
        let count = groupMinimum(style)
        guard available.count >= count else { return }
        day.groups = (day.groups ?? []) + [ExerciseGroup(name: name, style: style, exerciseIds: Array(available.prefix(count).map(\.id)))]
    }
}

extension WorkoutExercise {
    var displayMethod: String {
        let pattern = patternOptions.first { $0.0 == setPattern }?.1 ?? ""
        let load = (loadNames[loadBasis] ?? loadBasis) + (loadBasis == "per_hand" ? " · 按\((loadCount ?? 1) == 2 ? "双只" : "单只")累计" : "")
        return pattern.isEmpty ? load : "\(pattern) · \(load)"
    }
}

struct WorkoutView: View {
    @Bindable var store: AppStore; @State var workout: Workout; @State private var endConfirm = false
    @State private var phoneHealthConfirm = false
    var active: Bool { workout.status == "in_progress" }
    var paused: Bool { workout.pausedAt != nil }
    var lastCompleted: Date? { workout.exercises.flatMap(\.sets).compactMap(\.completedAt).max() }
    var body: some View {
        List {
            Section {
                HStack { Label(workout.activity == nil ? "\(workout.completedSets) / \(workout.totalSets) 组" : workout.name, systemImage: workout.activity == nil ? "checkmark.circle" : "figure.walk"); Spacer(); Text(active ? "训练中" : "已结束").foregroundStyle(Theme.green) }
                if let activity = workout.activity {
                    Text(activity.targetMinutes.map { "目标 \($0) 分钟" } ?? "按时长记录").foregroundStyle(.secondary)
                    if let distance = activity.targetDistanceMeters { Text("距离目标 \(distance.formatted()) 米").foregroundStyle(.secondary) }
                    if active { TimelineView(.periodic(from: .now, by: 1)) { context in Text("\(paused ? "已暂停 · " : "")已运动 \(Int(workout.elapsedSeconds(at: context.date) / 60)) 分钟").monospacedDigit() } }
                    else if workout.finishedAt != nil { Text("实际 \(Int(workout.elapsedSeconds(at: Date()) / 60)) 分钟") }
                    if active {
                        TextField("实际距离（米，可选）", value: $workout.actualDistanceMeters, format: .number).keyboardType(.decimalPad)
                    } else if let distance = workout.actualDistanceMeters { Text("实际距离 \(distance.formatted()) 米") }
                }
                if active, workout.restUntil != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = CompanionCore.remaining(workout, now: context.date)
                        Text(remaining > 0 ? "休息剩余 \(remaining) 秒" : "休息结束，可开始下一组").monospacedDigit().foregroundStyle(Theme.green)
                    }
                }
                Text(workout.startedAt, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                if active {
                    Button(paused ? "继续训练" : "暂停训练") { store.controlWorkout(id: workout.id, action: paused ? "resume_workout" : "pause_workout") }
                        .buttonStyle(.bordered)
                }
                if workout.activity == nil { VStack(alignment: .leading, spacing: 8) {
                    Text("已完成容量 \((workout.completedVolumeKg / 1000).formatted(.number.precision(.fractionLength(0...2)))) 吨").font(.headline)
                    if let target = workout.volumeTargetKg, target > 0 {
                        ProgressView(value: min(workout.completedVolumeKg, target), total: target).tint(Theme.green)
                        Text("计划容量 \((target / 1000).formatted(.number.precision(.fractionLength(0...2)))) 吨 · 由计划正式组自动计算").font(.caption)
                    }
                    Text("只计已完成的正式组；热身、自重及辅助重量不计入。每只重量按所选单只或双只累计。").font(.caption2).foregroundStyle(.secondary)
                } }
            }
            ForEach(workout.exercises.indices, id: \.self) { index in
                if let group = (workout.groups ?? []).first(where: { $0.exerciseIds.contains(workout.exercises[index].id) }) {
                    if group.exerciseIds.first == workout.exercises[index].id {
                        Section {
                            let indices = group.exerciseIds.compactMap { id in workout.exercises.firstIndex { $0.id == id } }
                            let rounds = indices.map { workout.exercises[$0].sets.count }.max() ?? 0
                            Text("依次完成本轮各动作，再进入下一轮。").font(.caption).foregroundStyle(.secondary)
                            ForEach(0..<rounds, id: \.self) { round in
                                ForEach(indices, id: \.self) { exerciseIndex in
                                    if round < workout.exercises[exerciseIndex].sets.count {
                                        VStack(alignment: .leading) {
                                            Text("第 \(round + 1) 轮 · \(workout.exercises[exerciseIndex].name)").font(.headline)
                                            Text(workout.exercises[exerciseIndex].displayMethod).font(.caption).foregroundStyle(.secondary)
                                            NavigationLink("查看动作说明") { ExerciseGuideView(store: store, exerciseId: workout.exercises[exerciseIndex].exerciseId, name: workout.exercises[exerciseIndex].name) }.font(.caption)
                                            SetRow(set: $workout.exercises[exerciseIndex].sets[round], editable: active && !paused)
                                        }
                                    }
                                }
                            }
                        } header: { Text("\(group.name) · \(groupTitle(group.style))") }
                    }
                } else {
                    Section {
                        NavigationLink("动作图解与说明") { ExerciseGuideView(store: store, exerciseId: workout.exercises[index].exerciseId, name: workout.exercises[index].name) }
                        ForEach($workout.exercises[index].sets) { $set in SetRow(set: $set, editable: active && !paused) }
                    } header: { Text("\(workout.exercises[index].name) · \(workout.exercises[index].displayMethod)") }
                    }
            }
            Section("身体反馈（可选）") {
                RatingPicker(title: "训练前疼痛", value: $workout.feedback.painBefore)
                RatingPicker(title: "训练中疼痛", value: $workout.feedback.painDuring)
                RatingPicker(title: "疲劳程度", value: $workout.feedback.fatigue)
                TextField("备注", text: $workout.feedback.note, axis: .vertical)
            }.disabled(!active)
            if workout.status == "completed" {
                Section("Apple 健康") {
                    if store.healthWorkoutSaved(workout.id) { Text("已写入 Apple 健康").foregroundStyle(Theme.green) }
                    else if store.workoutHealth.hasPairedWatch {
                        Text("由日益手表写入；等待手表记录同步。").font(.caption).foregroundStyle(.secondary)
                        Button("本次未用手表，改由手机写入") { phoneHealthConfirm = true }
                    } else { Button("写入 Apple 健康") { Task { await store.writeWorkoutToHealth(workout) } } }
                    if let message = store.healthExportMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if active {
                Section {
                    Button("停止并保存训练") {
                        if workout.exercises.flatMap(\.sets).contains(where: { $0.status == "pending" }) { endConfirm = true }
                        else { finish() }
                    }.font(.headline)
                }
            }
        }.navigationTitle(workout.name)
            .onChange(of: try? Wire.data(workout)) { old, new in
                guard let old, let base: Workout = try? Wire.read(old),
                      base.id == workout.id,
                      new != (try? Wire.data(store.workouts.first { $0.id == workout.id })) else { return }
                store.saveWorkoutEdits(base: base, proposed: workout)
                if let latest = store.workouts.first(where: { $0.id == workout.id }) { workout = latest }
            }
            .onChange(of: try? Wire.data(store.workouts.first { $0.id == workout.id })) { _, _ in
                if let latest = store.workouts.first(where: { $0.id == workout.id }) { workout = latest }
            }
            .alert("还有未完成的组", isPresented: $endConfirm) {
                Button("继续训练", role: .cancel) { }
                Button("标记剩余组为跳过并结束") {
                    finish()
                }
            } message: { Text("已完成的组会保留，未完成的组不会计入完成量。") }
            .confirmationDialog("确认本次没有用日益手表记录？", isPresented: $phoneHealthConfirm) {
                Button("由手机写入") { Task { await store.writeWorkoutToHealth(workout) } }
            } message: { Text("如果手表正在保存同一次训练，请等待同步，避免重复。") }
    }
    func finish() { store.controlWorkout(id: workout.id, action: workout.activity == nil ? "finish_workout" : "finish_activity") }
}

struct SetRow: View {
    @Binding var set: WorkoutSet; let editable: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(set.role == "warmup" ? "热身组" : "正式组").font(.caption).foregroundStyle(.secondary); Spacer(); Text("计划 \(set.plannedWeight.formatted()) kg × \(set.plannedReps)").font(.subheadline) }
            HStack {
                TextField("重量", value: Binding(get: { set.actualWeight ?? set.plannedWeight }, set: { set.actualWeight = $0 }), format: .number).keyboardType(.decimalPad)
                Text("kg ×").foregroundStyle(.secondary)
                TextField("次数", value: Binding(get: { set.actualReps ?? set.plannedReps }, set: { set.actualReps = $0 }), format: .number).keyboardType(.numberPad).accessibilityIdentifier("actual-reps-\(set.id)")
                if set.status == "completed" { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green) }
                if set.status == "skipped" { Text("已跳过").font(.caption).foregroundStyle(.secondary) }
            }.disabled(!editable || set.status != "pending")
            if editable && set.status == "pending" {
                HStack {
                    if set.startedAt == nil { Button("开始本组") { set.startedAt = Date() } }
                    else { Button("完成本组") { set.actualWeight = set.actualWeight ?? set.plannedWeight; set.actualReps = set.actualReps ?? set.plannedReps; set.completedAt = Date(); set.status = "completed" }.disabled((set.actualWeight ?? set.plannedWeight) < 0 || (set.actualWeight ?? set.plannedWeight) > 2000 || (set.actualReps ?? set.plannedReps) < 0 || (set.actualReps ?? set.plannedReps) > 1000) }
                    Spacer(); Button("跳过") { set.status = "skipped" }
                }.buttonStyle(.borderless)
            }
            DifficultyStars(value: $set.rpe).disabled(!editable)
            DisclosureGroup("本组备注") {
                TextField("本组备注", text: $set.note)
            }.font(.caption).disabled(!editable)
        }.padding(.vertical, 6)
    }
}

struct DifficultyStars: View {
    @Binding var value: Double?
    // Retain the existing 0–10 storage scale; viewing old records never rewrites them.
    private var selected: Int { value.map { min(5, max(1, Int(ceil($0 / 2)))) } ?? 0 }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("主观难度").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { star in
                    Button { value = selected == star ? nil : Double(star * 2) } label: {
                        Image(systemName: star <= selected ? "star.fill" : "star")
                            .font(.title2)
                            .foregroundStyle(star <= selected ? Theme.green : Theme.muted)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("主观难度，\(star) 颗星")
                    .accessibilityValue(star <= selected ? "已选" : "未选")
                    .accessibilityHint("星越多越难，再点当前星级可取消")
                }
            }
        }
    }
}

struct RatingPicker: View {
    let title: String; @Binding var value: Int?
    var body: some View { Picker(title, selection: Binding(get: { value ?? -1 }, set: { value = $0 < 0 ? nil : $0 })) { Text("未填写").tag(-1); ForEach(0...10, id: \.self) { Text("\($0)").tag($0) } } }
}

struct CheckinView: View {
    @Bindable var store: AppStore; @State private var value = Checkin(); @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            Form {
                DatePicker("记录时间", selection: $value.recordedAt, in: ...Date())
                RatingPicker(title: "疲劳程度", value: $value.fatigue); RatingPicker(title: "疼痛程度", value: $value.pain)
                TextField("睡眠感受", text: $value.sleepFeeling); TextField("身体感受或症状", text: $value.note, axis: .vertical)
                TextField("饮食情况（可选）", text: Binding(get: { value.dietNote ?? "" }, set: { value.dietNote = $0 }), axis: .vertical)
                Picker("关联训练（如次日反馈）", selection: Binding(get: { value.relatedWorkoutId ?? "" }, set: { value.relatedWorkoutId = $0.isEmpty ? nil : $0 })) {
                    Text("不关联").tag(""); ForEach(Array(store.workouts.prefix(20))) { w in Text("\(w.name) · \(w.startedAt.formatted(date: .abbreviated, time: .omitted))").tag(w.id) }
                }
            }.navigationTitle("身体感受").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { if store.save(value, kind: "checkin", id: value.id) { dismiss() } } } }
        }
    }
}
