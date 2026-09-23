import SwiftUI
import WatchKit
import HealthKit
import WatchConnectivity

@main struct AiHealthWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) var delegate
    var body: some Scene { WindowGroup { WatchTrainingView(store: .shared) } }
}
final class WatchDelegate: NSObject, WKApplicationDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in WatchStore.shared.startRequested = true; WatchStore.shared.flush() }
    }
    func handleActiveWorkoutRecovery() { Task { @MainActor in WatchStore.shared.health.recover() } }
    private var pendingTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    private var completionTimer: Timer?
    private var deadline = Date()
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let connectivity = task as? WKWatchConnectivityRefreshBackgroundTask { pendingTasks.append(connectivity) }
            else { task.setTaskCompletedWithSnapshot(false) }
        }
        deadline = Date().addingTimeInterval(15)
        completionTimer?.invalidate()
        completionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let idle = WCSession.default.activationState == .activated && !WCSession.default.hasContentPending && !CompanionTransport.hasPendingDelivery
            if idle || Date() >= self.deadline {
                self.pendingTasks.forEach { $0.setTaskCompletedWithSnapshot(false) }; self.pendingTasks.removeAll()
                self.completionTimer?.invalidate(); self.completionTimer = nil
            }
        }
    }
}
struct WatchTrainingView: View {
    @Bindable var store: WatchStore
    @State private var weight = 0.0
    @State private var reps = 0
    @State private var skipConfirm = false
    @State private var activityFinishConfirm = false
    @State private var strengthFinishConfirm = false
    @State private var selectedOfferIndex = 0
    @State private var editDraft: WatchActualDraft?
    @State private var showStatus = false
    @Environment(\.scenePhase) var scenePhase
    private let green = Color(red: 0.10, green: 0.37, blue: 0.27)
    private let cream = Color(red: 0.96, green: 0.98, blue: 0.94)
    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                VStack(alignment: .leading, spacing: 5) {
                    if let workout = store.displayWorkout {
                        if workout.status == "in_progress", workout.pausedAt != nil {
                            Text("训练已暂停").font(.headline)
                            Text("已运动 \(Int(workout.elapsedSeconds(at: timeline.date) / 60)) 分钟").font(.caption)
                            Button("继续训练") { store.controlWorkout("resume_workout") }
                                .buttonStyle(.plain).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 42).background(green, in: Capsule())
                            Button("停止并保存") { strengthFinishConfirm = workout.activity == nil; activityFinishConfirm = workout.activity != nil }
                                .font(.caption).buttonStyle(.plain)
                        } else if workout.status == "in_progress", let (exercise, set) = CompanionCore.current(workout) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(exercise.name).font(.system(size: 18, weight: .bold)).lineLimit(2).minimumScaleFactor(0.75)
                                Spacer(minLength: 0)
                                Text("\(workout.completedSets)/\(workout.totalSets)").font(.system(size: 11).monospacedDigit())
                            }
                            Text("计划 \(set.plannedWeight.formatted()) kg × \(set.plannedReps) · \(loadNames[exercise.loadBasis] ?? exercise.loadBasis)")
                                .font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.7)
                            Button {
                                editDraft = WatchActualDraft(sessionId: workout.id, setId: set.id, expectedSet: CompanionCore.token(set), weight: weight, reps: reps)
                            } label: {
                                HStack(spacing: 5) { Text("实际 \(weight.formatted()) kg × \(reps)"); Image(systemName: "pencil") }
                                    .font(.system(size: 15, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7).frame(height: 24)
                            }.buttonStyle(.plain)
                            let remaining = CompanionCore.remaining(workout, now: timeline.date)
                            Text(remaining > 0 ? "休息 \(remaining) 秒" : set.startedAt == nil ? "准备下一组" : "本组进行中")
                                .font(.system(size: 12, weight: .medium).monospacedDigit()).frame(height: 16)
                            HStack(spacing: 7) {
                                Button {
                                    store.act(set.startedAt == nil ? "start" : "complete", weight: weight, reps: reps)
                                } label: {
                                    Text(set.startedAt == nil ? "开始本组" : "完成本组").font(.system(size: 15, weight: .semibold))
                                        .frame(maxWidth: .infinity, minHeight: 42)
                                }.buttonStyle(.plain).foregroundStyle(.white).background(green, in: Capsule())
                                Button("跳过") { skipConfirm = true }.font(.system(size: 12)).buttonStyle(.plain)
                                    .frame(width: 38, height: 42).background(green.opacity(0.1), in: Capsule())
                                Button("结束") { strengthFinishConfirm = true }.font(.system(size: 12)).buttonStyle(.plain)
                                    .frame(width: 38, height: 42).background(green.opacity(0.1), in: Capsule())
                            }
                            .confirmationDialog("跳过当前组？", isPresented: $skipConfirm) { Button("跳过") { store.act("skip") } }
                            HStack {
                                Button("暂停") { store.controlWorkout("pause_workout") }
                                Spacer()
                                Button("停止并保存") { strengthFinishConfirm = true }
                            }.font(.system(size: 11)).buttonStyle(.plain)
                            .task(id: set.id) { weight = set.actualWeight ?? set.plannedWeight; reps = set.actualReps ?? set.plannedReps }
                        } else if let activity = workout.activity {
                            Text(activity.name).font(.headline)
                            Text(workout.status == "in_progress" ? "已运动 \(Int(workout.elapsedSeconds(at: timeline.date) / 60)) 分钟" : "本次训练已结束")
                                .font(.caption).monospacedDigit()
                            if let target = activity.targetMinutes { Text("目标 \(target) 分钟").font(.caption2) }
                            if let meters = store.health.distanceMeters { Text("已记录 \(Int(meters)) 米").font(.caption2).monospacedDigit() }
                            if activity.resolvedSport == "swimming" { Text("游泳结束后先解锁入水锁定").font(.caption2) }
                            if workout.status == "in_progress" {
                                Button("暂停") { store.controlWorkout("pause_workout") }.font(.caption).buttonStyle(.plain)
                                Button(store.replica.events.contains(where: { $0.action == "finish_activity" && $0.sessionId == workout.id }) ? "等待手机确认…" : "完成本次运动") { activityFinishConfirm = true }
                                    .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 42)
                                    .buttonStyle(.plain).foregroundStyle(.white).background(green, in: Capsule())
                                    .disabled(store.replica.events.contains(where: { $0.action == "finish_activity" && $0.sessionId == workout.id }))
                            }
                        } else {
                            Text(workout.status == "in_progress" ? "本次组已完成" : "训练已结束").font(.headline)
                            Text("\(workout.completedSets) / \(workout.totalSets) 组").font(.caption)
                            if workout.status == "in_progress" {
                                HStack {
                                    Button("暂停") { store.controlWorkout("pause_workout") }
                                    Button("停止并保存") { strengthFinishConfirm = true }
                                }.font(.caption).buttonStyle(.plain)
                            }
                            else if selectedOffer != nil { todayStartButton }
                        }
                        HStack(spacing: 5) {
                            Image(systemName: "heart.fill")
                            if let bpm = store.health.bpm, let observed = store.health.observedAt, timeline.date.timeIntervalSince(observed) < 30 {
                                Text("\(Int(bpm)) 次/分").monospacedDigit()
                            } else { Text(store.health.needsAuthorization ? "等待健康授权" : "心率 —") }
                            Spacer(minLength: 0)
                            if !store.replica.events.isEmpty { Image(systemName: "arrow.triangle.2.circlepath") }
                        }.font(.system(size: 13, weight: .medium)).frame(height: 20)
                    } else {
                        if let offer = selectedOffer {
                            Text(offer.day.name).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                            Text("\(sportTitle(offer.plan.resolvedCategory)) · \(selectedOfferIndex + 1)/\(store.todayOffers.count) · 左右滑动切换").font(.caption2)
                        } else if let name = store.todayStatus?.activityName {
                            Text(name).font(.headline)
                            Text("今日训练 · 请在 iPhone 开始").font(.caption)
                        } else if store.todayStatus?.kind == "rest" {
                            Text("今天是休息日").font(.headline)
                            Text("今天没有训练任务，按计划恢复").font(.caption)
                        } else if store.todayStatus?.kind == "unplanned" {
                            Text("今天没有安排训练").font(.headline)
                            Text("可在 iPhone 训练日历中安排").font(.caption)
                        } else {
                            Text("等待今日训练任务").font(.headline)
                            Text("请保持与 iPhone 连接").font(.caption)
                        }
                        if selectedOffer != nil { todayStartButton }
                    }
                    Button { showStatus = true } label: {
                        Text(store.error != nil ? "同步遇到问题，点此查看" : store.replica.displayMessage)
                            .font(.system(size: 10)).lineLimit(2).minimumScaleFactor(0.8)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }.padding(.horizontal, 10).padding(.top, 34).padding(.bottom, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(.container, edges: .top).background(cream).foregroundStyle(green)
                    .overlay(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 8).fill(green).frame(width: 66, height: 23)
                            .padding(.trailing, 10).padding(.top, 15).offset(y: -geometry.safeAreaInsets.top).allowsHitTesting(false)
                    }
            }
        }.gesture(DragGesture(minimumDistance: 25).onEnded { value in
            guard store.displayWorkout?.status != "in_progress", store.todayOffers.count > 1 else { return }
            if value.translation.width < -25 { selectedOfferIndex = min(store.todayOffers.count - 1, selectedOfferIndex + 1) }
            if value.translation.width > 25 { selectedOfferIndex = max(0, selectedOfferIndex - 1) }
        })
        .confirmationDialog("结束并保存这次力量训练？未完成的组将标为跳过。", isPresented: $strengthFinishConfirm) {
            Button("结束训练") { store.finishStrength() }
        }
        .confirmationDialog("结束并保存这次运动？", isPresented: $activityFinishConfirm) {
            Button("完成运动") { store.finishActivity() }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { store.flush() } }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--watch-editor-demo"),
               let workout = store.replica.projected, let (_, set) = CompanionCore.current(workout) {
                editDraft = WatchActualDraft(sessionId: workout.id, setId: set.id, expectedSet: CompanionCore.token(set), weight: 42.5, reps: 8)
            }
            #endif
        }
        .sheet(item: $editDraft) { draft in
            WatchActualEditor(draft: draft) { newWeight, newReps in
                guard let workout = store.replica.projected, workout.id == draft.sessionId,
                      let (_, current) = CompanionCore.current(workout), current.id == draft.setId,
                      CompanionCore.token(current) == draft.expectedSet else {
                    store.error = "这一组已更新，未修改其它组。请返回核对。"; editDraft = nil; return
                }
                weight = newWeight; reps = newReps; editDraft = nil
            }
        }
        .sheet(isPresented: $showStatus) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.health.status)
                    if let zone = store.health.zoneText { Text(zone) }
                    Text(store.replica.displayMessage)
                    if let error = store.error { Text(error).foregroundStyle(.red) }
                    if store.health.needsAuthorization { Button("完成健康授权") { Task { await store.enableHealth() } } }
                }.font(.caption).padding()
            }.background(cream).foregroundStyle(green)
        }
    }
    private var selectedOffer: CompanionStartOffer? {
        let offers = store.todayOffers
        return offers.indices.contains(selectedOfferIndex) ? offers[selectedOfferIndex] : offers.first
    }
    private var todayStartButton: some View {
        Button {
            if let selectedOffer { store.startToday(offer: selectedOffer) }
        } label: {
            Text(store.replica.pendingStart != nil ? "等待手机确认…" : selectedOffer?.lastStatus == "completed" || selectedOffer?.lastStatus == "cancelled" ? "重新开始此项目" : "开始此项目")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 42)
        }.buttonStyle(.plain).foregroundStyle(.white).background(green, in: Capsule())
            .disabled(!store.canStartToday)
    }
}

