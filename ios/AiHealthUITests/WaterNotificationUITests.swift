import XCTest

final class WaterNotificationUITests: XCTestCase {
    func testReminderOpensDietWaterEntryWithoutLoggingUnchosenAmount() {
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--water-notification-ui-test"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["饮食"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["饮食"].isSelected)
        XCTAssertTrue(app.navigationBars["饮水"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["+ 250 ml"].exists)
        XCTAssertTrue(app.buttons["+ 500 ml"].exists)
        XCTAssertTrue(app.staticTexts["0"].exists)
        app.buttons.matching(NSPredicate(format: "label == %@", "+ 250 ml")).element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["250"].waitForExistence(timeout: 5))
    }
}
