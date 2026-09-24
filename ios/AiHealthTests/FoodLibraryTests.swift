import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import AiHealth

final class FoodLibraryTests: XCTestCase {
    func testNutritionTargetsUseManualValuesIndependentlyAndNeverInventMissingData() {
        var profile = Profile()
        profile.goal = "增肌"
        let missing = DailyNutritionTargets.make(profile: profile, weightKg: nil, energyBaselineKcal: nil, energyBaselineDays: 0)
        XCTAssertNil(missing.energyKcal); XCTAssertNil(missing.proteinG)
        XCTAssertNil(missing.fatG); XCTAssertNil(missing.carbG)
        let automatic = DailyNutritionTargets.make(profile: profile, weightKg: 75, energyBaselineKcal: 2500, energyBaselineDays: 5)
        XCTAssertEqual(automatic.energyKcal, 2750)
        XCTAssertEqual(automatic.proteinG, 120)
        XCTAssertEqual(automatic.fatG, 92)
        XCTAssertEqual(automatic.carbG, 361)
        profile.proteinGoalG = 150; profile.fatGoalG = 80
        let mixed = DailyNutritionTargets.make(profile: profile, weightKg: 75, energyBaselineKcal: 2500, energyBaselineDays: 5)
        XCTAssertEqual(mixed.proteinG, 150)
        XCTAssertEqual(mixed.fatG, 80)
        XCTAssertEqual(mixed.carbG, 358)
        profile.energyGoalKcal = 2200; profile.carbGoalG = 180
        let manual = DailyNutritionTargets.make(profile: profile, weightKg: nil, energyBaselineKcal: nil, energyBaselineDays: 0)
        XCTAssertEqual(manual.energyKcal, 2200)
        XCTAssertEqual(manual.proteinG, 150)
        XCTAssertEqual(manual.fatG, 80)
        XCTAssertEqual(manual.carbG, 180)
    }
    func testEnergyBaselineRequiresThreeDaysOfBothEnergySources() throws {
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-09-24T09:00:00+08:00"))
        var samples: [HealthSample] = []
        for day in 21...23 {
            let start = try XCTUnwrap(formatter.date(from: "2026-09-\(day)T00:00:00+08:00"))
            let end = start.addingTimeInterval(86400)
            samples.append(HealthSample(healthkitUuid: newID(), type: "basal_energy", value: 1800, unit: "kcal", startAt: start, endAt: end, sourceBundleId: "watch"))
            samples.append(HealthSample(healthkitUuid: newID(), type: "active_energy", value: 500, unit: "kcal", startAt: start, endAt: end, sourceBundleId: "watch"))
        }
        XCTAssertEqual(LocalHealthOverview.energyBaseline(samples: samples, zone: "Asia/Shanghai", now: now)?.kcal, 2300)
        XCTAssertEqual(LocalHealthOverview.energyBaseline(samples: Array(samples.dropLast()), zone: "Asia/Shanghai", now: now)?.days, nil)
    }
    func testNewMealDefaultsToCurrentClockTimeNotMidnight() throws {
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-09-23T04:47:30Z"))
        let todayMidnight = try XCTUnwrap(formatter.date(from: "2026-09-22T16:00:00Z"))
        XCTAssertEqual(mealEntryTime(for: todayMidnight, zone: "Asia/Shanghai", now: now), now)
        let yesterdayMidnight = try XCTUnwrap(formatter.date(from: "2026-09-21T16:00:00Z"))
        let past = mealEntryTime(for: yesterdayMidnight, zone: "Asia/Shanghai", now: now)
        XCTAssertEqual(formatter.string(from: past), "2026-09-22T04:47:30Z")
    }
    func testEstimatedRangesAreCountedSeparatelyFromMissingCalories() {
        var breakfast = MealLog(slot: "breakfast", description: "小笼包", eatenAt: Date(), timezone: "Asia/Shanghai")
        breakfast.energyMethod = "estimated_range"; breakfast.estimateMinKcal = 200; breakfast.estimateMaxKcal = 400
        breakfast.nutritionSource = "AI 文字粗估"
        var lunch = MealLog(slot: "lunch", description: "泡面、虾、鸡蛋", eatenAt: Date(), timezone: "Asia/Shanghai")
        lunch.energyMethod = "estimated_range"; lunch.estimateMinKcal = 515; lunch.estimateMaxKcal = 950
        lunch.nutritionSource = "AI 文字粗估"
        let summary = MealEnergySummary([breakfast, lunch])
        XCTAssertEqual(summary.singleCount, 0)
        XCTAssertEqual(summary.rangeCount, 2)
        XCTAssertEqual(summary.unknownCount, 0)
        XCTAssertEqual(summary.totalMinKcal, 715)
        XCTAssertEqual(summary.totalMaxKcal, 1350)
        XCTAssertEqual(summary.totalMidpointKcal, 1032.5)
        XCTAssertEqual(MealEnergySummary([breakfast, lunch, MealLog(description: "水果")]).unknownCount, 1)
    }
    func testProteinTargetAndMacroSummaryKeepUnknownSeparate() {
        let target = ProteinTarget.make(weightKg: 75, goal: "增肌", chosenFactor: nil)
        XCTAssertEqual(target?.grams, 120)
        XCTAssertEqual(ProteinTarget.make(weightKg: 75, goal: "减脂", chosenFactor: nil)?.grams, 135)
        XCTAssertNil(ProteinTarget.make(weightKg: nil, goal: "增肌", chosenFactor: nil))
        var label = MealLog(slot: "lunch", description: "鸡胸肉", eatenAt: Date(), timezone: "Asia/Shanghai")
        label.proteinG = 30
        var estimated = MealLog(slot: "dinner", description: "外食", eatenAt: Date(), timezone: "Asia/Shanghai")
        estimated.proteinMinG = 12; estimated.proteinMaxG = 25; estimated.macroSource = "AI 粗估"
        let summary = MealMacroTotal([label, estimated, MealLog(description: "水果")], exact: \.proteinG, low: \.proteinMinG, high: \.proteinMaxG)
        XCTAssertEqual(summary.midpointG, 48.5)
        XCTAssertEqual(summary.rangeCount, 1)
        XCTAssertEqual(summary.unknownCount, 1)
    }
    #if canImport(UIKit)
    func testCameraPhotoIsRenderedAtUploadPixelSize() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 3024, height: 4032), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3024, height: 4032))
            for row in 0..<40 {
                UIColor(hue: CGFloat(row) / 40, saturation: 0.8, brightness: 0.8, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: row * 100, width: 3024, height: 50))
            }
        }
        let jpeg = try XCTUnwrap(foodJPEG(image))
        XCTAssertLessThan(jpeg.count, 1_300_000)
        let decoded = try XCTUnwrap(UIImage(data: jpeg)?.cgImage)
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 1600)
    }
    #endif
    func testPackageLabelUsesPerPieceAverageAndOriginalKJ() {
        let product = FoodProduct(name: "非遗黑猪肉老面小笼包", packageAmount: 500,
                                  unitsPerPackage: 20, servingUnit: "只", energyPer100: 992)
        XCTAssertTrue(product.valid)
        let result = product.calculated(quantity: 5, unit: "只")
        XCTAssertEqual(result?.amount, 125)
        XCTAssertEqual(result?.kcal ?? 0, 1240 / 4.184, accuracy: 0.001)
        XCTAssertNil(product.calculated(quantity: 1, unit: "杯"))
        XCTAssertEqual(try Wire.read(Wire.data(product), as: FoodProduct.self).name, product.name)
        let shared = """
        {"id":"\(product.id)","name":"非遗黑猪肉老面小笼包","brand":"","package_amount":500,"package_unit":"g","units_per_package":20,"serving_unit":"只","energy_per100":992,"energy_unit":"kJ","basis_unit":"g","source":"label","verified_at":"2026-09-23T01:00:00Z"}
        """.data(using: .utf8)!
        XCTAssertEqual(try Wire.read(shared, as: FoodProduct.self).kcalPer100, 992 / 4.184, accuracy: 0.001)
    }

    func testPackageMacrosFollowActualPiecesAndMissingIsUnknown() {
        var product = FoodProduct(name: "小笼包", packageAmount: 500, unitsPerPackage: 20, servingUnit: "只", energyPer100: 992)
        product.proteinPer100 = 8; product.fatPer100 = 10
        let result = product.calculated(quantity: 5, unit: "只")
        XCTAssertEqual(result?.amount, 125)
        XCTAssertEqual(product.macroGrams(per100: product.proteinPer100, amount: result!.amount), 10)
        XCTAssertEqual(product.macroGrams(per100: product.fatPer100, amount: result!.amount), 12.5)
        XCTAssertNil(product.macroGrams(per100: product.carbPer100, amount: result!.amount))
    }

    func testFoodProductRejectsMismatchedMassAndVolume() {
        var product = FoodProduct(name: "牛奶", packageAmount: 250, packageUnit: "ml", energyPer100: 63,
                                  energyUnit: "kcal", basisUnit: "g")
        XCTAssertFalse(product.valid)
        product.basisUnit = "ml"
        XCTAssertTrue(product.valid)
        XCTAssertEqual(product.calculated(quantity: 250, unit: "ml")?.kcal ?? 0, 157.5, accuracy: 0.001)
    }

    func testPhotoEstimateRangeIsDistinctFromKnownCalories() {
        var log = MealLog(slot: "lunch", description: "一碗外食", eatenAt: Date(), timezone: "Asia/Shanghai")
        log.energyMethod = "estimated_range"
        log.estimateMinKcal = 180; log.estimateMaxKcal = 310
        log.nutritionSource = "AI 粗估：菜品与份量不确定"
        XCTAssertTrue(log.valid)
        XCTAssertNil(log.energyKcal)
        log.estimateMaxKcal = 100
        XCTAssertFalse(log.valid)
        log.energyMethod = "unknown"
        log.calculateEnergy()
        XCTAssertTrue(log.valid)
        XCTAssertNil(log.estimateMinKcal)
    }
}
