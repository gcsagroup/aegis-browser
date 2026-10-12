import UIKit
import XCTest

@MainActor
final class WebsiteEnhancementUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }
  private func launch(reset: Bool = true) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments =
      ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
      + (reset ? ["--ui-testing-enhancements-reset"] : [])
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
    open("website-enhancements-button", app)
    app.switches["enhance-copy"].coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
    XCTAssertEqual(app.switches["enhance-copy"].value as? String, "1")
    app.buttons["enhance-save-site"].tap()
    XCTAssertTrue(app.staticTexts["enhance-result"].waitForExistence(timeout: 5))
    capture("网站设置已保存")
    app.terminate()
    app = launch(reset: false)
    navigate(app, "http://127.0.0.1:8768/enhancements/page")
    XCTAssertTrue(app.webViews.staticTexts["网站增强验收文章"].firstMatch.waitForExistence(timeout: 12))
    open("website-enhancements-button", app)
    XCTAssertEqual(app.switches["enhance-copy"].value as? String, "1")
    app.navigationBars["网站增强与脚本"].buttons["完成"].tap()
    open("profile-menu", app)
    app.buttons["私密"].tap()
    navigate(app, "http://127.0.0.1:8768/enhancements/page")
    XCTAssertTrue(app.webViews.staticTexts["网站增强验收文章"].firstMatch.waitForExistence(timeout: 12))
    open("website-enhancements-button", app)
    XCTAssertEqual(app.switches["enhance-copy"].value as? String, "0")
    capture("私密设置没有继承")
  }
  func testScriptDraftTrialEnableAndRecovery() {
    let app = launch()
    navigate(app, "http://127.0.0.1:8768/enhancements/page")
    XCTAssertTrue(app.webViews.staticTexts["网站增强验收文章"].firstMatch.waitForExistence(timeout: 12))
    open("website-enhancements-button", app)
    tapVisible(app.buttons["enhance-new-script"], app)
    let source = app.textViews["user-script-source"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    source.tap()
    app.typeKey("a", modifierFlags: .command)
    source.typeText(XCUIKeyboardKey.delete.rawValue)
    source.typeText(
      "// ==UserScript==\n// @name UI acceptance\n// @match http://127.0.0.1:8768/enhancements/*\n// @grant none\n// ==/UserScript==\ndocument.querySelector('h1').textContent='SCRIPT_APPLIED';"
    )
    tapVisible(app.buttons["user-script-trial"], app)
    XCTAssertTrue(app.alerts["在真实页面试运行？"].waitForExistence(timeout: 5))
    app.alerts.buttons["试运行"].tap()
    app.navigationBars["编辑用户脚本"].buttons["完成"].tap()
    app.navigationBars["网站增强与脚本"].buttons["完成"].tap()
    XCTAssertTrue(app.webViews.staticTexts["SCRIPT_APPLIED"].waitForExistence(timeout: 8))
    capture("脚本试运行效果")
    open("website-enhancements-button", app)
    tapVisible(app.buttons["启用"], app)
    app.alerts.buttons["确认启用"].tap()
    tapVisible(app.buttons["停用全部脚本并恢复当前页"], app)
    app.alerts.buttons["停用并恢复"].tap()
    app.navigationBars["网站增强与脚本"].buttons["完成"].tap()
    XCTAssertTrue(app.webViews.staticTexts["网站增强验收文章"].firstMatch.waitForExistence(timeout: 12))
    XCTAssertFalse(app.webViews.staticTexts["SCRIPT_APPLIED"].exists)
  }
  func testMarkdownPreviewSourceAndLandscape() {
    let app = launch()
    navigate(app, "http://127.0.0.1:8768/enhancements/document.md")
    open("markdown-reader-button", app)
    app.buttons["读取当前原始页面"].firstMatch.tap()
    XCTAssertTrue(app.webViews.staticTexts["Markdown 验收"].firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(
      app.webViews.descendants(matching: .any).matching(identifier: "源码").firstMatch
        .waitForExistence(timeout: 5))
    app.webViews.descendants(matching: .any).matching(identifier: "源码").firstMatch.tap()
    XCTAssertTrue(
      app.webViews.staticTexts.matching(
        NSPredicate(format: "label CONTAINS 'window.markdownExecuted'")
      ).firstMatch.waitForExistence(timeout: 5))
    app.webViews.descendants(matching: .any).matching(identifier: "源码").firstMatch.tap()
    capture("Markdown 表格与任务列表")
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(app.webViews.buttons["目录"].waitForExistence(timeout: 5))
    capture("Markdown 横屏")
    XCUIDevice.shared.orientation = .portrait
  }
}
