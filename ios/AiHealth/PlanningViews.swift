import SwiftUI

struct PlanningCalendar: View {
    @Bindable var store: AppStore; let kind: String
    @State private var expanded = false
    private var calendar: Calendar { DayKey.calendar(store.settings.timezone) }
    private var dates: [Date?] {
        if expanded {
            let first = calendar.date(from: calendar.dateComponents([.year,.month], from: store.calendarDate))!
            let offset = (calendar.component(.weekday, from: first) + 5) % 7
            return Array(repeating: nil, count: offset) + (0..<(calendar.range(of: .day, in: .month, for: first)?.count ?? 30)).map { calendar.date(byAdding: .day, value: $0, to: first) }
        }
        let first = calendar.date(byAdding: .day, value: -(calendar.component(.weekday, from: store.calendarDate) + 5) % 7, to: calendar.startOfDay(for: store.calendarDate))!
        return (0..<7).map { calendar.date(byAdding: .day, value: $0, to: first) }
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 32,height: 40) }.accessibilityLabel(expanded ? "上个月" : "上一周")
                Spacer(); Text(store.calendarDate, format: .dateTime.year().month()).font(.headline); Spacer()
                Button(expanded ? "收起" : "月历") { expanded.toggle() }.font(.subheadline)
                Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 32,height: 40) }.accessibilityLabel(expanded ? "下个月" : "下一周")
            }.buttonStyle(.borderless)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(),spacing: 2),count: 7),spacing: 6) {
                ForEach(["一","二","三","四","五","六","日"],id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(dates.enumerated()),id: \.offset) { _, date in
                    if let date {
                        let key = DayKey.string(date,zone: store.settings.timezone)
                        let selected = key == store.calendarKey
                        Button { store.calendarDate = date } label: {
                            VStack(spacing: 3) { Text("\(calendar.component(.day,from: date))").font(.subheadline); Text(marker(key)).font(.caption2).frame(height: 12) }.frame(maxWidth: .infinity,minHeight: 42).foregroundStyle(selected ? .white : Theme.ink).background(selected ? Theme.green : .clear,in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.borderless).accessibilityLabel("\(key) \(marker(key))").accessibilityIdentifier("calendar-\(key)")
                    } else { Color.clear.frame(height: 42) }
                }
            }
            HStack { Text("○ 已安排  ✓ 有实际记录  休 休息日").font(.caption2).foregroundStyle(.secondary); Spacer(); Button("今天") { store.calendarDate = Date() }.font(.caption).buttonStyle(.borderless) }
        }.padding(.vertical,4)
    }
    private func marker(_ date: String) -> String {
        if kind == "training" ? !store.workouts(on: date).isEmpty : !store.meals(on: date).isEmpty { return "✓" }
        if let (_,day) = store.scheduled(kind,date: date) { return day.rest ? "休" : "○" }; return " "
    }
    private func move(_ step: Int) { store.calendarDate = calendar.date(byAdding: expanded ? .month : .day,value: expanded ? step : step * 7,to: store.calendarDate) ?? store.calendarDate }
}

