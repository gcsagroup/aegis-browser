import XCTest
import UIKit

@MainActor
final class AegisUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testBrowserStartsAndNavigatesOfflineFixture() {
        let app = launchApp()
        XCTAssertTrue(app.textFields["address-field"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["agent-button"].exists)
        XCTAssertTrue(app.staticTexts["webextension-status"].waitForExistence(timeout: 8))

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

    func testPrivateProfileIsIsolatedAndAgentDisabled() {
        let app = launchApp()
        if UIDevice.current.userInterfaceIdiom == .pad {
            let profilePicker = app.segmentedControls.firstMatch
            XCTAssertTrue(profilePicker.waitForExistence(timeout: 8))
            profilePicker.buttons["私密"].tap()
        } else {
            let menu = app.buttons["profile-menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 8))
            menu.tap()
            app.buttons["私密"].tap()
        }
        XCTAssertTrue(app.staticTexts["私密 Profile：不记录历史，Agent 与任务恢复已禁用"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["agent-button"].isEnabled)
        XCTAssertFalse(app.buttons["data-button"].isEnabled)
    }

    func testResearchWorkflowHasTenCitations() {
        let app = launchApp()
        openAgent(app)
        app.buttons["workflow-research"].tap()
        XCTAssertTrue(app.staticTexts["pre-consent-zero-io"].waitForExistence(timeout: 5))
        app.buttons["approve-task-button"].tap()
        XCTAssertTrue(app.staticTexts["10 个来源已交叉核对"].waitForExistence(timeout: 8))
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["来源 10/10"], in: app))
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["引用 · 10"], in: app))
    }

    func testBrowserManagerCanUndo() {
        let app = launchApp()
        openAgent(app)
        app.buttons["workflow-browserManager"].tap()
        app.buttons["approve-task-button"].tap()
        let approvalScreen = app.descendants(matching: .any)["action-approval-screen"]
        XCTAssertTrue(approvalScreen.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'AwaitingActionApproval'")
        ).firstMatch.exists)
        XCTAssertFalse(app.otherElements["workflow-result-browserManager"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["action-confirmation-digest"].exists)
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
        XCTAssertTrue(app.buttons["已撤销，逻辑树哈希一致"].waitForExistence(timeout: 3))
    }

    func testBrowserManagerCanRecoverUndoAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--ui-testing-persistence",
            "--ui-testing-persistence-reset",
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
        app.launchArguments = ["--ui-testing", "--ui-testing-persistence"]
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

    func testSafeDownloadShowsMissingSignatureExplicitly() {
        let app = launchApp()
        openAgent(app)
        app.buttons["workflow-safeDownload"].tap()
        app.buttons["approve-task-button"].tap()
        XCTAssertTrue(app.staticTexts["发布者签名：未提供"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["SHA-256 匹配"].exists)
    }

    func testShoppingStopsAtUserHandoff() {
        let app = launchApp()
        openAgent(app)
        app.buttons["workflow-shopping"].tap()
        app.buttons["approve-task-button"].tap()
        XCTAssertTrue(app.staticTexts["已停在最终提交前"].waitForExistence(timeout: 8))
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["最终提交 0 次"], in: app))
        let reason = app.staticTexts["最终下单和支付属于 R3，只能由用户完成"]
        XCTAssertTrue(scrollUntilVisible(reason, in: app))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'UserTakeover'")).firstMatch.exists)
    }

    func testInterruptedTaskDoesNotAutoResume() {
        let app = launchApp()
        app.terminate()
        app.launchArguments += ["--ui-testing-recovery"]
        app.launch()
        openAgent(app)
        XCTAssertTrue(app.staticTexts["任务已中断"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Recovering'")).firstMatch.exists)
        XCTAssertFalse(app.otherElements["agent-running"].exists)
    }

    func testAgentSheetClosesWhenSceneLeavesActive() {
        let app = launchApp()
        openAgent(app)
        app.buttons["workflow-research"].tap()
        XCTAssertTrue(app.staticTexts["pre-consent-zero-io"].waitForExistence(timeout: 5))

        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(app.otherElements["agent-center"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["agent-button"].waitForExistence(timeout: 5))
    }

    func testIPadShowsPersistentSidebar() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("仅 iPad 验证") }
        let app = launchApp()
        XCTAssertTrue(app.staticTexts["智能工作流"].waitForExistence(timeout: 5))
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing"]
        app.launch()
        return app
    }

    private func openAgent(_ app: XCUIApplication) {
        let button = app.buttons["agent-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 8))
        button.tap()
        XCTAssertTrue(app.otherElements["agent-center"].waitForExistence(timeout: 5))
    }

    private func scrollUntilVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<6 {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists
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
