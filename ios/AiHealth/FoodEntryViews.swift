import SwiftUI
import PhotosUI
import UIKit

func foodJPEG(_ image: UIImage) -> Data? {
    let longest = max(image.size.width, image.size.height)
    guard longest > 0 else { return nil }
    let format = UIGraphicsImageRendererFormat.default()
    // The default renderer uses the phone's 3x screen scale. That turns a
    // 1600-point preview into a 4800-pixel upload and rejects ordinary photos.
    format.scale = 1
    format.opaque = true
    for limit in [1600.0, 1280.0, 960.0] {
        let scale = min(1, limit / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        for quality in [0.78, 0.68, 0.55, 0.42] as [CGFloat] {
            if let data = rendered.jpegData(compressionQuality: quality), data.count < 1_300_000 { return data }
        }
    }
    return nil
}

struct FoodCameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.modalPresentationStyle = .fullScreen
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage, dismiss: dismiss) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        let dismiss: DismissAction
        init(onImage: @escaping (UIImage) -> Void, dismiss: DismissAction) { self.onImage = onImage; self.dismiss = dismiss }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onImage(image) }
            dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() }
    }
}

private struct FoodPhotoRow: View {
    let title: String
    let hint: String
    @Binding var image: UIImage?
    var onCamera: () -> Void
    @State private var selected: PhotosPickerItem?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8)) }
                else { Image(systemName: "camera.viewfinder").frame(width: 56, height: 56).background(Theme.cream, in: RoundedRectangle(cornerRadius: 8)) }
                VStack(alignment: .leading) { Text(title).font(.headline); Text(hint).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if image != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green) }
            }
            HStack {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("拍照", action: onCamera)
                } else {
                    Text("此设备无相机，请从相册选").font(.caption).foregroundStyle(.secondary)
                }
                PhotosPicker("从相册选", selection: $selected, matching: .images)
            }.buttonStyle(.bordered)
        }.onChange(of: selected) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    await MainActor.run { self.image = image }
                }
            }
        }
    }
}

private enum PackagePhotoSlot: String, Identifiable { case front, nutrition, extra; var id: String { rawValue } }

struct FoodPackageCaptureView: View {
    @Bindable var store: AppStore
    let date: Date
    @Environment(\.dismiss) private var dismiss
    @State private var front: UIImage?
    @State private var nutrition: UIImage?
    @State private var extra: UIImage?
    @State private var cameraSlot: PackagePhotoSlot?
    @State private var extraction: FoodPackageExtraction?
    @State private var reviewing = false
    @State private var didSave = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("拍商品正面和营养成分表。规格和数量通常在正面；没拍清楚时可补一张。").font(.footnote)
                }
                Section("必需照片") {
                    FoodPhotoRow(title: "商品正面", hint: "品牌、名称、净含量与数量", image: $front) { cameraSlot = .front }
                    FoodPhotoRow(title: "营养成分表", hint: "拍清每 100 克或毫升的能量", image: $nutrition) { cameraSlot = .nutrition }
                }
                Section("可选") {
                    FoodPhotoRow(title: "补拍规格", hint: "正面看不清时再拍", image: $extra) { cameraSlot = .extra }
                }
                Section {
                    Button(busy ? "正在识别…" : "AI 整理商品信息") { Task { await analyze() } }.disabled(front == nil || nutrition == nil || busy)
                    Button("手动填写商品资料") { extraction = nil; reviewing = true }
                    Text("识别只生成待核对草稿。照片会传给已配置的 AI 服务；商品库只保存确认后的文字与营养数值。").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.navigationTitle("拍包装加入常用").toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .fullScreenCover(item: $cameraSlot) { slot in
            FoodCameraPicker { image in
                switch slot { case .front: front = image; case .nutrition: nutrition = image; case .extra: extra = image }
            }.ignoresSafeArea()
        }
        .sheet(isPresented: $reviewing, onDismiss: { if didSave { dismiss() } }) {
            FoodPackageReviewView(store: store, date: date, extraction: extraction) { didSave = true }
        }
    }

    private func analyze() async {
        guard let front, let nutrition, let a = foodJPEG(front), let b = foodJPEG(nutrition) else { error = "照片过大或无法读取，请重拍清晰照片"; return }
        busy = true; error = nil; defer { busy = false }
        do { extraction = try await store.extractFoodPackage(front: a, nutrition: b, extra: extra.flatMap(foodJPEG)); reviewing = true }
        catch { self.error = error.localizedDescription }
    }
}

