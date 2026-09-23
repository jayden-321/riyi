import XCTest

final class SessionRecoveryUITests: XCTestCase {
    func testExpiredSessionOffersLoginAndMyEntryWithoutLoggingOut() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--session-expired-ui-test"]
        app.launch()
        XCTAssertTrue(app.navigationBars["云端账号"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["reauth-email"].exists)
        XCTAssertTrue(app.buttons["reauth-submit"].exists)
        app.buttons["稍后"].tap()
        XCTAssertTrue(app.buttons["云端登录已过期 · 重新登录"].waitForExistence(timeout: 5))
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.buttons["account-reauth"].waitForExistence(timeout: 5))
        app.buttons["account-reauth"].tap()
        XCTAssertTrue(app.navigationBars["云端账号"].waitForExistence(timeout: 5))
    }
}
