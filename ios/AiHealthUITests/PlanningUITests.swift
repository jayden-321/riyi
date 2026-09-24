import XCTest

final class PlanningUITests: XCTestCase {
    func testActivityRingsOpenSelectedDayDetails() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--activity-rings-ui-test"]
        app.launch()
        XCTAssertTrue(app.navigationBars["训练"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["open-activity-details"].waitForExistence(timeout: 5))
        app.buttons["open-activity-details"].tap()
        XCTAssertTrue(app.navigationBars["活动详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["选择日期"].exists)
        XCTAssertTrue(app.buttons["上一周"].exists)
        XCTAssertTrue(app.staticTexts["284/1,500 千卡"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["11/30 分钟"].exists)
        XCTAssertTrue(app.staticTexts["10/12 小时"].exists)
        XCTAssertTrue(app.staticTexts["2,559"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "三环每日详情"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testAppleFitnessHIITAppearsAsCompletedTraining() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--external-workout-ui-test"]
        app.launch()
        XCTAssertTrue(app.navigationBars["训练"].waitForExistence(timeout: 10))
        let workout = app.staticTexts["HIIT 高强度间歇"]
        XCTAssertTrue(workout.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Apple 健康导入 · 已完成")).firstMatch.exists)
        workout.tap()
        XCTAssertTrue(app.staticTexts["从 Apple 健康导入 · Apple Watch"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["写入 Apple 健康"].exists)
        XCTAssertFalse(app.staticTexts["当天活动圆环"].exists)
    }
    func testSelectedDateCanCreateSportTrainingDirectly() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--planning-ui-test"]
        app.launch()
        app.tabBars.buttons["训练"].tap()
        XCTAssertFalse(app.buttons["我的计划与历史记录"].exists)
        app.buttons["schedule-training-day"].tap()
        app.buttons["plan-sport-category"].tap()
        let pilates = app.buttons["普拉提"]
        if !pilates.exists { app.buttons["plan-sport-category"].tap() }
        XCTAssertTrue(pilates.waitForExistence(timeout: 5))
        pilates.tap()
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["1. 普拉提"].waitForExistence(timeout: 6))
    }
    func testPlanEditorChoosesSportBeforeExerciseLibrary() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--planning-ui-test"]
        app.launch()
        app.tabBars.buttons["训练"].tap()
        XCTAssertFalse(app.buttons["我的计划与历史记录"].exists)
        app.buttons["schedule-training-day"].tap()
        XCTAssertTrue(app.buttons["plan-sport-category"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["choose-library-exercise"].exists)
        XCTAssertFalse(app.textFields["动作名称"].exists)
        app.buttons["plan-sport-category"].tap()
        app.buttons["游泳"].tap()
        XCTAssertTrue(app.textFields["目标距离（米，可选）"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["choose-library-exercise"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "游泳计划按时长和距离编辑"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testRestDayCanBecomeWalkingTrainingAndBeDeleted() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--rest-day-ui-test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["今天是休息日"].waitForExistence(timeout: 10))
        app.buttons["查看／调整今天安排"].tap()
        let activity = app.descendants(matching: .any)["activity-name"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        XCTAssertEqual(activity.value as? String, "饭后散步")
        app.buttons["安排为训练"].tap()
        XCTAssertTrue(app.staticTexts["1. 饭后散步"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["今天是休息日"].exists)
        app.tabBars.buttons["训练"].tap()
        app.buttons["scheduled-activity"].tap()
        let deleteButtons = app.buttons.matching(NSPredicate(format: "label == %@", "删除当前训练"))
        deleteButtons.element(boundBy: 0).tap()
        deleteButtons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["这一天尚未安排训练"].waitForExistence(timeout: 5))
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
    func testManualCycleCanEditTrainingForSelectedDate() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--planning-ui-test"]; app.launch()
        app.tabBars.buttons["训练"].tap()
        app.buttons["安排训练周期"].tap()
        XCTAssertTrue(app.buttons["manual-training-cycle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ai-training-cycle"].exists)
        app.buttons["manual-training-cycle"].tap()
        XCTAssertTrue(app.navigationBars["手动编辑周期"].waitForExistence(timeout: 5))
        let trainingDay = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "manual-day-toggle-")).firstMatch
        XCTAssertTrue(trainingDay.waitForExistence(timeout: 5))
        XCTAssertTrue(trainingDay.isHittable)
        // SwiftUI exposes the whole Form row as a Switch; tap the visible
        // trailing control rather than its label/row midpoint.
        trainingDay.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
        XCTAssertEqual(trainingDay.value as? String, "1")
        XCTAssertTrue(app.navigationBars["手动编辑周期"].exists)
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "edit-cycle-day-")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        app.buttons["plan-sport-category"].tap()
        app.buttons["普拉提"].tap()
        app.navigationBars["编辑训练项目"].buttons["保存"].tap()
        app.buttons["save-manual-training-cycle"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "普拉提")).firstMatch.waitForExistence(timeout: 6))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "手动周期安排到日历"; attachment.lifetime = .keepAlways; add(attachment)
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
        XCTAssertTrue(app.staticTexts["另有 1 笔热量未估算"].waitForExistence(timeout: 5))
        let savedMeal = app.staticTexts["蛋糕一小块"]
        for _ in 0..<4 where !savedMeal.exists { app.swipeUp() }
        XCTAssertTrue(savedMeal.exists)
        XCTAssertTrue(app.staticTexts["热量待估算"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot());shot.name = "饮食日历与临时加餐";shot.lifetime = .keepAlways;add(shot)
        app.buttons["和 AI 安排饮食周期"].tap()
        XCTAssertTrue(app.navigationBars["饮食周期"].waitForExistence(timeout: 5));XCTAssertTrue(app.buttons["一周"].exists)
        app.buttons["自定义"].tap();XCTAssertTrue(app.staticTexts["结束日期"].exists)
        app.buttons["取消"].tap();app.tabBars.buttons["训练"].tap()
        XCTAssertTrue(app.navigationBars["训练"].waitForExistence(timeout: 5));XCTAssertTrue(app.buttons["schedule-training-day"].exists)
        XCTAssertTrue(app.buttons["安排训练周期"].exists)
        app.buttons["月历"].tap();XCTAssertTrue(app.buttons["收起"].exists)
    }
}
