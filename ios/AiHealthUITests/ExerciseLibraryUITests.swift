import XCTest

final class ExerciseLibraryUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchEnvironment["AIHEALTH_EXERCISE_MEDIA_BASE"] = "http://127.0.0.1:18091/media/exercises/fedb-a859101d633a"
        app.launchArguments = ["-localDemo", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["先体验本地记录"].waitForExistence(timeout: 8))
        app.buttons["先体验本地记录"].tap(); app.tabBars.buttons["训练"].tap()
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    func testBrowseSearchPhotosAndCacheSettings() {
        let app = launch()
        app.buttons["exercise-library-entry"].tap()
        XCTAssertTrue(app.navigationBars["动作库"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["876 个"].exists)
        let card = app.buttons["exercise-card-bench_press"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        app.buttons["body-part-胸"].tap()
        card.tap()
        XCTAssertTrue(app.navigationBars["动作说明"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["动作要点"].exists)
        let photo = app.buttons["放大动作照片 1"]
        XCTAssertTrue(photo.waitForExistence(timeout: 8))
        capture(app, "卧推_真实照片与动作要点")
        photo.tap(); XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5)); capture(app, "动作照片_大图"); app.buttons["完成"].tap()
        app.navigationBars["动作说明"].buttons.element(boundBy: 0).tap()
        capture(app, "动作库_缩略图与部位筛选")
        app.buttons["body-part-全部"].tap()
        let search = app.textFields["exercise-library-search"]
        search.tap(); search.typeText("no-such-exercise-98765")
        XCTAssertTrue(app.staticTexts["没有匹配的动作"].waitForExistence(timeout: 5))
        app.buttons["清除筛选"].tap()
        XCTAssertTrue(app.staticTexts["876 个"].waitForExistence(timeout: 5))
        search.tap(); search.typeText("Kettlebell Halo")
        let textOnly = app.buttons["exercise-card-fedb_Kettlebell_Halo"]
        XCTAssertTrue(textOnly.waitForExistence(timeout: 5)); textOnly.tap()
        XCTAssertTrue(app.staticTexts["暂无可用图解 · 请阅读下方动作要点"].waitForExistence(timeout: 5))
        capture(app, "无图动作_明确文字教学")
        app.navigationBars["动作说明"].buttons.element(boundBy: 0).tap()
        app.navigationBars["动作库"].buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["我的"].tap()
        let settings = app.buttons["图片缓存与下载"]
        for _ in 0..<8 where !settings.isHittable { app.swipeUp() }
        XCTAssertTrue(settings.isHittable); settings.tap()
        XCTAssertTrue(app.buttons["清理图片缓存"].exists); app.buttons["清理图片缓存"].tap()
        XCTAssertTrue(app.staticTexts["图片缓存已清理"].waitForExistence(timeout: 5))
    }
    func testChooseNewExerciseAndPreserveOldGuideLink() {
        let app = launch()
        app.buttons["编辑计划"].firstMatch.tap()
        let old = app.buttons["动作图解与说明"].firstMatch
        for _ in 0..<6 where !old.isHittable { app.swipeUp() }
        old.tap(); XCTAssertTrue(app.staticTexts["杠铃卧推"].waitForExistence(timeout: 5))
        app.navigationBars["动作说明"].buttons.element(boundBy: 0).tap()
        let addFromLibrary = app.buttons["从动作库添加"]
        for _ in 0..<12 where !addFromLibrary.isHittable { app.swipeUp() }
        XCTAssertTrue(addFromLibrary.isHittable); addFromLibrary.tap()
        let search = app.textFields["exercise-library-search"]; search.tap(); search.typeText("Dumbbell Bench Press")
        let target = app.buttons["exercise-card-fedb_Dumbbell_Bench_Press"]
        XCTAssertTrue(target.waitForExistence(timeout: 5)); target.tap()
        let add = app.buttons["添加到训练日"]
        XCTAssertTrue(add.waitForExistence(timeout: 5)); XCTAssertTrue(add.isEnabled); add.tap()
        XCTAssertTrue(app.navigationBars["编辑训练计划"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["保存"].isEnabled); app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["4 个动作"].waitForExistence(timeout: 5))
        capture(app, "动作库选入训练日")
    }
}
