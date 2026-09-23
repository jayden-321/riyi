import XCTest

final class FoodEntryUITests: XCTestCase {
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
            field.tap()
            if let old = field.value as? String, old != field.placeholderValue {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
            }
            field.typeText(value)
        }
        fill("商品名称", "非遗黑猪肉老面小笼包")
        fill("整包净含量", "500")
        fill("整包数量（没有可留 0）", "20")
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
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "非遗黑猪肉老面小笼包 5只")).firstMatch.waitForExistence(timeout: 5))
        let dietShot = XCTAttachment(screenshot: app.screenshot()); dietShot.name = "按标签记录五只小笼包"; dietShot.lifetime = .keepAlways; add(dietShot)
    }
}
