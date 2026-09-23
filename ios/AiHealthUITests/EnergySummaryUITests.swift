import XCTest

final class EnergySummaryUITests: XCTestCase {
    func testEstimatedRangeIsVisibleAndNotCalledMissing() {
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--energy-summary-ui-test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["已记录热量约 1,032.5 千卡"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "715–1,350")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["0 笔单值热量，2 笔粗估范围，0 笔仍待估算。计划未吃不计入实际。"].exists)
    }
}
