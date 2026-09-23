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
                                VStack(alignment: .leading) { Text(day.name); Text("\(day.exercises.count) 个动作").font(.caption).foregroundStyle(.secondary) }
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
                    Button { editing = Plan() } label: { Label("新建训练计划", systemImage: "plus") }
                    if store.plans.isEmpty { Button("从示例模板开始") { editing = Plan.starter() }; Text("示例重量仅供编辑，请按自己的实际计划调整。").font(.caption).foregroundStyle(.secondary) }
                }
                Section("训练记录") {
                    if store.workouts.isEmpty { Text("完成的每一组，都会留在这里。").foregroundStyle(.secondary) }
                    ForEach(store.workouts) { w in
                        NavigationLink { WorkoutView(store: store, workout: w) } label: {
                            VStack(alignment: .leading, spacing: 5) { Text(w.name).font(.headline); Text("\(w.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(w.completedSets) 组 · \(w.status == "completed" ? "已完成" : w.status == "cancelled" ? "已结束" : "进行中")").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }.navigationTitle("训练").navigationDestination(isPresented: Binding(get: { training != nil }, set: { if !$0 { training = nil } })) { if let training { WorkoutView(store: store, workout: training) } }.sheet(item: $editing) { p in PlanEditor(store: store, plan: p) }
        }
    }
}

struct PlanEditor: View {
    @Bindable var store: AppStore; @State var plan: Plan; @Environment(\.dismiss) var dismiss
    @State private var selectingDayID: String?
    var valid: Bool { !plan.name.trimmingCharacters(in: .whitespaces).isEmpty && !plan.days.isEmpty && plan.days.allSatisfy { !$0.name.isEmpty && !$0.exercises.isEmpty && validGroups($0.groups ?? [], exerciseIds: $0.exercises.map(\.id)) && ($0.volumeTargetKg == nil || (1...1_000_000).contains($0.volumeTargetKg!)) && $0.exercises.allSatisfy { !$0.name.isEmpty && !$0.sets.isEmpty && $0.sets.allSatisfy { $0.weight >= 0 && $0.weight <= 2000 && $0.reps > 0 && $0.reps <= 1000 } } } }
    var body: some View {
        NavigationStack {
            Form {
                Section("计划") {
                    TextField("名称", text: $plan.name)
                    Picker("训练目标", selection: $plan.trainingGoal) { Text("增肌").tag("hypertrophy"); Text("力量").tag("strength"); Text("容量").tag("volume"); Text("自定义").tag("custom") }
                    Picker("默认组模式", selection: $plan.setPattern) { ForEach(patternOptions, id: \.0) { Text($0.1).tag($0.0) } }
                    Text("目标与组模式独立；每组重量、次数以你填写的数值为准。").font(.caption).foregroundStyle(.secondary)
                }
                ForEach($plan.days) { $day in
                    Section {
                        TextField("训练日名称", text: $day.name)
                        VolumeTargetEditor(value: $day.volumeTargetKg)
                        NavigationLink("特殊组合 · \((day.groups ?? []).count) 个") { GroupEditor(day: $day) }
                        if !validGroups(day.groups ?? [], exerciseIds: day.exercises.map(\.id)) { Text("请在特殊组合中补足动作，或移除不完整的组合后保存。").font(.caption).foregroundStyle(.red) }
                    } header: { Text(day.name) }
                    ForEach($day.exercises) { $exercise in
                        Section {
                                TextField("动作名称", text: $exercise.name).font(.headline)
                                NavigationLink { ExerciseGuideView(store: store, exerciseId: exercise.exerciseId, name: exercise.name) } label: { Label("动作图解与说明", systemImage: "figure.strengthtraining.traditional") }.font(.subheadline)
                                Picker("重量口径", selection: $exercise.loadBasis) { ForEach(loadNames.keys.sorted(), id: \.self) { Text(loadNames[$0]!).tag($0) } }
                                if exercise.loadBasis == "per_hand" {
                                    Picker("容量计算", selection: Binding(get: { exercise.loadCount ?? 1 }, set: { exercise.loadCount = $0 })) { Text("单只 / 单侧").tag(1); Text("双只 / 双侧").tag(2) }
                                }
                                Picker("组模式", selection: Binding(get: { exercise.setPattern ?? "" }, set: { exercise.setPattern = $0.isEmpty ? nil : $0 })) {
                                    Text("跟随计划").tag(""); ForEach(patternOptions, id: \.0) { Text($0.1).tag($0.0) }
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
                        } header: { Text(exercise.name) }
                    }
                    Section {
                        Button("从动作库添加") { selectingDayID = day.id }
                        Button("添加动作") { day.exercises.append(PlanExercise()) }
                        Button("删除训练日", role: .destructive) { plan.days.removeAll { $0.id == day.id } }
                    } header: { Text(day.name) }
                }
                Button("添加训练日") { plan.days.append(PlanDay()) }
            }.navigationTitle("编辑训练计划")
                .sheet(isPresented: Binding(get: { selectingDayID != nil }, set: { if !$0 { selectingDayID = nil } })) {
                    NavigationStack {
                        ExerciseLibraryView(store: store) { guide in
                            guard let dayID = selectingDayID, let index = plan.days.firstIndex(where: { $0.id == dayID }) else { return }
                            var exercise = PlanExercise(exerciseId: guide.id, name: guide.name, loadBasis: guide.equipmentGroup == "自重" ? "bodyweight" : "total")
                            exercise.sets = [PlanSet(weight: 0, reps: 12)]
                            plan.days[index].exercises.append(exercise)
                            selectingDayID = nil
                        }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { selectingDayID = nil } } }
                    }
                }.toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { if store.save(plan, kind: "plan", id: plan.id) { dismiss() } }.disabled(!valid) }
            }
        }
    }
}

