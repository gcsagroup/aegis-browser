import XCTest

@MainActor
final class LocalizationUITests: XCTestCase {
    func testAddressAndSettingsInEveryRequestedLanguage() {
        let labels = [
            "de": ("Suchen oder Adresse eingeben", "Einstellungen"),
            "en-GB": ("Search or enter a URL", "Settings"),
            "en-HK": ("Search or enter a URL", "Settings"),
            "en": ("Search or enter a URL", "Settings"),
            "es": ("Buscar o introducir una URL", "Ajustes"),
            "fr": ("Rechercher ou saisir une URL", "Réglages"),
            "id": ("Cari atau masukkan URL", "Pengaturan"),
            "it": ("Cerca o inserisci un URL", "Impostazioni"),
            "ja": ("検索またはURLを入力", "設定"),
            "ko": ("검색 또는 URL 입력", "설정"),
            "ms": ("Cari atau masukkan URL", "Tetapan"),
            "pt": ("Pesquisar ou introduzir um URL", "Definições"),
            "th": ("ค้นหาหรือป้อน URL", "การตั้งค่า"),
            "vi": ("Tìm kiếm hoặc nhập URL", "Cài đặt"),
            "zh-Hans": ("搜索或输入网址", "设置"),
            "zh-Hant-HK": ("搜索或輸入網址", "設定"),
            "zh-Hant": ("搜索或輸入網址", "設定"),
        ]
        // This destination title was previously an English fallback in the added languages.
        let browsingTitles = [
            "de": "Browsereinstellungen",
            "en": "Browsing settings",
            "es": "Ajustes de navegación",
            "fr": "Réglages de navigation",
            "id": "Pengaturan penjelajahan",
            "it": "Impostazioni di navigazione",
            "ja": "閲覧設定",
            "ko": "탐색 설정",
            "ms": "Tetapan pelayaran",
            "pt": "Definições de navegação",
            "th": "การตั้งค่าการท่องเว็บ",
            "vi": "Cài đặt duyệt web",
            "zh-Hans": "浏览设置",
            "zh-Hant": "瀏覽設置",
        ]
        let fallbacks = ["en-GB": "en", "en-HK": "en", "zh-Hant-HK": "zh-Hant"]
        for locale in labels.keys.sorted() {
            let expected = labels[locale]!
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "-AppleLanguages", "(\(locale))",
                                   "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            app.launch()
            let address = app.textFields["address-field"]
            XCTAssertTrue(address.waitForExistence(timeout: 10), locale)
            XCTAssertEqual(address.label, expected.0, locale)
            app.buttons["browser-more"].tap()
            let settings = app.buttons[expected.1]
            // At accessibility sizes the system menu starts scrolled to the bottom.
            if !settings.isHittable {
                let menu = app.collectionViews.firstMatch
                if menu.waitForExistence(timeout: 2) {
                    for _ in 0..<4 where !settings.isHittable {
                        menu.swipeDown()
                    }
                }
            }
            guard settings.isHittable else {
                XCTFail("Settings menu item is not reachable for \(locale)")
                app.terminate()
                continue
            }
            settings.tap()
            XCTAssertTrue(app.navigationBars[expected.1].waitForExistence(timeout: 5), locale)
            let general = app.buttons["general-browser-settings"]
            XCTAssertTrue(general.waitForExistence(timeout: 5), locale)
            let done = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(done.isHittable, locale)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Localization-\(locale)-accessibility-text"
            attachment.lifetime = .keepAlways
            add(attachment)
            general.tap()
            let title = browsingTitles[fallbacks[locale] ?? locale]!
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), locale)
            let browsing = XCTAttachment(screenshot: app.screenshot())
            browsing.name = "Localization-\(locale)-browsing-accessibility-text"
            browsing.lifetime = .keepAlways
            add(browsing)
            app.terminate()
        }
    }
}
