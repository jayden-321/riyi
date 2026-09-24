import SwiftUI
import ImageIO

struct ExerciseGuide: Decodable, Identifiable {
    var id: String; var name: String; var aliases: [String]; var muscles: String; var equipment: String
    var secondaryMuscles: String; var equipmentGroup: String; var bodyParts: [String]
    var category: String; var level: String; var images: [String]
    var steps: [String]; var tips: [String]; var mistakes: [String]
    var sourceId: String; var repBased: Bool; var coachEligible: Bool

    static let parts = ["全部", "胸", "上胸", "中下胸", "背", "腿", "肩", "前锯肌", "斜方肌", "二头", "三头", "小腿", "前臂", "颈部", "功能性", "核心稳定", "腹部", "热身动作", "拉伸", "有氧"]
    static let equipmentGroups = ["全部器械", "杠铃", "哑铃", "绳索", "器械", "自重", "壶铃", "弹力带", "曲杆", "药球", "健身球", "泡沫轴", "其他"]
    static let all: [ExerciseGuide] = {
        guard let url = Bundle.main.url(forResource: "exercise_guides", withExtension: "json"), let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode([ExerciseGuide].self, from: data)) ?? []
    }()
    static func find(id: String, name: String) -> ExerciseGuide? {
        if let exact = all.first(where: { $0.id == id || $0.sourceId == id }) { return exact }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = all.filter { $0.name.localizedCaseInsensitiveCompare(cleaned) == .orderedSame || $0.aliases.contains(where: { $0.localizedCaseInsensitiveCompare(cleaned) == .orderedSame }) }
        // Ambiguous aliases must never silently attach a different exercise's pictures.
        return matches.count == 1 ? matches.first : nil
    }
    func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let haystack = ([name, muscles, secondaryMuscles, equipment, equipmentGroup] + aliases + bodyParts).joined(separator: " ")
        return words.allSatisfy { haystack.localizedStandardContains($0) }
    }
    var sourceURL: URL { URL(string: "https://github.com/yuhonas/free-exercise-db/tree/a859101d633a01c4a1a920d6a8ce41dabba0705f/exercises/" + sourceId + ".json")! }
}

