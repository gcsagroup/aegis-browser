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
      if button.isHittable { break }
      app.swipeUp()
    }
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
    app.switches["site-copy"].coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
    XCTAssertEqual(app.switches["site-copy"].value as? String, "1")
    XCTAssertTrue(app.staticTexts["site-rule-result"].waitForExistence(timeout: 5))
    capture("网站设置已保存")
    app.terminate()
    app = launch(reset: false)
    navigate(app, "http://127.0.0.1:8768/enhancements/page")
    XCTAssertTrue(app.webViews.staticTexts["网站增强验收文章"].firstMatch.waitForExistence(timeout: 12))
    app.buttons["page-protection"].tap()
    XCTAssertEqual(app.switches["site-copy"].value as? String, "1")
    app.navigationBars["当前网站"].buttons["完成"].tap()
    open("profile-menu", app)
    app.buttons["私密"].tap()
    navigate(app, "http://127.0.0.1:8768/enhancements/page")
    XCTAssertTrue(app.webViews.staticTexts["网站增强验收文章"].firstMatch.waitForExistence(timeout: 12))
    app.buttons["page-protection"].tap()
    XCTAssertEqual(app.switches["site-copy"].value as? String, "0")
    capture("私密设置没有继承")
  }

  func testConfiguredNodeAndBoundQuotaAreVisible() throws {
    let env = ProcessInfo.processInfo.environment
    guard let origin = env["AEGIS_S1_FIXTURE_ORIGIN"], let token = env["AEGIS_S1_FIXTURE_C"],
          let nodeConfig = env["AEGIS_UI_NODE_CONFIG"] else {
      throw XCTSkip("Start the controlled account service and supply the authorized node config")
    }
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    app.launchEnvironment["AEGIS_ACCESS_LOCAL_V2RAY_CONFIG"] = nodeConfig
    app.launchEnvironment["AEGIS_ACCOUNT_SIM_ORIGIN"] = origin
    app.launchEnvironment["AEGIS_ACCOUNT_SIM_ACTION"] = "bind"
    app.launchEnvironment["AEGIS_ACCOUNT_SIM_ID"] = "C"
    app.launchEnvironment["AEGIS_ACCOUNT_SIM_TOKEN"] = token
    app.launch()
    navigate(app, "http://127.0.0.1:8768/enhancements/page")
    XCTAssertTrue(app.webViews.staticTexts["网站增强验收文章"].firstMatch.waitForExistence(timeout: 12))
    app.buttons["page-protection"].tap()
    let protocolSummary = app.staticTexts["VLESS · TCP · REALITY · Vision"]
    XCTAssertTrue(protocolSummary.waitForExistence(timeout: 10))
    capture("节点配置和代理状态")
    let refresh = app.buttons["access-usage-refresh"]
    for _ in 0..<8 {
      if refresh.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(refresh.isHittable)
    XCTAssertTrue(app.staticTexts["10000 B"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["9970 B"].exists)
    capture("受控账户C额度显示")
  }

  func testAccessIntentIsolatedBetweenOrdinaryAndPrivateStores() {
    let app = launch()
    navigate(app, "http://127.0.0.1:8768/enhancements/page")
    XCTAssertTrue(app.webViews.staticTexts["网站增强验收文章"].firstMatch.waitForExistence(timeout: 12))
    app.buttons["page-protection"].tap()
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
    let recovery = app.switches["access-site-proxy-toggle"]
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
}