struct VolumeTargetEditor: View {
    @Binding var value: Double?
    @State private var tons = ""
    private var entered: Double? { Double(tons.replacingOccurrences(of: ",", with: ".")) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(value.map { "容量目标 \(($0 / 1000).formatted()) 吨" } ?? "容量目标 · 未设置").font(.subheadline)
            HStack {
                Button("10 吨") { value = 10_000 }
                Button("15 吨") { value = 15_000 }
                Spacer(); Button("不设目标") { value = nil }
            }.buttonStyle(.borderless)
            HStack {
                TextField("自定义吨数", text: $tons).keyboardType(.decimalPad)
                Text("吨").foregroundStyle(.secondary)
                Button("设置") { if let entered { value = entered * 1000 }; dismissInputKeyboard() }
                    .buttonStyle(.borderless).disabled(entered == nil || !(0.001...1000).contains(entered ?? 0))
            }
        }
    }
}

struct GroupEditor: View {
    @Binding var day: PlanDay
    private var groups: Binding<[ExerciseGroup]> { Binding(get: { day.groups ?? [] }, set: { day.groups = $0 }) }
    var body: some View {
        Form {
            Section { Text("超级组选 2 个动作，三合组选 3 个，巨人组选 4 个或以上。同一动作只加入一个组合，按选择顺序逐轮记录。").font(.caption) }
            ForEach(groups) { $group in
                Section {
                    TextField("组合名称", text: $group.name)
                    Picker("组合方式", selection: $group.style) { ForEach(groupOptions, id: \.0) { Text($0.1).tag($0.0) } }
                    ForEach(day.exercises) { exercise in
                        Toggle(exercise.name, isOn: Binding(get: { group.exerciseIds.contains(exercise.id) }, set: { selected in
                            if selected { group.exerciseIds.append(exercise.id) }
                            else { group.exerciseIds.removeAll { $0 == exercise.id } }
                        })).disabled((day.groups ?? []).contains { $0.id != group.id && $0.exerciseIds.contains(exercise.id) })
                    }
                    Text("已选 \(group.exerciseIds.count) 个动作").font(.caption).foregroundStyle(.secondary)
                    Button("移除组合", role: .destructive) { day.groups?.removeAll { $0.id == group.id } }
                }
            }
            Section("添加组合") {
                ForEach(groupOptions, id: \.0) { style, name in
                    Button(name) { day.groups = (day.groups ?? []) + [ExerciseGroup(name: name, style: style)] }
                }
            }
        }.navigationTitle("特殊组合")
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
    var active: Bool { workout.status == "in_progress" }
    var lastCompleted: Date? { workout.exercises.flatMap(\.sets).compactMap(\.completedAt).max() }
    var body: some View {
        List {
            Section {
                HStack { Label("\(workout.completedSets) / \(workout.totalSets) 组", systemImage: "checkmark.circle"); Spacer(); Text(active ? "训练中" : "已结束").foregroundStyle(Theme.green) }
                if active, workout.restUntil != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = CompanionCore.remaining(workout, now: context.date)
                        Text(remaining > 0 ? "休息剩余 \(remaining) 秒" : "休息结束，可开始下一组").monospacedDigit().foregroundStyle(Theme.green)
                    }
                }
                Text(workout.startedAt, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("已完成容量 \((workout.completedVolumeKg / 1000).formatted(.number.precision(.fractionLength(0...2)))) 吨").font(.headline)
                    if let target = workout.volumeTargetKg, target > 0 {
                        ProgressView(value: min(workout.completedVolumeKg, target), total: target).tint(Theme.green)
                        Text(workout.completedVolumeKg >= target ? "本次容量目标已达成" : "目标 \((target / 1000).formatted()) 吨 · 还差 \(((target - workout.completedVolumeKg) / 1000).formatted(.number.precision(.fractionLength(0...2)))) 吨").font(.caption)
                    }
                    if active { DisclosureGroup("设置本次容量目标") { VolumeTargetEditor(value: $workout.volumeTargetKg) } }
                    Text("只计已完成的正式组；热身、自重及辅助重量不计入。每只重量按所选单只或双只累计。").font(.caption2).foregroundStyle(.secondary)
                }
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
                                            SetRow(set: $workout.exercises[exerciseIndex].sets[round], editable: active)
                                        }
                                    }
                                }
                            }
                        } header: { Text("\(group.name) · \(groupTitle(group.style))") }
                    }
                } else {
                    Section {
                        NavigationLink("动作图解与说明") { ExerciseGuideView(store: store, exerciseId: workout.exercises[index].exerciseId, name: workout.exercises[index].name) }
                        ForEach($workout.exercises[index].sets) { $set in SetRow(set: $set, editable: active) }
                    } header: { Text("\(workout.exercises[index].name) · \(workout.exercises[index].displayMethod)") }
                    }
            }
            Section("身体反馈（可选）") {
                RatingPicker(title: "训练前疼痛", value: $workout.feedback.painBefore)
                RatingPicker(title: "训练中疼痛", value: $workout.feedback.painDuring)
                RatingPicker(title: "疲劳程度", value: $workout.feedback.fatigue)
                TextField("备注", text: $workout.feedback.note, axis: .vertical)
            }.disabled(!active)
            if active {
                Section {
                    Button("完成训练") {
                        if workout.exercises.flatMap(\.sets).contains(where: { $0.status == "pending" }) { endConfirm = true }
                        else { finish() }
                    }.font(.headline)
                }
            }
        }.navigationTitle(workout.name)
            .onChange(of: try? Wire.data(workout)) { old, new in
                guard let old, let base: Workout = try? Wire.read(old),
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
                    for i in workout.exercises.indices { for j in workout.exercises[i].sets.indices where workout.exercises[i].sets[j].status == "pending" { workout.exercises[i].sets[j].status = "skipped" } }; finish()
                }
            } message: { Text("已完成的组会保留，未完成的组不会计入完成量。") }
    }
    func finish() { workout.status = "completed"; workout.finishedAt = Date() }
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