struct FoodPackageReviewView: View {
    @Bindable var store: AppStore
    let date: Date
    let extraction: FoodPackageExtraction?
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false
    @State private var name = ""
    @State private var brand = ""
    @State private var packageAmount = 0.0
    @State private var packageUnit = "g"
    @State private var count = 0.0
    @State private var servingUnit = "只"
    @State private var energy = 0.0
    @State private var energyUnit = "kJ"
    @State private var recordNow = false
    @State private var eaten = 0.0
    @State private var slot = "breakfast"
    @State private var error: String?
    @State private var productToShare: FoodProduct?

    private var preview: FoodProduct {
        FoodProduct(name: name.trimmingCharacters(in: .whitespacesAndNewlines), brand: brand,
                    packageAmount: packageAmount, packageUnit: packageUnit,
                    unitsPerPackage: count > 0 ? count : nil, servingUnit: count > 0 ? servingUnit : "",
                    energyPer100: energy, energyUnit: energyUnit, basisUnit: packageUnit)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("请核对包装") {
                    TextField("商品名称", text: $name)
                    TextField("品牌（识别后请核对）", text: $brand)
                    Text("AI 会把包装上清楚可见的品牌和商品名称分开填写；未读到品牌时可在这里补录。").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("整包净含量", value: $packageAmount, format: .number).keyboardType(.decimalPad)
                        Picker("单位", selection: $packageUnit) { Text("克").tag("g"); Text("毫升").tag("ml") }.labelsHidden()
                    }
                    HStack {
                        TextField("数量", value: $count, format: .number).keyboardType(.decimalPad)
                        TextField("数量单位", text: $servingUnit).frame(width: 60)
                    }
                    if extraction != nil && extraction?.unitsPerPackage == nil {
                        Text("照片未读出数量；按片、只等单位记录前，请从包装其他位置或购买信息核对。").font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        TextField("每 100 克/毫升能量", value: $energy, format: .number).keyboardType(.decimalPad)
                        Picker("标签单位", selection: $energyUnit) { Text("千焦").tag("kJ"); Text("千卡").tag("kcal") }.labelsHidden()
                    }
                    if let each = preview.amountPerUnit { Text("平均每\(servingUnit)约 \(each.formatted(.number.precision(.fractionLength(0...1)))) \(packageUnit == "g" ? "克" : "毫升")").foregroundStyle(Theme.green) }
                    Text("仅按包装平均值换算；营养表的千焦会除以 4.184 转为千卡。").font(.caption).foregroundStyle(.secondary)
                }
                if let extraction, !extraction.warnings.isEmpty { Section("识别提示") { ForEach(extraction.warnings, id: \.self) { Text($0) } } }
                Section("本次实际吃喝") {
                    Toggle("同时记录这次饮食", isOn: $recordNow)
                    if recordNow {
                        Picker("餐次", selection: $slot) { ForEach(mealSlots, id: \.0) { Text($0.1).tag($0.0) } }
                        TextField("实际吃了多少\(servingUnit)", value: $eaten, format: .number).keyboardType(.decimalPad)
                        if let result = preview.calculated(quantity: eaten, unit: servingUnit) { Text("约 \(result.kcal.formatted(.number.precision(.fractionLength(0)))) 千卡 · 按本品标签计算") }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.navigationTitle("核对商品资料").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(store.isDemo ? "保存到常用" : "保存并共享") { save() }.disabled(!preview.valid) }
            }.onAppear { load() }
                .sheet(item: $productToShare, onDismiss: { onSaved(); dismiss() }) { product in
                    FoodShareView(store: store, product: product, autoGenerate: true)
                }
        }
    }
    private func load() {
        guard !loaded else { return }; loaded = true
        name = extraction?.name ?? ""; brand = extraction?.brand ?? ""
        packageAmount = extraction?.packageAmount ?? 0; packageUnit = extraction?.packageUnit ?? "g"
        count = extraction?.unitsPerPackage ?? 0
        let recognized = extraction?.servingUnit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        servingUnit = recognized.isEmpty ? "件" : recognized
        energy = extraction?.energyPer100 ?? 0; energyUnit = extraction?.energyUnit ?? "kJ"
    }
    private func save() {
        let product = preview
        guard product.valid else { error = "请核对商品名称、净含量和每 100 克/毫升能量"; return }
        if recordNow && product.calculated(quantity: eaten, unit: servingUnit) == nil { error = "请填写这次实际吃的数量；若只想存商品，关闭同时记录"; return }
        guard store.save(product, kind: "food", id: product.id) else { error = store.error ?? "商品未保存"; return }
        if recordNow {
            guard let log = store.mealLog(from: product, quantity: eaten, unit: servingUnit, slot: slot, at: mealEntryTime(for: date, zone: store.settings.timezone)), store.save(log, kind: "meal", id: log.id) else {
                error = "商品已存入常用，但这次饮食未保存；请从常用再记录一次。"; return
            }
        }
        if store.isDemo { onSaved(); dismiss() }
        else { productToShare = product }
    }
}

