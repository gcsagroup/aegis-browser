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

    func testAboutAppNameAtStandardSize() {
        inspectAboutAppName(largeText: false)
    }

    func testAboutAppNameAtLargestTextSize() {
        inspectAboutAppName(largeText: true)
    }

    private func inspectAboutAppName(largeText: Bool) {
        let app = XCUIApplication()
        let language = largeText ? "zh-Hans" : "en"
        app.launchArguments = ["--ui-testing", "--ui-testing-settings", "-AppleLanguages", "(\(language))",
                               "-AppleLocale", largeText ? "zh_CN" : "en_US",
                               "-UIPreferredContentSizeCategoryName", largeText ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(app.navigationBars[largeText ? "设置" : "Settings"].waitForExistence(timeout: 10))
        let appName = "Aegis Browser"
        let appField = largeText ? "应用" : "App"
        let nameLabels = NSPredicate(format: "label == %@ OR (label BEGINSWITH %@ AND label ENDSWITH %@)",
                                     appName, appField, appName)
        let name = app.collectionViews.firstMatch.staticTexts.matching(nameLabels).firstMatch
        XCTAssertTrue(reveal(name, app), "The About app name must remain visible at the requested text size")
        XCTAssertEqual(app.label, appName)
        XCTAssertTrue(name.label.hasSuffix(appName))
        XCTAssertFalse(name.label.contains("GCSA"))
        XCTAssertTrue(name.isHittable)
        assertInsideWindow(name, app)
        capture("Aegis Browser-About-\(largeText ? "largest" : "standard")", app)
        app.terminate()
    }

    func testAboutLinksAtLargestTextSize() {
        let app = XCUIApplication()
        // Standard-size coverage enters through the browser menu. Keep this
        // large-type check focused on the About links and license content.
        app.launchArguments = ["--ui-testing", "--ui-testing-settings", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
        for identifier in ["aegis-website-link", "aegis-support-link", "aegis-privacy-policy-link", "third-party-notices-link"] {
            let link = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            XCTAssertTrue(reveal(link, app), "关于中的链接必须可达：\(identifier)")
            assertInsideWindow(link, app)
            XCTAssertTrue(link.isHittable)
        }
        capture("支持与隐私政策入口-最大字体", app)
        let notices = app.buttons["third-party-notices-link"]
        XCTAssertTrue(reveal(notices, app))
        notices.tap()
        assertNoticesContent(app, title: "开源许可与鸣谢", name: "许可正文-最大字体")
        app.terminate()
    }

    func testThirdPartyNoticesAtStandardSize() {
        inspectNotices(largeText: false)
    }

    func testThirdPartyNoticesAtLargestTextSize() {
        inspectNotices(largeText: true)
    }

    func testThirdPartyNoticesInEnglishAtStandardSize() {
        inspectNotices(largeText: false, language: "en")
    }

    func testThirdPartyNoticesInEnglishAtLargestTextSize() {
        inspectNotices(largeText: true, language: "en")
    }

    private func inspectNotices(largeText: Bool, language: String = "zh-Hans") {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(\(language))",
                               "-UIPreferredContentSizeCategoryName", largeText ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        if largeText { app.launchArguments.append("--ui-testing-settings") }
        app.launch()
        if !largeText {
            XCTAssertTrue(app.buttons["browser-more"].waitForExistence(timeout: 10))
            openSettings(app, title: language == "en" ? "Settings" : "设置")
        }
        let entry = app.buttons["third-party-notices-link"]
        XCTAssertTrue(reveal(entry, app))
        entry.tap()
        let title = language == "en" ? "Open Source Licenses & Acknowledgements" : "开源许可与鸣谢"
        assertNoticesContent(app, title: title, name: "许可正文-\(language)-\(largeText ? "最大字体" : "普通字体")")
        app.terminate()
    }

    private func assertNoticesContent(_ app: XCUIApplication, title: String, name: String) {
        let list = app.collectionViews["third-party-notices-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let heading = app.staticTexts["third-party-notices-title"]
        XCTAssertEqual(heading.label, title)
        XCTAssertTrue(heading.isHittable)
        assertHorizontalBounds(heading, in: list)
        XCTAssertGreaterThan(heading.frame.height, 0)
        // Check the initial viewport before any scroll: the heading must wrap
        // within the list and leave the first real component directly usable.
        let firstComponent = app.buttons["third-party-notices-component-1"]
        XCTAssertTrue(firstComponent.waitForExistence(timeout: 5))
        XCTAssertTrue(firstComponent.isHittable)
        assertHorizontalBounds(firstComponent, in: list)
        XCTAssertGreaterThanOrEqual(firstComponent.frame.minY, heading.frame.maxY - 1)
        XCTAssertGreaterThan(list.frame.intersection(firstComponent.frame).height, 0)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "GCSA Aegis — Third-party licenses and acknowledgements"
        )).firstMatch.exists)
        capture(name + "-列表", app)

        XCTAssertFalse(app.buttons["third-party-notices-component-0"].exists)
        let components = [
            ("markdown-it", "15.0.2", "MIT"),
            ("DOMPurify", "3.4.16", "Apache-2.0 OR MPL-2.0"),
            ("markdown-it-task-lists", "2.1.1", "ISC"),
            ("acorn", "8.15.0", "MIT"),
            ("highlight.js", "11.12.0", "BSD-3-Clause")
        ]
        for (index, component) in components.enumerated() {
            let (componentTitle, version, licenseID) = component
            let entry = app.buttons["third-party-notices-component-\(index + 1)"]
            if index == 0 {
                XCTAssertTrue(entry.isHittable)
            } else {
                XCTAssertTrue(reveal(entry, app))
            }
            XCTAssertTrue(entry.label.contains(componentTitle))
            XCTAssertTrue(entry.label.contains(version))
            XCTAssertTrue(entry.label.contains(licenseID))
            XCTAssertFalse(entry.label.contains("-LICENSE"))
            assertHorizontalBounds(entry, in: list)
            entry.tap()
            let scroll = app.scrollViews["third-party-notice-detail-scroll"]
            XCTAssertTrue(scroll.waitForExistence(timeout: 5))
            let detailHeading = app.staticTexts["third-party-notice-detail-title"]
            XCTAssertEqual(detailHeading.label, componentTitle)
            XCTAssertTrue(detailHeading.isHittable)
            assertHorizontalBounds(detailHeading, in: scroll)
            XCTAssertGreaterThan(detailHeading.frame.height, 0)
            let metadata = app.staticTexts["third-party-notice-detail-metadata"]
            XCTAssertTrue(revealNoticeElement(metadata, in: scroll, app: app))
            XCTAssertEqual(metadata.label, "\(version) · \(licenseID)")
            assertHorizontalBounds(metadata, in: scroll)
            let website = app.descendants(matching: .any)
                .matching(identifier: "third-party-notice-detail-website").firstMatch
            XCTAssertTrue(revealNoticeElement(website, in: scroll, app: app))
            XCTAssertEqual(website.label, title == "开源许可与鸣谢" ? "官方网站" : "Official Website")
            assertHorizontalBounds(website, in: scroll)
            let firstParagraph = app.staticTexts["third-party-notice-detail-paragraph-0"]
            XCTAssertTrue(revealNoticeElement(firstParagraph, in: scroll, app: app))
            XCTAssertFalse(firstParagraph.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            assertHorizontalBounds(firstParagraph, in: scroll)
            assertNoNoticeEngineeringText(app)
            capture(name + "-" + componentTitle, app)

            if index == 0 {
                // Exercise every legal paragraph, including the final disclaimer.
                // Exact full bodies for all five libraries are checked by the model test.
                for (paragraph, marker) in [
                    (0, "Copyright (c) 2014 Vitaly Puzrin, Alex Kocharin."),
                    (1, "Permission is hereby granted"),
                    (2, "included in all copies or substantial portions of the Software."),
                    (3, "OTHER DEALINGS IN THE SOFTWARE.")
                ] {
                    let legal = app.staticTexts["third-party-notice-detail-paragraph-\(paragraph)"]
                    XCTAssertTrue(revealNoticeElement(legal, in: scroll, app: app))
                    XCTAssertTrue(legal.label.contains(marker))
                    assertHorizontalBounds(legal, in: scroll)
                    assertNoNoticeEngineeringText(app)
                }
                capture(name + "-完整许可条款", app)
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(list.waitForExistence(timeout: 5))
            XCTAssertTrue(reveal(entry, app))
        }
        // The next independent notice remains reachable after the web libraries.
        let otherNotice = app.buttons["third-party-notices-component-6"]
        XCTAssertTrue(reveal(otherNotice, app))
        XCTAssertTrue(otherNotice.label.contains("EasyList and EasyPrivacy"))
        otherNotice.tap()
        XCTAssertTrue(app.scrollViews["third-party-notice-detail-scroll"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["third-party-notice-detail-title"].label,
                       "EasyList and EasyPrivacy — The EasyList authors")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        // The rights note remains accessible below every component, including
        // at largest text where the list needs more than the usual 14 swipes.
        let introduction = app.staticTexts["third-party-notices-introduction-0"]
        for _ in 0..<100 {
            if introduction.exists, introduction.isHittable,
               list.frame.intersection(introduction.frame).height >= min(80, introduction.frame.height) { break }
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.8))
                .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.3)))
        }
        XCTAssertTrue(introduction.exists)
        XCTAssertTrue(introduction.isHittable)
        XCTAssertGreaterThanOrEqual(list.frame.intersection(introduction.frame).height,
                                    min(80, introduction.frame.height))
        XCTAssertTrue(introduction.label.contains("Third-party works retain their own licenses. These notices do not change those licenses."))
        XCTAssertFalse(introduction.label.contains("GCSA Aegis — Third-party licenses and acknowledgements"))
        assertHorizontalBounds(introduction, in: list)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["third-party-notices-link"].waitForExistence(timeout: 5))
    }

    private func assertNoNoticeEngineeringText(_ app: XCUIApplication) {
        for text in ["Source file:", "manifest.json", "CDN", "网页增强内置资源",
                     "Web enhancements — component versions and sources",
                     "apps/browser/overlay/"] {
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists,
                           "Engineering metadata must not appear in component details: \(text)")
        }
    }

    private func revealNoticeElement(_ element: XCUIElement, in scroll: XCUIElement,
                                     app: XCUIApplication) -> Bool {
        for _ in 0..<24 {
            assertNoNoticeEngineeringText(app)
            // Lazy paragraphs may not exist yet. Selectable Text can report an AX
            // frame taller than the viewport: require visible intersection, not a
            // centered or fully contained frame, and keep gestures off the text.
            if element.exists, element.isHittable,
               scroll.frame.intersection(element.frame).height >= min(80, element.frame.height) {
                return true
            }
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.8))
                .press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.35)))
        }
        return false
    }

    private func assertHorizontalBounds(_ element: XCUIElement, in surface: XCUIElement) {
        XCTAssertGreaterThanOrEqual(element.frame.minX, surface.frame.minX - 1)
        XCTAssertLessThanOrEqual(element.frame.maxX, surface.frame.maxX + 1)
        XCTAssertGreaterThan(element.frame.width, 0)
    }

    func testSettingsPagesInLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        inspectSettings(largeText: false)
    }

    func testFirebaseControlsAreIndependentAtLargestTextSize() {
        inspectFirebaseControls(largeText: true)
    }

    func testFirebaseControlsThroughSettingsMenu() {
        inspectFirebaseControls(largeText: false)
    }

    private func inspectFirebaseControls(largeText: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if largeText {
            // Focus the large-type check on the settings controls. The separate
            // menu test verifies the production entry without a launch shortcut.
            app.launchArguments += ["--ui-testing-settings", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        } else {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        }
        app.launch()
        if !largeText {
            XCTAssertTrue(app.buttons["browser-more"].waitForExistence(timeout: 10))
            openSettings(app)
        } else {
            XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
        }
        enterFeatureSettings(app)
        app.buttons["aegis-privacy-settings"].tap()
        let entry = app.buttons["firebase-data-collection-details"]
        XCTAssertTrue(reveal(entry, app))
        assertInsideWindow(entry, app)
        entry.tap()
        let crashes = app.switches["firebase-crash-reports"]
        let analytics = app.switches["firebase-analytics"]
        let remote = app.switches["firebase-remote-configuration"]
        for control in [crashes, analytics, remote] {
            XCTAssertTrue(reveal(control, app))
            assertInsideWindow(control, app)
            XCTAssertEqual(control.value as? String, "1")
        }
        XCTAssertTrue(reveal(analytics, app, scrollDown: true))
        capture("Firebase-使用分析-点击前", app)
        let controls = XCTAttachment(string: app.debugDescription)
        controls.name = "Firebase-开关层级"
        controls.lifetime = .keepAlways
        add(controls)
        tapFirebaseSwitch(analytics)
        capture("Firebase-使用分析-点击后", app)
        XCTAssertEqual(analytics.value as? String, "0")
        XCTAssertEqual(crashes.value as? String, "1")
        XCTAssertTrue(reveal(remote, app)); tapFirebaseSwitch(remote)
        XCTAssertEqual(remote.value as? String, "0")
        tapFirebaseSwitch(remote)
        XCTAssertEqual(remote.value as? String, "1")
        XCTAssertTrue(reveal(analytics, app, scrollDown: true))
        XCTAssertEqual(analytics.value as? String, "0")
        tapFirebaseSwitch(analytics)
        XCTAssertEqual(analytics.value as? String, "1")
        let disclosure = app.staticTexts["已获准发送的崩溃报告无法撤回。"]
        XCTAssertTrue(reveal(disclosure, app))
        assertInsideWindow(disclosure, app)
        capture(largeText ? "Firebase-独立开关-最大字体" : "Firebase-独立开关-普通字体", app)
        app.terminate()
    }

    private func tapFirebaseSwitch(_ control: XCUIElement) {
        // SwiftUI exposes the whole label row as the switch accessibility frame.
        // Tap the trailing native switch rather than the center of its text.
        XCTAssertTrue(control.isHittable)
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
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

    private func openSettings(_ app: XCUIApplication, title: String = "设置") {
        app.buttons["browser-more"].tap()
        let settings = app.buttons[title]
        _ = settings.waitForExistence(timeout: 5)
        // iPad 的大字号菜单会分页，手势必须落在右侧菜单内。
        for _ in 0..<8 {
            if settings.exists, settings.isHittable { break }
            let menu = app.collectionViews.firstMatch
            XCTAssertTrue(menu.exists)
            menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.1, thenDragTo: menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
        }
        XCTAssertTrue(settings.exists)
        settings.tap()
    }

    private func reveal(_ element: XCUIElement, _ app: XCUIApplication, scrollDown: Bool? = nil) -> Bool {
        _ = element.waitForExistence(timeout: 3)
        for _ in 0..<14 {
            // 导航动画期间集合视图会被替换，滚动坐标固定绑定应用窗口。
            let form = app.collectionViews.firstMatch
            let surface = form.exists ? form : app
            let bounds = surface.frame
            let top = max(bounds.minY, app.navigationBars.allElementsBoundByIndex.last?.frame.maxY ?? bounds.minY) + 8
            let bottom = bounds.maxY - 8
            if element.exists, element.isHittable, element.frame.midY >= top, element.frame.midY <= bottom { return true }
            // Virtualized rows may have no frame. A caller returning to an earlier row
            // can supply the known direction instead of scrolling farther away.
            let down = scrollDown ?? (element.exists && !element.frame.isEmpty && element.frame.midY < top)
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.35 : 0.75))
                .press(forDuration: 0.1, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.75 : 0.35)))
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