struct TrainingCalendarView: View {
    @Bindable var store: AppStore; @State private var planning = false; @State private var template: Plan?
    var body: some View {
        NavigationStack {
            List {
                Section { PlanningCalendar(store: store,kind: "training") }
                Section {
                    Button("和 AI 安排训练周期") { planning = true }
                    NavigationLink("我的计划与历史记录") { TrainingView(store: store) }
                }
                if !store.plans.isEmpty {
                    Section("从已有计划安排") {
                        ForEach(store.plans) { plan in
                            Button { template = plan } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(plan.name).font(.headline)
                                    Text("\(plan.days.count) 个训练日 · 选择日期后才会显示在日历").font(.caption).foregroundStyle(.secondary)
                                }
                            }.accessibilityIdentifier("schedule-template-\(plan.id)")
                        }
                    }
                }
                if let active = store.activeWorkout { Section("正在训练") { NavigationLink("\(active.name) · 继续训练") { WorkoutView(store: store,workout: active) } } }
                Section(store.calendarKey) {
                    if let (_,day) = store.scheduled("training",date: store.calendarKey) {
                        if day.rest {
                            NavigationLink { ScheduledRestDayView(store: store, date: day.date) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(day.recoveryActivity?.isEmpty == false ? day.recoveryActivity! : "已安排休息日", systemImage: "leaf")
                                    if day.recoveryActivity?.isEmpty == false { Text("力量训练休息日 · 恢复活动").font(.caption).foregroundStyle(.secondary) }
                                }
                            }.accessibilityIdentifier("scheduled-rest-day")
                        }
                        else if let plan = day.plan { NavigationLink { ScheduledTrainingView(store: store,plan: plan,date: day.date) } label: { VStack(alignment: .leading,spacing: 4) { Text(plan.days.first?.name ?? plan.name).font(.headline); Text("计划 · 点击查看动作和训练组").font(.caption).foregroundStyle(.secondary) } } }
                    } else if let legacy = store.plans.first(where: { $0.scheduledDate == store.calendarKey }), legacy.days.count == 1 {
                        NavigationLink { ScheduledTrainingView(store: store, plan: legacy, date: store.calendarKey) } label: { Text(legacy.days[0].name) }
                    } else {
                        Text("当天没有安排。上面的已有计划可选训练日并安排到这一天。").foregroundStyle(.secondary)
                    }
                    ForEach(store.workouts(on: store.calendarKey)) { w in NavigationLink { WorkoutView(store: store,workout: w) } label: { VStack(alignment: .leading) { Text(w.name); Text("实际 \(w.completedSets) 组 · \(w.status == "in_progress" ? "进行中" : "已结束")").font(.caption).foregroundStyle(.secondary) } } }
                }
            }.navigationTitle("训练")
                .sheet(isPresented: $planning) { PlanningRequestView(store: store,kind: "training") }
                .sheet(item: $template) { value in TemplateScheduleView(store: store, plan: value) }
        }
    }
}
struct ScheduledRestDayView: View {
    @Bindable var store: AppStore
    let date: String
    @Environment(\.dismiss) private var dismiss
    @State private var activity = ""
    @State private var selectedPlan: Plan?
    @State private var confirmDelete = false
    var body: some View {
        List {
            Section("\(date) · 力量训练休息日") {
                TextField("恢复活动，例如饭后散步", text: $activity, axis: .vertical)
                    .accessibilityIdentifier("rest-recovery-activity")
                Button("保存恢复活动") { if store.setRestDayRecovery(on: date, activity: activity) { dismiss() } }
                    .disabled(activity.count > 240)
                Text("散步等轻活动会显示在今天；这一天仍是力量训练休息日。").font(.caption).foregroundStyle(.secondary)
            }
            Section("改为力量训练") {
                if store.plans.isEmpty {
                    Button("请 AI 教练安排力量训练") {
                        store.coachPromptDraft = "请把 \(date) 的休息日改为力量训练日；先确认我的恢复状态，再给出可采用的具体训练安排。"
                        store.selectedTab = "coach"; dismiss()
                    }
                } else {
                    ForEach(store.plans) { plan in
                        Button("选用 \(plan.name)") { selectedPlan = plan }
                    }
                }
            }
            Section {
                Button("删除今天的休息安排", role: .destructive) { confirmDelete = true }
            }
        }.navigationTitle("调整今天安排")
            .onAppear { activity = store.scheduled("training", date: date)?.1.recoveryActivity ?? "" }
            .confirmationDialog("删除 \(date) 的休息安排？", isPresented: $confirmDelete) {
                Button("删除当天安排", role: .destructive) { if store.deleteRestDay(on: date) { dismiss() } }
            } message: { Text("只删除这一天的日历安排，已有实际训练记录保留。") }
            .sheet(item: $selectedPlan) { plan in
                TemplateScheduleView(store: store, plan: plan, initialDate: DayKey.date(date, zone: store.settings.timezone), replaceExisting: true)
                    .onDisappear { if store.scheduled("training", date: date)?.1.rest == false { dismiss() } }
            }
    }
}
struct TemplateScheduleView: View {
    @Bindable var store: AppStore; let plan: Plan
    var initialDate: Date? = nil
    var replaceExisting = false
    @Environment(\.dismiss) private var dismiss
    @State private var dates: [Date] = []
    @State private var chosen: Set<Int> = []
    @State private var replace = false
    @State private var busy = false
    @State private var status: String?
    @State private var requestID = newID()
    private var selectedDates: [String] {
        chosen.sorted().compactMap { dates.indices.contains($0) ? DayKey.string(dates[$0], zone: store.settings.timezone) : nil }
    }
    private var hasDuplicateDates: Bool { Set(selectedDates).count != selectedDates.count }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(plan.name).font(.headline)
                    Text("这是一份 \(plan.days.count) 天训练模板。选择训练日与具体日期后，才会出现在训练日历；已有实际记录不变。").font(.footnote).foregroundStyle(.secondary)
                    Button("选择全部并按顺序排日期") {
                        let calendar = DayKey.calendar(store.settings.timezone)
                        chosen = Set(plan.days.indices)
                        dates = plan.days.indices.map { calendar.date(byAdding: .day, value: $0, to: store.calendarDate) ?? store.calendarDate }
                        requestID = newID()
                    }
                }
                ForEach(Array(plan.days.enumerated()), id: \.element.id) { index, day in
                    Section(day.name) {
                        Toggle("安排这一天", isOn: Binding(get: { chosen.contains(index) }, set: { enabled in if enabled { chosen.insert(index) } else { chosen.remove(index) }; requestID = newID() }))
                        if dates.indices.contains(index) {
                            DatePicker("安排日期", selection: Binding(get: { dates[index] }, set: { dates[index] = $0; requestID = newID() }), displayedComponents: .date)
                            if store.scheduled("training", date: DayKey.string(dates[index], zone: store.settings.timezone)) != nil && chosen.contains(index) {
                                Text("该日已有安排").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Text("\(day.exercises.count) 个动作 · \(day.exercises.reduce(0) { $0 + $1.sets.count }) 组计划").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("已有安排") {
                    Toggle("替换未开始的日历安排", isOn: $replace)
                    Text("已开始或已结束的训练及组记录保留。关闭替换时，只安排空白日期。").font(.caption).foregroundStyle(.secondary)
                }
                if hasDuplicateDates { Section { Text("选中的训练日不能安排在同一天，请调整日期。").foregroundStyle(.red) } }
                if let status { Section { Text(status).foregroundStyle(.red) } }
                Section {
                    Button(busy ? "正在安排…" : "安排所选 \(chosen.count) 天到日历") { Task { await adopt() } }
                        .disabled(busy || chosen.isEmpty || hasDuplicateDates || dates.count != plan.days.count)
                        .accessibilityIdentifier("schedule-existing-plan")
                }
            }
            .navigationTitle("安排已有计划")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) } }
            .onAppear {
                guard dates.isEmpty else { return }
                dates = Array(repeating: initialDate ?? store.calendarDate, count: plan.days.count)
                replace = replaceExisting
                let completed = Set(store.workouts.filter { $0.planId == plan.id && $0.status == "completed" }.compactMap { workout in
                    workout.planDayId ?? plan.days.first(where: { $0.name == workout.name })?.id
                })
                let next = plan.days.firstIndex(where: { !completed.contains($0.id) }) ?? 0
                chosen = [next]
            }
        }
    }
    private func adopt() async {
        guard !busy, !chosen.isEmpty, !hasDuplicateDates else { return }
        busy = true; defer { busy = false }
        let zone = store.settings.timezone
        let days: [CycleDay] = chosen.sorted().map { index in
            let date = DayKey.string(dates[index], zone: zone)
            var snapshot = plan
            snapshot.id = stableID("training-day/\(plan.id)/\(plan.days[index].id)/\(date)")
            snapshot.days = [plan.days[index]]
            snapshot.scheduledDate = date
            return CycleDay(id: stableID("schedule-day/\(plan.id)/\(plan.days[index].id)/\(date)"), date: date, plan: snapshot)
        }
        guard let first = days.map(\.date).min(), let last = days.map(\.date).max() else { return }
        let cycle = PlanningCycle(id: stableID("template-schedule/\(plan.id)/\(first)"), name: plan.name, kind: "training", startDate: first, endDate: last, timezone: zone, days: days)
        if store.isDemo {
            guard days.allSatisfy({ store.scheduled("training", date: $0.date) == nil }) else { status = "本地已有安排，请先选择空白日期。"; return }
            if store.save(cycle, kind: "cycle", id: cycle.id) { store.calendarDate = DayKey.date(first, zone: zone) ?? Date(); dismiss() }
            else { status = store.error ?? "计划未保存" }
            return
        }
        do { let outcome = try await store.adoptCycle(cycle, replace: replace, requestId: requestID); dismiss(); store.error = outcome }
        catch { status = error.localizedDescription }
    }
}
struct ScheduledTrainingView: View {
    @Bindable var store: AppStore; let plan: Plan; let date: String
    @State private var training: Workout?
    var body: some View {
        List {
            Section { Text(date); Text(plan.name).font(.headline) }
            if let day = plan.days.first {
                ForEach(day.exercises) { exercise in Section(exercise.name) {
                    NavigationLink("动作图解与说明") { ExerciseGuideView(store: store,exerciseId: exercise.exerciseId,name: exercise.name) }
                    ForEach(exercise.sets) { set in Text("\(set.weight.formatted()) kg × \(set.reps) 次") }
                } }
                Section {
                    if let w = store.workouts.first(where: { $0.planId == plan.id }) { NavigationLink(w.status == "in_progress" ? "继续训练" : "查看实际记录") { WorkoutView(store: store,workout: w) } }
                    else if date == DayKey.string(Date(),zone: store.settings.timezone) { Button("开始训练") { store.start(plan: plan,day: day); training = store.activeWorkout }.disabled(store.activeWorkout != nil) }
                    else { Text("该页面是 \(date) 的安排，到了当天可开始训练。").font(.footnote).foregroundStyle(.secondary) }
                    Button("和教练讨论调整") { store.coachPromptDraft = "请调整我已采用的 \(date) 训练安排："; store.selectedTab = "coach" }
                }
            }
        }.navigationTitle("训练详情").navigationDestination(isPresented: Binding(get: { training != nil },set: { if !$0 { training = nil } })) { if let training { WorkoutView(store: store,workout: training) } }
    }
}

