import XCTest

@MainActor
final class AppLanguageUITests: XCTestCase {
    private var launchedApp: XCUIApplication?
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        launchedApp?.terminate()
        launchedApp = nil
    }

    func testTaiwanChoiceIsDistinctAndSurvivesRelaunch() {
        let app = launch(settings: true)
        openPicker(app)
        let system = app.buttons["language-choice-system"]
        let simplified = app.buttons["language-choice-zh-Hans"]
        let taiwan = app.buttons["language-choice-zh-Hant-TW"]
        let hongKong = app.buttons["language-choice-zh-Hant-HK"]
        XCTAssertTrue(system.exists && simplified.exists && taiwan.exists && hongKong.exists)
        XCTAssertLessThan(system.frame.minY, simplified.frame.minY)
        XCTAssertLessThan(simplified.frame.minY, taiwan.frame.minY)
        XCTAssertLessThan(taiwan.frame.minY, hongKong.frame.minY)
        hongKong.tap()
        XCTAssertTrue(app.navigationBars["語言"].waitForExistence(timeout: 5))
        XCTAssertTrue(hongKong.isSelected)
        XCTAssertFalse(taiwan.isSelected)
        let uk = app.buttons["language-choice-en-GB"]
        reveal(uk, in: app); uk.tap()
        XCTAssertTrue(app.navigationBars["Language"].waitForExistence(timeout: 5))
        XCTAssertEqual(uk.label, "English (UK)")
        XCTAssertTrue(uk.isSelected)
        let us = app.buttons["language-choice-en-US"]
        reveal(us, in: app); us.tap()
        XCTAssertEqual(us.label, "English (US)")
        XCTAssertTrue(us.isSelected)
        reveal(taiwan, in: app)
        XCTAssertEqual(taiwan.label, "中文（台湾）")
        taiwan.tap()
        XCTAssertTrue(app.navigationBars["語言"].waitForExistence(timeout: 5))
        XCTAssertTrue(taiwan.isSelected)
        reveal(hongKong, in: app)
        XCTAssertFalse(hongKong.isSelected)
        capturePicker(app, name: "繁體中文（台灣） selected")
        app.terminate()
        app.launchArguments.append("--ui-testing-preferences-keep")
        app.launch()
        openPicker(app)
        reveal(taiwan, in: app)
        XCTAssertTrue(taiwan.isSelected)
        app.navigationBars["語言"].buttons.element(boundBy: 0).tap()
        app.buttons["settings-done"].tap()
        XCTAssertEqual(app.textFields["address-field"].label, "搜索或輸入網址")
        XCTAssertTrue(app.webViews.staticTexts["安心瀏覽，清楚掌控。"].waitForExistence(timeout: 8))
    }

    func testLiveSwitchPickerChromeStartPageAndPersistence() {
        let app = launch(settings: true, largeText: true)
        openPicker(app)
        let english = app.buttons["language-choice-en-US"]
        reveal(english, in: app)
        XCTAssertEqual(app.buttons.matching(identifier: "language-choice-en-US").count, 1)
        XCTAssertEqual(english.label, "English (US)")
        XCTAssertFalse(app.buttons["language-choice-en-HK"].exists)
        capturePicker(app, name: "Language picker — English visible — accessibility text")
        let german = app.buttons["language-choice-de"]
        reveal(german, in: app); german.tap()
        XCTAssertTrue(app.navigationBars["Sprache"].waitForExistence(timeout: 5))
        XCTAssertTrue(german.isSelected)
        let traditional = app.buttons["language-choice-zh-Hant-TW"]
        reveal(traditional, in: app)
        XCTAssertEqual(app.buttons.matching(identifier: "language-choice-zh-Hant-TW").count, 1)
        XCTAssertFalse(app.buttons["language-choice-zh-Hant"].exists)
        traditional.tap()
        XCTAssertTrue(app.navigationBars["語言"].waitForExistence(timeout: 5))
        XCTAssertTrue(traditional.isSelected)
        capturePicker(app, name: "Language picker — 繁體中文 selected — accessibility text")
        // Reuse the same Settings scene and then return to its existing browser.
        reveal(german, in: app); german.tap()
        app.navigationBars["Sprache"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Einstellungen"].waitForExistence(timeout: 5))
        app.buttons["settings-done"].tap()
        let address = app.textFields["address-field"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertEqual(address.label, "Suchen oder Adresse eingeben")
        XCTAssertTrue(app.webViews.staticTexts["Sicher surfen. Die Kontrolle behalten."].waitForExistence(timeout: 8))
        openMenuItem("find-in-page", in: app)
        let find = app.textFields["find-text"]
        XCTAssertTrue(find.waitForExistence(timeout: 5))
        XCTAssertEqual(find.placeholderValue, "Suchtext")
        find.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        find.typeText("KEEP_FIND")
        XCTAssertEqual(find.value as? String, "KEEP_FIND")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Live language switch with accessibility text"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
        app.launchArguments.removeAll { $0 == "--ui-testing-settings" }
        app.launchArguments.append("--ui-testing-preferences-keep")
        app.launch()
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        XCTAssertEqual(address.label, "Suchen oder Adresse eingeben")
        openMenuItem("open-browser-settings", in: app)
        openPicker(app)
        let system = app.buttons["language-choice-system"]
        reveal(system, in: app); system.tap()
        XCTAssertTrue(app.navigationBars["Language"].waitForExistence(timeout: 5))
        XCTAssertTrue(system.isSelected)
        app.terminate(); app.launch()
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        XCTAssertEqual(address.label, "Search or enter a URL")
    }

    func testExternalPageAndFormSurviveLanguageChange() {
        let app = launch()
        let address = app.textFields["address-field"]
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        address.tap()
        address.typeText("http://127.0.0.1:8768/article\n")
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].waitForExistence(timeout: 12))
        let field = app.webViews.textFields["输入框不应进入助手"]
        reveal(field, in: app)
        field.tap(); field.typeText(" LANGUAGE_DRAFT")
        // The fixture input has no form action. Use the native accessory
        // toolbar (or keyboard hide control), never Return or page navigation.
        let accessoryDone = app.toolbars.buttons["Done"].firstMatch
        let keyboardHide = app.keyboards.buttons.matching(NSPredicate(
            format: "label IN %@", ["Hide keyboard", "Dismiss keyboard"]
        )).firstMatch
        let dismissKeyboard = accessoryDone.exists ? accessoryDone : keyboardHide
        XCTAssertTrue(dismissKeyboard.waitForExistence(timeout: 5))
        // tap supplies native interaction synchronization; AX existence alone
        // does not imply an immediately hittable keyboard animation frame.
        dismissKeyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let draftReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "LANGUAGE_DRAFT"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [draftReady], timeout: 5), .completed)
        let before = field.value as? String
        XCTAssertTrue(before?.contains("LANGUAGE_DRAFT") == true)
        openMenuItem("open-browser-settings", in: app)
        openPicker(app)
        reveal(app.buttons["language-choice-en-US"], in: app)
        capturePicker(app, name: "Language picker — English visible — standard text")
        let traditional = app.buttons["language-choice-zh-Hant-TW"]
        reveal(traditional, in: app); traditional.tap()
        XCTAssertTrue(app.navigationBars["語言"].waitForExistence(timeout: 5))
        XCTAssertTrue(traditional.isSelected)
        capturePicker(app, name: "Language picker — 繁體中文 selected — standard text")
        app.navigationBars["語言"].buttons.element(boundBy: 0).tap()
        app.buttons["settings-done"].tap()
        XCTAssertEqual(address.label, "搜索或輸入網址")
        reveal(field, in: app)
        XCTAssertEqual(field.value as? String, before, "Language selection must not reload the external document")
        XCTAssertTrue(app.webViews.staticTexts["城市绿地观察"].exists)
    }

    private func launch(settings: Bool = false, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        launchedApp = app
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en-US)", "-AppleLocale", "en_GB"]
        if settings { app.launchArguments.append("--ui-testing-settings") }
        app.launchArguments += ["-UIPreferredContentSizeCategoryName",
                                largeText ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        if ProcessInfo.processInfo.environment["AEGIS_UI_DARK"] == "1" {
            app.launchArguments.append("--ui-testing-dark")
        }
        app.launch()
        return app
    }

    private func openPicker(_ app: XCUIApplication) {
        let link = app.buttons["language-settings-link"]
        reveal(link, in: app); link.tap()
        XCTAssertTrue(app.buttons["language-choice-system"].waitForExistence(timeout: 5))
    }

    private func capturePicker(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openMenuItem(_ identifier: String, in app: XCUIApplication) {
        let more = app.buttons["browser-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertTrue(more.isHittable)
        more.tap()
        if identifier == "find-in-page" {
            tapMenuItem(labels: ["Page actions", "Seitenaktionen", "頁面操作"], in: app)
            tapMenuItem(labels: ["Find in page", "Auf Seite suchen", "在頁面中查找"], in: app)
        } else {
            XCTAssertEqual(identifier, "open-browser-settings")
            tapMenuItem(labels: ["Settings", "Einstellungen", "設定"], in: app)
        }
    }

    private func tapMenuItem(labels: [String], in app: XCUIApplication) {
        let item = app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        _ = item.waitForExistence(timeout: 5)
        for down in [false, true] {
            for step in 0...8 {
                let menu = app.collectionViews.firstMatch
                XCTAssertTrue(menu.exists)
                let windowBounds = app.frame
                let menuBounds = menu.frame.intersection(windowBounds)
                let target = menu.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
                if target.exists, target.isHittable,
                   menuBounds.contains(target.frame), !target.frame.isEmpty {
                    target.tap(); return
                }
                guard step < 8 else { break }
                // AX container frames do not describe native popup clipping.
                // Use a middle hittable row, with both endpoints inside that row.
                let visibleCells = menu.cells.allElementsBoundByIndex.filter {
                    $0.exists && $0.isHittable && !$0.frame.isEmpty && menuBounds.contains($0.frame)
                }
                let rows = visibleCells.isEmpty ? menu.buttons.allElementsBoundByIndex.filter {
                    $0.exists && $0.isHittable && !$0.frame.isEmpty && menuBounds.contains($0.frame)
                } : visibleCells
                let ordered = rows.sorted { $0.frame.midY < $1.frame.midY }
                guard !ordered.isEmpty else {
                    XCTFail("No fully visible hittable native menu row for scrolling")
                    return
                }
                let row = ordered[ordered.count / 2]
                row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.25 : 0.75))
                    .press(forDuration: 0.1, thenDragTo: row.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.75 : 0.25)))
            }
        }
        XCTFail("Unreachable menu item inside visible popup: \(labels)")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        _ = element.waitForExistence(timeout: 3)
        // Search both directions for virtualized rows; gestures stay in the
        // presented list (or the external document), including iPad sheets.
        for down in [false, true] {
            for _ in 0..<8 {
                let list = app.collectionViews.firstMatch
                let surface = list.exists ? list : app.webViews.firstMatch
                XCTAssertTrue(surface.exists)
                let bounds = surface.frame.intersection(app.frame)
                let navigationBottom = app.navigationBars.allElementsBoundByIndex.last?.frame.maxY ?? bounds.minY
                let top = max(bounds.minY, navigationBottom) + 8
                let bottom = bounds.maxY - 8
                if element.exists, element.isHittable,
                   element.frame.midY >= top, element.frame.midY <= bottom,
                   element.frame.midX >= bounds.minX, element.frame.midX <= bounds.maxX { return }
                let startY = top + (bottom - top) * (down ? 0.3 : 0.7)
                let endY = top + (bottom - top) * (down ? 0.7 : 0.3)
                let origin = surface.coordinate(withNormalizedOffset: .zero)
                origin.withOffset(CGVector(dx: bounds.midX - surface.frame.minX, dy: startY - surface.frame.minY))
                    .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: bounds.midX - surface.frame.minX, dy: endY - surface.frame.minY)))
            }
        }
        XCTFail("Unreachable control within visible content: \(element.identifier)")
    }
}
