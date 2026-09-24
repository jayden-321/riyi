import XCTest

final class WaterNotificationUITests: XCTestCase {
    func testWaterDetailUsesDietCalendarSelection() {
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--planning-ui-test"]
        app.launch()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        let key = formatter.string(from: yesterday)
        let day = app.buttons["calendar-\(key)"]
        if !day.exists { app.buttons["上一周"].tap() }
        XCTAssertTrue(day.waitForExistence(timeout: 5))
        day.tap()
        app.buttons["饮水记录、补记与提醒"].tap()
        XCTAssertTrue(app.staticTexts["\(key) 已记录"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["这一天还没有饮水记录"].exists)
        app.buttons["+ 250 ml"].tap()
        XCTAssertTrue(app.staticTexts["250"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["250 ml"].exists)
    }
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