struct DietView: View {
    @Bindable var store: AppStore
    @State private var editing: MealLog?; @State private var planning = false
    @State private var common = false; @State private var textEntry = false; @State private var photoEntry = false
    @State private var camera = false; @State private var capturedImage: UIImage?
    private var logs: [MealLog] { store.meals(on: store.calendarKey) }
    private var energy: MealEnergySummary { MealEnergySummary(logs) }
    private var future: Bool { store.calendarKey > DayKey.string(Date(),zone: store.settings.timezone) }
    var body: some View {
        NavigationStack {
            List {
                Section("饮水") {
                    Text("\(store.water(on: store.calendarKey)) / \(store.profile.waterGoalMl) ml").font(.headline)
                    HStack { Button("+ 250 ml") { water(250) }; Spacer(); Button("+ 500 ml") { water(500) } }.buttonStyle(.bordered).disabled(future)
                    NavigationLink("饮水记录、补记与提醒") { WaterView(store: store) }
                }
                Section { PlanningCalendar(store: store,kind: "diet") }
                Section {
                    HStack {
                        Button { common = true } label: { Label("常用", systemImage: "star") }.disabled(future)
                        Spacer()
                        Button { textEntry = true } label: { Label("文字", systemImage: "text.cursor") }.disabled(future).accessibilityIdentifier("add-meal-log")
                        Spacer()
                        Button {
                            if UIImagePickerController.isSourceTypeAvailable(.camera) { camera = true }
                            else { photoEntry = true }
                        } label: { Label("拍照", systemImage: "camera") }.disabled(future)
                    }.buttonStyle(.bordered)
                    Button("和 AI 安排饮食周期") { planning = true }
                }
                Section("\(store.calendarKey) · 实际摄入") {
                    if energy.rangeCount > 0 {
                        Text("已记录热量约 \(energy.totalMidpointKcal.formatted(.number.precision(.fractionLength(0...1)))) 千卡").font(.headline)
                    } else {
                        Text("已记录热量 \(energy.singleKcal.formatted(.number.precision(.fractionLength(0...1)))) 千卡").font(.headline)
                    }
                    if energy.unknownCount > 0 { Text("另有 \(energy.unknownCount) 笔热量未估算").font(.caption).foregroundStyle(.secondary) }
                    ForEach(logs) { log in Button { editing = log } label: { MealLogRow(log: log) }.buttonStyle(.plain).swipeActions { Button("删除",role: .destructive) { store.remove(kind: "meal",id: log.id) } } }
                }
                Section("当天食谱计划") {
                    if let (_,day) = store.scheduled("diet",date: store.calendarKey) {
                        ForEach(day.meals) { meal in NavigationLink { MealPlanDetail(store: store,meal: meal,date: day.date) } label: { VStack(alignment: .leading,spacing: 5) { Text(meal.name).font(.headline); Text(meal.foods.joined(separator: "、")).font(.subheadline).foregroundStyle(.secondary) } } }
                    } else { Text("还没有采用食谱。没有计划也可以记录实际吃喝。").foregroundStyle(.secondary) }
                }
            }.navigationTitle("饮食").sheet(item: $editing) { log in MealLogEditor(store: store,log: log) }.sheet(isPresented: $planning) { PlanningRequestView(store: store,kind: "diet") }
                .sheet(isPresented: $common) { FoodCommonView(store: store, date: store.calendarDate) }
                .sheet(isPresented: $textEntry) { FoodTextEntryView(store: store, date: store.calendarDate) }
                .sheet(isPresented: $photoEntry, onDismiss: { capturedImage = nil }) { FoodOutsidePhotoView(store: store, date: store.calendarDate, initialImage: capturedImage) }
                .fullScreenCover(isPresented: $camera, onDismiss: { if capturedImage != nil { photoEntry = true } }) { FoodCameraPicker { capturedImage = $0 }.ignoresSafeArea() }
        }
    }
    private func makeLog() -> MealLog { MealLog(description: "",eatenAt: mealEntryTime(for: store.calendarDate, zone: store.settings.timezone),timezone: store.settings.timezone) }
    private func water(_ amount: Int) { store.addWater(amount,date: DayKey.calendar(store.settings.timezone).isDate(store.calendarDate,inSameDayAs: Date()) ? Date() : store.calendarDate) }
}
struct MealLogRow: View {
    let log: MealLog
    private var energyText: String {
        if let kcal = log.energyKcal { return "\(kcal.formatted(.number.precision(.fractionLength(0...1)))) 千卡 · \(log.energyMethod == "label" ? "按标签计算" : log.energyMethod == "estimated" ? "估算" : "手动填写")" }
        if let low = log.estimateMinKcal, let high = log.estimateMaxKcal { return "约 \(low.formatted(.number.precision(.fractionLength(0))))–\(high.formatted(.number.precision(.fractionLength(0)))) 千卡 · AI 粗估" }
        return "热量待估算"
    }
    var body: some View { VStack(alignment: .leading,spacing: 5) { HStack { Text(mealSlots.first { $0.0 == log.slot }?.1 ?? "饮食").font(.headline); Spacer(); Text(log.eatenAt,format: .dateTime.hour().minute()).font(.caption) }; Text(log.description); Text(energyText).font(.caption).foregroundStyle(.secondary) } }
}
struct MealPlanDetail: View {
    @Bindable var store: AppStore; let meal: NutritionMeal; let date: String
    @State private var editing: MealLog?
    var body: some View {
        List {
            Section("\(date) · \(meal.name)") { Text(meal.foods.joined(separator: "、")); Text(meal.preparation); ForEach(Array(meal.alternatives.enumerated()),id: \.offset) { _,text in Text(text).font(.footnote) } }
            Section("实际记录") {
                if let log = store.mealLogs.first(where: { $0.planMealId == meal.id }) { MealLogRow(log: log); Button("修改实际记录") { editing = log } }
                else { Text("尚未记录，计划不代表已经吃过。").foregroundStyle(.secondary); Button("按计划记录 / 修改实际吃的") { editing = MealLog(id: stableID("meal/" + meal.id),slot: meal.slot,description: meal.foods.joined(separator: "、"),eatenAt: mealEntryTime(for: DayKey.date(date,zone: store.settings.timezone) ?? Date(), zone: store.settings.timezone),timezone: store.settings.timezone,planMealId: meal.id) }.disabled(date > DayKey.string(Date(),zone: store.settings.timezone)) }
            }
            Section { Button("和教练讨论这一餐") { store.coachPromptDraft = "请调整我已采用的 \(date) \(meal.name)："; store.selectedTab = "coach" } }
        }.navigationTitle("餐次详情").sheet(item: $editing) { log in MealLogEditor(store: store,log: log) }
    }
}
struct MealLogEditor: View {
    @Bindable var store: AppStore; @State var log: MealLog; @Environment(\.dismiss) private var dismiss
    @State private var photoEstimate = false
    @State private var photoSaved = false
    @State private var estimatingText = false
    @State private var estimateNote: String?
    @State private var aiEstimateDescription = ""
    private var calculated: MealLog { var value = log; value.calculateEnergy(); return value }
    var body: some View {
        NavigationStack { Form {
            Section("实际吃喝") {
                Picker("餐次",selection: $log.slot) { ForEach(mealSlots,id: \.0) { Text($0.1).tag($0.0) } }
                TextField("吃了什么、多少，例如一小块蛋糕",text: $log.description,axis: .vertical).accessibilityIdentifier("meal-description")
                DatePicker("发生时间",selection: $log.eatenAt,in: ...Date())
            }
            Section("热量（选填）") {
                Button(estimatingText ? "正在估算…" : "按文字请 AI 粗估") { Task { await estimateText() } }
                    .disabled(estimatingText || log.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("拍照请 AI 识别并粗估") { photoEstimate = true }.accessibilityIdentifier("meal-ai-photo")
                if let estimateNote { Text(estimateNote).font(.caption).foregroundStyle(.secondary) }
                Picker("记录方式",selection: $log.energyMethod) { Text("热量待估算，先保存").tag("unknown"); Text("按标签与克数计算").tag("label"); Text("填写已知热量").tag("manual"); Text("填写估算热量").tag("estimated"); Text("手动填写粗估范围").tag("estimated_range") }
                if log.energyMethod == "label" {
                    TextField("实际吃了多少克",value: $log.grams,format: .number).keyboardType(.decimalPad)
                    TextField("标签每 100 克多少千卡",value: $log.kcalPer100,format: .number).keyboardType(.decimalPad)
                    if let kcal = calculated.energyKcal { Text("本次 \(kcal.formatted(.number.precision(.fractionLength(0...1)))) 千卡") }
                } else if log.energyMethod == "estimated_range" {
                    Text("范围可手动填写，也可由上方 AI 粗估带入。没有可靠数值时可选“热量待估算，先保存”。").font(.caption).foregroundStyle(.secondary)
                    TextField("粗估下限（千卡）", value: $log.estimateMinKcal, format: .number).keyboardType(.decimalPad)
                    TextField("粗估上限（千卡）", value: $log.estimateMaxKcal, format: .number).keyboardType(.decimalPad)
                    TextField("估算依据", text: Binding(get: { log.nutritionSource ?? "" }, set: { log.nutritionSource = $0 }), axis: .vertical)
                } else if log.energyMethod != "unknown" { TextField("本次总热量（千卡）",value: $log.energyKcal,format: .number).keyboardType(.decimalPad) }
                Text("千焦 ÷ 4.184 = 千卡。拍照识别会生成待确认结果；份量或配方不清楚时可保留粗估范围或留空，不会把未知值算成 0。").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("饮食记录").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { if store.save(calculated,kind: "meal",id: log.id) { dismiss() } }.disabled(!calculated.valid).accessibilityIdentifier("save-meal-log") } }
            .sheet(isPresented: $photoEstimate, onDismiss: { if photoSaved { dismiss() } }) {
                FoodOutsidePhotoView(store: store, date: log.eatenAt, existingLog: log) { photoSaved = true }
            }
            .onChange(of: log.description) { _, value in
                if !aiEstimateDescription.isEmpty && value != aiEstimateDescription {
                    log.energyMethod = "unknown"; log.estimateMinKcal = nil; log.estimateMaxKcal = nil
                    log.nutritionSource = nil; estimateNote = "食物描述已改变，请重新估算。"
                    aiEstimateDescription = ""
                }
            }
        }
    }
    private func estimateText() async {
        estimatingText = true; estimateNote = nil; defer { estimatingText = false }
        do {
            let result = try await store.estimateFoodText(log.description.trimmingCharacters(in: .whitespacesAndNewlines))
            if let (low, high) = result.usableRange {
                log.energyMethod = "estimated_range"; log.estimateMinKcal = low; log.estimateMaxKcal = high
                log.nutritionSource = "AI 文字粗估：" + String(result.estimateBasis.prefix(280))
                aiEstimateDescription = log.description
                estimateNote = "AI 粗估约 \(low.formatted(.number.precision(.fractionLength(0))))–\(high.formatted(.number.precision(.fractionLength(0)))) 千卡；请核对份量后保存。"
            } else { log.energyMethod = "unknown"; estimateNote = result.estimateBasis.isEmpty ? "份量信息不足，已改为热量待估算，可先保存。" : result.estimateBasis }
        } catch { store.error = error.localizedDescription }
    }
}

struct PlanningRequestView: View {
    @Bindable var store: AppStore; let kind: String; @Environment(\.dismiss) private var dismiss
    @State private var mode = "week"; @State private var start = Date(); @State private var end = Date()
    private var last: Date { mode == "single" ? start : mode == "week" ? DayKey.calendar(store.settings.timezone).date(byAdding: .day,value: 6,to: start)! : end }
    private var count: Int { (DayKey.calendar(store.settings.timezone).dateComponents([.day],from: start,to: last).day ?? 0) + 1 }
    var body: some View {
        NavigationStack { Form {
            Section("和教练沟通安排") {
                Picker("周期",selection: $mode) { Text("单日").tag("single"); Text("一周").tag("week"); Text("自定义").tag("custom") }.pickerStyle(.segmented)
                DatePicker("开始日期",selection: $start,displayedComponents: .date)
                if mode == "custom" { DatePicker("结束日期",selection: $end,in: start...,displayedComponents: .date) }
                Text("\(DayKey.string(start,zone: store.settings.timezone)) 至 \(DayKey.string(last,zone: store.settings.timezone)) · \(count) 天")
                Text("先回到聊天补充要求，AI 生成草稿后再选择采用。每次 AI 生成最多 31 天，可分段安排更长周期。").font(.footnote).foregroundStyle(.secondary)
                Button("继续与教练沟通") { store.openPlanningChat(kind: kind,start: start,end: last); dismiss() }.disabled(count < 1 || count > 31)
            }
        }.navigationTitle(kind == "diet" ? "饮食周期" : "训练周期").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }.onAppear { start = store.calendarDate; end = DayKey.calendar(store.settings.timezone).date(byAdding: .day,value: 6,to: start)! } }
    }
}