struct WatchActualDraft: Identifiable {
    var id: String { setId }
    let sessionId: String
    let setId: String
    let expectedSet: String
    let weight: Double
    let reps: Int
}

/// Keep the edit draft outside TimelineView and independent of incoming workout snapshots.
struct WatchActualEditor: View {
    @State private var weight: Double
    @State private var reps: Int
    let save: (Double, Int) -> Void
    private let green = Color(red: 0.10, green: 0.37, blue: 0.27)
    private let cream = Color(red: 0.96, green: 0.98, blue: 0.94)
    init(draft: WatchActualDraft, save: @escaping (Double, Int) -> Void) {
        _weight = State(initialValue: draft.weight); _reps = State(initialValue: draft.reps); self.save = save
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 7) {
                Text("本组实际").font(.system(size: 16, weight: .semibold))
                editorRow(title: "重量 · kg", value: weight.formatted(.number.precision(.fractionLength(0...1))),
                          minusEnabled: weight > 0, plusEnabled: weight < 2000,
                          minus: { weight = max(0, weight - 0.5) }, plus: { weight = min(2000, weight + 0.5) })
                editorRow(title: "次数", value: String(reps), minusEnabled: reps > 0, plusEnabled: reps < 1000,
                          minus: { reps = max(0, reps - 1) }, plus: { reps = min(1000, reps + 1) })
                Button { save(weight, reps) } label: {
                    Text("确定").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 34)
                }.buttonStyle(.plain).foregroundStyle(.white).background(green, in: Capsule())
            }.padding(.horizontal, 12).padding(.vertical, 4)
        }.background(cream).foregroundStyle(green)
    }
    private func editorRow(title: String, value: String, minusEnabled: Bool, plusEnabled: Bool,
                           minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(green.opacity(0.8))
            HStack(spacing: 6) {
                adjustButton("minus", enabled: minusEnabled, action: minus)
                Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: .infinity)
                adjustButton("plus", enabled: plusEnabled, action: plus)
            }.frame(height: 34)
        }
    }
    private func adjustButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).frame(width: 34, height: 34) }
            .buttonStyle(.plain).background(green.opacity(0.12), in: Circle()).disabled(!enabled)
            .accessibilityLabel(symbol == "plus" ? "增加" : "减少")
    }
}
