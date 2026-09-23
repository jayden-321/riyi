import XCTest

final class EnergySummaryUITests: XCTestCase {
    func testEstimatedRangeIsVisibleAndNotCalledMissing() {
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--energy-summary-ui-test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["已记录热量约 1,032.5 千卡"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "0 笔单值热量")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "AI 粗估区间")).firstMatch.exists)
    }
}
