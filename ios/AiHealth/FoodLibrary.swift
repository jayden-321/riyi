import Foundation

struct FoodProduct: Codable, Identifiable {
    var id = newID()
    var name: String
    var brand = ""
    var packageAmount: Double
    var packageUnit = "g"
    var unitsPerPackage: Double?
    var servingUnit = "只"
    var energyPer100: Double
    var energyUnit = "kJ"
    var basisUnit = "g"
    var source = "label"
    var sourceUrl: String?
    var originShareCode: String?
    var verifiedAt = Date()

    var kcalPer100: Double { energyUnit == "kJ" ? energyPer100 / 4.184 : energyPer100 }
    var amountPerUnit: Double? {
        guard let unitsPerPackage, unitsPerPackage > 0 else { return nil }
        return packageAmount / unitsPerPackage
    }
    func calculated(quantity: Double, unit: String) -> (amount: Double, kcal: Double)? {
        guard quantity.isFinite, quantity > 0 else { return nil }
        let amount: Double
        if unit == basisUnit { amount = quantity }
        else if unit == servingUnit, let amountPerUnit { amount = quantity * amountPerUnit }
        else { return nil }
        let kcal = amount * kcalPer100 / 100
        guard kcal.isFinite, (0...30000).contains(kcal) else { return nil }
        return (amount, kcal)
    }
    var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120 && brand.count <= 80 &&
        packageAmount.isFinite && energyPer100.isFinite &&
        (0.1...100000).contains(packageAmount) && (0.1...10000).contains(energyPer100) &&
        packageUnit == basisUnit && ["g", "ml"].contains(basisUnit) && ["kJ", "kcal"].contains(energyUnit) &&
        (unitsPerPackage == nil || (unitsPerPackage!.isFinite && unitsPerPackage! >= 1 && unitsPerPackage! <= 10000)) &&
        (unitsPerPackage == nil || !servingUnit.isEmpty && servingUnit.count <= 12)
    }
}

struct FoodPackageExtraction: Decodable {
    var name: String; var brand: String
    var packageAmount: Double?; var packageUnit: String?
    var unitsPerPackage: Double?; var servingUnit: String?
    var energyPer100: Double?; var energyUnit: String?; var basisUnit: String?
    var warnings: [String]
}

struct FoodMealRecognition: Decodable {
    var name: String; var foodKey: String; var quantity: Double?; var unit: String
    var additionsUnknown: Bool; var estimateMinKcal: Double?; var estimateMaxKcal: Double?; var estimateBasis: String; var questions: [String]
}

struct FoodTextEstimate: Decodable {
    var estimateMinKcal: Double?; var estimateMaxKcal: Double?; var estimateBasis: String; var questions: [String]
    var usableRange: (Double, Double)? {
        guard let low = estimateMinKcal, let high = estimateMaxKcal, low.isFinite, high.isFinite,
              (0...5000).contains(low), (low...5000).contains(high), !estimateBasis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (low, high)
    }
}

struct SharedFood: Decodable, Identifiable {
    var code: String; var product: FoodProduct
    var id: String { code }
}

struct SharedFoodPage: Decodable { var items: [SharedFood]; var hasMore: Bool }

struct FoodShareStatus: Decodable { var code: String; var searchable: Bool }

extension AppStore {
    var foodProducts: [FoodProduct] { (values("food") as [FoodProduct]).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }

    func mealLog(from product: FoodProduct, quantity: Double, unit: String, slot: String, at date: Date) -> MealLog? {
        guard let result = product.calculated(quantity: quantity, unit: unit) else { return nil }
        var log = MealLog(slot: slot, description: "\(product.name) \(quantity.formatted(.number.precision(.fractionLength(0...1))))\(unit)", eatenAt: date, timezone: settings.timezone)
        log.energyMethod = "label"; log.grams = result.amount; log.kcalPer100 = product.kcalPer100
        log.energyKcal = result.kcal; log.foodProductId = product.id
        log.energyBasisUnit = product.basisUnit
        log.nutritionSource = product.source == "imported" ? "导入商品的包装营养表" : "已核对的商品包装营养表"
        log.quantity = quantity; log.quantityUnit = unit
        return log.valid ? log : nil
    }

    func extractFoodPackage(front: Data, nutrition: Data, extra: Data? = nil) async throws -> FoodPackageExtraction {
        guard !isDemo else { throw AppError.message("拍照识别需要登录云端账号") }
        struct Request: Encodable { var frontJPEG: String; var nutritionJPEG: String; var extraJPEG: String }
        let request = Request(frontJPEG: front.base64EncodedString(), nutritionJPEG: nutrition.base64EncodedString(), extraJPEG: extra?.base64EncodedString() ?? "")
        return try Wire.read(await network.request("/v1/foods/recognize-package", method: "POST", body: Wire.data(request), timeout: 85))
    }