struct ExercisePhoto: View {
    let filename: String; var pixels = 420
    var onPhotoTap: (() -> Void)? = nil
    @State private var photo: UIImage?
    @State private var failed = false
    @State private var retry = 0
    var body: some View {
        Group {
            if let photo {
                if let onPhotoTap {
                    Button(action: onPhotoTap) { Image(uiImage: photo).resizable().scaledToFit().accessibilityIdentifier("exercise-photo") }.buttonStyle(.plain)
                } else {
                    Image(uiImage: photo).resizable().scaledToFit().accessibilityIdentifier("exercise-photo")
                }
            } else if failed {
                Button { retry += 1 } label: {
                    VStack(spacing: 6) { Image(systemName: "arrow.clockwise"); Text("点此重试").font(.caption2) }
                        .foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                }.buttonStyle(.plain).accessibilityLabel("图片加载失败，点此重试")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.task(id: "\(filename):\(pixels):\(retry)") {
            failed = false
            do {
                let data = try await ExerciseMediaCache.shared.data(filename: filename, thumbnail: pixels <= 420)
                try Task.checkCancellation()
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { failed = true; return }
                photo = UIImage(cgImage: image)
            } catch { if !Task.isCancelled { failed = true } }
        }.onDisappear { photo = nil }
    }
}

struct ExerciseLibraryView: View {
    @Bindable var store: AppStore
    var onSelect: ((ExerciseGuide) -> Void)? = nil
    var selectRepBasedOnly = false
    @State private var query = ""
    @State private var part = "全部"
    @State private var equipment = "全部器械"
    private var filtered: [ExerciseGuide] {
        ExerciseGuide.all.filter { (!selectRepBasedOnly || $0.repBased) && (part == "全部" || $0.bodyParts.contains(part)) && (equipment == "全部器械" || $0.equipmentGroup == equipment) && $0.matches(query) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("搜索动作、器械或英文名称", text: $query).autocorrectionDisabled().accessibilityIdentifier("exercise-library-search")
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("清空搜索") }
            }.padding(13).background(.white, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 16).padding(.bottom, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ExerciseGuide.equipmentGroups, id: \.self) { item in
                        Button { equipment = item } label: {
                            Text(item).font(.subheadline.weight(equipment == item ? .semibold : .regular)).padding(.horizontal, 14).padding(.vertical, 9)
                                .background(equipment == item ? Theme.green : Color.white, in: Capsule()).foregroundStyle(equipment == item ? .white : Theme.ink)
                        }.accessibilityIdentifier("equipment-\(item)").accessibilityAddTraits(equipment == item ? .isSelected : [])
                    }
                }.padding(.horizontal, 16)
            }.padding(.bottom, 12)
            HStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(ExerciseGuide.parts, id: \.self) { item in
                            Button { part = item } label: {
                                Text(item).font(.system(size: 14, weight: part == item ? .bold : .regular)).frame(maxWidth: .infinity).padding(.vertical, 15)
                                    .background(part == item ? Color.white : Color.clear).foregroundStyle(part == item ? Theme.green : Theme.muted)
                                    .overlay(alignment: .leading) { if part == item { Capsule().fill(Theme.green).frame(width: 3, height: 22) } }
                            }.accessibilityIdentifier("body-part-\(item)").accessibilityAddTraits(part == item ? .isSelected : [])
                        }
                    }
                }.frame(width: 75).background(Theme.green.opacity(0.035))
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack { Text(part == "全部" ? "全部动作" : part).font(.headline); Spacer(); Text("\(filtered.count) 个").font(.caption).foregroundStyle(Theme.muted) }.id("top")
                            if filtered.isEmpty {
                                ContentUnavailableView("没有匹配的动作", systemImage: "magnifyingglass", description: Text("试试其他名称，或清除部位和器械筛选。"))
                                Button("清除筛选") { query = ""; part = "全部"; equipment = "全部器械" }.buttonStyle(.bordered)
                            }
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
                                ForEach(filtered) { guide in
                                    NavigationLink {
                                        ExerciseGuideView(store: store, exerciseId: guide.id, name: guide.name, onSelect: onSelect)
                                    } label: { ExerciseCard(guide: guide) }.buttonStyle(.plain).accessibilityIdentifier("exercise-card-\(guide.id)")
                                }
                            }
                            Text("\(ExerciseGuide.all.count) 个动作 · 图片按需加载").font(.caption2).foregroundStyle(Theme.muted).padding(.top, 8)
                        }.padding(12)
                    }.onChange(of: part) { _, _ in proxy.scrollTo("top", anchor: .top) }
                        .onChange(of: equipment) { _, _ in proxy.scrollTo("top", anchor: .top) }
                        .onChange(of: query) { _, _ in proxy.scrollTo("top", anchor: .top) }
                }.background(.white.opacity(0.4))
            }
        }.background(Theme.cream).navigationTitle(onSelect == nil ? "动作库" : "选择动作").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { ExerciseSourcesView() } label: { Image(systemName: "info.circle") }.accessibilityLabel("动作资料来源") } }
    }
}

private struct ExerciseCard: View {
    let guide: ExerciseGuide
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let first = guide.images.first {
                ExercisePhoto(filename: first).frame(height: 105).frame(maxWidth: .infinity).background(Color.white)
            } else {
                VStack(spacing: 8) { Image(systemName: "text.book.closed").font(.title2); Text("文字教学").font(.caption) }
                    .foregroundStyle(Theme.muted).frame(height: 105).frame(maxWidth: .infinity).background(Theme.cream)
            }
            Text(guide.name).font(.system(size: 14, weight: .semibold)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            Text(guide.equipmentGroup + " · " + guide.level).font(.caption2).foregroundStyle(Theme.muted)
        }.padding(9).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Theme.green.opacity(0.08)))
            .accessibilityElement(children: .combine)
    }
}

