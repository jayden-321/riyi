import XCTest

final class FoodEntryUITests: XCTestCase {
    func testSharedFoodCanBeReportedOrBlockedFromImportScreen() {
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--food-moderation-ui-test"]
        app.launch()
        XCTAssertTrue(app.navigationBars["饮食"].waitForExistence(timeout: 10))
        app.buttons["常用"].tap()
        app.buttons["导入"].tap()
        XCTAssertTrue(app.staticTexts["测试品牌 · 测试麦片"].waitForExistence(timeout: 8))
        app.buttons["举报商品"].tap()
        XCTAssertTrue(app.navigationBars["举报商品"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["举报原因"].exists || app.staticTexts["举报原因"].exists)
        app.buttons["取消"].tap()
        app.buttons["屏蔽此来源"].tap()
        XCTAssertTrue(app.buttons["屏蔽来源"].waitForExistence(timeout: 5))
    }
    func testImportCanSearchWithEmptyText() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--food-share-ui-test"]
        app.launch()
        app.buttons["常用"].tap()
        app.buttons["导入"].tap()
        XCTAssertTrue(app.navigationBars["导入商品"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["商品名或分享码；留空查看全部"].exists)
        XCTAssertTrue(app.buttons["搜索"].isEnabled)
    }

    func testPackageSaveReturnsToCommonWithoutSharePage() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--planning-ui-test"]
        app.launch()
        app.buttons["常用"].tap()
        app.buttons["拍包装，加入常用"].tap()
        app.buttons["手动填写商品资料"].tap()
        func fill(_ label: String, _ value: String) {
            let field = app.textFields[label]
            XCTAssertTrue(field.waitForExistence(timeout: 5), label)
            field.tap(); field.typeText(value)
        }
        fill("商品名称", "方便面")
        fill("品牌（识别后请核对）", "盒马")
        fill("整包净含量", "100")
        fill("每 100 克/毫升能量", "1900")
        app.buttons["保存到常用"].tap()
        XCTAssertTrue(app.navigationBars["常用"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.navigationBars["分享商品"].exists)
        let product = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "方便面")).firstMatch
        XCTAssertTrue(product.waitForExistence(timeout: 5))
        product.tap()
        XCTAssertTrue(app.staticTexts["品牌：盒马"].waitForExistence(timeout: 5))
    }

    func testExistingCommonProductCanAddProtein() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--planning-ui-test"]
        app.launch()
        app.buttons["常用"].tap()
        app.buttons["拍包装，加入常用"].tap()
        app.buttons["手动填写商品资料"].tap()
        for (label, value) in [("商品名称", "蛋白补录测试"), ("整包净含量", "100"), ("每 100 克/毫升能量", "500")] {
            let field = app.textFields[label]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap(); field.typeText(value)
        }
        app.buttons["保存到常用"].tap()
        let product = app.staticTexts["蛋白补录测试"]
        XCTAssertTrue(product.waitForExistence(timeout: 8))
        product.tap()
        app.buttons["编辑常用商品"].tap()
        let protein = app.textFields["蛋白质"]
        XCTAssertTrue(protein.waitForExistence(timeout: 5))
        protein.tap(); protein.typeText("20")
        app.buttons["保存修改"].tap()
        XCTAssertTrue(product.waitForExistence(timeout: 8))
        product.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "蛋白质 20 克")).firstMatch.waitForExistence(timeout: 5))
    }

    func testEntryOrderAndPhotoRoutes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--planning-ui-test"]
        app.launch()
        XCTAssertTrue(app.navigationBars["饮食"].waitForExistence(timeout: 10))
        let common = app.buttons["常用"], text = app.buttons["文字"], photo = app.buttons["拍照"]
        XCTAssertTrue(common.exists && text.exists && photo.exists)
        XCTAssertLessThan(common.frame.minX, text.frame.minX)
        XCTAssertLessThan(text.frame.minX, photo.frame.minX)
        photo.tap()
        XCTAssertTrue(app.navigationBars["拍照记录外食"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["无需包装或营养表"].exists)
        XCTAssertTrue(app.buttons["从相册选"].exists)
        app.buttons["关闭"].tap()
        common.tap()
        XCTAssertTrue(app.navigationBars["常用"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["拍包装，加入常用"].exists)
    }

    func testPackageReviewCommonAndActualFivePieces() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--planning-ui-test"]
        app.launch()
        XCTAssertTrue(app.navigationBars["饮食"].waitForExistence(timeout: 10))
        app.buttons["常用"].tap()
        XCTAssertTrue(app.navigationBars["常用"].waitForExistence(timeout: 5))
        app.buttons["拍包装，加入常用"].tap()
        app.buttons["手动填写商品资料"].tap()
        XCTAssertTrue(app.navigationBars["核对商品资料"].waitForExistence(timeout: 5))

        func fill(_ label: String, _ value: String) {
            let field = app.textFields[label]
            XCTAssertTrue(field.waitForExistence(timeout: 5), label)
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            if let old = field.value as? String, old != field.placeholderValue {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
            }
            field.typeText(value)
        }
        fill("商品名称", "非遗黑猪肉老面小笼包")
        fill("整包净含量", "500")
        fill("数量", "20")
        fill("数量单位", "只")
        fill("每 100 克/毫升能量", "992")
        XCTAssertTrue(app.staticTexts["平均每只约 25 克"].waitForExistence(timeout: 5))
        app.buttons["保存到常用"].tap()
        XCTAssertTrue(app.navigationBars["常用"].waitForExistence(timeout: 8))
        let product = app.staticTexts["非遗黑猪肉老面小笼包"]
        XCTAssertTrue(product.waitForExistence(timeout: 5))
        let libraryShot = XCTAttachment(screenshot: app.screenshot()); libraryShot.name = "常用商品与包装资料"; libraryShot.lifetime = .keepAlways; add(libraryShot)
        product.tap()
        fill("实际吃了多少只", "5")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "296 千卡")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["保存实际饮食"].tap()
        app.buttons["关闭"].tap()
        let savedMeal = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "非遗黑猪肉老面小笼包 5只")).firstMatch
        for _ in 0..<4 where !savedMeal.exists { app.swipeUp() }
        XCTAssertTrue(savedMeal.waitForExistence(timeout: 5))
        let dietShot = XCTAttachment(screenshot: app.screenshot()); dietShot.name = "按标签记录五只小笼包"; dietShot.lifetime = .keepAlways; add(dietShot)
    }
}
