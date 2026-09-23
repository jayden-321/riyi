import XCTest

final class WatchStartUITests: XCTestCase {
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
