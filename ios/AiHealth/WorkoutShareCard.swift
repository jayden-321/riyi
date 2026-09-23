import SwiftUI
import UIKit

struct WorkoutShareHeart {
    let mean: Double
    let maximum: Double
}

struct WorkoutShareImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct WorkoutShareSheet: UIViewControllerRepresentable {
    let image: UIImage
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct WorkoutShareCard: View {
    let workout: Workout
    let heart: WorkoutShareHeart?
    let energyKcal: Double?
    private let ink = Color(red: 0.10, green: 0.31, blue: 0.25)
    private let muted = Color(red: 0.43, green: 0.54, blue: 0.47)
    private let pale = Color(red: 0.95, green: 0.98, blue: 0.94)
    private var completedExercises: [WorkoutExercise] {
        workout.exercises.filter { $0.sets.contains(where: { $0.status == "completed" }) }
    }
    private var focus: [String] {
        var result: [String] = []
        for exercise in completedExercises {
            guard let guide = ExerciseGuide.find(id: exercise.exerciseId, name: exercise.name) else { continue }
            for part in guide.bodyParts where !["全部", "热身动作", "拉伸"].contains(part) && !result.contains(part) {
                result.append(part)
            }
        }
        return Array(result.prefix(4))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("日益").font(.title.bold())
                Spacer()
                Text("训练总结").font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.white.opacity(0.8), in: Capsule())
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(workout.startedAt.formatted(.dateTime.year().month().day().weekday(.wide)))
                    .font(.subheadline).foregroundStyle(muted)
                Text(workout.name).font(.system(size: 27, weight: .bold)).lineLimit(2)
                Text(workout.activity.map { sportTitle($0.resolvedSport) } ?? "力量训练")
                    .font(.subheadline).foregroundStyle(muted)
            }
            HStack(spacing: 10) {
                metric("运动时长", "\(Int(workout.elapsedSeconds(at: workout.finishedAt ?? Date()) / 60))", "分钟")
                if workout.activity == nil {
                    metric("实际容量", (workout.completedVolumeKg / 1000).formatted(.number.precision(.fractionLength(0...2))), "吨")
                    metric("完成组数", "\(workout.completedSets)", "组")
                } else if let meters = workout.actualDistanceMeters {
                    metric("实际距离", meters.formatted(.number.precision(.fractionLength(0...1))), "米")
                }
            }
            if let heart {
                HStack(spacing: 8) {
                    Image(systemName: "heart.fill").foregroundStyle(.red)
                    Text("心率采样均值 \(Int(heart.mean.rounded())) · 最高 \(Int(heart.maximum.rounded())) 次/分")
                }.font(.subheadline.bold()).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
            }
            if let energyKcal {
                HStack(spacing: 8) {
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                    Text("Apple 健康记录活动能量 \(Int(energyKcal.rounded())) 千卡")
                }.font(.subheadline.bold()).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
            }
            if !focus.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("本次练到").font(.headline)
                    HStack(spacing: 6) {
                        Image(systemName: "figure.strengthtraining.traditional").font(.title2)
                        ForEach(focus, id: \.self) { part in
                            Text(part).font(.caption.bold()).padding(.horizontal, 9).padding(.vertical, 6)
                                .background(Color(red: 0.85, green: 0.93, blue: 0.86), in: Capsule())
                        }
                    }
                }
            }
            if !completedExercises.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("动作明细").font(.title3.bold())
                    ForEach(Array(completedExercises.prefix(8))) { exercise in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(exercise.name).font(.headline)
                            let sets = exercise.sets.filter { $0.status == "completed" }
                            Text(sets.prefix(8).enumerated().map { index, set in
                                "\(index + 1)  \((set.actualWeight ?? 0).formatted()) kg × \(set.actualReps ?? 0)"
                            }.joined(separator: "   ·   "))
                                .font(.caption).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                            if sets.count > 8 { Text("另有 \(sets.count - 8) 组已完成").font(.caption2).foregroundStyle(muted) }
                        }
                    }
                    if completedExercises.count > 8 { Text("另有 \(completedExercises.count - 8) 个已练动作").font(.caption).foregroundStyle(muted) }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 18))
            }
            Text("仅汇总已保存的实际训练；未记录的热量和心率不会补算。")
                .font(.caption2).foregroundStyle(muted)
        }
        .padding(22).frame(width: 360, alignment: .leading)
        .background(pale).foregroundStyle(ink)
    }
    private func metric(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption2).foregroundStyle(muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title2.bold()).minimumScaleFactor(0.7)
                Text(unit).font(.caption).foregroundStyle(muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 15))
    }
}

struct WorkoutSummaryView: View {
    @Bindable var store: AppStore
    let workout: Workout
    @State private var heart: WorkoutShareHeart?
    @State private var energyKcal: Double?
    @State private var loading = false
    @State private var sharing = false
    @State private var shareImage: WorkoutShareImage?
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                WorkoutShareCard(workout: workout, heart: heart, energyKcal: energyKcal)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .shadow(color: Color.black.opacity(0.06), radius: 14, y: 7)
                if loading { ProgressView("正在读取心率统计…") }
                else if heart == nil {
                    Text("本次暂无可关联的手表心率采样；分享图不会显示虚构数值。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                Button { Task { await share() } } label: {
                    Label(sharing ? "正在生成图片…" : "分享这张训练总结", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(sharing || loading)
                Text("图片仅在这台手机生成；是否发送给别人由你在系统分享面板决定。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 18)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.cream)
        .navigationTitle("训练总结")
        .task(id: workout.id) { await load() }
        .sheet(item: $shareImage) { image in WorkoutShareSheet(image: image.image) }
    }
    private func load() async {
        guard store.signedIn && !store.isDemo else { return }
        loading = true; defer { loading = false }
        do {
            let data = try await store.network.request("/v1/workouts/\(workout.id)/insights")
            let result: WorkoutInsights = try Wire.read(data)
            if let value = result.heartRate { heart = WorkoutShareHeart(mean: value.pointMeanBpm, maximum: value.maxBpm) }
            else { heart = nil }
            energyKcal = result.activeEnergyKcal
            note = nil
        } catch { note = "云端统计暂不可用；本机已保存的训练内容仍可预览和分享。" }
    }
    private func share() async {
        sharing = true; defer { sharing = false }
        let renderer = ImageRenderer(content: WorkoutShareCard(workout: workout, heart: heart, energyKcal: energyKcal))
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(width: 360, height: nil)
        if let image = renderer.uiImage { shareImage = WorkoutShareImage(image: image) }
        else { note = "图片暂时无法生成，请稍后重试。" }
    }
}
