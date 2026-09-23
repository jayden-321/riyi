import XCTest

final class PlanningUITests: XCTestCase {
    func testRestDayCanShowRecoveryActivityAndBeDeleted() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--rest-day-ui-test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["今天是休息日"].waitForExistence(timeout: 10))
        app.buttons["查看／调整今天安排"].tap()
        let activity = app.descendants(matching: .any)["rest-recovery-activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        activity.tap(); activity.typeText("饭后散步")
        app.buttons["保存恢复活动"].tap()
        XCTAssertTrue(app.staticTexts["饭后散步"].waitForExistence(timeout: 5))
        app.buttons["查看／调整今天安排"].tap()
        app.buttons["删除今天的休息安排"].tap()
        app.buttons["删除当天安排"].tap()
        XCTAssertFalse(app.staticTexts["今天是休息日"].exists)
    }

    func testTeamRankingCardOpensWithoutAddingBottomTab() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--rest-day-ui-test"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["组团打卡"].exists)
        let card = app.buttons["today-team-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        for _ in 0..<3 where !card.isHittable { app.swipeUp() }
        card.tap()
        XCTAssertTrue(app.navigationBars["组团打卡"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["登录云端账号后可以创建或加入团队。"].exists)
    }
    func testTodayShowsScheduledRestInsteadOfEmptyPlanPrompt() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--rest-day-ui-test"]; app.launch()
        XCTAssertTrue(app.staticTexts["今天是休息日"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["从一份训练计划开始"].exists)
    }
    func testExistingPlanCanBeArrangedForToday() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--planning-ui-test"]; app.launch()
        app.tabBars.buttons["训练"].tap()
        let template = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "schedule-template-")).firstMatch
        XCTAssertTrue(template.waitForExistence(timeout: 8)); template.tap()
        XCTAssertTrue(app.navigationBars["安排已有计划"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["增肌计划 A"].exists)
        XCTAssertTrue(app.buttons["安排所选 1 天到日历"].exists)
        app.buttons["schedule-existing-plan"].tap()
        XCTAssertTrue(app.staticTexts["胸 + 三头"].waitForExistence(timeout: 6))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "已有训练模板安排到今天"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testAccountEntrancesAndProfileMetricsAreInside() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--planning-ui-test"]; app.launch()
        app.tabBars.buttons["我的"].tap()
        for id in ["account-profile", "account-teams", "account-health", "account-images", "account-ai", "account-sync", "account-data"] {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), "Missing \(id)")
        }
        XCTAssertFalse(app.staticTexts["BMI"].exists)
        let menu = XCTAttachment(screenshot: app.screenshot()); menu.name = "我的入口"; menu.lifetime = .keepAlways; add(menu)
        app.buttons["account-profile"].tap()
        XCTAssertTrue(app.navigationBars["我的健康档案"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["BMI"].exists)
        XCTAssertTrue(app.staticTexts["体脂率"].exists)
        app.navigationBars["我的健康档案"].buttons.element(boundBy: 0).tap()
        app.buttons["account-images"].tap()
        XCTAssertTrue(app.buttons["exercise-library-entry"].exists)
        XCTAssertTrue(app.buttons["图片缓存与下载"].exists)
    }
    func testDietCalendarExtraMealAndPlanningChatEntry() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--planning-ui-test"]; app.launch()
        XCTAssertTrue(app.navigationBars["饮食"].waitForExistence(timeout: 10))
        let addMeal = app.buttons["add-meal-log"]; XCTAssertTrue(addMeal.waitForExistence(timeout: 5)); addMeal.tap()
        let input = app.textFields["meal-description"].exists ? app.textFields["meal-description"] : app.textViews["meal-description"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("蛋糕一小块")
        app.buttons["save-meal-log"].tap()
        XCTAssertTrue(app.staticTexts["蛋糕一小块"].waitForExistence(timeout: 5));XCTAssertTrue(app.staticTexts["热量待估算"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot());shot.name = "饮食日历与临时加餐";shot.lifetime = .keepAlways;add(shot)
        app.buttons["和 AI 安排饮食周期"].tap()
        XCTAssertTrue(app.navigationBars["饮食周期"].waitForExistence(timeout: 5));XCTAssertTrue(app.buttons["一周"].exists)
        app.buttons["自定义"].tap();XCTAssertTrue(app.staticTexts["结束日期"].exists)
        app.buttons["取消"].tap();app.tabBars.buttons["训练"].tap()
        XCTAssertTrue(app.navigationBars["训练"].waitForExistence(timeout: 5));XCTAssertTrue(app.buttons["我的计划与历史记录"].exists)
        app.buttons["月历"].tap();XCTAssertTrue(app.buttons["收起"].exists)
    }
}
