import XCTest

final class EnergySummaryUITests: XCTestCase {
    func testEstimatedRangeIsVisibleAndNotCalledMissing() {
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--energy-summary-ui-test"]
        app.launch()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "已记录约 715")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["0 笔单值热量，2 笔粗估范围，0 笔仍待估算。计划未吃不计入实际。"].exists)
    }
}
