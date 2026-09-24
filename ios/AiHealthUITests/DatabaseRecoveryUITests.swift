import XCTest

final class DatabaseRecoveryUITests: XCTestCase {
    func testStoreFailureShowsNonDestructiveRecoveryInsteadOfCrashing() {
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--database-unavailable-ui-test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["database-unavailable"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "不要卸载")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["合成数据库打开失败"].exists)
    }
}
