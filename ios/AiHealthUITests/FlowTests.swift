import XCTest

final class FlowTests: XCTestCase {
    func testFixedCloudWelcomeAndRecoveryEntry() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launch()
        if app.tabBars.buttons["我的"].waitForExistence(timeout: 3) {
            app.tabBars.buttons["我的"].tap()
            app.buttons["account-data"].tap()
            let leave = app.buttons["退出本地体验"].exists ? app.buttons["退出本地体验"] : app.buttons["退出登录"]
            for _ in 0..<8 where !leave.isHittable { app.swipeUp() }
            leave.tap(); app.alerts.buttons["退出"].tap()
        }
        XCTAssertTrue(app.buttons["已有账号？登录"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.textFields["服务器地址"].exists)
        XCTAssertFalse(app.buttons["先体验本地记录"].exists)
        app.buttons["已有账号？登录"].tap()
        app.buttons["忘记密码？"].tap()
        XCTAssertTrue(app.navigationBars["找回密码"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["发送找回验证码"].exists)
    }

    func testClearRestoreConversationFromFixture() throws {
        continueAfterFailure = false
        struct Fixture: Decodable { let email: String; let password: String; let planName: String; let message: String }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/coach-clear-fixture.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path))
        defer { cleanupCoachAccount(email: fixture.email, password: fixture.password) }
        let app = XCUIApplication(); app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["-localDemo", "NO"]; app.launch()
        if app.tabBars.buttons["我的"].waitForExistence(timeout: 3) {
            if app.alerts.buttons["知道了"].exists { app.alerts.buttons["知道了"].tap() }
            app.tabBars.buttons["我的"].tap()
            if !app.navigationBars["我的"].exists { app.tabBars.buttons["我的"].tap() }
            let leave = app.buttons["退出本地体验"].exists ? app.buttons["退出本地体验"] : app.buttons["退出登录"]
            for _ in 0..<10 where !leave.isHittable { app.swipeUp() }
            leave.tap(); app.alerts.buttons["退出"].tap()
        }
        app.buttons["已有账号？登录"].tap()
        app.textFields["邮箱"].tap(); app.textFields["邮箱"].typeText(fixture.email)
        app.secureTextFields.firstMatch.tap(); app.secureTextFields.firstMatch.typeText(fixture.password)
        app.buttons["登录"].tap()
        XCTAssertTrue(app.tabBars.buttons["教练"].waitForExistence(timeout: 15))
        for application in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard"), XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")] {
            if application.buttons["以后"].waitForExistence(timeout: 1) { application.buttons["以后"].tap(); break }
        }
        app.tabBars.buttons["教练"].tap()
        if !app.navigationBars["AI 教练"].exists { app.tabBars.buttons["教练"].tap() }
        XCTAssertTrue(app.staticTexts[fixture.message].waitForExistence(timeout: 10))
        app.buttons["更多教练功能"].tap(); app.buttons["清空对话"].tap()
        let confirm = app.buttons.matching(identifier: "confirm-clear-coach").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.buttons["制定训练计划"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts[fixture.message].exists)
        app.tabBars.buttons["训练"].tap(); XCTAssertTrue(app.staticTexts[fixture.planName].exists)
        app.tabBars.buttons["教练"].tap(); app.buttons["更多教练功能"].tap(); app.buttons["恢复已清空对话"].tap()
        XCTAssertTrue(app.staticTexts[fixture.message].waitForExistence(timeout: 10))
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "清空恢复对话且保留计划"; image.lifetime = .keepAlways; add(image)
    }
    func testPlanGuideContinueAndDeletion() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--watch-start-pair-test"]; app.launch()
        app.tabBars.buttons["训练"].tap()
        app.staticTexts["胸 + 三头"].firstMatch.tap()
        let guide = app.buttons["动作图解与说明"].firstMatch
        for _ in 0..<5 where !guide.isHittable { app.swipeUp() }
        guide.tap(); XCTAssertTrue(app.navigationBars["动作说明"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "日历训练可打开动作说明"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.navigationBars["动作说明"].buttons.element(boundBy: 0).tap()
        app.buttons["开始训练"].tap(); XCTAssertTrue(app.navigationBars["胸 + 三头"].waitForExistence(timeout: 5))
        app.navigationBars["胸 + 三头"].buttons.element(boundBy: 0).tap()
        app.navigationBars["训练详情"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["继续训练"].waitForExistence(timeout: 5)); app.buttons["继续训练"].tap()
        XCTAssertTrue(app.navigationBars["胸 + 三头"].waitForExistence(timeout: 5))
        app.navigationBars["胸 + 三头"].buttons.element(boundBy: 0).tap()
        app.staticTexts["胸 + 三头"].firstMatch.tap()
        app.buttons["删除当天安排"].tap()
        app.buttons["删除安排"].tap()
        XCTAssertTrue(app.buttons["schedule-training-day"].exists)
        app.terminate(); app.launchArguments = []; app.launch(); app.tabBars.buttons["训练"].tap()
        XCTAssertTrue(app.staticTexts["胸 + 三头"].exists || app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "胸 + 三头")).firstMatch.exists)
    }
    func testCloudCoachGeneratesEditablePlan() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["-localDemo", "NO"]; app.launch()
        let email = UUID().uuidString.lowercased() + "@example.test", password = "CoachUITest-" + UUID().uuidString
        defer { cleanupCoachAccount(email: email, password: password) }
        if app.tabBars.buttons["我的"].waitForExistence(timeout: 3) {
            if app.alerts.buttons["知道了"].exists { app.alerts.buttons["知道了"].tap() }
            app.tabBars.buttons["我的"].tap()
            if !app.navigationBars["我的"].exists { app.tabBars.buttons["我的"].tap() }
            let leave = app.buttons["退出登录"]
            for _ in 0..<8 where !leave.isHittable { app.swipeUp() }
            leave.tap(); app.alerts.buttons["退出"].tap()
        }
        app.textFields["邮箱"].tap(); app.textFields["邮箱"].typeText(email)
        app.secureTextFields.firstMatch.tap(); app.secureTextFields.firstMatch.typeText(password)
        app.buttons["创建账号，开始记录"].tap()
        XCTAssertTrue(app.tabBars.buttons["教练"].waitForExistence(timeout: 15))
        for application in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard"), XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")] {
            if application.buttons["以后"].waitForExistence(timeout: 2) { application.buttons["以后"].tap(); break }
        }
        app.tabBars.buttons["教练"].tap()
        if !app.navigationBars["AI 教练"].exists { app.tabBars.buttons["教练"].tap() }
        XCTAssertTrue(app.navigationBars["AI 教练"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["同意并启用 AI 教练"].waitForExistence(timeout: 5), app.debugDescription); app.buttons["同意并启用 AI 教练"].tap()
        let input = app.descendants(matching: .any).matching(identifier: "coach-message-input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.tap()
        input.typeText("我想增肌，有一年经验，每周练2天，每次45分钟，健身房有杠铃哑铃绳索，无运动限制，无伤痛。没有可信的负重记录，重量请填0待确认。请生成两天计划，每天2个动作各2组，先不安排食谱。")
        app.buttons["发送"].tap()
        let planButton = app.buttons["查看 / 编辑计划"].firstMatch
        XCTAssertTrue(planButton.waitForExistence(timeout: 80), app.debugDescription)
        for _ in 0..<8 where !planButton.isHittable { app.swipeUp() }
        let coachImage = XCTAttachment(screenshot: app.screenshot()); coachImage.name = "AI教练生成计划"; coachImage.lifetime = .keepAlways; add(coachImage)
        planButton.tap()
        let planName = app.textFields["名称"].value as? String ?? ""
        XCTAssertFalse(planName.isEmpty); XCTAssertTrue(app.buttons["保存"].isEnabled); app.buttons["保存"].tap()
        let arrange = app.buttons["安排到训练日历"].firstMatch
        XCTAssertTrue(arrange.waitForExistence(timeout: 5)); arrange.tap()
        let adopt = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "采用所选")).firstMatch
        for _ in 0..<8 where !adopt.isHittable { app.swipeUp() }
        XCTAssertTrue(adopt.isEnabled); adopt.tap()
        app.tabBars.buttons["训练"].tap()
        XCTAssertTrue(app.staticTexts[planName].waitForExistence(timeout: 5))
        app.tabBars.buttons["教练"].tap()
        let preferences = app.buttons["教练资料与定时分析"]
        app.buttons["更多教练功能"].tap(); app.buttons["清空对话"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "confirm-clear-coach").firstMatch.waitForExistence(timeout: 5)); app.buttons.matching(identifier: "confirm-clear-coach").firstMatch.tap()
        XCTAssertTrue(app.buttons["制定训练计划"].waitForExistence(timeout: 10)); XCTAssertFalse(planButton.exists)
        app.tabBars.buttons["训练"].tap(); XCTAssertTrue(app.staticTexts[planName].exists)
        app.tabBars.buttons["教练"].tap(); app.buttons["更多教练功能"].tap(); app.buttons["恢复已清空对话"].tap()
        XCTAssertTrue(planButton.waitForExistence(timeout: 10))
        for _ in 0..<8 where !preferences.isHittable { app.swipeDown() }
        preferences.tap()
        XCTAssertTrue(app.staticTexts["健身 · 晚上分析，早上提醒"].waitForExistence(timeout: 5))
        let timingImage = XCTAttachment(screenshot: app.screenshot()); timingImage.name = "AI教练资料与两条定时策略"; timingImage.lifetime = .keepAlways; add(timingImage)
    }
    private func cleanupCoachAccount(email: String, password: String) {
        func call(_ path: String, method: String, token: String? = nil) -> Data? {
            var request = URLRequest(url: URL(string: "https://health.gzqy.xyz" + path)!); request.httpMethod = method; request.timeoutInterval = 12
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            request.httpBody = try? JSONSerialization.data(withJSONObject: method == "DELETE" ? ["password": password] : ["email": email, "password": password, "timezone": "Asia/Shanghai"])
            let semaphore = DispatchSemaphore(value: 0); var output: Data?
            URLSession.shared.dataTask(with: request) { data, _, _ in output = data; semaphore.signal() }.resume()
            _ = semaphore.wait(timeout: .now() + 15); return output
        }
        if let data = call("/v1/auth/login", method: "POST"), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let token = json["access_token"] as? String { _ = call("/v1/account", method: "DELETE", token: token) }
    }
    func testTrainingMethodsAndVolumeTarget() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["--watch-start-pair-test"]; app.launch()
        app.tabBars.buttons["训练"].tap(); app.staticTexts["胸 + 三头"].firstMatch.tap(); app.buttons["调整训练安排"].tap()
        let pattern = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "默认组模式")).firstMatch
        XCTAssertTrue(pattern.waitForExistence(timeout: 5)); pattern.tap(); app.buttons["金字塔组"].tap()
        app.buttons["10 吨"].tap()
        XCTAssertTrue(app.buttons["保存"].isHittable); XCTAssertTrue(app.buttons["保存"].isEnabled); app.buttons["保存"].tap()
        XCTAssertTrue(app.buttons["开始训练"].waitForExistence(timeout: 5)); app.buttons["开始训练"].tap()
        app.tabBars.buttons["今天"].tap()
        let ongoing = app.buttons["继续训练"]
        XCTAssertTrue(ongoing.waitForExistence(timeout: 5), app.debugDescription); ongoing.tap()
        XCTAssertTrue(app.staticTexts["目标 10 吨 · 还差 10 吨"].waitForExistence(timeout: 5))
        let stars = app.buttons["主观难度，4 颗星"].firstMatch
        for _ in 0..<3 where !stars.isHittable { app.swipeUp() }
        stars.tap(); XCTAssertEqual(stars.value as? String, "已选")
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "金字塔组容量目标与五星难度"; capture.lifetime = .keepAlways; self.add(capture)
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["继续训练"].waitForExistence(timeout: 5)); app.buttons["继续训练"].tap()
        XCTAssertTrue(app.staticTexts["目标 10 吨 · 还差 10 吨"].waitForExistence(timeout: 5))
        let restoredStars = app.buttons["主观难度，4 颗星"].firstMatch
        for _ in 0..<5 where !restoredStars.isHittable { app.swipeUp() }
        XCTAssertEqual(restoredStars.value as? String, "已选")
    }
    func testLightAppearanceAndHistoryWindow() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString; app.launchArguments = ["--allow-local-demo-ui-test"]; app.launch()
        if app.buttons["先体验本地记录"].waitForExistence(timeout: 5) { app.buttons["先体验本地记录"].tap() }
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 5)); app.tabBars.buttons["我的"].tap()
        let picker = app.descendants(matching: .any).matching(identifier: "health-history-window").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.tap()
        app.buttons["近 30 天"].tap()
        XCTAssertTrue(app.staticTexts["近 30 天"].waitForExistence(timeout: 5))
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "浅色健康设置与范围"; image.lifetime = .keepAlways; add(image)
        app.terminate(); app.launch(); app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.staticTexts["近 30 天"].waitForExistence(timeout: 5))
        app.descendants(matching: .any).matching(identifier: "health-history-window").firstMatch.tap()
        app.buttons["近 1 年"].tap()
        XCTAssertTrue(app.staticTexts["近 1 年"].waitForExistence(timeout: 5))
    }
    func testLocalHealthEntryDoesNotRequireAccountOrServer() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString; app.launchArguments = ["--allow-local-demo-ui-test"]; app.launch()
        if app.buttons["先体验本地记录"].waitForExistence(timeout: 5) { app.buttons["先体验本地记录"].tap() }
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 5)); app.tabBars.buttons["我的"].tap()
        let read = app.buttons["read-local-health"]
        XCTAssertTrue(read.waitForExistence(timeout: 5)); XCTAssertTrue(read.isEnabled)
        XCTAssertTrue(app.staticTexts["无需登录或连接服务器。由你在系统授权页选择数据类型，读取后先保存在本机。"].exists)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "无需服务器的健康读取入口"; image.lifetime = .keepAlways; add(image)
    }
    func testCloudAIConfiguration() throws {
        try runCloudConfiguration(server: "http://localhost:18089")
    }
    func testBWGRegistrationAndAIConfiguration() throws {
        try runCloudConfiguration(server: "https://health.gzqy.xyz")
    }
    private func runCloudConfiguration(server: String) throws {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "系统密码保存提示") { alert in
            if alert.buttons["以后"].exists { alert.buttons["以后"].tap(); return true }
            if alert.buttons["Not Now"].exists { alert.buttons["Not Now"].tap(); return true }
            return false
        }
        let app = XCUIApplication(); app.launchEnvironment["AIHEALTH_TEST_SERVER_URL"] = server; app.launch()
        if app.tabBars.buttons["我的"].waitForExistence(timeout: 4) {
            app.tabBars.buttons["我的"].tap()
            let leave = app.buttons["退出本地体验"].exists ? app.buttons["退出本地体验"] : app.buttons["退出登录"]
            for _ in 0..<4 where !leave.isHittable { app.swipeUp() }
            XCTAssertTrue(leave.exists); leave.tap(); app.alerts.buttons["退出"].tap()
        }
        let email = UUID().uuidString.lowercased() + "@example.test"
        let password = "UiTestPass" + String(UUID().uuidString.prefix(8))
        let emailField = app.textFields["邮箱"]; XCTAssertTrue(emailField.waitForExistence(timeout: 6)); emailField.tap(); emailField.typeText(email)
        let passwordField = app.secureTextFields.firstMatch; passwordField.tap()
        if let current = passwordField.value as? String, current != passwordField.placeholderValue { passwordField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)) }
        passwordField.typeText(password)
        app.buttons["创建账号，开始记录"].tap()
        let signedIn = app.tabBars.buttons["我的"].waitForExistence(timeout: 15)
        if !signedIn { let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "登录联调"; capture.lifetime = .keepAlways; self.add(capture) }
        XCTAssertTrue(signedIn, app.alerts.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " / "))
        for application in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard"), XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")] {
            if application.buttons["以后"].waitForExistence(timeout: 2) { application.buttons["以后"].tap(); break }
        }
        let beforeTab = XCTAttachment(screenshot: app.screenshot()); beforeTab.name = "登录后首页"; beforeTab.lifetime = .keepAlways; add(beforeTab)
        app.tabBars.buttons["我的"].tap()
        if !app.navigationBars["我的"].exists { app.tabBars.buttons["我的"].tap() }
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 5))
        let account = XCTAttachment(screenshot: app.screenshot()); account.name = "账号页面"; account.lifetime = .keepAlways; add(account)
        let config = app.descendants(matching: .any).matching(identifier: "ai-config-link").firstMatch
        for _ in 0..<4 where !config.isHittable { app.swipeUp() }
        XCTAssertTrue(config.waitForExistence(timeout: 5), app.debugDescription); config.tap()
        XCTAssertTrue(app.staticTexts["密钥已配置"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["模型名称"].value as? String, "gpt-5.6-terra")
        XCTAssertEqual(app.textFields["https://api.example.com/v1"].value as? String, "https://cpa.fastto.top/v1")
        app.buttons["保存配置"].tap()
        XCTAssertTrue(app.staticTexts["配置已保存"].waitForExistence(timeout: 8))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "AI 服务配置"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let delete = app.buttons["删除账号与数据"]
        for _ in 0..<6 where !delete.isHittable { app.swipeUp() }
        XCTAssertTrue(delete.exists); delete.tap()
        let confirmPassword = app.secureTextFields["输入当前账号密码"]; XCTAssertTrue(confirmPassword.waitForExistence(timeout: 5)); confirmPassword.tap(); confirmPassword.typeText(password)
        app.buttons["永久删除"].tap(); app.buttons["确认删除"].tap()
        XCTAssertTrue(app.buttons["创建账号，开始记录"].waitForExistence(timeout: 10))
    }

    func testLocalTrainingAndWater() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchEnvironment["AIHEALTH_UI_TEST_STORE"] = UUID().uuidString
        // The fresh database must also enter demo mode afresh to create its starter plan.
        app.launchArguments = ["-localDemo", "NO", "--allow-local-demo-ui-test"]; app.launch()
        if app.tabBars.buttons["我的"].waitForExistence(timeout: 3) {
            if app.alerts.buttons["知道了"].exists { app.alerts.buttons["知道了"].tap() }
            app.tabBars.buttons["我的"].tap()
            if !app.navigationBars["我的"].exists { app.tabBars.buttons["我的"].tap() }
            let leave = app.buttons["退出登录"]
            for _ in 0..<10 where !leave.isHittable { app.swipeUp() }
            leave.tap(); app.alerts.buttons["退出"].tap()
        }
        if app.buttons["先体验本地记录"].waitForExistence(timeout: 8) { app.buttons["先体验本地记录"].tap() }
        XCTAssertTrue(app.tabBars.buttons["今天"].waitForExistence(timeout: 8))
        if app.buttons["开始训练"].exists { app.buttons["开始训练"].tap() }
        XCTAssertTrue(app.buttons["继续训练"].waitForExistence(timeout: 5)); app.buttons["继续训练"].tap()
        let reps = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "actual-reps-")).firstMatch
        XCTAssertTrue(reps.waitForExistence(timeout: 5))
        app.buttons["动作图解与说明"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["怎么做"].waitForExistence(timeout: 5))
        let guideImage = XCTAttachment(screenshot: app.screenshot()); guideImage.name = "卧推动作图解与步骤"; guideImage.lifetime = .keepAlways; add(guideImage)
        app.navigationBars["动作说明"].buttons.element(boundBy: 0).tap()
        reps.tap(); let old = reps.value as? String ?? "12"
        reps.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "8")
        XCTAssertEqual(reps.value as? String, "8")
        let start = app.buttons["开始本组"].firstMatch; XCTAssertTrue(start.exists); start.tap()
        let finish = app.buttons["完成本组"].firstMatch; XCTAssertTrue(finish.exists); finish.tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "实际训练记录"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["饮水"].tap()
        XCTAssertTrue(app.buttons["+ 250 ml"].waitForExistence(timeout: 5)); app.buttons["+ 250 ml"].tap()
        XCTAssertTrue(app.staticTexts["250"].waitForExistence(timeout: 3))
        let water = XCTAttachment(screenshot: app.screenshot()); water.name = "饮水记录"; water.lifetime = .keepAlways; add(water)
        app.terminate(); app.launchArguments = []; app.launch()
        app.tabBars.buttons["训练"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "1/")).firstMatch.waitForExistence(timeout: 5))
    }
}