struct ExerciseGuideView: View {
    @Bindable var store: AppStore; let exerciseId: String; let name: String
    var onSelect: ((ExerciseGuide) -> Void)? = nil
    @State private var explanation: String?
    @State private var imageIndex = 0
    @State private var fullScreen = false
    private var guide: ExerciseGuide? { ExerciseGuide.find(id: exerciseId, name: name) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let guide {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(guide.name).font(.title2.bold())
                        Text(guide.equipment + " · " + guide.level).font(.subheadline).foregroundStyle(Theme.muted)
                    }
                    if guide.images.isEmpty {
                        Label("暂无可用图解 · 请阅读下方动作要点", systemImage: "text.book.closed").font(.subheadline).foregroundStyle(Theme.muted).padding(18)
                    } else {
                    VStack(spacing: 10) {
                        TabView(selection: $imageIndex) {
                            ForEach(Array(guide.images.enumerated()), id: \.offset) { index, filename in
                                ExercisePhoto(filename: filename, pixels: index == imageIndex ? 1000 : 420, onPhotoTap: { fullScreen = true }).frame(maxWidth: .infinity, maxHeight: .infinity).tag(index)
                                    .accessibilityLabel("放大动作照片 \(index + 1)")
                            }
                        }.frame(height: 240).tabViewStyle(.page(indexDisplayMode: .never))
                        HStack(spacing: 12) {
                            ForEach(Array(guide.images.enumerated()), id: \.offset) { index, filename in
                                Button { imageIndex = index } label: {
                                    ExercisePhoto(filename: filename, pixels: 160).frame(width: 65, height: 46).clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(imageIndex == index ? Theme.green : .clear, lineWidth: 2))
                                }.accessibilityLabel("示范照片 \(index + 1)")
                            }
                            Spacer()
                            Text("\(imageIndex + 1) / \(guide.images.count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption).foregroundStyle(Theme.muted)
                        }.padding(.horizontal, 12)
                        Text("左右滑动查看 · 点图片放大").font(.caption2).foregroundStyle(Theme.muted)
                    }.padding(.vertical, 12).background(.white, in: RoundedRectangle(cornerRadius: 20))
                    }
                    HStack(alignment: .top, spacing: 15) {
                        VStack(alignment: .leading, spacing: 5) { Text("主要部位").font(.caption).foregroundStyle(Theme.muted); Text(guide.muscles).font(.subheadline.bold()) }
                        Spacer()
                        VStack(alignment: .leading, spacing: 5) { Text("训练类型").font(.caption).foregroundStyle(Theme.muted); Text(guide.category).font(.subheadline.bold()) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 16))
                    if !guide.secondaryMuscles.isEmpty { Text("辅助部位：\(guide.secondaryMuscles)").font(.footnote).foregroundStyle(Theme.muted) }
                    copySection("动作要点", items: guide.tips, numbered: false)
                    copySection("怎么做", items: guide.steps, numbered: true)
                    copySection("常见错误", items: guide.mistakes, numbered: false)
                    if guide.level == "高级" || guide.category == "奥林匹克举重" || guide.bodyParts.contains("颈部") || guide.name.contains("颈后") || guide.name.contains("断头台") {
                        Label("这类动作对技术要求较高，初次练习请由现场教练指导。", systemImage: "person.crop.circle.badge.checkmark").font(.footnote).foregroundStyle(Theme.muted)
                    }
                    Text("先用能控制的负荷熟悉动作，幅度以舒适、稳定为准；出现疼痛或眩晕时停止。").font(.footnote).foregroundStyle(.secondary)
                    NavigationLink { ExerciseSourcesView(source: guide) } label: { Label("图解来源与说明", systemImage: "photo.on.rectangle") }.font(.footnote)
                } else {
                    Text(name).font(.title2.bold())
                    Text("未找到准确匹配的动作，请在动作库中确认器械和做法。").foregroundStyle(.secondary)
                    NavigationLink("浏览动作库") { ExerciseLibraryView(store: store) }
                    if !store.isDemo && store.settings.aiConsent {
                        Button(store.coachBusy ? "正在讲解…" : "请 AI 讲解这个动作") {
                            Task { if await store.sendCoach("请讲解“\(name)”这个动作的起始姿势、步骤和常见错误。只讲动作，不制定训练计划；如果名称不能确定具体做法，请先询问器械。") { explanation = store.coach?.runs.first?.result?.message } }
                        }.buttonStyle(.borderedProminent).disabled(store.coachBusy)
                        if let explanation { Text(explanation).lineSpacing(5) }
                        if let error = store.coachError { Text(error).font(.footnote).foregroundStyle(.red) }
                    }
                }
            }.padding(20)
        }.background(Theme.cream).navigationTitle("动作说明").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if let onSelect, let guide {
                    VStack(spacing: 6) {
                        Button { onSelect(guide) } label: { Text("添加到训练日").bold().frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.borderedProminent).disabled(!guide.repBased)
                        if !guide.repBased { Text("此动作主要按时间或距离记录，当前计划暂只支持次数；可在动作库查看教学。").font(.caption).foregroundStyle(.secondary) }
                    }.padding().background(.regularMaterial)
                }
            }
            .sheet(isPresented: $fullScreen) {
                if let guide { ExercisePhotoViewer(guide: guide, index: imageIndex) }
            }
    }
    private func copySection(_ title: String, items: [String], numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 10) {
                    Text(numbered ? String(index + 1) : "·").font(.subheadline.bold()).foregroundStyle(Theme.green).frame(width: 20)
                    Text(item).font(.subheadline).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct ExercisePhotoViewer: View {
    let guide: ExerciseGuide
    @State var index: Int
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(Array(guide.images.enumerated()), id: \.offset) { n, filename in
                    ZoomableExercisePhoto(filename: filename).tag(n)
                }
            }.tabViewStyle(.page).background(.black).navigationTitle("\(guide.name) · \(index + 1)/\(guide.images.count)").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.black, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) { Text("\(guide.name) · \(index + 1)/\(guide.images.count)").font(.headline).foregroundStyle(.white) }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.foregroundStyle(.white) }
                }
        }
    }
}

