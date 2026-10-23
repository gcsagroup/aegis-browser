import XCTest

@MainActor
final class SettingsLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func testSettingsPagesAtStandardSize() {
        inspectSettings(largeText: false)
    }

    func testSettingsPagesAtLargestTextSize() {
        inspectSettings(largeText: true)
    }

    func testSettingsPagesInLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        inspectSettings(largeText: false)
    }

    func testExpandedSettingsAtLargestTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let address = app.textFields["address-field"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText("http://127.0.0.1:8768/article\n")
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 10))
        openSettings(app)
        app.buttons["website-settings"].tap()
        app.buttons["current-site-settings"].tap()
        for title in ["网页缩放", "网站模式", "JavaScript", "系统加固", "严格指纹限制（实验）", "相机", "麦克风"] {
            // SwiftUI 菜单在不同系统快照中可报告为按钮或弹出菜单。
            let control = app.descendants(matching: .any).matching(NSPredicate(
                format: "(elementType == %d OR elementType == %d) AND label BEGINSWITH %@",
                XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.popUpButton.rawValue, title
            )).firstMatch
            XCTAssertTrue(reveal(control, app), title)
            assertInsideWindow(control, app)
            capture("网站权限-" + title, app)
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        enterFeatureSettings(app)
        let enhancements = app.buttons["enhancement-settings"]
        XCTAssertTrue(reveal(enhancements, app)); enhancements.tap()
        let newScript = app.buttons["enhance-new-script"]
        XCTAssertTrue(reveal(newScript, app)); newScript.tap()
        let disclosure = app.buttons["执行环境与子框架"]
        XCTAssertTrue(reveal(disclosure, app)); disclosure.tap()
        let world = app.buttons["script-world-setting"]
        XCTAssertTrue(reveal(world, app)); assertInsideWindow(world, app)
        capture("脚本执行设置", app)
        app.navigationBars["编辑用户脚本"].buttons["完成"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["完成"].tap()
        if !app.buttons["downloads-button"].isHittable { app.buttons["browser-more"].tap() }
        app.buttons["downloads-button"].tap()
        let storage = app.buttons["下载设置与存储"]
        XCTAssertTrue(reveal(storage, app)); storage.tap()
        for name in ["download-concurrency", "download-size-limit", "download-recovery"] {
            let control = app.buttons[name]
            XCTAssertTrue(reveal(control, app)); assertInsideWindow(control, app)
            capture("下载设置-" + name, app)
        }
        app.terminate()
    }

    private func inspectSettings(largeText: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["browser-more"].waitForExistence(timeout: 10))
        openSettings(app)
        capture("设置首页", app)

        for (entry, control, name) in [
            ("general-browser-settings", "search-engine-picker", "浏览设置"),
            ("website-settings", "已保存的网站设置", "网站设置"),
            ("website-data-settings", "website-data-description", "网站数据管理"),
            ("enhancement-settings", "enhance-new-script", "网站增强"),
            ("reading-preferences-settings", "reading-width-setting", "阅读外观"),
            ("model-service-settings", "model-endpoint", "模型服务"),
            ("protection-options", "mining-protection", "保护选项"),
            ("content-filter-settings", "filter-network-count", "广告过滤")
        ] {
            let feature = !["general-browser-settings", "website-settings", "website-data-settings"].contains(entry)
            var depth = 1
            if feature {
                enterFeatureSettings(app)
                depth += 1
                let parent = entry == "reading-preferences-settings" ? "aegis-reading-settings" :
                    ["protection-options", "content-filter-settings"].contains(entry) ? "aegis-privacy-settings" : nil
                if let parent {
                    let group = app.buttons[parent]
                    XCTAssertTrue(reveal(group, app)); group.tap()
                    depth += 1
                }
            }
            let link = app.buttons[entry]
            XCTAssertTrue(reveal(link, app), "设置入口必须可达：\(entry)")
            assertInsideWindow(link, app)
            link.tap()
            let target = app.descendants(matching: .any)[control].firstMatch
            XCTAssertTrue(reveal(target, app), "页面控件必须可达：\(control)")
            assertInsideWindow(target, app)
            capture(name, app)
            if entry == "model-service-settings" {
                for identifier in ["model-endpoint", "model-name", "save-model"] {
                    let field = app.descendants(matching: .any)[identifier].firstMatch
                    XCTAssertTrue(reveal(field, app))
                    assertInsideWindow(field, app)
                }
                capture("模型服务底部", app)
            }
            for _ in 0..<depth {
                let back = app.navigationBars.buttons.element(boundBy: 0)
                XCTAssertTrue(back.isHittable)
                back.tap()
            }
        }
        enterFeatureSettings(app)
        for (entry, title) in [("aegis-gestures-settings", "鼠标手势"),
                               ("aegis-tools-settings", "本机工具连接"),
                               ("aegis-experiments-settings", "实验功能")] {
            let link = app.buttons[entry]
            XCTAssertTrue(reveal(link, app)); assertInsideWindow(link, app); link.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            capture(title, app)
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        let downloads = app.buttons["aegis-downloads-settings"]
        XCTAssertTrue(reveal(downloads, app)); downloads.tap()
        XCTAssertTrue(app.textFields["download-url"].waitForExistence(timeout: 5))
        capture("统一入口-下载增强", app)
        app.navigationBars["下载"].buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["Aegis 设置"].waitForExistence(timeout: 5))
        app.terminate()
    }

    private func enterFeatureSettings(_ app: XCUIApplication) {
        let entry = app.buttons["aegis-feature-settings"]
        XCTAssertTrue(reveal(entry, app)); assertInsideWindow(entry, app); entry.tap()
        XCTAssertTrue(app.navigationBars["Aegis 设置"].waitForExistence(timeout: 5))
        capture("Aegis八类设置入口", app)
    }

    private func openSettings(_ app: XCUIApplication) {
        app.buttons["browser-more"].tap()
        let settings = app.buttons["设置"]
        _ = settings.waitForExistence(timeout: 5)
        // iPad 的大字号菜单会分页，手势必须落在右侧菜单内。
        for _ in 0..<8 {
            if settings.exists { break }
            let menu = app.collectionViews.firstMatch
            XCTAssertTrue(menu.exists)
            menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.1, thenDragTo: menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
        }
        XCTAssertTrue(settings.exists)
        settings.tap()
    }

    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) -> Bool {
        _ = element.waitForExistence(timeout: 3)
        for _ in 0..<14 {
            // 导航动画期间集合视图会被替换，滚动坐标固定绑定应用窗口。
            let bounds = app.frame
            let top = max(bounds.minY, app.navigationBars.allElementsBoundByIndex.last?.frame.maxY ?? bounds.minY) + 8
            let bottom = bounds.maxY - 8
            if element.exists, element.isHittable, element.frame.midY >= top, element.frame.midY <= bottom { return true }
            let down = element.exists && !element.frame.isEmpty && element.frame.midY < top
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.35 : 0.75))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.75 : 0.35)))
        }
        capture("无法定位设置控件", app)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "无法定位时的界面层级"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        return false
    }

    private func assertInsideWindow(_ element: XCUIElement, _ app: XCUIApplication) {
        XCTAssertGreaterThan(element.frame.width, 0)
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX - 1)
        XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX + 1, "控件不得横向溢出：\(element.identifier)")
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
