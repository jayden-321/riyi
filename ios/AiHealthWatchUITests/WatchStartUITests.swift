import XCTest

final class WatchStartUITests: XCTestCase {
    func testFinishedWorkoutReturnsToIdleRings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--watch-completed-rings-demo", "--watch-rings-demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["今天是休息日"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["活动 284"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["训练已结束"].exists)
    }
    func testRestDayShowsAppleActivityRingsWithoutStartTask() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--watch-rest-demo", "--watch-rings-demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["今天是休息日"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.staticTexts["活动 284"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["锻炼 11分"].exists)
        XCTAssertTrue(app.staticTexts["站立 10时"].exists)
        XCTAssertFalse(app.buttons["开始此项目"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "手表休息日活动三环"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testRestDayHidesOldEndedWorkoutAndStartButton() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--watch-rest-demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["今天是休息日"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(app.staticTexts["训练已结束"].exists)
        XCTAssertFalse(app.buttons["开始今天训练"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "休息日不展示昨天训练"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testTodayTaskStartsOnWatchAndReturnsWorkout() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let start = app.buttons["开始今天训练"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), app.debugDescription)
        let before = XCTAttachment(screenshot: app.screenshot()); before.name = "手表今日任务"; before.lifetime = .keepAlways; add(before)
        start.tap()
        XCTAssertTrue(app.buttons["开始本组"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.buttons["今日训练已开始"].waitForExistence(timeout: 30), app.debugDescription)
        let after = XCTAttachment(screenshot: app.screenshot()); after.name = "手表已进入训练"; after.lifetime = .keepAlways; add(after)
    }
}