private struct ZoomableExercisePhoto: View {
    let filename: String
    @State private var image: UIImage?
    @State private var failed = false
    @State private var retry = 0
    var body: some View {
        Group {
            if let image { ExerciseZoomCanvas(image: image) }
            else if failed { Button("加载失败，点此重试") { retry += 1 }.foregroundStyle(.white) }
            else { ProgressView().tint(.white) }
        }.task(id: "\(filename):\(retry)") {
            failed = false
            do {
                let data = try await ExerciseMediaCache.shared.data(filename: filename, thumbnail: false)
                try Task.checkCancellation()
                image = UIImage(data: data); failed = image == nil
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

private struct ExerciseZoomCanvas: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 4
        scroll.delegate = context.coordinator; scroll.backgroundColor = .black
        scroll.showsVerticalScrollIndicator = false; scroll.showsHorizontalScrollIndicator = false
        let photo = context.coordinator.photo
        photo.contentMode = .scaleAspectFit; photo.isAccessibilityElement = true
        photo.accessibilityLabel = "动作原图，可双指缩放和拖动查看"; photo.accessibilityIdentifier = "exercise-full-photo"
        scroll.addSubview(photo)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2; scroll.addGestureRecognizer(tap)
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.photo.image = image
        if scroll.zoomScale == 1 { context.coordinator.photo.frame = scroll.bounds; scroll.contentSize = scroll.bounds.size }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIScrollView, context: Context) -> CGSize? {
        let size = CGSize(width: proposal.width ?? 320, height: proposal.height ?? 500)
        if uiView.zoomScale == 1 { context.coordinator.photo.frame = CGRect(origin: .zero, size: size); uiView.contentSize = size }
        return size
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let photo = UIImageView()
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { photo }
        @objc func doubleTap(_ tap: UITapGestureRecognizer) {
            guard let scroll = tap.view as? UIScrollView else { return }
            scroll.setZoomScale(scroll.zoomScale > 1 ? 1 : 2, animated: true)
        }
    }
}

private struct ExerciseSourcesView: View {
    var source: ExerciseGuide? = nil
    var body: some View {
        List {
            Section("动作图解") {
                Text("示范照片来自 Free Exercise DB。列表加载缩略图，打开详情再下载大图；已经查看的图片可在缓存保留期间离线查看。照片是不同动作阶段的静态示范，不是连续视频。")
                Link("查看公开图库与许可", destination: URL(string: "https://github.com/yuhonas/free-exercise-db")!)
                Text("上游许可：公共领域 / Unlicense。图片保留原始内容，未使用 AI 生成。")
                if let source { Link("查看这个动作的原始资料", destination: source.sourceURL) }
            }
            Section("中文教学") {
                Text("中文名称、步骤、动作要点及常见错误由日益根据公开动作资料整理，含 AI 辅助编写内容，未经真人教练逐条审定。")
                Text("目录按部位和器械组织。动作名称与器械变式分别保留；图库没有对应素材时，不用其他动作的照片冒充。")
            }
        }.navigationTitle("动作资料来源").navigationBarTitleDisplayMode(.inline)
    }
}