struct FoodCommonView: View {
    @Bindable var store: AppStore
    let date: Date
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var capturing = false
    @State private var importing = false
    private var visible: [FoodProduct] { store.foodProducts.filter { search.isEmpty || $0.name.localizedStandardContains(search) || $0.brand.localizedStandardContains(search) } }
    var body: some View {
        NavigationStack {
            List {
                Section { Button { capturing = true } label: { Label("拍包装，加入常用", systemImage: "camera") } }
                Section { TextField("搜索我的常用", text: $search).textInputAutocapitalization(.never) }
                Section("我的商品") {
                    if visible.isEmpty { Text(store.foodProducts.isEmpty ? "还没有常用商品" : "没有找到匹配商品").foregroundStyle(.secondary) }
                    ForEach(visible) { product in
                        NavigationLink { FoodRecordView(store: store, product: product, date: date) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(product.brand.isEmpty ? product.name : "\(product.brand) · \(product.name)").font(.headline)
                                Text("品牌：\(product.brand.isEmpty ? "未填写" : product.brand)").font(.caption).foregroundStyle(.secondary)
                                Text(product.amountPerUnit.map { "每\(product.servingUnit)约 \($0.formatted(.number.precision(.fractionLength(0...1)))) \(product.basisUnit == "g" ? "克" : "毫升")" } ?? "按\(product.basisUnit == "g" ? "克" : "毫升")记录").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }.navigationTitle("常用").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("导入") { importing = true }.disabled(store.isDemo) }
            }
        }.sheet(isPresented: $capturing) { FoodPackageCaptureView(store: store, date: date) }
         .sheet(isPresented: $importing) { FoodImportView(store: store) }
    }
}

struct FoodRecordView: View {
    @Bindable var store: AppStore
    let product: FoodProduct
    let date: Date
    @Environment(\.dismiss) private var dismiss
    @State private var quantity = 1.0
    @State private var unit = "只"
    @State private var slot = "breakfast"
    @State private var sharing = false
    @State private var error: String?
    private var result: (amount: Double, kcal: Double)? { product.calculated(quantity: quantity, unit: unit) }
    var body: some View {
        Form {
            Section(product.brand.isEmpty ? product.name : "\(product.brand) · \(product.name)") {
                Text("品牌：\(product.brand.isEmpty ? "未填写" : product.brand)").font(.footnote).foregroundStyle(.secondary)
                Text("整包 \(product.packageAmount.formatted()) \(product.packageUnit == "g" ? "克" : "毫升") · 每 100 \(product.basisUnit == "g" ? "克" : "毫升") \(product.energyPer100.formatted()) \(product.energyUnit == "kJ" ? "千焦" : "千卡")").font(.footnote)
                Picker("餐次", selection: $slot) { ForEach(mealSlots, id: \.0) { Text($0.1).tag($0.0) } }
                Picker("数量单位", selection: $unit) {
                    if product.amountPerUnit != nil { Text(product.servingUnit).tag(product.servingUnit) }
                    Text(product.basisUnit == "g" ? "克" : "毫升").tag(product.basisUnit)
                }
                TextField("实际吃了多少\(unit)", value: $quantity, format: .number).keyboardType(.decimalPad)
                if let result { Text("约 \(result.kcal.formatted(.number.precision(.fractionLength(0)))) 千卡 · 按保存的包装数据计算").foregroundStyle(Theme.green) }
                Button("保存实际饮食") { save() }.disabled(result == nil)
            }
            Section { Button("分享商品资料") { sharing = true }.disabled(store.isDemo); Text("只分享商品名称、品牌、规格和营养值，不分享你的饮食记录。").font(.caption).foregroundStyle(.secondary) }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }.navigationTitle("常用商品").onAppear {
            unit = product.amountPerUnit == nil ? product.basisUnit : product.servingUnit
            if let last = store.mealLogs.last(where: { $0.foodProductId == product.id }), let value = last.quantity, value > 0 { quantity = value; unit = last.quantityUnit ?? unit }
        }.sheet(isPresented: $sharing) { FoodShareView(store: store, product: product) }
    }
    private func save() {
        guard let log = store.mealLog(from: product, quantity: quantity, unit: unit, slot: slot, at: mealEntryTime(for: date, zone: store.settings.timezone)) else { error = "请核对本次实际数量"; return }
        guard store.save(log, kind: "meal", id: log.id) else { error = store.error ?? "饮食未保存"; return }
        dismiss()
    }
}

struct FoodShareView: View {
    @Bindable var store: AppStore
    let product: FoodProduct
    var autoGenerate = false
    @Environment(\.dismiss) private var dismiss
    @State private var searchable = true
    @State private var code: String?
    @State private var moderationState: String?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section(product.brand.isEmpty ? product.name : "\(product.brand) · \(product.name)") {
                    Text("品牌：\(product.brand.isEmpty ? "未填写" : product.brand)").font(.footnote).foregroundStyle(.secondary)
                    Text("保存后默认允许其他用户按名称或品牌搜索。只共享商品名称、品牌、规格与营养表，不包含个人饮食记录；你可关闭搜索或撤销分享。").font(.footnote)
                    Toggle("允许其他用户按名称或品牌搜索", isOn: $searchable)
                    if moderationState == "pending" { Text("该商品已进入举报复核，暂不对其他用户显示。").font(.caption).foregroundStyle(.orange) }
                    if moderationState == "removed" { Text("该商品已从公开搜索移除。如有疑问请联系日益支持。").font(.caption).foregroundStyle(.orange) }
                    Button(busy ? "正在生成…" : code == nil ? "生成分享码" : "保存分享设置") { Task { await share() } }
                        .disabled(busy || moderationState == "pending" || moderationState == "removed")
                    if let code {
                        Text(code).textSelection(.enabled).font(.body.monospaced())
                        ShareLink("发送分享码", item: code)
                        Button("撤销分享", role: .destructive) { Task { await revoke(code) } }.disabled(busy)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.navigationTitle("分享商品").toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
             .task {
                 do {
                     let state = try await store.foodShareStatus(product)
                     if !state.code.isEmpty { code = state.code; searchable = state.searchable; moderationState = state.moderationState }
                     else if autoGenerate { await share() }
                 } catch {
                     if autoGenerate { await share() }
                     else { self.error = error.localizedDescription }
                 }
             }
        }
    }
    private func share() async {
        busy = true; error = nil; defer { busy = false }
        do { code = try await store.shareFood(product, searchable: searchable); moderationState = "visible" }
        catch { self.error = error.localizedDescription }
    }
    private func revoke(_ value: String) async {
        busy = true; error = nil; defer { busy = false }
        do { try await store.revokeFoodShare(value); code = nil; searchable = true }
        catch { self.error = error.localizedDescription }
    }
}

struct FoodImportView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SharedFood] = []
    @State private var busy = false
    @State private var error: String?
    @State private var searched = false
    @State private var searchedQuery = ""
    @State private var hasMore = false
    @State private var nextOffset = 0
    @State private var reporting: SharedFood?
    @State private var blocking: SharedFood?
    @State private var notice: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("商品名或分享码；留空查看全部", text: $query).textInputAutocapitalization(.never)
                        .onChange(of: query) { _, _ in results = []; hasMore = false; searched = false; nextOffset = 0 }
                    Button(busy ? "搜索中…" : "搜索") { Task { await search() } }
                        .disabled(busy || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                }
                Section("已分享的商品") {
                    if results.isEmpty { Text(searched ? "没有找到可导入的商品" : "留空点搜索可浏览全部可搜索商品；私有商品请输入分享码").foregroundStyle(.secondary) }
                    ForEach(results) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.product.brand.isEmpty ? item.product.name : "\(item.product.brand) · \(item.product.name)").font(.headline)
                            Text("品牌：\(item.product.brand.isEmpty ? "未填写" : item.product.brand)").font(.caption).foregroundStyle(.secondary)
                            Text("整包 \(item.product.packageAmount.formatted()) \(item.product.packageUnit == "g" ? "克" : "毫升") · 每 100 \(item.product.basisUnit == "g" ? "克" : "毫升") \(item.product.energyPer100.formatted()) \(item.product.energyUnit == "kJ" ? "千焦" : "千卡")").font(.caption).foregroundStyle(.secondary)
                            Button("核对一致，导入常用") { Task { await importItem(item) } }
                            HStack {
                                Button("举报商品") { reporting = item }.buttonStyle(.borderless)
                                Spacer()
                                Button("屏蔽此来源", role: .destructive) { blocking = item }.buttonStyle(.borderless)
                            }.font(.caption)
                        }
                    }
                    if hasMore { Button("加载更多") { Task { await loadMore() } }.disabled(busy) }
                }
                Section {
                    Text("导入前请确认品牌、规格和营养表相同。朋友的饮食记录不会导入。").font(.caption).foregroundStyle(.secondary)
                    NavigationLink("管理已屏蔽来源") { BlockedFoodSourcesView(store: store) }
                    Link("联系日益支持", destination: URL(string: "https://health.gzqy.xyz/support")!)
                }
                if let notice { Section { Text(notice).foregroundStyle(Theme.green) } }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.navigationTitle("导入商品").toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .sheet(item: $reporting) { item in
                FoodReportView(store: store, item: item) {
                    results.removeAll { $0.code == item.code }
                    notice = "举报已提交；该商品已从搜索中隐藏，等待复核。"
                }
            }
            .confirmationDialog("屏蔽这个商品的分享来源？", isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } })) {
                Button("屏蔽来源", role: .destructive) {
                    if let item = blocking { Task { await blockSource(item) } }
                    blocking = nil
                }
            } message: { Text("此来源分享的商品将不再出现在你的搜索结果中，可在下方管理页面解除。") }
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--food-moderation-ui-test") {
                    results = [SharedFood(code: "RIYI-TEST-0000001", product: FoodProduct(name: "测试麦片", brand: "测试品牌", packageAmount: 100, energyPer100: 1400))]
                    searched = true
                }
                #endif
            }
        }
    }
    private func search() async {
        busy = true; error = nil; defer { busy = false }
        do {
            let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let page = try await store.searchSharedFoods(clean)
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == clean else { return }
            results = page.items; hasMore = page.hasMore; nextOffset = page.items.count
            searchedQuery = clean; searched = true
        }
        catch { self.error = error.localizedDescription }
    }
    private func loadMore() async {
        guard hasMore else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            let page = try await store.searchSharedFoods(searchedQuery, offset: nextOffset)
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == searchedQuery else { return }
            nextOffset += page.items.count
            let known = Set(results.map(\.code))
            results.append(contentsOf: page.items.filter { !known.contains($0.code) })
            hasMore = page.hasMore
        } catch { self.error = error.localizedDescription }
    }
    private func importItem(_ item: SharedFood) async {
        do { _ = try await store.importSharedFood(item); dismiss() }
        catch { self.error = error.localizedDescription }
    }
    private func blockSource(_ item: SharedFood) async {
        do {
            try await store.blockSharedFoodSource(item.code)
            notice = "已屏蔽该分享来源。"
            await search()
        } catch { self.error = error.localizedDescription }
    }
}

