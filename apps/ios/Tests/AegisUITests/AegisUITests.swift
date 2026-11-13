import XCTest
import UIKit
import Vision

@MainActor
final class AegisUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testBrowserStartsAndNavigatesOfflineFixture() {
        let app = launchApp()
        XCTAssertTrue(app.textFields["address-field"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["page-protection"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["webextension-status"].exists)

        let address = app.textFields["address-field"]
        address.tap()
        address.clearAndType("aegis://injection")
        address.typeText("\n")
        XCTAssertTrue(app.webViews.staticTexts["页面提示注入已隔离"].waitForExistence(timeout: 8))
    }

    func testPolicyBlocksHighRiskURLBeforeNetwork() {
        let app = launchApp()
        let address = app.textFields["address-field"]
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        address.tap()
        address.clearAndType("aegis://injection")
        address.typeText("\n")
        XCTAssertTrue(app.webViews.staticTexts["页面提示注入已隔离"].waitForExistence(timeout: 8))

        address.tap()
        address.clearAndType("http://paypal.example.top/login/paypal?utm_source=message")
        address.typeText("\n")

        let banner = app.descendants(matching: .any)["navigation-policy-blocked"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已阻止高风险导航"].exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '请求未加载'")
        ).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["page-protection-blocked"].exists)
        XCTAssertFalse(app.webViews.staticTexts["页面提示注入已隔离"].exists)
    }

    func testPolicySanitizesTrackingURLBeforeLoad() {
        let app = launchApp()
        let address = app.textFields["address-field"]
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        address.tap()
        address.clearAndType("https://example.com/?utm_source=feed&keep=1")
        address.typeText("\n")

        let banner = app.descendants(matching: .any)["navigation-policy-sanitized"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已清理追踪参数"].exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'utm_source'")
        ).firstMatch.exists)
        let cleanedAddress = NSPredicate(
            format: "value == %@",
            "https://example.com/?keep=1"
        )
        expectation(for: cleanedAddress, evaluatedWith: address)
        waitForExpectations(timeout: 8)
    }

    func testPrivateProfileKeepsFeaturesAvailable() {
        let app = launchApp()
        tapBrowserButton("profile-menu", in: app)
        app.buttons["私密"].tap()
        XCTAssertEqual(app.buttons["page-protection"].value as? String, "私密浏览：不记录历史，保存和发送资料前需确认")
        app.buttons["browser-more"].tap()
        XCTAssertTrue(app.buttons["agent-button"].exists)
        XCTAssertTrue(app.buttons["agent-button"].isEnabled)
        XCTAssertTrue(app.buttons["data-button"].isEnabled)
    }

    func testPrivateBookmarkOrganizerUsesSavedBookmarksAndRequiresApproval() {
        let app = launchApp()
        tapBrowserButton("profile-menu", in: app); app.buttons["私密"].tap()
        openAgent(app)
        app.buttons["workflow-browserManager"].tap()
        XCTAssertTrue(app.staticTexts["pre-consent-zero-io"].waitForExistence(timeout: 5))
        app.buttons["approve-task-button"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["action-approval-screen"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["收藏夹整理已应用"].exists)
        let apply = app.buttons["confirm-bookmark-action"]
        XCTAssertTrue(scrollUntilVisible(apply, in: app)); apply.tap()
        XCTAssertTrue(app.staticTexts["收藏夹整理已应用"].waitForExistence(timeout: 8))
        attachScreenshot("私密模式整理已保存收藏仍需两次确认", app)
    }

    func testPrivateSaveAndDownloadRequireConfirmation() async throws {
        let app = launchApp()
        let marker = "AEGISPRIVATE_" + UUID().uuidString
        tapBrowserButton("profile-menu", in: app); app.buttons["私密"].tap()
        navigate(app, to: "http://127.0.0.1:8768/article?case=" + marker)
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 12))
        tapBrowserButton("page-actions", in: app); app.buttons["toggle-bookmark"].tap()
        XCTAssertTrue(app.alerts["修改已保存的收藏？"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "http://127.0.0.1:8768/article?case=" + marker)).firstMatch.exists)
        app.alerts.buttons["取消"].tap()
        tapBrowserButton("page-actions", in: app)
        XCTAssertEqual(app.buttons["toggle-bookmark"].label, "添加收藏")
        app.buttons["toggle-bookmark"].tap(); app.alerts["修改已保存的收藏？"].buttons["确认修改"].firstMatch.tap()
        tapBrowserButton("data-button", in: app)
        XCTAssertTrue(app.staticTexts["private-library-notice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch.waitForExistence(timeout: 5))
        app.segmentedControls.buttons["历史"].tap()
        XCTAssertTrue(app.staticTexts["暂无历史"].exists)
        app.segmentedControls.buttons["工作区"].tap(); app.buttons["save-workspace"].tap()
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS '当前私密标签的网址'")).firstMatch.exists)
        app.alerts.buttons["取消"].tap()
        app.buttons["save-workspace"].tap()
        app.alerts.textFields.firstMatch.tap(); app.alerts.textFields.firstMatch.typeText("主动保存私密工作区")
        app.alerts.buttons["保存"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '主动保存私密工作区'")).firstMatch.waitForExistence(timeout: 5))
        attachScreenshot("私密收藏与工作区由用户确认保存", app)
        app.buttons["完成"].tap()
        tapBrowserButton("downloads-button", in: app)
        let address = app.textFields["download-url"]
        address.tap(); address.typeText("http://127.0.0.1:8768/download.bin?case=" + marker)
        app.buttons["start-download"].tap()
        XCTAssertTrue(app.alerts["保存私密浏览中的下载？"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "http://127.0.0.1:8768/download.bin?case=" + marker)).firstMatch.exists)
        try await assertFixtureRequests(marker, model: 0, download: 0)
        app.alerts.buttons["取消"].tap()
        try await assertFixtureRequests(marker, model: 0, download: 0)
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["暂无下载"], in: app))
        for _ in 0..<6 {
            if app.buttons["start-download"].isHittable { break }
            app.swipeDown()
        }
        app.buttons["start-download"].tap(); app.alerts["保存私密浏览中的下载？"].buttons["确认下载并保留记录"].firstMatch.tap()
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["已完成"].firstMatch, in: app))
        try await assertFixtureRequests(marker, model: 0, download: 1)
        attachScreenshot("私密下载确认后完成并保留记录", app)
        app.buttons["完成"].tap()
        tapBrowserButton("profile-menu", in: app); app.buttons["普通"].tap()
        tapBrowserButton("downloads-button", in: app)
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["已完成"].firstMatch, in: app))
    }

    func testPrivateAssistantSendsOnlyAfterConsentAndSavesOnlyOnRequest() async throws {
        let app = launchApp()
        let marker = "AEGISPRIVATE_" + UUID().uuidString
        navigate(app, to: "http://127.0.0.1:8768/article-two")
        XCTAssertTrue(app.webViews.staticTexts["绿地改造补充说明"].waitForExistence(timeout: 12))
        app.buttons["browser-more"].tap(); app.buttons["设置"].tap(); app.buttons["模型服务"].tap()
        let endpoint = app.textFields["model-endpoint"]
        endpoint.tap(); endpoint.clearAndType("http://127.0.0.1:8768/v1")
        let model = app.textFields["model-name"]
        model.tap(); model.clearAndType("aegis-simulator-fixture")
        app.buttons["save-model"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["完成"].tap()
        tapBrowserButton("profile-menu", in: app); app.buttons["私密"].tap()
        navigate(app, to: "http://127.0.0.1:8768/article?case=" + marker)
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 12))
        tapBrowserButton("agent-button", in: app)
        XCTAssertTrue(app.staticTexts["private-assistant-notice"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches.matching(NSPredicate(format: "label CONTAINS '第二篇合成来源'")).firstMatch.exists)
        let goal = app.textFields["assistant-goal"].exists ? app.textFields["assistant-goal"] : app.textViews["assistant-goal"]
        goal.tap(); goal.clearAndType("总结主要内容并引用来源 " + marker)
        let read = app.buttons["read-pages"]
        XCTAssertTrue(scrollUntilVisible(read, in: app)); read.tap()
        XCTAssertTrue(app.staticTexts["等待确认发送"].waitForExistence(timeout: 8))
        try await assertFixtureRequests(marker, model: 0, download: 0)
        let analyze = app.buttons["analyze-pages"]
        XCTAssertTrue(scrollUntilVisible(analyze, in: app)); analyze.tap()
        XCTAssertTrue(app.staticTexts["private-model-send-notice"].waitForExistence(timeout: 5))
        try await assertFixtureRequests(marker, model: 0, download: 0)
        app.navigationBars.buttons["取消"].tap()
        try await assertFixtureRequests(marker, model: 0, download: 0)
        XCTAssertTrue(scrollUntilVisible(analyze, in: app)); analyze.tap()
        let confirm = app.buttons["confirm-model-send"]
        XCTAssertTrue(scrollUntilVisible(confirm, in: app)); confirm.tap()
        let done = expectation(for: NSPredicate(format: "label == %@", "已完成"), evaluatedWith: app.staticTexts["assistant-status"])
        await fulfillment(of: [done], timeout: 20)
        try await assertFixtureRequests(marker, model: 1, download: 0)
        let history = app.buttons["assistant-history"]
        revealAssistantHistory(in: app)
        history.tap()
        XCTAssertTrue(app.staticTexts["暂无任务记录"].waitForExistence(timeout: 5))
        attachScreenshot("私密分析完成但不自动建立任务记录", app)
        app.navigationBars["任务记录"].buttons["完成"].tap()
        let save = app.buttons["save-assistant-report"]
        XCTAssertTrue(scrollUntilVisible(save, in: app)); save.tap()
        XCTAssertTrue(app.alerts["保存私密分析结果？"].waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
        revealAssistantHistory(in: app)
        history.tap(); XCTAssertTrue(app.staticTexts["暂无任务记录"].waitForExistence(timeout: 5))
        app.navigationBars["任务记录"].buttons["完成"].tap()
        XCTAssertTrue(scrollUntilVisible(save, in: app)); save.tap()
        app.alerts["保存私密分析结果？"].buttons["确认保存"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["研究结果已加密保存。"].waitForExistence(timeout: 5))
        attachScreenshot("私密分析经明确确认后保存", app)
        app.terminate(); app.launchArguments += ["--ui-testing-assistant-history-keep", "--ui-testing-windows-keep"]; app.launch()
        XCTAssertTrue(app.buttons["page-protection"].waitForExistence(timeout: 8))
        XCTAssertFalse((app.buttons["page-protection"].value as? String ?? "").contains("私密浏览"))
        tapBrowserButton("profile-menu", in: app); app.buttons["私密"].tap()
        XCTAssertEqual(app.textFields["address-field"].value as? String, "aegis://start")
        tapBrowserButton("agent-button", in: app); app.buttons["assistant-history"].tap()
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5)); record.tap()
        XCTAssertTrue(app.staticTexts["saved-assistant-report"].waitForExistence(timeout: 5))
    }

    func testRealPageModelAndCitation() {
        let app = launchApp()
        navigate(app, to: "http://127.0.0.1:8768/article")
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 12))
        app.buttons["browser-more"].tap()
        app.buttons["设置"].tap()
        app.buttons["模型服务"].tap()
        let endpoint = app.textFields["model-endpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        endpoint.tap(); endpoint.clearAndType("http://127.0.0.1:8768/v1")
        app.buttons["detect-models"].tap()
        XCTAssertTrue(app.staticTexts["连接成功，请选择模型并保存。"].waitForExistence(timeout: 12))
        app.buttons["save-model"].tap()
        XCTAssertTrue(app.staticTexts["模型设置已保存。"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["完成"].tap()
        tapBrowserButton("agent-button", in: app)
        XCTAssertTrue(app.buttons["read-pages"].waitForExistence(timeout: 5))
        app.buttons["read-pages"].tap()
        XCTAssertTrue(app.staticTexts["等待确认发送"].waitForExistence(timeout: 8))
        let analyze = app.buttons["analyze-pages"]
        XCTAssertTrue(scrollUntilVisible(analyze, in: app)); analyze.tap()
        app.buttons["confirm-model-send"].tap()
        let output = app.staticTexts["assistant-output"]
        XCTAssertTrue(output.waitForExistence(timeout: 15))
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "已完成"), object: app.staticTexts["assistant-status"])
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 15), .completed)
        XCTAssertTrue(output.label.contains("12 公顷"))
        XCTAssertTrue(output.label.contains("[1]"))
        XCTAssertFalse(output.label.contains("10 个来源已交叉核对"))
        XCTAssertTrue(scrollUntilVisible(output, in: app))
        attachScreenshot("真实页面与合成模型结果", app)
        let save = app.buttons["save-assistant-report"]
        XCTAssertTrue(scrollUntilVisible(save, in: app)); save.tap()
        app.terminate(); app.launchArguments.append("--ui-testing-assistant-history-keep"); app.launch()
        tapBrowserButton("agent-button", in: app)
        app.buttons["assistant-history"].tap()
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS '总结主要内容'")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5)); record.tap()
        XCTAssertTrue(app.staticTexts["saved-assistant-report"].waitForExistence(timeout: 5))
        attachScreenshot("重启后加密保存的研究结果", app)
        let resume = app.buttons["resume-assistant-task"].firstMatch
        XCTAssertTrue(scrollUntilVisible(resume, in: app)); resume.tap()
        XCTAssertTrue(app.staticTexts["任务已恢复，请重新读取页面并确认发送。"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["analyze-pages"].exists)
    }

    func testExpiredActionDisplaysLocalizedError() async throws {
        let variants = [
            ("en", "The action confirmation has expired."),
            ("zh-Hans", "动作确认已过期"),
            ("zh-Hant-HK", "操作確認已過期"),
        ]
        for (language, expected) in variants {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "-AppleLanguages", "(\(language))"]
            app.launch()
            app.buttons["browser-more"].tap()
            let assistant = app.buttons[language == "en" ? "AI Assistant" : "AI 助手"]
            XCTAssertTrue(assistant.waitForExistence(timeout: 5))
            if !assistant.isHittable {
                app.collectionViews.firstMatch.swipeDown()
            }
            assistant.tap()
            let organizer = app.buttons["bookmark-organizer"]
            XCTAssertTrue(scrollUntilVisible(organizer, in: app))
            organizer.tap()
            app.buttons["workflow-browserManager"].tap()
            app.buttons["approve-task-button"].tap()
            let confirm = app.buttons["confirm-bookmark-action"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            XCTAssertTrue(scrollUntilVisible(confirm, in: app))
            // Exercise the production 60-second approval lifetime.
            try await Task.sleep(for: .seconds(61))
            confirm.tap()
            let message = app.staticTexts[expected]
            XCTAssertTrue(message.waitForExistence(timeout: 10), language)
            XCTAssertTrue(scrollUntilVisible(message, in: app), language)
            attachScreenshot("Expired-action-\(language)", app)
            app.terminate()
        }
    }

    func testBrowserManagerCanUndo() {
        let app = launchApp()
        openAgent(app)
        app.buttons["workflow-browserManager"].tap()
        app.buttons["approve-task-button"].tap()
        let approvalScreen = app.descendants(matching: .any)["action-approval-screen"]
        XCTAssertTrue(approvalScreen.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '等待确认'")
        ).firstMatch.exists)
        XCTAssertFalse(app.otherElements["workflow-result-browserManager"].exists)
        let confirmApply = app.buttons["confirm-bookmark-action"]
        XCTAssertTrue(scrollUntilVisible(confirmApply, in: app))
        confirmApply.tap()

        XCTAssertTrue(app.staticTexts["收藏夹整理已应用"].waitForExistence(timeout: 8))
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["整理前 4 条"], in: app))
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["整理后 3 条"], in: app))
        let undo = app.buttons["撤销本次整理"]
        XCTAssertTrue(scrollUntilVisible(undo, in: app))
        undo.tap()
        XCTAssertTrue(app.staticTexts["pre-consent-zero-io"].waitForExistence(timeout: 5))
        app.buttons["approve-task-button"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["action-approval-screen"]
                .waitForExistence(timeout: 5)
        )
        let confirmUndo = app.buttons["confirm-bookmark-undo"]
        XCTAssertTrue(scrollUntilVisible(confirmUndo, in: app))
        confirmUndo.tap()
        XCTAssertTrue(app.buttons["已恢复整理前的收藏"].waitForExistence(timeout: 3))
    }

    func testBrowserManagerCanRecoverUndoAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--ui-testing-persistence",
            "--ui-testing-persistence-reset", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        openAgent(app)
        app.buttons["workflow-browserManager"].tap()
        app.buttons["approve-task-button"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["action-approval-screen"]
                .waitForExistence(timeout: 8)
        )
        let confirmApply = app.buttons["confirm-bookmark-action"]
        XCTAssertTrue(confirmApply.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilVisible(confirmApply, in: app))
        confirmApply.tap()
        XCTAssertTrue(app.staticTexts["收藏夹整理已应用"].waitForExistence(timeout: 8))

        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-testing-persistence", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        openAgent(app)
        let recover = app.buttons["recovered-bookmark-undo"]
        XCTAssertTrue(recover.waitForExistence(timeout: 8))
        recover.tap()
        XCTAssertTrue(app.staticTexts["pre-consent-zero-io"].waitForExistence(timeout: 5))
        app.buttons["approve-task-button"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["action-approval-screen"]
                .waitForExistence(timeout: 8)
        )
        let confirmUndo = app.buttons["confirm-bookmark-undo"]
        XCTAssertTrue(confirmUndo.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilVisible(confirmUndo, in: app))
        confirmUndo.tap()
        XCTAssertTrue(app.staticTexts["上次收藏整理已撤销"].waitForExistence(timeout: 8))
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["恢复后 4 条"], in: app))

        app.terminate()
        app.launch()
        openAgent(app)
        XCTAssertFalse(app.buttons["recovered-bookmark-undo"].waitForExistence(timeout: 2))
    }

    func testAdvertisingFilterSettingsAndSiteException() {
        let app = launchApp()
        navigate(app, to: "http://127.0.0.1:8768/article")
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 20))
        app.buttons["browser-more"].tap(); app.buttons["设置"].tap()
        let aegisSettings = app.buttons["aegis-feature-settings"]
        XCTAssertTrue(scrollPortableControl(aegisSettings, in: app, shortScroll: true)); aegisSettings.tap()
        app.buttons["aegis-privacy-settings"].tap()
        let filterSettings = app.buttons["content-filter-settings"]
        XCTAssertTrue(scrollPortableControl(filterSettings, in: app, shortScroll: true)); filterSettings.tap()
        XCTAssertTrue(app.staticTexts["网络规则"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["元素隐藏规则"].exists)
        attachScreenshot("广告过滤规则与更新", app)
        let toggle = app.switches["content-filter-toggle"]
        XCTAssertTrue(toggle.exists)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        let disabled = NSPredicate(format: "value == '0'")
        expectation(for: disabled, evaluatedWith: toggle); waitForExpectations(timeout: 5)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        let enabled = NSPredicate(format: "value == '1'")
        expectation(for: enabled, evaluatedWith: toggle); waitForExpectations(timeout: 5)
        if UIDevice.current.userInterfaceIdiom == .phone {
            let update = app.buttons["update-content-filters"]
            XCTAssertTrue(scrollUntilVisible(update, in: app)); update.tap()
            // 旧更新日期会保留，必须等本次请求结束，不能只断言日期标签存在。
            let finished = NSPredicate(format: "enabled == true AND label == %@", "更新过滤规则")
            expectation(for: finished, evaluatedWith: update); waitForExpectations(timeout: 100)
            XCTAssertTrue(app.staticTexts["最近更新"].exists)
            attachScreenshot("在线更新广告规则成功", app)
        }
        let site = app.buttons["content-filter-site-exception"]
        XCTAssertTrue(scrollUntilVisible(site, in: app)); site.tap()
        XCTAssertTrue(app.buttons["恢复当前网站的过滤"].exists)
        site.tap()
        XCTAssertTrue(app.buttons["为当前网站暂停过滤"].exists)
    }

    func testMirrorDownloadFallbackThroughUI() {
        let app = launchApp()
        app.buttons["browser-more"].tap(); app.buttons["下载"].tap()
        let url = app.textFields["download-url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap(); url.clearAndType("http://127.0.0.1:8768/missing")
        app.buttons["备用镜像（每行一个）"].tap()
        let mirrors = app.descendants(matching: .any)["download-mirrors"].firstMatch
        XCTAssertTrue(mirrors.waitForExistence(timeout: 5)); mirrors.tap()
        mirrors.typeText("http://127.0.0.1:8768/download.bin")
        app.buttons["start-download"].tap()
        // iPad 表单弹窗较短，列表不会提前创建屏幕外的下载记录。
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["已完成"], in: app))
        XCTAssertTrue(app.staticTexts["已完成"].waitForExistence(timeout: 20))
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["镜像 2 / 2"], in: app))
        attachScreenshot("备用镜像实际下载完成", app)
    }

    func testRealDownloadCompletesWithHash() {
        let app = launchApp()
        app.buttons["browser-more"].tap()
        app.buttons["下载"].tap()
        let url = app.textFields["download-url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap(); url.clearAndType("http://127.0.0.1:8768/download.bin")
        let hash = app.textFields["download-hash"]
        hash.tap(); hash.clearAndType("098e36bb4a85fa669a62d326a22df3f7faf838741b9d1e5f81ee3056dad58436")
        app.buttons["start-download"].tap()
        XCTAssertTrue(scrollUntilVisible(app.buttons["save-download-file"].firstMatch, in: app))
        XCTAssertTrue(app.staticTexts["与预期 SHA-256 一致。"].waitForExistence(timeout: 20))
        attachScreenshot("真实下载与文件校验", app)
        app.buttons["save-download-file"].firstMatch.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == '保存' OR label == '存储' OR label == 'Save' OR label == '儲存'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        attachScreenshot("文件保存面板", app)
        confirm.tap()
        XCTAssertTrue(app.staticTexts["文件已保存。"].waitForExistence(timeout: 8))
    }

    func testSensitivePageIsRejectedBeforeModelSend() {
        let app = launchApp()
        navigate(app, to: "http://127.0.0.1:8768/sensitive")
        XCTAssertTrue(app.webViews.secureTextFields.firstMatch.waitForExistence(timeout: 10))
        tapBrowserButton("agent-button", in: app)
        app.buttons["read-pages"].tap()
        let error = app.staticTexts["assistant-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 8))
        XCTAssertTrue(error.label.contains("登录或支付表单"))
        XCTAssertFalse(app.buttons["analyze-pages"].exists)
    }

    func testDamagedRecordsShowErrorsAndKeepBrowsingAvailable() {
        let app = launchApp(extraArguments: ["--ui-testing-damaged-records"])
        navigate(app, to: "http://127.0.0.1:8768/article")
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 10))
        tapBrowserButton("data-button", in: app)
        app.segmentedControls.buttons["工作区"].tap()
        let workspaceError = app.staticTexts["workspace-storage-error"]
        XCTAssertTrue(workspaceError.waitForExistence(timeout: 5))
        XCTAssertTrue(workspaceError.label.contains("原文件已保留"))
        app.buttons["save-workspace"].tap()
        app.alerts.textFields.firstMatch.tap()
        app.alerts.textFields.firstMatch.typeText("不应覆盖")
        app.alerts.buttons["保存"].tap()
        XCTAssertTrue(workspaceError.label.contains("无法保存更改"))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", workspaceError.label)).count, 1)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS '不应覆盖'")).firstMatch.exists)
        attachScreenshot("工作区损坏记录保留与错误提示", app)
        app.buttons["完成"].tap()
        app.buttons["browser-more"].tap(); app.buttons["下载"].tap()
        let downloadError = app.staticTexts["download-storage-error"]
        XCTAssertTrue(downloadError.waitForExistence(timeout: 5))
        XCTAssertTrue(downloadError.label.contains("原文件已保留"))
        let address = app.textFields["download-url"]
        address.tap(); address.typeText("http://127.0.0.1:8768/download.bin")
        XCTAssertFalse(app.buttons["start-download"].isEnabled)
        XCTAssertFalse(app.staticTexts["正在下载"].exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", downloadError.label)).count, 1)
        attachScreenshot("下载损坏记录保留与错误提示", app)
        app.buttons["完成"].tap()
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].exists)
    }

    func testWorkspaceSaveRestoreAndUndo() {
        let app = launchApp()
        navigate(app, to: "http://127.0.0.1:8768/article")
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 10))
        tapBrowserButton("data-button", in: app)
        app.segmentedControls.buttons["工作区"].tap()
        app.buttons["save-workspace"].tap()
        app.alerts.textFields.firstMatch.tap()
        app.alerts.textFields.firstMatch.typeText("绿地研究")
        app.alerts.buttons["保存"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '绿地研究'")).firstMatch.waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label CONTAINS '绿地研究'")).firstMatch.tap()
        app.buttons["追加打开这些页面"].tap()
        XCTAssertTrue(app.staticTexts["已打开 1 个页面。"].waitForExistence(timeout: 5))
        app.buttons["撤销本次恢复"].tap()
        XCTAssertTrue(app.staticTexts["本次恢复的标签已关闭。"].exists)
        attachScreenshot("工作区恢复与撤销", app)
        let workspace = app.buttons.matching(NSPredicate(format: "label CONTAINS '绿地研究'")).firstMatch
        workspace.swipeLeft()
        app.buttons["重命名"].tap()
        app.alerts.textFields.firstMatch.tap()
        app.alerts.textFields.firstMatch.clearAndType("绿地计划")
        app.alerts.buttons["保存"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '绿地计划'")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["export-workspaces"].tap()
        let save = app.buttons.matching(NSPredicate(format: "label == '保存' OR label == '存储' OR label == 'Save' OR label == '儲存'")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        attachScreenshot("工作区系统文件导出", app)
        let filename = systemExportFilenameField(in: app)
        XCTAssertTrue(filename.waitForExistence(timeout: 5), "系统导出文件名控件未出现")
        filename.tap(); filename.clearAndType("Aegis-workspace-test-" + UUID().uuidString)
        save.tap()
        XCTAssertTrue(app.staticTexts["工作区文件已保存。"].waitForExistence(timeout: 8))
    }

    func testInterruptedTaskDoesNotAutoResume() {
        let app = launchApp()
        app.terminate()
        app.launchArguments += ["--ui-testing-recovery"]
        app.launch()
        openAgent(app)
        XCTAssertTrue(app.staticTexts["任务已中断"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '发现中断任务'")).firstMatch.exists)
        XCTAssertFalse(app.otherElements["agent-running"].exists)
    }

    func testAgentSheetClosesWhenSceneLeavesActive() {
        let app = launchApp()
        openAgent(app)
        app.buttons["workflow-browserManager"].tap()
        XCTAssertTrue(app.staticTexts["pre-consent-zero-io"].waitForExistence(timeout: 5))

        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(app.otherElements["agent-center"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["browser-more"].waitForExistence(timeout: 5))
    }

    func testIPadUsesFullWindowForWebPage() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("仅 iPad 验证") }
        let app = launchApp()
        navigate(app, to: "http://127.0.0.1:8768/article")
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.otherElements["ipad-sidebar"].exists)
        XCTAssertGreaterThan(app.webViews.firstMatch.frame.width, app.windows.firstMatch.frame.width * 0.92)
        attachScreenshot("iPad 网页占满窗口，无常驻侧栏", app)
    }

    func testTabGroupsRenameRestoreAndUngroup() {
        let app = launchApp()
        tapBrowserButton("tabs-button", in: app)
        app.buttons["tab-group-selector"].tap(); app.buttons["新建标签组"].tap()
        app.alerts.textFields.firstMatch.tap(); app.alerts.textFields.firstMatch.typeText("研究资料")
        app.alerts.buttons["保存"].tap()
        XCTAssertTrue(app.buttons["tab-group-selector"].label.contains("研究资料"))
        app.buttons["完成"].tap()
        navigate(app, to: "http://127.0.0.1:8768/article")
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 15))
        tapBrowserButton("tabs-button", in: app); app.buttons["tab-group-selector"].tap()
        app.buttons["重命名标签组"].tap()
        app.alerts.textFields.firstMatch.tap(); app.alerts.textFields.firstMatch.clearAndType("公园资料")
        app.alerts.buttons["保存"].tap()
        attachScreenshot("标签分组与重命名", app)
        app.terminate(); app.launchArguments.append("--ui-testing-windows-keep"); app.launch()
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 15))
        tapBrowserButton("tabs-button", in: app)
        XCTAssertTrue(app.buttons["tab-group-selector"].label.contains("公园资料"))
        app.buttons["tab-group-selector"].tap(); app.buttons["取消分组（保留标签）"].tap()
        XCTAssertTrue(app.buttons["tab-group-selector"].label.contains("所有标签"))
        let restoredTab = app.buttons.matching(NSPredicate(format: "label CONTAINS '127.0.0.1'")).firstMatch
        XCTAssertTrue(restoredTab.waitForExistence(timeout: 5))
        attachScreenshot("重启恢复分组并保留页面", app)
        restoredTab.tap()
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 10))
    }

    func testZZIPadIndependentWindowsCloseAndReopen() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("仅 iPad 验证") }
        let app = launchApp()
        navigate(app, to: "http://127.0.0.1:8768/article")
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 15))
        app.buttons["browser-more"].tap(); app.buttons["manage-browser-windows"].tap()
        XCTAssertTrue(app.buttons["重命名当前窗口"].waitForExistence(timeout: 5))
        app.buttons["重命名当前窗口"].tap()
        app.alerts.textFields.firstMatch.tap(); app.alerts.textFields.firstMatch.typeText("研究窗口")
        app.alerts.buttons["保存"].tap(); app.buttons["完成"].tap()
        app.buttons["browser-more"].tap(); app.buttons["new-browser-window"].tap()
        let blank = app.textFields.matching(NSPredicate(format: "identifier == 'address-field' AND value == 'aegis://start'")).firstMatch
        XCTAssertTrue(blank.waitForExistence(timeout: 15))
        let newWindow = try XCTUnwrap(app.windows.allElementsBoundByIndex.first { window in
            window.textFields.matching(NSPredicate(format: "identifier == 'address-field' AND value == 'aegis://start'")).count > 0
        })
        // 输入后 value 会变化，编辑过程使用窗口内的固定标识定位。
        let secondAddress = newWindow.textFields["address-field"]
        secondAddress.tap(); secondAddress.clearAndType("http://127.0.0.1:8768/article-two"); secondAddress.typeText("\n")
        XCTAssertTrue(app.webViews.staticTexts["绿地改造补充说明"].waitForExistence(timeout: 15))
        let secondWindow = try XCTUnwrap(app.windows.allElementsBoundByIndex.first { window in
            window.textFields.matching(NSPredicate(format: "identifier == 'address-field' AND value CONTAINS 'article-two'")).count > 0
        })
        secondWindow.buttons["browser-more"].tap(); app.buttons["manage-browser-windows"].tap()
        app.buttons["重命名当前窗口"].tap()
        app.alerts.textFields.firstMatch.tap(); app.alerts.textFields.firstMatch.typeText("对照窗口")
        app.alerts.buttons["保存"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '研究窗口'")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '对照窗口'")).firstMatch.exists)
        attachScreenshot("iPad 独立窗口与保存记录", app)
        app.buttons["close-browser-window"].tap()
        // 全屏 iPad 关闭前台窗口后可能回到桌面，重新激活剩余窗口再操作。
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let firstAddress = app.textFields.matching(NSPredicate(format: "identifier == 'address-field' AND value ENDSWITH '/article'")).firstMatch
        XCTAssertTrue(firstAddress.waitForExistence(timeout: 10))
        let firstWindow = try XCTUnwrap(app.windows.allElementsBoundByIndex.first { window in
            window.textFields.matching(NSPredicate(format: "identifier == 'address-field' AND value ENDSWITH '/article'")).count > 0
        })
        let more = firstWindow.buttons["browser-more"]
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: more)
        waitForExpectations(timeout: 10)
        more.tap()
        XCTAssertTrue(app.buttons["manage-browser-windows"].waitForExistence(timeout: 5))
        app.buttons["manage-browser-windows"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '对照窗口'")).firstMatch.tap()
        XCTAssertTrue(app.webViews.staticTexts["绿地改造补充说明"].waitForExistence(timeout: 15))
        attachScreenshot("iPad 关闭后重新打开原窗口页面", app)
        let reopened = try XCTUnwrap(app.windows.allElementsBoundByIndex.first { window in
            window.textFields.matching(NSPredicate(format: "identifier == 'address-field' AND value CONTAINS 'article-two'")).count > 0
        })
        reopened.buttons["browser-more"].tap(); app.buttons["manage-browser-windows"].tap()
        app.buttons["close-browser-window"].tap()
    }

    func testEnglishAndTraditionalSettings() {
        for (language, locale, settingsTitle, hubTitle, modelTitle) in [
            ("en", "en_US", "Settings", "Aegis settings", "AI and models"),
            ("zh-Hant", "zh_TW", "設定", "Aegis 設定", "AI 與模型")
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
            app.launch()
            XCTAssertTrue(app.buttons["browser-more"].waitForExistence(timeout: 8))
            app.buttons["browser-more"].tap()
            XCTAssertTrue(app.buttons[settingsTitle].waitForExistence(timeout: 5))
            app.buttons[settingsTitle].tap()
            let hub = app.buttons["aegis-feature-settings"]
            XCTAssertTrue(hub.waitForExistence(timeout: 5))
            XCTAssertTrue(hub.label.contains(hubTitle))
            hub.tap()
            XCTAssertTrue(app.navigationBars[hubTitle].waitForExistence(timeout: 5))
            let model = app.buttons["model-service-settings"]
            XCTAssertTrue(model.waitForExistence(timeout: 5))
            XCTAssertTrue(model.label.contains(modelTitle))
            attachScreenshot("\(language)-设置", app)
            app.terminate()
        }
    }

    func testDarkLargeTextAndLandscape() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-dark", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["browser-more"].waitForExistence(timeout: 8))
        tapBrowserButton("agent-button", in: app)
        XCTAssertTrue(app.buttons["read-pages"].waitForExistence(timeout: 5))
        attachScreenshot("深色与大字体助手", app)
        app.buttons["完成"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let landscapeReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscapeReady], timeout: 8), .completed)
        for element in [app.buttons["browser-more"], app.buttons["page-protection"], app.textFields["address-field"]] {
            XCTAssertTrue(element.isHittable)
            XCTAssertTrue(app.frame.contains(element.frame), "横屏控件应完整位于可用界面内：\(element.identifier)")
        }
        attachScreenshot("横屏浏览器", app)
    }

    func testPublicWebsiteAndFind() {
        let app = launchApp()
        // example.com 在当前宿主机网络也会超时；使用可达的公开 HTML 页面验收浏览和查找。
        navigate(app, to: "https://www.apple.com/legal/")
        XCTAssertTrue(app.buttons["刷新"].waitForExistence(timeout: 30))
        app.buttons["browser-more"].tap()
        app.buttons["page-actions"].tap()
        app.buttons["在页面中查找"].tap()
        let field = app.textFields["find-text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("Apple")
        app.buttons["查找下一个"].tap()
        XCTAssertTrue(app.staticTexts["已找到匹配内容。"].waitForExistence(timeout: 5))
        attachScreenshot("真实网站页内查找", app)
    }

    func testDownloadContinuesWhileAppBackgrounded() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-background-download", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["browser-more"].waitForExistence(timeout: 8))
        app.buttons["browser-more"].tap(); app.buttons["下载"].tap()
        let field = app.textFields["download-url"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("http://127.0.0.1:8768/slow.bin")
        app.buttons["start-download"].tap()
        XCUIDevice.shared.press(.home)
        // 合成服务器故意分块发送，覆盖真实离开前台的传输窗口。
        Thread.sleep(forTimeInterval: 5)
        app.activate()
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["slow.bin"].firstMatch, in: app))
        XCTAssertTrue(app.buttons["save-download-file"].waitForExistence(timeout: 20))
        XCTAssertTrue(scrollUntilVisible(app.buttons["save-download-file"], in: app))
        attachScreenshot("后台传输完成", app)
    }

    func testExternalLinkKeepsPrivateModeUntilExplicitConfirmation() {
        let app = launchApp()
        tapBrowserButton("profile-menu", in: app); app.buttons["私密"].tap()
        let link = URL(string: "gcsa-aegis://open?url=http%3A%2F%2F127.0.0.1%3A8768%2Farticle")!
        XCUIDevice.shared.system.open(link)
        XCTAssertTrue(app.alerts["在普通浏览中打开分享页面？"].waitForExistence(timeout: 8))
        app.alerts.buttons["取消"].tap()
        XCTAssertEqual(app.buttons["page-protection"].value as? String, "私密浏览：不记录历史，保存和发送资料前需确认")
        XCUIDevice.shared.system.open(link)
        XCTAssertTrue(app.alerts.buttons["用普通标签打开"].waitForExistence(timeout: 8))
        app.alerts.buttons["用普通标签打开"].tap()
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 12))
        app.buttons["browser-more"].tap()
        XCTAssertTrue(app.buttons["agent-button"].exists)
        XCTAssertTrue(app.buttons["agent-button"].isEnabled)
        attachScreenshot("外部链接经明确确认后打开", app)
    }

    func testRecoverDamagedWorkspaceAndDownloadRecordsInApp() {
        let app = launchApp(extraArguments: ["--ui-testing-damaged-records"])
        navigate(app, to: "http://127.0.0.1:8768/article")
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 10))
        tapBrowserButton("data-button", in: app)
        app.segmentedControls.buttons["工作区"].tap()
        app.buttons["workspace-recovery"].tap()
        app.buttons["reset-records"].tap()
        app.buttons["确认备份并重置"].tap()
        XCTAssertTrue(app.staticTexts["记录已更新，可以继续使用。"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'restore-record-backup-' ")).firstMatch.exists)
        attachScreenshot("工作区原件备份与恢复入口", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["save-workspace"].tap()
        app.alerts.textFields.firstMatch.tap(); app.alerts.textFields.firstMatch.typeText("恢复后保存")
        app.alerts.buttons["保存"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '恢复后保存'")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.buttons["browser-more"].tap(); app.buttons["下载"].tap()
        XCTAssertTrue(scrollUntilVisible(app.buttons["下载设置与存储"], in: app))
        app.buttons["下载设置与存储"].tap()
        XCTAssertTrue(scrollUntilVisible(app.buttons["download-recovery"], in: app))
        app.buttons["download-recovery"].tap()
        app.buttons["reset-records"].tap(); app.buttons["确认备份并重置"].tap()
        XCTAssertTrue(app.staticTexts["记录已更新，可以继续使用。"].waitForExistence(timeout: 5))
        attachScreenshot("下载记录恢复完成", app)
    }

    func testRecoveryControlsAccessibility() throws {
        let app = launchApp(extraArguments: ["--ui-testing-damaged-records"])
        tapBrowserButton("data-button", in: app)
        app.segmentedControls.buttons["工作区"].tap()
        app.buttons["workspace-recovery"].tap()
        try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription, .trait])
        attachScreenshot("恢复界面辅助功能检查", app)
    }

    func testLibrarySearchAndDownloadPreview() throws {
        let app = launchApp()
        tapBrowserButton("data-button", in: app)
        app.swipeDown()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("does-not-exist")
        XCTAssertTrue(app.staticTexts["没有匹配的资料"].waitForExistence(timeout: 5))
        if app.buttons["关闭"].exists { app.buttons["关闭"].tap() }
        else if app.buttons["取消"].exists { app.buttons["取消"].tap() }
        app.buttons["完成"].tap()
        app.buttons["browser-more"].tap(); app.buttons["下载"].tap()
        let url = app.textFields["download-url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5)); url.tap(); url.typeText("http://127.0.0.1:8768/test.txt")
        app.buttons["start-download"].tap()
        let preview = app.buttons["preview-download-file"].firstMatch
        XCTAssertTrue(scrollUntilVisible(preview, in: app))
        preview.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        // Quick Look 正文由系统视图绘制，使用截图识别核对实际展示的合成文件内容。
        let image = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([recognition])
        let visibleText = recognition.results?.compactMap { $0.topCandidates(1).first?.string }.joined() ?? ""
        XCTAssertTrue(visibleText.contains("文件预览验收资料"))
        attachScreenshot("系统文件预览", app)
    }

    func testStreamingDraftCannotBeSavedAfterCancellation() {
        let app = launchApp()
        navigate(app, to: "http://127.0.0.1:8768/article")
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 12))
        app.buttons["browser-more"].tap(); app.buttons["设置"].tap(); app.buttons["模型服务"].tap()
        let endpoint = app.textFields["model-endpoint"]
        endpoint.tap(); endpoint.clearAndType("http://127.0.0.1:8768/v1")
        let model = app.textFields["model-name"]
        model.tap(); model.clearAndType("stream-slow")
        app.buttons["save-model"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["完成"].tap()
        tapBrowserButton("agent-button", in: app); app.buttons["read-pages"].tap()
        XCTAssertTrue(app.staticTexts["等待确认发送"].waitForExistence(timeout: 8))
        let analyze = app.buttons["analyze-pages"]
        XCTAssertTrue(scrollUntilVisible(analyze, in: app)); analyze.tap()
        app.buttons["confirm-model-send"].tap()
        let draft = app.staticTexts["assistant-output"]
        XCTAssertTrue(draft.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["save-assistant-report"].exists)
        let cancel = app.buttons["cancel-assistant"]
        XCTAssertTrue(scrollUntilVisible(cancel, in: app)); cancel.tap()
        XCTAssertFalse(app.buttons["save-assistant-report"].exists)
        XCTAssertTrue(app.staticTexts["尚未完成的回答"].exists)
        XCTAssertFalse(app.buttons["导出结果与来源"].isEnabled)
        attachScreenshot("流式草稿取消后禁止保存与导出", app)
    }

    func testIPadKeyboardShortcutsNavigateAndManageTabs() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("仅 iPad 键盘验收") }
        let app = launchApp()
        XCTAssertTrue(app.textFields["address-field"].waitForExistence(timeout: 8))
        app.typeKey("t", modifierFlags: .command)
        let twoTabs = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "标签 2"), object: app.buttons["browser-more"])
        XCTAssertEqual(XCTWaiter.wait(for: [twoTabs], timeout: 5), .completed)
        app.typeKey("w", modifierFlags: .command)
        let oneTab = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "标签 1"), object: app.buttons["browser-more"])
        XCTAssertEqual(XCTWaiter.wait(for: [oneTab], timeout: 5), .completed)
        app.typeKey("l", modifierFlags: .command)
        app.textFields["address-field"].typeText("http://127.0.0.1:8768/article\n")
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 12))
        app.typeKey("f", modifierFlags: .command)
        let find = app.textFields["find-text"]
        let present = find.waitForExistence(timeout: 5)
        if !present { add(XCTAttachment(string: app.debugDescription)) }
        XCTAssertTrue(present)
        find.typeText("12")
        XCTAssertEqual(find.value as? String, "12")
        attachScreenshot("iPad 键盘新建关闭地址与查找", app)
    }

    func testDownloadBatchRemovalKeepsFilesRecoverable() {
        let app = launchApp()
        app.buttons["browser-more"].tap(); app.buttons["下载"].tap()
        let url = app.textFields["download-url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5)); url.tap(); url.typeText("http://127.0.0.1:8768/test.txt")
        app.buttons["start-download"].tap(); app.buttons["start-download"].tap()
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["test.txt"].firstMatch, in: app))
        app.buttons["edit-downloads"].tap()
        app.staticTexts["test.txt"].firstMatch.tap()
        let manage = app.buttons["manage-selected-downloads"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        app.buttons["全选筛选结果"].tap()
        XCTAssertTrue(manage.label.contains("2")); manage.tap()
        app.buttons["仅移除记录，保留文件"].tap()
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["暂无下载"], in: app))
        app.buttons["edit-downloads"].tap()
        for _ in 0..<4 {
            if app.buttons["下载设置与存储"].isHittable { break }
            app.swipeDown()
        }
        app.buttons["下载设置与存储"].tap()
        XCTAssertTrue(scrollUntilVisible(app.buttons["recover-download-files"], in: app))
        app.buttons["recover-download-files"].tap()
        let result = app.staticTexts["download-export-result"]
        for _ in 0..<6 {
            if result.exists && result.isHittable { break }
            app.swipeDown()
        }
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.label.contains("已恢复 2 个文件"))
        attachScreenshot("两项下载批量移除后重新找回文件", app)
    }

    func testCompactToolbarLeavesPageSpaceAndRestoresAfterScrolling() {
        let app = launchApp()
        navigate(app, to: "http://127.0.0.1:8768/long-article")
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 12))
        let page = app.webViews.firstMatch
        XCTAssertGreaterThan(page.frame.width, app.frame.width * 0.98)
        XCTAssertGreaterThan(page.frame.height, app.frame.height * 0.80)
        XCTAssertFalse(app.staticTexts["webextension-status"].exists)
        let metrics = XCTAttachment(string: "窗口：\(app.frame)，网页：\(page.frame)，地址栏：\(app.textFields["address-field"].frame)")
        metrics.name = "紧凑布局可视面积"; metrics.lifetime = .keepAlways; add(metrics)
        attachScreenshot("单行工具栏与完整网页", app)
        if UIDevice.current.userInterfaceIdiom == .phone {
            page.swipeUp()
            XCTAssertTrue(app.otherElements["browser-toolbar-collapsed"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["browser-more"].isHittable)
            attachScreenshot("向下浏览收起工具", app)
            page.swipeDown()
            XCTAssertTrue(app.otherElements["browser-toolbar-expanded"].waitForExistence(timeout: 5))
            page.swipeUp()
            XCTAssertTrue(app.otherElements["browser-toolbar-collapsed"].waitForExistence(timeout: 5))
            navigate(app, to: "http://127.0.0.1:8768/article-two")
            XCTAssertTrue(app.webViews.staticTexts["绿地改造补充说明"].waitForExistence(timeout: 12))
            XCTAssertTrue(app.buttons["page-protection"].isHittable)
        }
    }

    func testCompactToolbarProtectionAndMenuAccessibility() throws {
        let app = launchApp()
        XCTAssertTrue(app.buttons["page-protection"].waitForExistence(timeout: 8))
        // 本用例检查浏览器控件；网页自身的静态文本不是工具栏点击区域。
        let pageFrame = app.webViews.firstMatch.frame
        try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription, .trait]) { issue in
            guard let element = issue.element else { return false }
            return pageFrame.contains(element.frame)
        }
        for id in ["page-protection", "browser-more"] {
            XCTAssertGreaterThanOrEqual(app.buttons[id].frame.height, 44)
            XCTAssertGreaterThanOrEqual(app.buttons[id].frame.width, 44)
        }
        XCTAssertGreaterThanOrEqual(app.textFields["address-field"].frame.height, 44)
        app.buttons["page-protection"].tap()
        XCTAssertTrue(app.switches["content-filter-toggle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["filter-network-count"].exists)
        attachScreenshot("地址栏直接打开广告过滤", app)
        app.buttons["完成"].tap()
        app.buttons["browser-more"].tap()
        for id in ["tabs-button", "new-tab-button", "profile-menu", "data-button", "agent-button"] {
            XCTAssertTrue(app.buttons[id].exists, "菜单入口应保留：\(id)")
        }
        attachScreenshot("集中浏览器操作菜单", app)
    }

    private func tapBrowserButton(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        if !button.exists || !button.isHittable {
            let more = app.buttons["browser-more"]
            XCTAssertTrue(more.waitForExistence(timeout: 8))
            more.tap()
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    private func revealAssistantHistory(in app: XCUIApplication) {
        let history = app.buttons["assistant-history"]
        let navigation = app.navigationBars["AI 助手"]
        let scroll = app.scrollViews["assistant-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        for _ in 0..<8 {
            if history.isHittable, history.frame.minY >= navigation.frame.maxY { return }
            scroll.swipeDown()
        }
        XCTAssertTrue(history.isHittable && history.frame.minY >= navigation.frame.maxY)
    }

    private func assertFixtureRequests(_ marker: String, model: Int, download: Int) async throws {
        let url = URL(string: "http://127.0.0.1:8768/test-request-counts?case=" + marker)!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let counts = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(counts["model"], model)
        XCTAssertEqual(counts["download"], download)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "确认与取消后的实际请求计数"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    func testPortableSettingsPersistAndDownloadRulesAreEditable() {
        let app = launchApp()
        app.buttons["browser-more"].tap(); app.buttons["设置"].tap()
        app.buttons["general-browser-settings"].tap()
        app.buttons["search-engine-picker"].tap(); app.buttons["Bing"].tap()
        let desktop = app.switches["desktop-default-toggle"]
        XCTAssertTrue(scrollPortableControl(desktop, in: app)); tapPortableSwitch(desktop); XCTAssertEqual(desktop.value as? String, "1")
        let save = app.buttons["save-browser-preferences"]
        XCTAssertTrue(scrollPortableControl(save, in: app)); save.tap()
        XCTAssertTrue(app.staticTexts["浏览设置已保存。"].waitForExistence(timeout: 5))
        attachScreenshot("浏览设置保存", app)
        app.terminate(); app.launchArguments += ["--ui-testing-preferences-keep"]; app.launch()
        app.buttons["browser-more"].tap(); app.buttons["设置"].tap(); app.buttons["general-browser-settings"].tap()
        XCTAssertTrue(app.buttons["search-engine-picker"].label.contains("Bing"))
        XCTAssertTrue(scrollPortableControl(desktop, in: app)); XCTAssertEqual(desktop.value as? String, "1")
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["完成"].tap()
        tapBrowserButton("downloads-button", in: app)
        let storage = app.buttons["下载设置与存储"]
        XCTAssertTrue(scrollPortableControl(storage, in: app, shortScroll: true)); storage.tap()
        let cellular = app.switches["允许蜂窝网络下载"]
        XCTAssertTrue(scrollPortableControl(cellular, in: app, shortScroll: true)); tapPortableSwitch(cellular)
        XCTAssertEqual(cellular.value as? String, "0")
        let limit = app.buttons["download-size-limit"]
        XCTAssertTrue(scrollPortableControl(limit, in: app, shortScroll: true)); limit.tap(); app.buttons["500 MB"].tap()
        XCTAssertTrue(limit.label.contains("500 MB"))
        attachScreenshot("下载网络与容量设置", app)
    }

    func testSearchEngineDeletionRestartEmptyListAndRestore() {
        let app = launchApp()
        func openSettings() {
            app.buttons["browser-more"].tap(); app.buttons["设置"].tap()
            app.buttons["general-browser-settings"].tap()
        }
        func saveSettings() {
            app.buttons["管理搜索引擎"].tap()
            let save = app.buttons["save-browser-preferences"]
            XCTAssertTrue(scrollPortableControl(save, in: app)); save.tap()
            XCTAssertTrue(app.staticTexts["浏览设置已保存。"].waitForExistence(timeout: 5))
        }
        openSettings()
        app.buttons["管理搜索引擎"].tap()
        app.buttons["remove-search-engine-duckDuckGo"].tap()
        app.buttons["remove-search-engine-bing"].tap()
        XCTAssertTrue(app.buttons["search-engine-picker"].label.contains("Google"))
        saveSettings()
        app.terminate(); app.launchArguments += ["--ui-testing-preferences-keep"]; app.launch()
        openSettings()
        app.buttons["search-engine-picker"].tap()
        XCTAssertFalse(app.buttons["DuckDuckGo"].exists)
        XCTAssertFalse(app.buttons["Bing"].exists)
        app.buttons["Google"].tap()
        app.buttons["管理搜索引擎"].tap()
        for engine in ["google", "baidu", "custom"] { app.buttons["remove-search-engine-\(engine)"].tap() }
        XCTAssertTrue(app.buttons["search-engine-picker"].label.contains("未启用搜索"))
        attachScreenshot("搜索引擎全部删除", app)
        saveSettings()
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["完成"].tap()
        navigate(app, to: "do not send this search")
        XCTAssertTrue(app.staticTexts["尚未启用搜索引擎，请输入网址，或在浏览设置中恢复搜索引擎。"].waitForExistence(timeout: 5))
        navigate(app, to: "http://127.0.0.1:8768/article")
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 10))
        openSettings()
        app.buttons["管理搜索引擎"].tap()
        app.buttons["restore-search-engines"].tap()
        XCTAssertTrue(app.buttons["search-engine-picker"].label.contains("DuckDuckGo"))
        attachScreenshot("预置搜索引擎恢复", app)
        saveSettings()
    }

    func testPortableReadingTranslationSaveRestartAndArchive() {
        let app = launchApp()
        configurePortableModel(app)
        navigate(app, to: "http://127.0.0.1:8768/article")
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 12))
        tapBrowserButton("reading-library-button", in: app)
        app.buttons["reading-capture-page"].tap()
        XCTAssertTrue(app.staticTexts["reading-original"].waitForExistence(timeout: 8))
        let quote = app.textFields["reading-quote"].exists ? app.textFields["reading-quote"] : app.textViews["reading-quote"]
        XCTAssertTrue(scrollReadingControl(quote, in: app)); quote.tap(); quote.typeText("12 公顷")
        if app.keyboards.firstMatch.exists { app.buttons["reading-dismiss-keyboard"].tap() }
        let note = app.textFields["reading-note"].exists ? app.textFields["reading-note"] : app.textViews["reading-note"]
        XCTAssertTrue(scrollReadingControl(note, in: app)); note.tap(); note.typeText("跨重启保留的阅读批注")
        if app.keyboards.firstMatch.exists { app.buttons["reading-dismiss-keyboard"].tap() }
        let translate = app.buttons["reading-translate"]
        XCTAssertTrue(scrollReadingControl(translate, in: app)); translate.tap()
        let confirm = app.buttons["reading-confirm-translation"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reading-translation-destination"].label, "http://127.0.0.1:8768/v1")
        XCTAssertEqual(app.staticTexts["reading-translation-model"].label, "aegis-simulator-fixture")
        XCTAssertTrue(app.staticTexts["reading-translation-payload"].label.contains("12 公顷"))
        XCTAssertFalse(app.staticTexts["reading-translation-payload"].label.contains("跨重启保留的阅读批注"))
        attachScreenshot("翻译首次发送范围完整可见", app)
        XCTAssertTrue(scrollPortableControl(confirm, in: app)); confirm.tap()
        XCTAssertTrue(app.staticTexts["reading-translation"].waitForExistence(timeout: 15))
        let originalFrame = app.staticTexts["reading-original"].frame
        let translationFrame = app.staticTexts["reading-translation"].frame
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertLessThanOrEqual(originalFrame.maxX, translationFrame.minX)
            XCTAssertEqual(originalFrame.minY, translationFrame.minY, accuracy: 5)
        } else { XCTAssertGreaterThanOrEqual(translationFrame.minY, originalFrame.maxY) }
        let save = app.buttons["reading-save"]
        XCTAssertTrue(scrollReadingControl(save, in: app)); save.tap()
        XCTAssertTrue(app.staticTexts["阅读资料已保存。"].waitForExistence(timeout: 5))
        attachScreenshot("阅读译文与批注保存", app)
        app.terminate(); app.launchArguments += ["--ui-testing-reading-keep"]; app.launch()
        tapBrowserButton("reading-library-button", in: app)
        let record = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'reading-record-' ")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5)); record.tap()
        XCTAssertTrue(app.staticTexts["reading-translation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["reading-translation"].label.contains("12 hectares"))
        let archive = app.switches["归档此资料"]
        XCTAssertTrue(scrollReadingControl(archive, in: app)); tapPortableSwitch(archive)
        XCTAssertEqual(archive.value as? String, "1")
        XCTAssertTrue(scrollReadingControl(app.buttons["reading-save"], in: app)); app.buttons["reading-save"].tap()
        app.buttons["reading-editor-done"].tap()
        XCTAssertFalse(record.exists)
        tapPortableSwitch(app.switches["查看归档"]); XCTAssertTrue(record.waitForExistence(timeout: 5))
        attachScreenshot("阅读归档与重启恢复", app)
    }

    func testPortablePrivateReadingCancelDoesNotSaveOrSend() async throws {
        let app = launchApp()
        configurePortableModel(app)
        let marker = "AEGISPRIVATE_" + UUID().uuidString
        tapBrowserButton("profile-menu", in: app); app.buttons["私密"].tap()
        navigate(app, to: "http://127.0.0.1:8768/article?case=" + marker)
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 12))
        tapBrowserButton("reading-library-button", in: app); app.buttons["reading-capture-page"].tap()
        XCTAssertTrue(app.staticTexts["reading-original"].waitForExistence(timeout: 8))
        let save = app.buttons["reading-save"]
        XCTAssertTrue(scrollReadingControl(save, in: app)); save.tap()
        XCTAssertTrue(app.alerts["保存私密阅读资料？"].waitForExistence(timeout: 5)); app.alerts.buttons["取消"].tap()
        let translate = app.buttons["reading-translate"]
        XCTAssertTrue(scrollReadingControl(translate, in: app)); translate.tap()
        XCTAssertTrue(app.buttons["reading-confirm-translation"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reading-translation-destination"].label, "http://127.0.0.1:8768/v1")
        XCTAssertTrue(app.staticTexts["reading-translation-payload"].label.contains(marker))
        app.buttons["取消"].tap()
        app.buttons["reading-editor-done"].tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'reading-record-' ")).firstMatch.exists)
        try await assertFixtureRequests(marker, model: 0, download: 0)
        attachScreenshot("私密阅读取消后未保存", app)
    }

    func testPortableModelPlanConfirmationAndForegroundWatch() {
        let app = launchApp()
        configurePortableModel(app)
        navigate(app, to: "http://127.0.0.1:8768/article")
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 12))
        tapBrowserButton("agent-button", in: app); app.buttons["browser-operations"].tap()
        let goal = app.textFields["browser-operation-goal"].exists ? app.textFields["browser-operation-goal"] : app.textViews["browser-operation-goal"]
        XCTAssertTrue(scrollPortableControl(goal, in: app)); goal.tap(); goal.typeText("把选中的标签分组并保存工作区")
        if app.keyboards.firstMatch.exists { app.buttons["operation-dismiss-keyboard"].tap() }
        let propose = app.buttons["browser-operation-propose"]
        XCTAssertTrue(scrollPortableControl(propose, in: app)); propose.tap()
        let confirmModel = app.buttons["browser-operation-confirm-model"]
        XCTAssertTrue(confirmModel.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["browser-operation-destination"].label, "http://127.0.0.1:8768/v1")
        XCTAssertEqual(app.staticTexts["browser-operation-model"].label, "aegis-simulator-fixture")
        XCTAssertTrue(app.staticTexts["browser-operation-payload"].label.contains("把选中的标签分组并保存工作区"))
        XCTAssertTrue(app.staticTexts["browser-operation-payload"].label.contains("模拟器验收文章"))
        XCTAssertTrue(app.staticTexts["browser-operation-payload"].label.contains("http://127.0.0.1:8768/article"))
        attachScreenshot("模型步骤首次发送范围完整可见", app)
        XCTAssertTrue(scrollPortableControl(confirmModel, in: app)); confirmModel.tap()
        let execute = app.buttons["browser-operation-confirm"]
        XCTAssertTrue(scrollPortableControl(execute, in: app))
        XCTAssertFalse(app.staticTexts["已完成 2 个步骤。"].exists)
        attachScreenshot("模型计划执行前确认", app)
        execute.tap()
        let result = app.staticTexts["browser-operation-status"]
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "已完成 2 个步骤。"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 10), .completed)
        XCTAssertFalse(execute.exists)
        let watch = app.buttons["检查当前网页更新"]
        XCTAssertTrue(scrollPortableControl(watch, in: app)); watch.tap()
        app.buttons["foreground-watch-toggle"].tap()
        XCTAssertTrue(app.staticTexts["已检查 1 次"].waitForExistence(timeout: 10))
        app.buttons["foreground-watch-toggle"].tap()
        XCTAssertTrue(app.buttons["确认并开始检查"].exists)
        attachScreenshot("前台网页检查已停止", app)
    }

    private func scrollPortableControl(_ element: XCUIElement, in app: XCUIApplication, shortScroll: Bool = false) -> Bool {
        for _ in 0..<8 {
            // 虚拟列表尚未创建目标时，不能先读取目标的属性，否则 XCTest 会直接终止流程。
            let identifier = element.exists ? element.identifier : nil
            let scrolls = identifier.map { app.scrollViews.containing(.any, identifier: $0).allElementsBoundByIndex } ?? []
            let lists = identifier.map { app.collectionViews.containing(.any, identifier: $0).allElementsBoundByIndex } ?? []
            let container = scrolls.last ?? lists.last ?? app.collectionViews.allElementsBoundByIndex.last ?? app.scrollViews.allElementsBoundByIndex.last
            let bounds = (container?.frame ?? app.frame).intersection(app.frame)
            let top = max(bounds.minY, app.navigationBars.allElementsBoundByIndex.last?.frame.maxY ?? bounds.minY) + 8
            var bottom = bounds.maxY - 12
            let search = app.searchFields.firstMatch
            if search.exists, search.isHittable, search.frame.midY > bounds.midY { bottom = min(bottom, search.frame.minY - 8) }
            if app.keyboards.firstMatch.exists { bottom = min(bottom, app.keyboards.firstMatch.frame.minY - 8) }
            if element.exists, element.isHittable, element.frame.midY >= top, element.frame.midY <= bottom { return true }
            let moveDown = element.exists && element.frame.midY < top
            if shortScroll {
                // iPad 紧凑设置表单用短距离拖动，避免整页滑动反复越过目标行。
                let target = container ?? app
                let start = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: moveDown ? 0.4 : 0.7))
                let end = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: moveDown ? 0.7 : 0.4))
                start.press(forDuration: 0.1, thenDragTo: end)
            } else if moveDown { (container ?? app).swipeDown() }
            else { (container ?? app).swipeUp() }
        }
        return false
    }

    private func tapPortableSwitch(_ element: XCUIElement) {
        // 宽屏行的末端开关可能远离整行中点，优先点击实际的开关子元素。
        let control = element.switches.firstMatch
        if control.exists { control.tap() }
        else { element.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap() }
    }

    private func scrollReadingControl(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let scroll = app.scrollViews["reading-editor-scroll"]
        for _ in 0..<8 {
            let navigation = app.navigationBars["阅读资料"].frame
            let bounds = scroll.frame.intersection(app.frame)
            let top = max(bounds.minY, navigation.maxY) + 10
            if element.exists, element.isHittable, element.frame.minY >= top, element.frame.maxY <= bounds.maxY - 20 { return true }
            if element.exists, element.frame.minY < top { scroll.swipeDown() } else { scroll.swipeUp() }
        }
        return false
    }

    private func configurePortableModel(_ app: XCUIApplication) {
        app.buttons["browser-more"].tap(); app.buttons["设置"].tap(); app.buttons["模型服务"].tap()
        let endpoint = app.textFields["model-endpoint"]
        endpoint.tap(); endpoint.clearAndType("http://127.0.0.1:8768/v1")
        let model = app.textFields["model-name"]
        model.tap(); model.clearAndType("aegis-simulator-fixture")
        app.buttons["save-model"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["完成"].tap()
    }

    func testWebKitProtectionSettingsAndNativePageRecovery() {
        let app = launchApp(extraArguments: ["--ui-testing-security"])
        navigate(app, to: "http://127.0.0.1:8768/security/dynamic")
        let blocked = app.descendants(matching: .any)["page-protection-blocked"]
        XCTAssertTrue(blocked.waitForExistence(timeout: 15))
        attachScreenshot("WebKit-动态钓鱼阻止页", app)
        app.buttons["protection-continue-once"].tap()
        XCTAssertTrue(app.webViews.staticTexts["PayPal verify your account"].waitForExistence(timeout: 8))
        navigate(app, to: "http://127.0.0.1:8768/security/canvas")
        XCTAssertTrue(app.webViews.staticTexts["绘图与读取验收"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["fingerprint-observation"].waitForExistence(timeout: 5))
        app.buttons["browser-more"].tap(); app.buttons["设置"].tap()
        let protection = app.buttons["保护选项"]
        XCTAssertTrue(scrollPortableControl(protection, in: app, shortScroll: true)); protection.tap()
        let mining = app.switches["mining-protection"]
        XCTAssertTrue(scrollPortableControl(mining, in: app)); XCTAssertEqual(mining.value as? String, "1")
        let hardening = app.switches["hardened-security"]
        XCTAssertTrue(scrollPortableControl(hardening, in: app)); tapPortableSwitch(hardening)
        XCTAssertEqual(hardening.value as? String, "1")
        let strict = app.switches["strict-fingerprinting"]
        XCTAssertTrue(scrollPortableControl(strict, in: app)); tapPortableSwitch(strict)
        XCTAssertEqual(strict.value as? String, "1")
        attachScreenshot("WebKit-保护设置", app)
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["完成"].tap()
        navigate(app, to: "http://127.0.0.1:8768/security/canvas")
        XCTAssertTrue(app.webViews.staticTexts["绘图与读取验收"].waitForExistence(timeout: 8))
        attachScreenshot("WebKit-严格模式正常绘图", app)
    }

    private func launchApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchArguments += extraArguments
        app.launch()
        return app
    }

    private func openAgent(_ app: XCUIApplication) {
        tapBrowserButton("agent-button", in: app)
        let organizer = app.buttons["bookmark-organizer"]
        XCTAssertTrue(scrollUntilVisible(organizer, in: app))
        organizer.tap()
        XCTAssertTrue(app.otherElements["agent-center"].waitForExistence(timeout: 5))
    }

    private func navigate(_ app: XCUIApplication, to url: String) {
        let address = app.textFields["address-field"]
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        address.tap(); address.clearAndType(url); address.typeText("\n")
    }

    /// The system exporter still has to expose a filename field. iOS 26 no longer
    /// always uses `DOCPicker.filenameTextField`; the default name remains the field.
    private func systemExportFilenameField(in app: XCUIApplication) -> XCUIElement {
        let identified = app.textFields["DOCPicker.filenameTextField"]
        if identified.exists { return identified }
        let named = app.textFields.matching(NSPredicate(format: "value BEGINSWITH 'Aegis'")).firstMatch
        if named.exists { return named }
        return identified
    }

    private func attachScreenshot(_ name: String, _ app: XCUIApplication) {
        // 整屏截图保留设备方向，避免横屏时按 App 坐标裁剪出黑边和残缺内容。
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func scrollUntilVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        func isVisible() -> Bool {
            guard element.exists else { return false }
            // 空列表提示可能没有点击点。文字只检查显示范围，按钮仍须可点击。
            if element.elementType == .staticText {
                let frame = element.frame
                let list = app.collectionViews.firstMatch
                let scroll = app.scrollViews["assistant-scroll"].firstMatch
                let viewport = list.exists ? list.frame : (scroll.exists ? scroll.frame : app.frame)
                return !frame.isEmpty && !frame.isInfinite &&
                    !frame.intersection(viewport.intersection(app.frame)).isEmpty
            }
            return element.isHittable
        }
        for _ in 0..<6 {
            if isVisible() { return true }
            app.swipeUp()
        }
        return isVisible()
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        guard let current = value as? String else {
            typeText(text)
            return
        }
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        typeText(text)
    }
}

