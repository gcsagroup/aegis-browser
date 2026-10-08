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
        XCTAssertTrue(app.webViews.staticTexts["页面提示注入已隔离"].exists)
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
        app.buttons["content-filter-settings"].tap()
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
        hash.tap(); hash.clearAndType("e05bc4162ba70780d59dc6831e0981cf70e317c6ee9825afa5c6915e3a77126c")
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
        app.buttons["start-download"].tap()
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
        let filename = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(filename.waitForExistence(timeout: 5))
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
        for (language, locale, settingsTitle, modelTitle) in [
            ("en", "en_US", "Settings", "Model service"),
            ("zh-Hant", "zh_TW", "設定", "模型服務")
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
            app.launch()
            XCTAssertTrue(app.buttons["browser-more"].waitForExistence(timeout: 8))
            app.buttons["browser-more"].tap()
            XCTAssertTrue(app.buttons[settingsTitle].waitForExistence(timeout: 5))
            app.buttons[settingsTitle].tap()
            XCTAssertTrue(app.buttons[modelTitle].waitForExistence(timeout: 5))
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
