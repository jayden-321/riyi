import XCTest

final class SleepUITests: XCTestCase {
    func testUnrequestedSleepShowsOneTimeAuthorizationReminder() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--sleep-ui-test", "--sleep-auth-reminder-ui-test"]
        app.launch()
        let card = app.buttons["sleep-summary"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        for _ in 0..<4 where !card.isHittable { app.swipeUp() }
        card.tap()
        let reminder = app.alerts["授权本机睡眠读取"]
        XCTAssertTrue(reminder.waitForExistence(timeout: 8))
        XCTAssertTrue(reminder.buttons["去授权"].exists)
        reminder.buttons["稍后"].tap()
        XCTAssertTrue(app.buttons["sleep-auth-reminder-action"].exists)
    }
    func testWeekMonthAndSelectedNight() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--sleep-ui-test"]
        app.launch()
        let card = app.buttons["sleep-summary"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<4 where !card.isHittable { app.swipeUp() }
        card.tap()
        XCTAssertTrue(app.navigationBars["睡眠"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["sleep-average"].waitForExistence(timeout: 10))
        capture(app, "睡眠周趋势（合成数据）")
        app.segmentedControls.buttons["月"].tap()
        XCTAssertTrue(app.staticTexts["30 天睡眠"].exists)
        capture(app, "睡眠月趋势（合成数据）")
        app.segmentedControls.buttons["周"].tap()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let formatter = DateFormatter(); formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let yesterday = formatter.string(from: calendar.date(byAdding: .day, value: -1, to: Date())!)
        let row = app.buttons["sleep-night-\(yesterday)"]
        for _ in 0..<5 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.exists, app.debugDescription); row.tap()
        XCTAssertTrue(app.navigationBars["当晚睡眠"].waitForExistence(timeout: 8))
        let duration = app.staticTexts["sleep-duration"]
        XCTAssertTrue(duration.waitForExistence(timeout: 10))
        XCTAssertEqual(duration.label, "6 小时 30 分钟")
        XCTAssertEqual(app.staticTexts["sleep-selected-date"].label, "\(yesterday) 醒来")
        capture(app, "点选历史日期的当晚阶段（合成数据）")
        let analyze = app.buttons["analyze-selected-night"]
        for _ in 0..<5 where !analyze.isHittable { app.swipeUp() }
        XCTAssertTrue(analyze.exists)
        XCTAssertFalse(analyze.isEnabled, "Local-only data must not silently invoke cloud AI")
        capture(app, "所选日期的睡眠分析入口（合成数据）")
        app.navigationBars.buttons.firstMatch.tap()
        let missingDate = formatter.string(from: calendar.date(byAdding: .day, value: -2, to: Date())!)
        let missing = app.buttons["sleep-night-\(missingDate)"]
        for _ in 0..<5 where !missing.isHittable { app.swipeUp() }
        missing.tap()
        XCTAssertTrue(app.staticTexts["尚未读到这晚睡眠"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["sleep-duration"].exists)
        capture(app, "缺失日期不显示零或其他晚记录（合成数据）")
        app.navigationBars.buttons.firstMatch.tap()
        let today = formatter.string(from: Date())
        let bar = app.buttons["查看 \(today) 睡眠"]
        for _ in 0..<5 where !bar.isHittable { app.swipeDown() }
        XCTAssertTrue(bar.exists, app.debugDescription); bar.tap()
        XCTAssertTrue(app.staticTexts["sleep-duration"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["sleep-selected-date"].label, "\(today) 醒来")
        XCTAssertEqual(app.staticTexts["sleep-duration"].label, "7 小时 0 分钟")
        capture(app, "点击趋势柱形打开当晚（合成数据）")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