/// Opt-in evidence collection on a physical iPhone. XCTest completion is not a
/// full-page acceptance: each receipt and both screenshots require visual review.
@MainActor
final class AegisRealWebsiteSmokeTests: XCTestCase {
    func testDirectSubscriptionQuotaChangesAfterRealProxyBrowsing() throws {
        guard ProcessInfo.processInfo.environment["AEGIS_DIRECT_SUBSCRIPTION_SMOKE"] == "1" else {
            throw XCTSkip("Requires the authorized embedded node and private subscription descriptor")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["page-protection"].waitForExistence(timeout: 10))
        let before = try readDirectQuota(app, name: "direct-quota-before")
        for site in [Site(id: 6, host: "wikipedia.org"), Site(id: 26, host: "bbc.com")] {
            try submitAddress(site.url, in: app)
            let deadline = Date(timeIntervalSinceNow: 15)
            var action = recoveryButton(app)
            while action == nil, Date() < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 1)); action = recoveryButton(app)
            }
            action?.coordinate.tap()
            var content = try waitForContent(app, site: site)
            var route = readRoute(app)
            if route["local_entry_ready"] as? Bool != true {
                let change = enableVisibleSiteRecovery(app, site: site, prefix: "direct-quota-\(site.id)")
                XCTAssertEqual(change["performed"] as? Bool, true)
                content = try waitForContent(app, site: site)
                route = readRoute(app)
            }
            XCTAssertEqual(route["local_entry_ready"] as? Bool, true)
            XCTAssertTrue(site.contains(route["host"] as? String ?? ""))
            XCTAssertEqual(content["expected_site_address_observed"] as? Bool, true)
            attachJSON(content, name: "direct-quota-\(site.id)-content.json")
            attachJSON(route, name: "direct-quota-\(site.id)-route.json")
            screenshot("direct-quota-\(site.id)-content")
        }
        var after = try readDirectQuota(app, name: "direct-quota-after")
        for attempt in 0..<3 where (after["uploaded"] ?? 0) <= (before["uploaded"] ?? 0)
            || (after["downloaded"] ?? 0) <= (before["downloaded"] ?? 0) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 5))
            after = try readDirectQuota(app, name: "direct-quota-after-\(attempt)")
        }
        XCTAssertGreaterThan(try XCTUnwrap(after["uploaded"]), try XCTUnwrap(before["uploaded"]))
        XCTAssertGreaterThan(try XCTUnwrap(after["downloaded"]), try XCTUnwrap(before["downloaded"]))
        XCTAssertLessThan(try XCTUnwrap(after["remaining"]), try XCTUnwrap(before["remaining"]))
    }

    private func readDirectQuota(_ app: XCUIApplication, name: String) throws -> [String: UInt64] {
        app.buttons["page-protection"].tap()
        let refresh = app.buttons["access-usage-refresh"]
        for _ in 0..<8 where !refresh.isHittable { app.swipeUp() }
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        if refresh.isEnabled && refresh.isHittable { refresh.tap() }
        var values: [String: UInt64] = [:]
        let deadline = Date(timeIntervalSinceNow: 15)
        repeat {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            values = [:]
            func visit(_ snapshot: XCUIElementSnapshot) {
                for key in ["quota", "uploaded", "downloaded", "used", "remaining"] where snapshot.identifier == "access-usage-" + key {
                    if let raw = snapshot.value as? String, let bytes = UInt64(raw) { values[key] = bytes }
                }
                for child in snapshot.children { visit(child) }
            }
            visit(try app.snapshot())
        } while values.count != 5 && Date() < deadline
        screenshot(name)
        attachJSON(values.mapValues { String($0) }, name: name + ".json")
        XCTAssertEqual(values["quota"], 10_000_000_000)
        let used = try XCTUnwrap(values["used"])
        XCTAssertEqual(used, try XCTUnwrap(values["uploaded"]) + XCTUnwrap(values["downloaded"]))
        XCTAssertEqual(values["remaining"], used < 10_000_000_000 ? 10_000_000_000 - used : 0)
        app.navigationBars.buttons["完成"].tap()
        return values
    }

    func testCurrentSiteProxySwitchPreservesOtherSite() throws {
        guard ProcessInfo.processInfo.environment["AEGIS_REAL_SITE_SWITCH_SMOKE"] == "1" else {
            throw XCTSkip("Requires an explicitly enabled real-node UI run")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        let first = Site(id: 6, host: "wikipedia.org")
        let second = Site(id: 14, host: "dropbox.com")
        for site in [first, second, first] {
            try submitAddress(site.url, in: app)
            let deadline = Date(timeIntervalSinceNow: 15)
            var action = recoveryButton(app)
            while action == nil, Date() < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
                action = recoveryButton(app)
            }
            action?.coordinate.tap()
            _ = try waitForContent(app, site: site)
            var route = readRoute(app)
            if route["local_entry_ready"] as? Bool != true {
                let change = enableVisibleSiteRecovery(app, site: site, prefix: "site-switch-\(site.id)")
                XCTAssertEqual(change["performed"] as? Bool, true)
                _ = try waitForContent(app, site: site)
                route = readRoute(app)
            }
            XCTAssertEqual(route["local_entry_ready"] as? Bool, true)
            attachJSON(route, name: "site-switch-\(site.id)-route.json")
        }
        app.buttons["page-protection"].tap()
        let currentHost = app.staticTexts["access-site-proxy-host"]
        XCTAssertTrue(currentHost.waitForExistence(timeout: 5))
        XCTAssertTrue(first.contains(currentHost.label.lowercased()))
        let toggle = app.switches["access-site-proxy-toggle"]
        for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(toggle.isHittable)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let off = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: toggle)
        let offResult = XCTWaiter.wait(for: [off], timeout: 5)
        screenshot("site-switch-current-off")
        guard offResult == .completed else { XCTFail("Visible current-site switch did not turn off"); return }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let on = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [on], timeout: 5), .completed)
        screenshot("site-switch-current-on")
        app.navigationBars.buttons["完成"].tap()
        _ = try waitForContent(app, site: first)
        XCTAssertEqual(readRoute(app)["local_entry_ready"] as? Bool, true)
        try submitAddress(second.url, in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Address submission must dismiss the keyboard")
        _ = try waitForContent(app, site: second)
        let otherRoute = readRoute(app)
        XCTAssertEqual(otherRoute["local_entry_ready"] as? Bool, true)
        attachJSON(otherRoute, name: "site-switch-other-site-still-on.json")
        screenshot("site-switch-other-site-still-on")
    }

    private func submitAddress(_ url: String, in app: XCUIApplication) throws {
        let address = app.textFields["address-field"]
        let cancel = app.buttons["取消"]
        for attempt in 0..<2 {
            guard address.waitForExistence(timeout: 10), address.isHittable else { break }
            address.tap()
            guard cancel.waitForExistence(timeout: 3) else { continue }
            let keyboard = app.keyboards.firstMatch
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                keyboard.exists && keyboard.frame.intersects(app.frame)
            }, object: nil)
            _ = XCTWaiter.wait(for: [ready], timeout: 3)
            address.clearAndType(url)
            if address.value as? String == url {
                address.typeText("\n")
                return
            }
            screenshot("address-entry-attempt-\(attempt + 1)")
            if cancel.isHittable { cancel.tap() }
        }
        throw NSError(domain: "AegisRealWebsiteSmoke", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Address entry did not reach the requested URL before submission"])
    }

    private struct Site {
        let id: Int
        let host: String
        var url: String { "https://\(host)/" }
        func contains(_ candidate: String) -> Bool {
            candidate == host || candidate.hasSuffix("." + host)
        }
    }

    private static let sites: [Site] = [
        .init(id: 1, host: "google.com"),
        .init(id: 2, host: "facebook.com"),
        .init(id: 3, host: "youtube.com"),
        .init(id: 4, host: "instagram.com"),
        .init(id: 5, host: "x.com"),
        .init(id: 6, host: "wikipedia.org"),
        .init(id: 7, host: "pinterest.com"),
        .init(id: 8, host: "tiktok.com"),
        .init(id: 9, host: "whatsapp.com"),
        .init(id: 10, host: "vimeo.com"),
        .init(id: 11, host: "reddit.com"),
        .init(id: 12, host: "chatgpt.com"),
        .init(id: 13, host: "nih.gov"),
        .init(id: 14, host: "dropbox.com"),
        .init(id: 15, host: "archive.org"),
        .init(id: 16, host: "tumblr.com"),
        .init(id: 17, host: "snapchat.com"),
        .init(id: 18, host: "nytimes.com"),
        .init(id: 19, host: "godaddy.com"),
        .init(id: 20, host: "flickr.com"),
        .init(id: 21, host: "discord.com"),
        .init(id: 22, host: "soundcloud.com"),
        .init(id: 23, host: "theguardian.com"),
        .init(id: 24, host: "medium.com"),
        .init(id: 25, host: "brave.com"),
        .init(id: 26, host: "bbc.com"),
        .init(id: 27, host: "roku.com"),
        .init(id: 28, host: "forbes.com"),
        .init(id: 29, host: "twitch.tv"),
        .init(id: 30, host: "linktr.ee"),
        .init(id: 31, host: "reuters.com"),
        .init(id: 32, host: "archive.ph"),
        .init(id: 33, host: "etsy.com"),
        .init(id: 34, host: "ok.ru"),
        .init(id: 35, host: "tradingview.com"),
        .init(id: 36, host: "wsj.com"),
        .init(id: 37, host: "bsky.app"),
        .init(id: 38, host: "issuu.com"),
        .init(id: 39, host: "bloomberg.com"),
        .init(id: 40, host: "washingtonpost.com"),
        .init(id: 41, host: "substack.com"),
        .init(id: 42, host: "duckduckgo.com"),
        .init(id: 43, host: "line.me"),
        .init(id: 44, host: "steamcommunity.com"),
        .init(id: 45, host: "dailymotion.com"),
        .init(id: 46, host: "goodreads.com"),
        .init(id: 47, host: "businessinsider.com"),
        .init(id: 48, host: "amazon.co.jp"),
        .init(id: 49, host: "quora.com"),
        .init(id: 50, host: "openstreetmap.org"),
        .init(id: 51, host: "indiatimes.com"),
        .init(id: 52, host: "blogger.com"),
        .init(id: 53, host: "fandom.com"),
        .init(id: 54, host: "behance.net"),
        .init(id: 55, host: "ft.com"),
        .init(id: 56, host: "slideshare.net"),
        .init(id: 57, host: "threads.com"),
        .init(id: 58, host: "deviantart.com"),
        .init(id: 59, host: "time.com"),
        .init(id: 60, host: "rakuten.co.jp"),
        .init(id: 61, host: "meta.com"),
        .init(id: 62, host: "nike.com"),
        .init(id: 63, host: "elpais.com"),
        .init(id: 64, host: "lemonde.fr"),
        .init(id: 65, host: "bandcamp.com"),
        .init(id: 66, host: "itch.io"),
        .init(id: 67, host: "binance.com"),
        .init(id: 68, host: "dailymail.co.uk"),
        .init(id: 69, host: "independent.co.uk"),
        .init(id: 70, host: "bild.de"),
        .init(id: 71, host: "wattpad.com"),
        .init(id: 72, host: "viber.com"),
        .init(id: 73, host: "nikkei.com"),
        .init(id: 74, host: "welt.de"),
        .init(id: 75, host: "imgur.com"),
        .init(id: 76, host: "perplexity.ai"),
        .init(id: 77, host: "focus.de"),
        .init(id: 78, host: "daum.net"),
        .init(id: 79, host: "gofundme.com"),
        .init(id: 80, host: "nbcnews.com"),
        .init(id: 81, host: "cbc.ca"),
        .init(id: 82, host: "disqus.com"),
        .init(id: 83, host: "patreon.com"),
        .init(id: 84, host: "genius.com"),
        .init(id: 85, host: "character.ai"),
        .init(id: 86, host: "corriere.it"),
        .init(id: 87, host: "huffpost.com"),
        .init(id: 88, host: "pbs.org"),
        .init(id: 89, host: "abc.net.au"),
        .init(id: 90, host: "change.org"),
        .init(id: 91, host: "n-tv.de"),
        .init(id: 92, host: "pixiv.net"),
        .init(id: 93, host: "bol.com"),
        .init(id: 94, host: "tagesschau.de"),
        .init(id: 95, host: "archiveofourown.org"),
        .init(id: 96, host: "theatlantic.com"),
        .init(id: 97, host: "huggingface.co"),
        .init(id: 98, host: "moneycontrol.com"),
        .init(id: 99, host: "ameba.jp"),
        .init(id: 100, host: "rutube.ru")
    ]

    func testSelectedRealWebsites() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AEGIS_REAL_SITE_SMOKE"] == "1" else {
            throw XCTSkip("External websites require AEGIS_REAL_SITE_SMOKE=1 and AEGIS_REAL_SITE_IDS.")
        }