struct CyclePreviewView: View {
    @Bindable var store: AppStore; @State var cycle: PlanningCycle
    @Environment(\.dismiss) private var dismiss
    @State private var excluded = Set<String>(); @State private var replace = false; @State private var busy = false; @State private var message: String?
    @State private var requestID = newID()
    private var selected: PlanningCycle { var c = cycle; c.days.removeAll { excluded.contains($0.id) }; return c }
    private var duplicateDates: Bool { Set(cycle.days.map(\.date)).count != cycle.days.count }
    private var invalidRecovery: Bool { cycle.days.contains { ($0.recoveryActivity?.count ?? 0) > 240 || $0.recoveryActivity.map { !$0.isEmpty && $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true } }
    private var payloadRevision: String { (try? Wire.data(cycle).base64EncodedString()) ?? "" }
    var body: some View {
        NavigationStack { Form {
            Section("安排周期") {
                TextField("名称",text: $cycle.name)
                DatePicker("开始日期",selection: Binding(get: { DayKey.date(cycle.startDate,zone: cycle.timezone) ?? Date() },set: { cycle.shift(to: $0) }),displayedComponents: .date)
                Text("\(cycle.startDate) — \(cycle.endDate) · 选择 \(selected.days.count) / \(cycle.days.count) 天").font(.subheadline)
                Button("回到聊天调整周期或要求") { store.coachPromptDraft = "请调整刚才的\(cycle.kind == "diet" ? "饮食" : "训练")周期计划："; store.selectedTab = "coach"; dismiss() }
            }
            ForEach($cycle.days) { $day in
                Section(day.date) {
                    Toggle("采用这一天",isOn: Binding(get: { !excluded.contains(day.id) },set: { if $0 { excluded.remove(day.id) } else { excluded.insert(day.id) }; requestID = newID() }))
                    if store.scheduled(cycle.kind,date: day.date) != nil { Text("这一天已有安排").font(.caption).foregroundStyle(.orange) }
                    DatePicker("安排日期",selection: Binding(get: { DayKey.date(day.date,zone: cycle.timezone) ?? Date() },set: { day.date = DayKey.string($0,zone: cycle.timezone); updateRange() }),displayedComponents: .date)
                    if cycle.kind == "training" {
                        if day.rest {
                            Label("力量训练休息日",systemImage: "leaf")
                            TextField("恢复活动（可选）", text: Binding(get: { day.recoveryActivity ?? "" }, set: { day.recoveryActivity = $0.isEmpty ? nil : $0 }), axis: .vertical)
                        }
                        else if let plan = day.plan, let d = plan.days.first { Text(d.name).font(.headline); ForEach(d.exercises) { e in NavigationLink { ExerciseGuideView(store: store,exerciseId: e.exerciseId,name: e.name) } label: { Text("\(e.name) · \(e.sets.count) 组") } } }
                    } else {
                        ForEach($day.meals) { $meal in DisclosureGroup(meal.name) { TextField("餐次名称",text: $meal.name); TextField("食物与份量",text: Binding(get: { meal.foods.joined(separator: "、") },set: { meal.foods = [$0] }),axis: .vertical); Text(meal.preparation).font(.footnote); ForEach(Array(meal.alternatives.enumerated()),id: \.offset) { _,text in Text(text).font(.caption) } } }
                    }
                }
            }
            Section("遇到已有安排") { Toggle("替换可修改的计划",isOn: $replace); Text("关闭时只填空白日期。替换保留实际饮食记录；已开始或已结束的训练日期始终保留。整批采用在服务器一次完成。").font(.caption).foregroundStyle(.secondary) }
            if duplicateDates { Section { Text("有重复日期，请调整后再采用。").foregroundStyle(.red) } }
            if invalidRecovery { Section { Text("恢复活动最多 240 字，不能只填空格。").foregroundStyle(.red) } }
            if let message { Section { Text(message).foregroundStyle(.red) } }
            Section { Button(busy ? "正在采用…" : "采用所选 \(selected.days.count) 天") { Task { busy = true; defer { busy = false }; do { let result = try await store.adoptCycle(selected,replace: replace,requestId: requestID); dismiss(); store.error = result } catch { message = error.localizedDescription } } }.disabled(busy || selected.days.isEmpty || duplicateDates || invalidRecovery || cycle.name.isEmpty).accessibilityIdentifier("adopt-cycle") }
        }.navigationTitle("计划预览").toolbar { ToolbarItem(placement: .cancellationAction) { Button("继续沟通") { dismiss() }.disabled(busy) } }.interactiveDismissDisabled(busy).onChange(of: payloadRevision) { _,_ in requestID = newID() }.onChange(of: replace) { _,_ in requestID = newID() } }
    }
    private func updateRange() { cycle.startDate = cycle.days.map(\.date).min() ?? cycle.startDate; cycle.endDate = cycle.days.map(\.date).max() ?? cycle.endDate }
}