    func recognizeFoodPhoto(_ jpeg: Data) async throws -> FoodMealRecognition {
        guard !isDemo else { throw AppError.message("拍照识别需要登录云端账号") }
        struct Request: Encodable { var jpeg: String }
        return try Wire.read(await network.request("/v1/foods/recognize-meal", method: "POST", body: Wire.data(Request(jpeg: jpeg.base64EncodedString())), timeout: 85))
    }

    func estimateFoodText(_ description: String) async throws -> FoodTextEstimate {
        guard !isDemo else { throw AppError.message("AI 粗估需要登录云端账号") }
        struct Request: Encodable { var description: String }
        return try Wire.read(await network.request("/v1/foods/estimate-text", method: "POST", body: Wire.data(Request(description: description)), timeout: 85))
    }

    func searchSharedFoods(_ query: String, offset: Int = 0) async throws -> SharedFoodPage {
        guard !isDemo else { throw AppError.message("云端商品搜索需要登录账号") }
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else { throw AppError.message("商品搜索词无法编码") }
        return try Wire.read(await network.request("/v1/foods/shared?q=\(encoded)&offset=\(offset)"))
    }

    func shareFood(_ product: FoodProduct, searchable: Bool) async throws -> String {
        guard !isDemo else { throw AppError.message("分享商品需要登录账号") }
        try await syncFoodForSharing(product)
        guard !pending.contains(where: { $0.kind == "food" && $0.recordId == product.id }) else { throw AppError.message("请先完成商品同步，再分享") }
        struct Request: Encodable { var productID: String; var searchable: Bool }
        struct Reply: Decodable { var code: String }
        let reply: Reply = try Wire.read(await network.request("/v1/foods/share", method: "POST", body: Wire.data(Request(productID: product.id, searchable: searchable))))
        return reply.code
    }

    private func syncFoodForSharing(_ product: FoodProduct) async throws {
        reload()
        guard let change = pending.first(where: { $0.kind == "food" && $0.recordId == product.id }) else { return }
        guard change.conflictData == nil else { throw AppError.message("商品与云端记录冲突，请先处理同步冲突") }
        let owner = scope
        let baseVersion = change.baseVersion < 0 ? records.first(where: { $0.kind == "food" && $0.recordId == product.id })?.version ?? 0 : change.baseVersion
        let raw = try JSONSerialization.jsonObject(with: change.payload)
        let payload: [String: Any] = ["id": change.id, "kind": "food", "record_id": product.id,
                                      "base_version": baseVersion, "deleted": change.tombstoned, "payload": raw]
        let reply: SyncReply = try Wire.read(await network.request("/v1/sync", method: "POST", body: JSONSerialization.data(withJSONObject: payload)))
        guard scope == owner else { throw AppError.message("账号已切换，商品保留在原账号空间") }
        reload()
        guard let current = pending.first(where: { $0.id == change.id }) else { return }
        if reply.status == "conflict" {
            current.conflictData = try Wire.data(reply.record)
            try context.save(); reload()
            throw AppError.message("商品与云端记录冲突，请先处理同步冲突")
        }
        if let record = records.first(where: { $0.kind == "food" && $0.recordId == product.id }) { record.version = reply.record.version }
        context.delete(current)
        try context.save(); reload()
    }

    func foodShareStatus(_ product: FoodProduct) async throws -> FoodShareStatus {
        guard !isDemo else { throw AppError.message("分享商品需要登录账号") }
        return try Wire.read(await network.request("/v1/foods/share-status?product_id=\(product.id)"))
    }

    func revokeFoodShare(_ code: String) async throws {
        guard !isDemo else { throw AppError.message("撤销分享需要登录账号") }
        guard let encoded = code.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else { throw AppError.message("分享码无效") }
        _ = try await network.request("/v1/foods/share/\(encoded)", method: "DELETE")
    }

    func importSharedFood(_ shared: SharedFood) async throws -> FoodProduct {
        if let existing = foodProducts.first(where: { $0.originShareCode == shared.code || $0.brand == shared.product.brand && $0.name == shared.product.name && $0.packageAmount == shared.product.packageAmount && $0.energyPer100 == shared.product.energyPer100 }) {
            return existing
        }
        var copy = shared.product; copy.id = newID(); copy.source = "imported"; copy.originShareCode = shared.code; copy.verifiedAt = Date()
        guard copy.valid, save(copy, kind: "food", id: copy.id) else { throw AppError.message("导入商品未保存") }
        if !isDemo { await synchronize(showErrors: true) }
        return copy
    }
}