#if targetEnvironment(simulator)
        throw XCTSkip("Real-site smoke requires a physical iPhone.")
#else
        let selection = environment["AEGIS_REAL_SITE_IDS"] ?? ""
        let ids = selection.split(separator: ",", omittingEmptySubsequences: false)
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let selected = selection == "all" ? Self.sites : Self.sites.filter { ids.contains($0.id) }
        guard selection == "all" || (!ids.isEmpty && ids.count == selection.split(separator: ",", omittingEmptySubsequences: false).count
            && Set(ids).count == ids.count && selected.count == ids.count) else {
            XCTFail("Select all or a comma-separated subset of the 100 documented site IDs; raw URLs are rejected.")
            return
        }
        continueAfterFailure = true
        for site in selected {
            XCTContext.runActivity(named: "Real site \(site.id): \(site.host)") { _ in
                collect(site, tryLink: environment["AEGIS_REAL_SITE_LINKS"] == "1")
            }
        }
#endif
    }

    private func collect(_ site: Site, tryLink: Bool) {
        let app = XCUIApplication()
        let prefix = String(format: "real-site-%03d-%@", site.id, site.host)
        var receipt: [String: Any] = [
            "schema": 1, "site_id": site.id, "requested_url": site.url,
            "started_at": ISO8601DateFormatter().string(from: Date()),
            "recovery_action_count": 0, "recovery_action": "NONE",
            "result": "HARNESS_INCOMPLETE", "acceptance": "NOT_ESTABLISHED",
            "visual_review_required": true, "link_result": "NOT_REQUESTED",
            "checklist": ["Read initial and scrolled screenshots for complete content and missing assets.",
                          "Reject consent, challenge, login shell, blank or incomplete pages as full-page passes.",
                          "Confirm final host and route; local proxy readiness does not verify the remote connection.",
                          "Review redirect and optional link outcomes separately from the first recovery action."]
        ]
        defer {
            receipt["finished_at"] = ISO8601DateFormatter().string(from: Date())
            attachJSON(receipt, name: prefix + "-receipt.json")
            app.terminate()
        }
        // Standard UI-test launch resets tabs and test preferences between sites.
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let address = app.textFields["address-field"]
        guard address.waitForExistence(timeout: 10), address.isHittable else {
            receipt["result"] = "ADDRESS_UNAVAILABLE"; screenshot(prefix + "-launch")
            XCTFail("Address bar unavailable for site \(site.id)")
            return
        }
        address.tap(); address.clearAndType(site.url)
        let typed = address.value as? String ?? ""
        receipt["typed_address"] = sanitizedURL(typed)
        receipt["typed_address_matches_request"] = typed == site.url
        guard typed == site.url else {
            receipt["result"] = "TYPED_ADDRESS_MISMATCH"; screenshot(prefix + "-typed-address-mismatch")
            return
        }
        address.typeText("\n")
        receipt["keyboard_dismissed_after_submit"] = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        let initialUX = preActionEvidence(app)
        attachJSON(initialUX, name: prefix + "-pre-action-initial.json")
        screenshot(prefix + "-pre-action-initial")
        let deadline = Date(timeIntervalSinceNow: 38)
        var retry = recoveryButton(app)
        while retry == nil, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            retry = recoveryButton(app)
        }
        let ux = preActionEvidence(app)
        receipt["pre_action"] = ux
        attachJSON(ux, name: prefix + "-pre-action-final.json")
        screenshot(prefix + "-before-recovery")
        // The initial direct page may finish while evidence is captured. Resolve
        // the visible action again; a vanished banner is not a successful tap.
        retry = recoveryButton(app)
        if let retry {
            let pending = retry.label == "通过代理打开"
            let exposedTarget = ux["target"] as? String ?? "NOT_EXPOSED"
            let observedAddress = ux["observed_address"] as? String ?? "UNREADABLE"
            receipt["recovery_target"] = exposedTarget
            receipt["recovery_target_source"] = ux["target_source"]
            let hasExposedTarget = exposedTarget != "NOT_EXPOSED" && exposedTarget != "UNREADABLE"
            receipt["recovery_binding_source"] = hasExposedTarget ? "EXPOSED_NAVIGATION_TARGET" : "OBSERVED_ADDRESS_FIELD_ONLY"
            guard host(hasExposedTarget ? exposedTarget : observedAddress).map(site.contains) == true else {
                receipt["result"] = "RECOVERY_TARGET_MISMATCH"; screenshot(prefix + "-target-mismatch")
                return
            }
            receipt["recovery_action"] = pending ? "VISIBLE_PENDING_PROXY" : "VISIBLE_FAILURE_RETRY"
            // The page may finish between observing the native button and the
            // tap. Use the observed point, not a stale element query that aborts
            // the entire batch. This is only an attempted action; the later
            // host, route and content receipts still decide whether it worked.
            retry.coordinate.tap()
            receipt["recovery_action_count"] = 1
            receipt["recovery_action_requires_route_confirmation"] = true
        } else {
            receipt["result"] = "ACTION_UNAVAILABLE"
            let siteAction = enableVisibleSiteRecovery(app, site: site, prefix: prefix)
            receipt["site_menu_action"] = siteAction
            if siteAction["performed"] as? Bool == true {
                receipt["recovery_action"] = "VISIBLE_SITE_PROXY_TOGGLE"
                receipt["recovery_action_count"] = 1
                receipt["recovery_target"] = siteAction["target"]
                receipt["recovery_target_source"] = siteAction["target_source"]
                receipt["result"] = "AWAITING_CONTENT"
            }
        }
        do {
            let page = try waitForContent(app, site: site)
            receipt["content"] = page
            receipt["address_before_scroll"] = sanitizedURL(address.exists ? address.value as? String ?? "" : "")
            screenshot(prefix + "-before-scroll")
            let web = app.webViews.firstMatch
            var scrolledClass = "NO_WEBVIEW"
            if web.exists, !web.frame.isEmpty {
                web.swipeUp()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
                let scrolled = try pageEvidence(web)
                receipt["after_scroll_content"] = scrolled
                scrolledClass = scrolled["classification"] as? String ?? "SNAPSHOT_UNAVAILABLE"
                receipt["scroll_result"] = "GESTURE_SENT_REQUIRES_VISUAL_REVIEW"
            } else { receipt["scroll_result"] = "NO_WEBVIEW" }
            screenshot(prefix + "-after-scroll")
            let finalAddress = address.exists ? address.value as? String ?? "" : ""
            let finalHost = host(finalAddress) ?? ""
            receipt["final_address"] = sanitizedURL(finalAddress)
            receipt["final_host"] = finalHost
            receipt["redirect_class"] = finalHost.isEmpty ? "UNREADABLE_ADDRESS" :
                finalHost == site.host ? "SAME_HOST" : site.contains(finalHost) ? "SAME_REGISTRABLE_DOMAIN" : "CROSS_REGISTRABLE_DOMAIN"
            receipt["cross_registrable_redirect_observed"] = (page["observed_hosts"] as? [String] ?? []).contains { !site.contains($0) }
            let route = readRoute(app)
            receipt["route"] = route
            let routeHost = route["host"] as? String ?? ""
            receipt["route_address_match"] = !finalHost.isEmpty && routeHost == finalHost
            let contentClass = page["classification"] as? String ?? "SNAPSHOT_UNAVAILABLE"
            if receipt["result"] as? String != "ACTION_UNAVAILABLE" {
                receipt["result"] = !site.contains(finalHost) ? "OFF_HOST_OR_UNREADABLE" :
                    routeHost != finalHost ? "ROUTE_ADDRESS_UNVERIFIED" :
                    route["local_entry_ready"] as? Bool != true ? "PROXY_ROUTE_UNVERIFIED" : contentClass
            }
            if tryLink {
                receipt["link_result"] = "SKIPPED_INITIAL_CONTENT_OR_ROUTE_UNVERIFIED"
                if contentClass == "CONTENT_PRESENT_NEEDS_VISUAL_REVIEW", scrolledClass == contentClass,
                   site.contains(finalHost), routeHost == finalHost,
                   route["local_entry_ready"] as? Bool == true,
                   route["menu_closed"] as? Bool == true {
                    receipt["link"] = try followSafeLink(app, site: site, prefix: prefix)
                    receipt["link_result"] = (receipt["link"] as? [String: Any])?["result"]
                }
            }
        } catch {
            receipt["result"] = "SNAPSHOT_UNAVAILABLE"
            screenshot(prefix + "-snapshot-unavailable")
            XCTFail("Real-site snapshot unavailable for site \(site.id)")
        }
    }

    private let recoveryLabels = ["通过代理打开", "通过代理重试"]

    private struct ObservedRecoveryAction {
        let label: String
        let coordinate: XCUICoordinate
    }

    private func recoveryButton(_ app: XCUIApplication) -> ObservedRecoveryAction? {
        guard let snapshot = try? app.snapshot() else { return nil }
        let candidates = nativeDescendants(snapshot).filter {
            $0.elementType == .button && $0.isEnabled
                && ($0.identifier == "page-load-proxy-retry" || recoveryLabels.contains($0.label))
                && !$0.frame.isEmpty && $0.frame.intersects(snapshot.frame)
        }
        guard candidates.count == 1, let candidate = candidates.first,
              recoveryLabels.contains(candidate.label) else { return nil }
        // Identifier propagation must never turn a container or an unrelated
        // descendant into a tap target. Require a unique native button and label.
        // isHittable can itself raise an XCTest failure while the pending
        // button is replaced by a timeout button. Observe two complete native
        // snapshots instead; the later route/content checks still decide if
        // this one attempted action actually worked.
        guard let current = try? app.snapshot() else { return nil }
        let currentCandidates = nativeDescendants(current).filter {
            $0.elementType == .button && $0.isEnabled
                && ($0.identifier == "page-load-proxy-retry" || recoveryLabels.contains($0.label))
                && !$0.frame.isEmpty && !$0.frame.isInfinite && !$0.frame.isNull
                && current.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
        }
        guard currentCandidates.count == 1, let live = currentCandidates.first,
              live.frame == candidate.frame, live.label == candidate.label else { return nil }
        return ObservedRecoveryAction(label: live.label,
            coordinate: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: live.frame.midX - current.frame.minX,
                dy: live.frame.midY - current.frame.minY)))
    }

    private func preActionEvidence(_ app: XCUIApplication) -> [String: Any] {
        guard let snapshot = try? app.snapshot() else { return ["result": "SNAPSHOT_UNAVAILABLE"] }
        let nodes = nativeDescendants(snapshot)
        let address = nodes.first { $0.elementType == .textField && $0.identifier == "address-field" }
        let pending = nodes.first { $0.elementType == .staticText && $0.identifier == "page-load-pending-host" }
        let failed = nodes.first { $0.elementType == .staticText && $0.identifier == "page-load-failed-host" }
        let status = nodes.first { $0.elementType == .staticText && $0.identifier == "page-load-pending-status" }
        let knownStatus = ["正在准备代理连接…", "正在连接此网址。你可以选择通过代理打开。"]
        let targetNode = pending ?? failed
        let targetValue = targetNode?.value as? String
        let target = targetValue ?? targetNode?.label
        let controls = nodes.filter { $0.identifier == "page-load-proxy-retry" || recoveryLabels.contains($0.label) }
        return ["result": "OBSERVED", "observed_address": sanitizedURL(address?.value as? String ?? ""),
                "target": target.map(sanitizedURL) ?? "NOT_EXPOSED",
                "target_source": pending != nil ? "PENDING_NATIVE_HOST" : failed != nil ? "FAILED_NATIVE_HOST" : "NOT_EXPOSED",
                "pending_status": status.map { knownStatus.contains($0.label) ? $0.label : "UNRECOGNIZED" } ?? "NOT_EXPOSED",
                "recovery_controls": controls.prefix(8).map { item in
                    ["type": item.elementType.rawValue, "identifier_match": item.identifier == "page-load-proxy-retry",
                     "label": recoveryLabels.contains(item.label) ? item.label : "UNRECOGNIZED",
                     "enabled": item.isEnabled, "frame": String(describing: item.frame)] as [String: Any]
                }]
    }

    private func nativeDescendants(_ root: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        var pending = [root], result: [XCUIElementSnapshot] = []
        while let item = pending.popLast(), result.count < 2_000 {
            if item.elementType == .webView { continue }
            result.append(item); pending.append(contentsOf: item.children.reversed())
        }
        return result
    }

    private func enableVisibleSiteRecovery(_ app: XCUIApplication, site: Site, prefix: String) -> [String: Any] {
        let field = app.textFields["address-field"]
        let address = field.exists ? field.value as? String ?? "" : ""
        let web = app.webViews.firstMatch
        let native = preActionEvidence(app)
        let failedHost = native["target_source"] as? String == "FAILED_NATIVE_HOST"
            ? (native["target"] as? String).flatMap(host) : nil
        let committedPage = web.exists && (try? pageEvidence(web)["classification"] as? String).map {
            $0 != "BROWSER_START_PAGE"
        } == true
        guard let addressHost = host(address), site.contains(addressHost),
              committedPage || failedHost == addressHost else {
            return ["performed": false, "result": "NO_VISIBLE_CURRENT_SITE_EVIDENCE"]
        }
        let menu = app.buttons["page-protection"]
        guard menu.exists, menu.isHittable else { return ["performed": false, "result": "MENU_UNAVAILABLE"] }
        menu.tap()
        defer {
            let done = app.navigationBars.buttons["完成"]
            if done.exists, done.isHittable { done.tap(); _ = done.waitForNonExistence(timeout: 3) }
        }
        let committedHost = app.staticTexts["access-site-proxy-host"]
        guard committedHost.waitForExistence(timeout: 5), committedHost.label.lowercased() == addressHost else {
            return ["performed": false, "result": "COMMITTED_HOST_MISMATCH"]
        }
        let toggle = app.switches["access-site-proxy-toggle"]
        guard toggle.exists, toggle.isEnabled, toggle.isHittable,
              toggle.value as? String == "0", let snapshot = try? toggle.snapshot(),
              snapshot.elementType == .switch else {
            return ["performed": false, "result": "NO_VISIBLE_ENABLED_OFF_SWITCH", "target": addressHost]
        }
        screenshot(prefix + "-before-site-toggle")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: toggle)
        let changed = XCTWaiter.wait(for: [enabled], timeout: 5) == .completed
        return ["performed": changed, "result": changed ? "VISIBLE_SWITCH_ENABLED" : "VISIBLE_SWITCH_UNCHANGED", "target": addressHost,
                "target_source": failedHost == addressHost ? "FAILED_HOST_AND_SITE_MENU_AND_ADDRESS" : "COMMITTED_SITE_MENU_HOST_AND_ADDRESS",
                "toggle_value_after": toggle.exists ? toggle.value as? String ?? "UNREADABLE" : "UNAVAILABLE"]
    }

    private func waitForContent(_ app: XCUIApplication, site: Site, previousAddress: String? = nil,
                                previousContent: String? = nil) throws -> [String: Any] {
        let deadline = Date(timeIntervalSinceNow: 45)
        var last: [String: Any] = ["classification": "NO_WEBVIEW"]
        var previous = "", stable = 0
        var observedHosts: [String] = []
        var invalidSnapshotCount = 0
        repeat {
            let field = app.textFields["address-field"]
            let currentAddress = field.exists ? field.value as? String ?? "" : ""
            let currentHost = host(currentAddress)
            if let current = currentHost, !observedHosts.contains(current) {
                observedHosts.append(current)
            }
            let web = app.webViews.firstMatch
            if web.exists {
                do { last = try pageEvidence(web) }
                catch {
                    let failure = error as NSError
                    guard failure.domain == "com.apple.dt.xctest.automation-support.error", failure.code == 8 else { throw error }
                    // Rebinding replaces a WebView between existence and snapshot.
                    // Retry within the original deadline, never accept an old snapshot.
                    invalidSnapshotCount += 1
                    last = ["classification": "SNAPSHOT_UNAVAILABLE"]
                    stable = 0; previous = ""
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
                    continue
                }
                let signature = contentSignature(last) + ":" + currentAddress
                stable = signature == previous ? stable + 1 : 0
                previous = signature
                let addressMatches = currentHost.map(site.contains) == true && currentAddress.hasPrefix("https://")
                let moved = previousAddress.map { sanitizedURL($0) != sanitizedURL(currentAddress) } ?? true
                let changed = previousContent.map { $0 != contentSignature(last) } ?? true
                last["expected_site_address_observed"] = addressMatches
                last["navigation_away_from_previous_address"] = moved
                last["destination_content_changed"] = changed
                if stable >= 2, addressMatches, moved, changed,
                   last["classification"] as? String != "BROWSER_START_PAGE",
                   (last["visible_text_characters"] as? Int ?? 0) > 30 { break }
            } else {
                last = ["classification": "NO_WEBVIEW"]
                stable = 0; previous = ""
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        } while Date() < deadline
        last["settled_observation"] = stable >= 2 && last["expected_site_address_observed"] as? Bool == true
            && last["navigation_away_from_previous_address"] as? Bool == true && last["destination_content_changed"] as? Bool == true
            && last["classification"] as? String != "BROWSER_START_PAGE"
            && (last["visible_text_characters"] as? Int ?? 0) > 30
        last["observed_hosts"] = observedHosts
        last["invalid_snapshot_retries"] = invalidSnapshotCount
        return last
    }

    private func contentSignature(_ evidence: [String: Any]) -> String {
        ["classification", "visible_text_characters", "visible_links", "visible_images"]
            .map { String(describing: evidence[$0] ?? "") }.joined(separator: ":")
    }

    private func pageEvidence(_ web: XCUIElement) throws -> [String: Any] {
        // Resolve once; never index a live, changing web descendants query.
        let snapshot = try web.snapshot()
        let nodes = descendants(snapshot).filter { !$0.frame.isEmpty && $0.frame.intersects(snapshot.frame) }
        let text = nodes.filter { $0.elementType == .staticText || $0.elementType == .link }
            .map(\.label).filter { !$0.isEmpty }.joined(separator: " ").lowercased()
        let signals: [(String, [String])] = [
            ("CHALLENGE", ["verify you are human", "checking your browser", "just a moment", "验证码", "验证您是人类", "access denied", "unusual traffic"]),
            ("CONSENT", ["accept all cookies", "reject all cookies", "before you continue to", "consent preferences", "接受所有", "同意并继续"]),
            ("LOGIN", ["log in to continue", "sign in to continue", "login to continue", "登录以继续", "登录后继续"])
        ]
        var detected = signals.filter { $0.1.contains(where: text.contains) }.map(\.0)
        if text.count < 700, ["log in", "sign in", "登录"].contains(where: text.contains),
           ["password", "email", "sign up", "密码", "注册"].contains(where: text.contains), !detected.contains("LOGIN") {
            detected.append("LOGIN")
        }
        let startPage = text.contains("安心浏览，清楚掌控") && text.contains("网页摘要与研究")
        let classification = startPage ? "BROWSER_START_PAGE" : detected.first.map { $0 + "_REQUIRES_MANUAL_REVIEW" } ??
            (text.count < 30 ? "BLANK_OR_INSUFFICIENT_CONTENT" : "CONTENT_PRESENT_NEEDS_VISUAL_REVIEW")
        return ["classification": classification, "signals": detected, "visible_text_characters": text.count,
                "visible_links": nodes.filter { $0.elementType == .link }.count,
                "visible_images": nodes.filter { $0.elementType == .image }.count]
    }

    private func readRoute(_ app: XCUIApplication) -> [String: Any] {
        let button = app.buttons["page-protection"]
        if !button.exists || !button.isHittable {
            if app.webViews.firstMatch.exists { app.webViews.firstMatch.swipeDown() }
        }
        guard button.exists, button.isHittable else { return ["result": "MENU_UNAVAILABLE", "menu_closed": true] }
        button.tap()
        let routeHost = app.staticTexts["access-site-proxy-host"]
        guard routeHost.waitForExistence(timeout: 5) else {
            let done = app.navigationBars.buttons["完成"]
            if done.exists, done.isHittable { done.tap() }
            return ["result": "ROUTE_HOST_UNAVAILABLE", "menu_closed": !done.exists]
        }
        let route = app.staticTexts["access-proxy-page-route"]
        let routeText = route.exists ? route.label : ""
        var result: [String: Any] = ["result": "OBSERVED", "host": routeHost.label.lowercased(),
                                   "local_entry_ready": routeText == "本地代理入口已就绪；远端连接未验证",
                                   "remote_connection_verified": false]
        let connection = app.staticTexts["access-site-proxy-connection"]
        result["connection_ui"] = connection.exists ? connection.label : "UNAVAILABLE"
        let done = app.navigationBars.buttons["完成"]
        if done.exists, done.isHittable { done.tap(); _ = done.waitForNonExistence(timeout: 3) }
        result["menu_closed"] = !done.exists
        return result
    }

    private func followSafeLink(_ app: XCUIApplication, site: Site, prefix: String) throws -> [String: Any] {
        let web = app.webViews.firstMatch
        guard web.exists else { return ["result": "NO_WEBVIEW"] }
        // Only a real page link exposing a verifiable href is eligible. No consent,
        // login, TLS, download, search, menu or system-interstitial interaction.
        let safePaths = ["/about", "/about/", "/help", "/help/"] + (site.host == "lemonde.fr" ? ["/en/international/"] : [])
        let links = descendants(try web.snapshot()).filter { $0.elementType == .link }
        guard let candidate = links.first(where: { item in
            guard let raw = item.value as? String, let url = URLComponents(string: raw),
                  url.scheme == "https", let target = url.host?.lowercased(), site.contains(target),
                  url.query == nil, url.fragment == nil, url.user == nil, url.password == nil,
                  safePaths.contains(url.path) else { return false }
            return !item.label.isEmpty
        }), let raw = candidate.value as? String else { return ["result": "NO_VERIFIABLE_SAFE_SAME_SITE_LINK"] }
        let link = web.links.matching(NSPredicate(format: "label == %@ AND value == %@", candidate.label, raw)).firstMatch
        guard link.exists, link.isHittable else { return ["result": "SAFE_LINK_NOT_VISIBLE"] }
        let before = app.textFields["address-field"].value as? String ?? ""
        let beforeContent = contentSignature(try pageEvidence(web))
        link.tap()
        let content = try waitForContent(app, site: site, previousAddress: before, previousContent: beforeContent)
        let after = app.textFields["address-field"].value as? String ?? ""
        let actualHost = host(after) ?? ""
        screenshot(prefix + "-after-safe-link")
        let route = readRoute(app)
        let contentObserved = content["classification"] as? String == "CONTENT_PRESENT_NEEDS_VISUAL_REVIEW"
            && content["settled_observation"] as? Bool == true
        let routeObserved = route["host"] as? String == actualHost && route["local_entry_ready"] as? Bool == true
        return ["target": sanitizedURL(raw), "actual_address": sanitizedURL(after), "actual_host": actualHost,
                "result": actualHost.isEmpty ? "ADDRESS_UNREADABLE" : !site.contains(actualHost) ? "FOREIGN_HOST" :
                    sanitizedURL(before) == sanitizedURL(after) ? "NO_NAVIGATION_OBSERVED" :
                    !contentObserved ? "DESTINATION_CONTENT_UNVERIFIED" : !routeObserved ? "DESTINATION_ROUTE_UNVERIFIED" :
                    "SAME_SITE_CONTENT_AND_ROUTE_OBSERVED_NEEDS_VISUAL_REVIEW",
                "content": content, "route": route]
    }

    private func descendants(_ root: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        var pending = [root], result: [XCUIElementSnapshot] = []
        while let item = pending.popLast(), result.count < 8_000 {
            result.append(item); pending.append(contentsOf: item.children.reversed())
        }
        return result
    }

    private func host(_ raw: String) -> String? {
        URLComponents(string: raw.contains("://") ? raw : "https://" + raw)?.host?.lowercased()
    }

    private func sanitizedURL(_ raw: String) -> String {
        guard var url = URLComponents(string: raw.contains("://") ? raw : "https://" + raw),
              ["https", "http"].contains(url.scheme ?? ""), url.host != nil else { return "UNREADABLE" }
        url.query = nil; url.fragment = nil; url.user = nil; url.password = nil
        return url.string ?? "UNREADABLE"
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func attachJSON(_ value: [String: Any], name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            XCTFail("Could not encode real-site receipt")
            return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
