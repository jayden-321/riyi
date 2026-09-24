import XCTest

final class WeightUITests: XCTestCase {
    func testHomeWeightOpensHistoryAndShowsTrend() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--weight-ui-test"]
        app.launch()
        let card = app.buttons["weight-summary"]
        XCTAssertTrue(card.waitForExistence(timeout: 12))
        for _ in 0..<5 where !card.isHittable { app.swipeUp() }
        card.tap()
        XCTAssertTrue(app.navigationBars["体重"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["weight-trend"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "最近测量")).firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "体重历史_曲线和测量列表"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.navigationBars["体重"].buttons.element(boundBy: 0).tap()
        let resting = app.buttons["resting-heart-summary"]
        XCTAssertTrue(resting.waitForExistence(timeout: 8))
        for _ in 0..<4 where !resting.isHittable { app.swipeUp() }
        resting.tap()
        XCTAssertTrue(app.navigationBars["静息心率"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["vital-trend"].waitForExistence(timeout: 12))
        app.navigationBars["静息心率"].buttons.element(boundBy: 0).tap()
        let hrv = app.buttons["hrv-summary"]
        XCTAssertTrue(hrv.waitForExistence(timeout: 8))
        for _ in 0..<4 where !hrv.isHittable { app.swipeUp() }
        hrv.tap()
        XCTAssertTrue(app.navigationBars["HRV"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["vital-trend"].waitForExistence(timeout: 12))
    }
}