private struct FoodReportView: View {
    @Bindable var store: AppStore
    let item: SharedFood
    let onSubmitted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reason = "inaccurate"
    @State private var details = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section(item.product.brand.isEmpty ? item.product.name : "\(item.product.brand) · \(item.product.name)") {
                    Picker("举报原因", selection: $reason) {
                        Text("营养或商品资料不准确").tag("inaccurate")
                        Text("冒犯性内容").tag("offensive")
                        Text("垃圾或广告").tag("spam")
                        Text("涉嫌侵权").tag("copyright")
                        Text("其他").tag("other")
                    }
                    TextField("补充说明（选填，最多 500 字）", text: $details, axis: .vertical)
                    Text("举报后该商品会先从搜索中隐藏，待人工复核。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.navigationTitle("举报商品")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button(busy ? "提交中…" : "提交") { Task { await submit() } }.disabled(busy || details.count > 500) }
                }
        }
    }
    private func submit() async {
        busy = true; error = nil; defer { busy = false }
        do {
            try await store.reportSharedFood(item.code, reason: reason, details: details)
            onSubmitted(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct BlockedFoodSourcesView: View {
    @Bindable var store: AppStore
    @State private var items: [BlockedFoodSource] = []
    @State private var error: String?
    var body: some View {
        List {
            if items.isEmpty { Text("没有已屏蔽的来源").foregroundStyle(.secondary) }
            ForEach(items) { item in
                HStack {
                    Text(item.label)
                    Spacer()
                    Button("解除屏蔽") { Task { await unblock(item) } }.buttonStyle(.borderless)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("已屏蔽来源").task { await load() }
    }
    private func load() async {
        do { items = try await store.blockedFoodSources(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func unblock(_ item: BlockedFoodSource) async {
        do { try await store.unblockFoodSource(item.id); await load() }
        catch { self.error = error.localizedDescription }
    }
}

struct FoodTextEntryView: View {
    @Bindable var store: AppStore
    let date: Date
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var slot = "breakfast"
    @State private var error: String?
    @State private var estimate: FoodTextEstimate?
    @State private var estimating = false
    private func quantity(in text: String) -> Double? {
        let pattern = #"(\d+(?:\.\d+)?)\s*(只|个|克|毫升)"#
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(m.range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("实际吃喝") {
                    TextField("例如：早餐吃了5只小笼包", text: $text, axis: .vertical).accessibilityIdentifier("meal-description")
                    Picker("餐次", selection: $slot) { ForEach(mealSlots, id: \.0) { Text($0.1).tag($0.0) } }
                    Button(estimating ? "正在估算…" : "按文字请 AI 粗估热量") { Task { await estimateText() } }
                        .disabled(estimating || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let estimate {
                        if let (low, high) = estimate.usableRange {
                            Text("AI 粗估约 \(low.formatted(.number.precision(.fractionLength(0))))–\(high.formatted(.number.precision(.fractionLength(0)))) 千卡").foregroundStyle(Theme.green)
                        } else { Text("信息不足，热量待估算；仍可保存这餐。") }
                        Text(estimate.estimateBasis).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("记录这餐") { save() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("save-meal-log")
                    Text("若文字匹配到常用商品与数量，优先按已核对的营养表计算；否则可请 AI 粗估，或先保存为热量待估算。").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.navigationTitle("文字记录").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .onChange(of: text) { _, _ in estimate = nil }
        }
    }
    private func estimateText() async {
        estimating = true; error = nil; defer { estimating = false }
        do { estimate = try await store.estimateFoodText(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        catch { self.error = error.localizedDescription }
    }
    private func save() {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let product = store.foodProducts.first(where: { clean.contains($0.name) }), let amount = quantity(in: clean) {
            let unit = clean.contains("毫升") ? "ml" : clean.contains("克") ? "g" : product.servingUnit
            if let log = store.mealLog(from: product, quantity: amount, unit: unit, slot: slot, at: mealEntryTime(for: date, zone: store.settings.timezone)), store.save(log, kind: "meal", id: log.id) { dismiss(); return }
        }
        var log = MealLog(slot: slot, description: clean, eatenAt: mealEntryTime(for: date, zone: store.settings.timezone), timezone: store.settings.timezone)
        if let estimate, let (low, high) = estimate.usableRange {
            log.energyMethod = "estimated_range"; log.estimateMinKcal = low; log.estimateMaxKcal = high
            log.nutritionSource = "AI 文字粗估：" + String(estimate.estimateBasis.prefix(280))
        } else { log.energyMethod = "unknown" }
        if store.save(log, kind: "meal", id: log.id) { dismiss() }
        else { error = store.error ?? "饮食未保存" }
    }
}

struct FoodOutsidePhotoView: View {
    @Bindable var store: AppStore
    let date: Date
    let existingLog: MealLog?
    let onSaved: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var camera = false
    @State private var recognition: FoodMealRecognition?
    @State private var name = ""
    @State private var amount = 0.0
    @State private var unit = "ml"
    @State private var noAdditions = false
    @State private var slot = "drink"
    @State private var busy = false
    @State private var error: String?
    init(store: AppStore, date: Date, initialImage: UIImage? = nil, existingLog: MealLog? = nil, onSaved: (() -> Void)? = nil) {
        self.store = store; self.date = date; self.existingLog = existingLog; self.onSaved = onSaved
        _image = State(initialValue: initialImage)
        _name = State(initialValue: existingLog?.description ?? "")
        _slot = State(initialValue: existingLog?.slot ?? "drink")
    }
    private var estimate: Double? {
        guard let recognition, amount > 0, amount.isFinite else { return nil }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch recognition.foodKey {
        case "coffee_black" where noAdditions && unit == "ml" && ["冷萃冰咖啡", "冷萃咖啡", "黑咖啡", "美式咖啡"].contains(clean): return amount * 4 / 178
        case "rice_plain" where unit == "碗" && ["米饭", "白米饭", "白饭"].contains(clean): return amount * 230
        case "milk" where unit == "ml" && ["牛奶", "纯牛奶", "全脂牛奶"].contains(clean): return amount * 63 / 100
        default: return nil
        }
    }
    private var estimateRange: (low: Double, high: Double)? {
        guard estimate == nil, let recognition, name.trimmingCharacters(in: .whitespacesAndNewlines) == recognition.name.trimmingCharacters(in: .whitespacesAndNewlines),
              let low = recognition.estimateMinKcal, let high = recognition.estimateMaxKcal,
              low.isFinite, high.isFinite, (0...5000).contains(low), (low...5000).contains(high), !recognition.estimateBasis.isEmpty else { return nil }
        if unit != recognition.unit && amount > 0 { return nil }
        if unit == recognition.unit, let suggested = recognition.quantity, abs(amount - suggested) > 0.001 { return nil }
        return (low, high)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("拍外食或饮品") {
                    FoodPhotoRow(title: "这次吃喝的照片", hint: "无需包装或营养表", image: $image) { camera = true }
                    Button(busy ? "正在识别…" : "AI 识别并粗估") { Task { await analyze() } }.disabled(image == nil || busy)
                    Text("照片会发给已配置的 AI 服务；识别结果由你确认。看不出的配料和重量不会当成已知。").font(.caption).foregroundStyle(.secondary)
                }
                if let recognition {
                    Section("核对结果") {
                        TextField("食物或饮品名称", text: $name)
                        Picker("餐次", selection: $slot) { ForEach(mealSlots, id: \.0) { Text($0.1).tag($0.0) } }
                        TextField("这次的数量", value: $amount, format: .number).keyboardType(.decimalPad)
                        Picker("单位", selection: $unit) { Text("毫升").tag("ml"); Text("碗").tag("碗"); Text("份").tag("份"); Text("个").tag("个") }
                        if recognition.foodKey == "coffee_black" { Toggle("确认无奶、糖和糖浆", isOn: $noAdditions) }
                        if let kcal = estimate { Text("参考估算约 \(kcal.formatted(.number.precision(.fractionLength(0)))) 千卡").foregroundStyle(Theme.green) }
                        else if let range = estimateRange {
                            Text("AI 粗估约 \(range.low.formatted(.number.precision(.fractionLength(0))))–\(range.high.formatted(.number.precision(.fractionLength(0)))) 千卡").foregroundStyle(Theme.green)
                            Text(recognition.estimateBasis).font(.caption).foregroundStyle(.secondary)
                        }
                        else { Text("热量待估算；不会按 0 千卡记录").foregroundStyle(.secondary) }
                        ForEach(recognition.questions, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        Button("保存实际饮食") { save() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.navigationTitle("拍照记录外食").toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }.fullScreenCover(isPresented: $camera) { FoodCameraPicker { image = $0 }.ignoresSafeArea() }
    }
    private func analyze() async {
        guard let image, let data = foodJPEG(image) else { error = "照片过大或无法读取"; return }
        busy = true; error = nil; defer { busy = false }
        do {
            let result = try await store.recognizeFoodPhoto(data)
            recognition = result; name = result.name
            unit = result.unit == "ml" || result.unit == "碗" ? result.unit : result.foodKey == "rice_plain" ? "碗" : "ml"
            amount = result.unit == unit ? (result.quantity ?? 0) : 0
            noAdditions = false
            slot = ["coffee_black", "milk"].contains(result.foodKey) ? "drink" : "snack"
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { error = "请确认食物名称"; return }
        let amountText = amount > 0 ? " \(amount.formatted(.number.precision(.fractionLength(0...1))))\(unit == "ml" ? "毫升" : unit)" : ""
        var log = existingLog ?? MealLog(slot: slot, description: clean + amountText, eatenAt: mealEntryTime(for: date, zone: store.settings.timezone), timezone: store.settings.timezone)
        log.slot = slot; log.description = clean + amountText
        if let estimate {
            log.energyMethod = "estimated"; log.energyKcal = estimate
            log.nutritionSource = recognition?.foodKey == "coffee_black" ? "USDA 冲煮咖啡参考；按用户确认杯量和无奶糖计算" :
                recognition?.foodKey == "rice_plain" ? "香港食安中心普通碗白饭参考" : "同类牛奶商品营养标签参考"
        } else if let range = estimateRange {
            log.energyMethod = "estimated_range"; log.estimateMinKcal = range.low; log.estimateMaxKcal = range.high
            log.nutritionSource = "AI 粗估：" + String((recognition?.estimateBasis ?? "").prefix(280))
        }
        else { log.energyMethod = "unknown" }
        if amount > 0 { log.quantity = amount; log.quantityUnit = unit }
        else { log.quantity = nil; log.quantityUnit = nil }
        log.calculateEnergy()
        if store.save(log, kind: "meal", id: log.id) { onSaved?(); dismiss() }
        else { error = store.error ?? "饮食未保存" }
    }
}
