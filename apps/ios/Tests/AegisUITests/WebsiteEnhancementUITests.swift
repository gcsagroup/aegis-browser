import UIKit
import XCTest

@MainActor
final class WebsiteEnhancementUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }
  private func launch(reset: Bool = true, accountOrigin: String? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments =
      ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
      + (reset ? ["--ui-testing-enhancements-reset"] : [])
    if let accountOrigin { app.launchEnvironment["AEGIS_ACCOUNT_SIM_ORIGIN"] = accountOrigin }
    app.launch()
    return app
  }
  private func navigate(_ app: XCUIApplication, _ url: String) {
    let field = app.textFields["address-field"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    field.typeText(
      String(
        repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String)?.count ?? 0))
    field.typeText(url + "\n")
  }
  private func open(_ name: String, _ app: XCUIApplication) {
    if !app.buttons[name].isHittable { app.buttons["browser-more"].tap() }
    XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5))
    app.buttons[name].tap()
  }
  private func tapVisible(_ button: XCUIElement, _ app: XCUIApplication) {
    for _ in 0..<6 {
      if button.exists {
        let frame = button.frame
        // A restored form can expose an unrealized/offscreen cell with invalid
        // geometry. Scroll it into the viewport before asking AX for a hit point.
        if !frame.isEmpty, !frame.isInfinite, !frame.isNull,
           app.frame.contains(CGPoint(x: frame.midX, y: frame.midY)), button.isHittable { break }
      }
      if app.collectionViews.firstMatch.exists { app.collectionViews.firstMatch.swipeUp() }
      else if app.scrollViews.firstMatch.exists { app.scrollViews.firstMatch.swipeUp() }
      else { app.swipeUp() }
    }
    XCTAssertTrue(button.waitForExistence(timeout: 5))
    XCTAssertTrue(button.isHittable)
    button.tap()
  }
  private func capture(_ name: String) {
    let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    a.name = name
    a.lifetime = .keepAlways
    add(a)
  }

  func testWebsiteSettingSurvivesRestartAndPrivateProfileIsEmpty() {
    var app = launch()
    navigate(app, "http://127.0.0.1:8768/enhancements/page")
    XCTAssertTrue(app.webViews.staticTexts["网站增强验收文章"].firstMatch.waitForExistence(timeout: 12))
    app.buttons["page-protection"].tap()
    app.buttons["site-details"].tap()
    app.switches["site-copy"].coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
    XCTAssertEqual(app.switches["site-copy"].value as? String, "1")
    XCTAssertTrue(app.staticTexts["site-rule-result"].waitForExistence(timeout: 5))
    capture("网站设置已保存")
    app.terminate()
    app = launch(reset: false)
    navigate(app, "http://127.0.0.1:8768/enhancements/page")
    XCTAssertTrue(app.webViews.staticTexts["网站增强验收文章"].firstMatch.waitForExistence(timeout: 12))
    app.buttons["page-protection"].tap()
    app.buttons["site-details"].tap()
    XCTAssertEqual(app.switches["site-copy"].value as? String, "1")
    app.navigationBars["当前网站"].buttons["完成"].tap()
    open("profile-menu", app)
    app.buttons["私密"].tap()
    navigate(app, "http://127.0.0.1:8768/enhancements/page")
    XCTAssertTrue(app.webViews.staticTexts["网站增强验收文章"].firstMatch.waitForExistence(timeout: 12))
    app.buttons["page-protection"].tap()
    app.buttons["site-details"].tap()
    XCTAssertEqual(app.switches["site-copy"].value as? String, "0")
    capture("私密设置没有继承")
  }

  func testConfiguredServiceKeepsNodeDetailsPrivate() throws {
    let env = ProcessInfo.processInfo.environment
    guard let nodeConfig = env["AEGIS_UI_NODE_CONFIG"] else {
      throw XCTSkip("Supply a simulator node fixture path")
    }
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    app.launchEnvironment["AEGIS_ACCESS_LOCAL_V2RAY_CONFIG"] = nodeConfig
    app.launch()
    defer { app.terminate() }
    openFixturePageProtection(app)
    XCTAssertTrue(app.switches["access-site-proxy-toggle"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.descendants(matching: .any)["access-proxy-configured-node"].exists)
    XCTAssertFalse(app.staticTexts["VLESS · TCP · REALITY · Vision"].exists)
    openLocationServiceFromWebsite(app)
    XCTAssertTrue(app.staticTexts["测试服务用量（共享）"].waitForExistence(timeout: 5))
    capture("已配置的共享测试服务")
  }

  func testBoundAccountQuotaIsVisibleWithoutNodeConfiguration() throws {
    let env = ProcessInfo.processInfo.environment
    guard let origin = env["AEGIS_S1_FIXTURE_ORIGIN"], let token = env["AEGIS_S1_FIXTURE_C"] else {
      throw XCTSkip("Start the controlled simulator account fixture")
    }
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    app.launchEnvironment["AEGIS_ACCESS_LOCAL_V2RAY_CONFIG"] = ""
    app.launchEnvironment["AEGIS_ACCOUNT_SIM_ORIGIN"] = origin
    app.launchEnvironment["AEGIS_ACCOUNT_SIM_ACTION"] = "bind"
    app.launchEnvironment["AEGIS_ACCOUNT_SIM_ID"] = "C"
    app.launchEnvironment["AEGIS_ACCOUNT_SIM_TOKEN"] = token
    app.launch()
    defer {
      app.terminate()
      app.launchEnvironment.removeValue(forKey: "AEGIS_ACCOUNT_SIM_TOKEN")
      app.launchEnvironment["AEGIS_ACCOUNT_SIM_ACTION"] = "clear"
      app.launch()
      app.terminate()
    }
    openFixturePageProtection(app)
    XCTAssertFalse(app.staticTexts["VLESS · TCP · REALITY · Vision"].exists)
    openLocationServiceFromWebsite(app)
    let style = ByteCountFormatStyle(allowedUnits: .bytes, spellsOutZero: false, locale: Locale(identifier: "zh_CN"))
    for (key, bytes) in [("quota", 10_000), ("remaining", 9_970), ("uploaded", 10), ("downloaded", 20), ("used", 30)] {
      let metric = app.descendants(matching: .any).matching(identifier: "access-usage-" + key).firstMatch
      XCTAssertTrue(metric.waitForExistence(timeout: 10), key)
      XCTAssertEqual(metric.value as? String, style.format(Int64(bytes)), key)
    }
    capture("受控账户C额度显示")
  }

  private func openLocationServiceFromWebsite(_ app: XCUIApplication) {
    XCTAssertFalse(app.buttons["access-usage-link"].exists)
    app.navigationBars["当前网站"].buttons["完成"].tap()
    app.buttons["browser-more"].tap()
    tapMenuItem(labels: ["设置"], in: app)
    tapVisible(app.buttons["access-usage-link"], app)
  }

  private func openFixturePageProtection(_ app: XCUIApplication) {
    navigate(app, "http://127.0.0.1:8768/enhancements/page")
    XCTAssertTrue(app.webViews.staticTexts["网站增强验收文章"].firstMatch.waitForExistence(timeout: 12))
    app.buttons["page-protection"].tap()
    app.buttons["site-details"].tap()
  }

  func testAccessIntentIsolatedBetweenOrdinaryAndPrivateStores() {
    let app = launch()
    navigate(app, "http://127.0.0.1:8768/enhancements/page")
    XCTAssertTrue(app.webViews.staticTexts["网站增强验收文章"].firstMatch.waitForExistence(timeout: 12))
    app.buttons["page-protection"].tap()
    app.buttons["site-details"].tap()
    let toggle = app.switches["access-site-proxy-toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
    XCTAssertEqual(toggle.value as? String, "1")
    app.navigationBars["当前网站"].buttons["完成"].tap()
    app.buttons["browser-more"].tap()
    let modeMenu = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == %@ OR label == %@", "profile-menu", "普通")
    ).firstMatch
    XCTAssertTrue(modeMenu.waitForExistence(timeout: 5), app.debugDescription)
    modeMenu.tap()
    app.buttons["私密"].tap()
    navigate(app, "http://127.0.0.1:8768/enhancements/page")
    XCTAssertTrue(app.webViews.staticTexts["网站增强验收文章"].firstMatch.waitForExistence(timeout: 12))
    app.buttons["page-protection"].tap()
    app.buttons["site-details"].tap()
    let privateToggle = app.switches["access-site-proxy-toggle"]
    XCTAssertTrue(privateToggle.waitForExistence(timeout: 5))
    XCTAssertEqual(privateToggle.value as? String, "0")
    capture("私密代理意图没有继承")
  }
  func testPaidDownloadSelectionIsIndependentOfWebsiteRecovery() {
    let app = launch(accountOrigin: "http://127.0.0.1:8768")
    navigate(app, "http://127.0.0.1:8768/enhancements/page")
    XCTAssertTrue(app.webViews.staticTexts["网站增强验收文章"].firstMatch.waitForExistence(timeout: 12))
    app.buttons["page-protection"].tap()
    app.buttons["site-details"].tap()
    tapVisible(app.buttons["连接选项"], app)
    let recovery = app.switches["access-site-auto-recovery-toggle"]
    let download = app.switches["access-account-site-download-toggle"]
    XCTAssertTrue(download.waitForExistence(timeout: 5))
    XCTAssertEqual(recovery.value as? String, "0")
    download.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    XCTAssertEqual(download.value as? String, "1")
    XCTAssertEqual(recovery.value as? String, "0")
    recovery.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    XCTAssertEqual(recovery.value as? String, "1")
    XCTAssertEqual(download.value as? String, "1")
  }

  func testScriptDraftTrialEnableAndRecovery() {
    let app = launch()
    navigate(app, "http://127.0.0.1:8768/enhancements/page")
    XCTAssertTrue(app.webViews.staticTexts["网站增强验收文章"].firstMatch.waitForExistence(timeout: 12))
    app.buttons["page-protection"].tap()
    app.buttons["site-details"].tap()
    tapVisible(app.buttons["site-new-script"], app)
    let source = app.textViews["user-script-source"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    tapVisible(source, app)
    app.typeKey("a", modifierFlags: .command)
    source.typeText(XCUIKeyboardKey.delete.rawValue)
    source.typeText(
      "// ==UserScript==\n// @name UI acceptance\n// @match http://127.0.0.1:8768/enhancements/*\n// @grant none\n// ==/UserScript==\ndocument.querySelector('h1').textContent='SCRIPT_APPLIED';"
    )
    tapVisible(app.buttons["user-script-trial"], app)
    XCTAssertTrue(app.alerts["在真实页面试运行？"].waitForExistence(timeout: 5))
    app.alerts.buttons["试运行"].tap()
    app.navigationBars["编辑用户脚本"].buttons["完成"].tap()
    app.navigationBars["当前网站"].buttons["完成"].tap()
    XCTAssertTrue(app.webViews.staticTexts["SCRIPT_APPLIED"].waitForExistence(timeout: 8))
    capture("脚本试运行效果")
    app.buttons["page-protection"].tap()
    app.buttons["site-details"].tap()
    tapVisible(app.buttons["此网站的全部设置"], app)
    tapVisible(app.buttons["启用"], app)
    app.alerts.buttons["确认启用"].tap()
    tapVisible(app.buttons["恢复操作"], app)
    tapVisible(app.buttons["停用全部脚本并恢复当前页"], app)
    app.alerts.buttons["停用并恢复"].tap()
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.navigationBars["当前网站"].buttons["完成"].tap()
    XCTAssertTrue(app.webViews.staticTexts["网站增强验收文章"].firstMatch.waitForExistence(timeout: 12))
    XCTAssertFalse(app.webViews.staticTexts["SCRIPT_APPLIED"].exists)
  }
  func testMarkdownPreviewSourceAndLandscape() {
    let app = launch()
    navigate(app, "http://127.0.0.1:8768/enhancements/document.md")
    app.buttons["page-protection"].tap()
    app.buttons["site-details"].tap()
    tapVisible(app.buttons["site-read-markdown"], app)
    XCTAssertTrue(app.webViews.staticTexts["Markdown 验收"].firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["markdown-actions"].waitForExistence(timeout: 5))
    app.buttons["markdown-actions"].tap()
    app.buttons["查看源码"].tap()
    XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'window.markdownExecuted'")).firstMatch.waitForExistence(timeout: 5))
    app.buttons["markdown-actions"].tap()
    app.buttons["查看源码"].tap()
    capture("Markdown 表格与任务列表")
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(app.buttons["markdown-outline"].waitForExistence(timeout: 5))
    capture("Markdown 横屏")
    XCUIDevice.shared.orientation = .portrait
  }

  func testMarkdownFilePickerCancellationKeepsReaderUsable() {
    let app = launch()
    navigate(app, "http://127.0.0.1:8768/enhancements/document.md")
    app.buttons["page-protection"].tap(); app.buttons["site-details"].tap()
    tapVisible(app.buttons["site-read-markdown"], app)
    XCTAssertTrue(app.webViews.staticTexts["Markdown 验收"].firstMatch.waitForExistence(timeout: 10))
    app.buttons["markdown-actions"].tap(); app.buttons["打开文件"].tap()
    let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
    XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.tap()
    XCTAssertTrue(app.buttons["markdown-actions"].waitForExistence(timeout: 10))
    app.buttons["markdown-actions"].tap()
    let source = app.buttons["查看源码"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    XCTAssertTrue(source.isEnabled); source.tap()
    XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'window.markdownExecuted'")).firstMatch.waitForExistence(timeout: 5))
    capture("取消文件选择后仍可查看当前 Markdown 源码")
  }

  func testScriptAndMarkdownConsentMustBeRenewedAfterBackground() {
    let app = launch()
    navigate(app, "http://127.0.0.1:8768/enhancements/page")
    XCTAssertTrue(app.webViews.staticTexts["网站增强验收文章"].firstMatch.waitForExistence(timeout: 12))
    app.buttons["page-protection"].tap(); app.buttons["site-details"].tap()
    tapVisible(app.buttons["site-new-script"], app)
    let goal = app.textFields["user-script-goal"]
    XCTAssertTrue(goal.waitForExistence(timeout: 5)); goal.tap(); goal.typeText("Synthetic DOM label")
    tapVisible(app.buttons["user-script-generate"], app)
    XCTAssertTrue(app.alerts["确认发送给模型服务？"].waitForExistence(timeout: 5))
    XCUIDevice.shared.press(.home); app.activate()
    XCTAssertFalse(app.alerts["确认发送给模型服务？"].exists)
    tapVisible(app.buttons["user-script-generate"], app)
    XCTAssertTrue(app.alerts["确认发送给模型服务？"].waitForExistence(timeout: 5))
    app.alerts.buttons["取消"].tap()
    app.navigationBars["编辑用户脚本"].buttons["完成"].tap()
    app.navigationBars["当前网站"].buttons["完成"].tap()
    // The reader accepts raw Markdown, not the HTML article used for script editing.
    navigate(app, "http://127.0.0.1:8768/enhancements/document.md")
    XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Markdown 验收'")).firstMatch.waitForExistence(timeout: 12))
    app.buttons["page-protection"].tap(); app.buttons["site-details"].tap()
    tapVisible(app.buttons["site-read-markdown"], app)
    let assistant = app.buttons["markdown-assistant"]
    XCTAssertTrue(assistant.waitForExistence(timeout: 10)); assistant.tap()
    let send = app.buttons["确认范围并发送"]
    XCTAssertTrue(send.waitForExistence(timeout: 5)); tapVisible(send, app)
    XCTAssertTrue(app.alerts["发送所选文档内容？"].waitForExistence(timeout: 5))
    XCUIDevice.shared.press(.home); app.activate()
    XCTAssertFalse(app.alerts["发送所选文档内容？"].exists)
    tapVisible(send, app)
    XCTAssertTrue(app.alerts["发送所选文档内容？"].waitForExistence(timeout: 5))
    app.alerts.buttons["取消"].tap()
  }
}
