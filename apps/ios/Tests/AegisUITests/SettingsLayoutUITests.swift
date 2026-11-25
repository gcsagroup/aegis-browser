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

    func testAddressBarLocationPrivacyUsesOriginalConnectionWithoutServiceAndTogglesCurrentSite() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        let field = app.textFields["address-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("https://example.invalid/\n")
        let icon = app.buttons["address-location-privacy"]
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        XCTAssertFalse(icon.isSelected)
        XCTAssertEqual(icon.label, "隐藏地理位置")
        XCTAssertEqual(icon.value as? String, "使用浏览器原有连接")
        capture("地址栏-无服务时使用原连接", app)
        icon.tap()
        let retry = app.buttons["page-load-proxy-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 12))
        XCTAssertEqual(retry.label, "重试")
        XCTAssertTrue(icon.isSelected)
        XCTAssertEqual(icon.value as? String, "连接暂不可用")
        capture("地址栏-手动开启隐藏地理位置", app)
        app.buttons["page-protection"].tap()
        app.buttons["site-details"].tap()
        let siteSwitch = app.switches["access-site-proxy-toggle"]
        XCTAssertTrue(siteSwitch.waitForExistence(timeout: 5))
        XCTAssertEqual(siteSwitch.value as? String, "1")
        siteSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.navigationBars["当前网站"].buttons["完成"].tap()
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        XCTAssertFalse(icon.isSelected)
        field.tap()
        XCTAssertFalse(icon.exists)
        XCTAssertTrue((field.value as? String ?? "").contains("example.invalid"))
    }

    func testOriginalWebsiteChoiceOffersAnOriginalRetryWithLocationPrivacyEnabled() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }

        let address = app.textFields["address-field"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText("https://example.invalid/\n")
        let privacy = app.buttons["address-location-privacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 10))
        XCTAssertFalse(privacy.isSelected)
        privacy.tap()
        let proxyRetry = app.buttons["page-load-proxy-retry"]
        XCTAssertTrue(proxyRetry.waitForExistence(timeout: 12))
        XCTAssertTrue(privacy.isSelected)

        app.buttons["browser-more"].tap()
        app.buttons["open-browser-settings"].tap()
        let entry = app.buttons["domestic-acceleration-link"]
        XCTAssertTrue(reveal(entry, app))
        entry.tap()
        let original = app.buttons["使用原有连接"]
        XCTAssertTrue(reveal(original, app))
        original.tap()
        XCTAssertTrue(original.isSelected)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["settings-done"].tap()

        let retry = app.buttons["page-load-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 8), "The explicit original route must have an actionable retry")
        XCTAssertFalse(proxyRetry.exists)
        let stopLoading = app.buttons["停止加载"]
        XCTAssertFalse(stopLoading.exists)
        retry.tap()

        // WebKit may present its own HTTPS interstitial for this reserved host.
        // Observe a new load instead of requiring a second app-level DNS error.
        XCTAssertTrue(stopLoading.waitForExistence(timeout: 8))
        XCTAssertTrue((address.value as? String ?? "").contains("example.invalid"))
        XCTAssertTrue(privacy.isSelected)
        XCTAssertFalse(proxyRetry.exists)
    }

    func testLocationPrivacyControlsHideNodeDetailsAndKeepFailedTarget() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        let address = app.textFields["address-field"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText("http://127.0.0.1:64999/missing\n")
        let retry = app.buttons["page-load-proxy-retry"]
        let failedHost = app.staticTexts["page-load-failed-host"]
        XCTAssertTrue(failedHost.waitForExistence(timeout: 15))
        XCTAssertFalse(retry.exists)
        XCTAssertTrue(app.buttons["重试"].isHittable)
        XCTAssertEqual(failedHost.label, "本机页面")
        XCTAssertFalse((failedHost.value as? String ?? "").contains("127.0.0.1"))
        capture("加载失败-隐藏地理位置", app)
        app.buttons["page-protection"].tap()
        app.buttons["site-details"].tap()
        let toggle = app.switches["access-site-proxy-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.label, "隐藏地理位置")
        XCTAssertEqual(app.staticTexts["access-site-proxy-host"].label, "本机页面")
        XCTAssertFalse(app.descendants(matching: .any)["access-proxy-configured-node"].exists)
        XCTAssertFalse(app.staticTexts["VLESS · TCP · REALITY · Vision"].exists)
        XCTAssertFalse(app.switches["access-site-auto-recovery-toggle"].exists)
        XCTAssertFalse(app.buttons["access-dev-allow-block-allow"].exists)
        assertInsideWindow(toggle, app)
        capture("当前网站-隐藏地理位置", app)
    }

    func testInternalNodeEditorKeepsTextEntryAvailableAfterCameraUnavailable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-settings", "-AppleLanguages", "(en)",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        defer { app.terminate() }
        let entry = app.buttons["access-test-node-options"]
        XCTAssertTrue(reveal(entry, app))
        entry.tap()
        let profile = app.buttons["access-test-profile"]
        XCTAssertTrue(reveal(profile, app))
        profile.tap()
        let saved = app.staticTexts["access-test-node-saved"]
        XCTAssertFalse(saved.exists, "The UI test launch must start with an empty profile")
        let scan = app.buttons["access-test-node-scan"]
        XCTAssertTrue(reveal(scan, app))
        scan.tap()
        let cameraError = app.staticTexts["access-test-node-error"]
        XCTAssertTrue(reveal(cameraError, app))
        XCTAssertEqual(cameraError.label, "Camera scanning is unavailable. You can still enter a node link.")

        let field = app.secureTextFields["access-test-node-link"]
        XCTAssertTrue(reveal(field, app, scrollDown: true))
        field.tap()
        let syntheticLink = "vless://550e8400-e29b-41d4-a716-446655440000@198.51.100.10:443"
            + "?type=tcp&security=reality&flow=xtls-rprx-vision&sni=www.example.com"
            + "&pbk=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&sid=&spx=%2Fsynthetic"
            + "&support-x25519mlkem768=true#synthetic-node"
        field.typeText(syntheticLink)
        let preview = app.buttons["access-test-node-preview"]
        XCTAssertTrue(reveal(preview, app))
        preview.tap()
        let redacted = app.staticTexts["access-test-node-redacted-preview"]
        XCTAssertTrue(reveal(redacted, app))
        XCTAssertEqual(redacted.label, "3X-UI test node")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "synthetic-node")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "198.51.100.10")).firstMatch.exists)
        let apply = app.buttons["access-test-node-apply"]
        XCTAssertTrue(reveal(apply, app))
        XCTAssertTrue(apply.isEnabled)
        let discard = app.buttons["access-test-node-discard"]
        XCTAssertTrue(reveal(discard, app))
        discard.tap()
        XCTAssertFalse(redacted.exists)
        // Removing the draft section can reset this virtualized Form's scroll
        // position, especially with a saved node and accessibility text sizes.
        XCTAssertTrue(reveal(apply, app))
        XCTAssertFalse(apply.isEnabled)

        XCTAssertTrue(reveal(field, app, scrollDown: true))
        field.tap()
        field.typeText(syntheticLink)
        XCTAssertTrue(reveal(preview, app))
        preview.tap()
        XCTAssertTrue(reveal(apply, app))
        apply.tap()
        XCTAssertTrue(reveal(saved, app, scrollDown: true))
        XCTAssertEqual(saved.label, "Node saved.")
        // The saved section includes a URL TextField. Start below-viewport
        // scrolling in the form gutter so text interaction cannot absorb it.
        XCTAssertTrue(reveal(apply, app, dragOffsetX: 0.96))
        XCTAssertFalse(apply.isEnabled)
        let remove = app.buttons["access-test-node-remove"]
        XCTAssertTrue(reveal(remove, app, dragOffsetX: 0.96))
        XCTAssertTrue(remove.isEnabled)
        remove.tap()
        // UIKit may expose both a popup wrapper and its button with this identifier.
        let confirm = app.sheets.buttons.matching(identifier: "access-test-node-confirm-remove").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "One tap on Remove must present confirmation")
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5), "Confirmation must remove the visible saved-node action")
        XCTAssertTrue(saved.waitForNonExistence(timeout: 5))

        let profileBar = app.navigationBars["3X-UI test profile"]
        if profileBar.exists {
            let back = profileBar.buttons.firstMatch
            XCTAssertTrue(back.isHittable)
            back.tap()
        }
        XCTAssertTrue(reveal(profile, app))
        profile.tap()
        let emptyProfile = app.staticTexts["access-test-node-empty"]
        XCTAssertTrue(reveal(emptyProfile, app))
        XCTAssertEqual(emptyProfile.label, "No node saved.")
    }

    func testAccountUsageEntryShowsHonestEmptyStateInChinese() {
        inspectAccountUsage(language: "zh-Hans", largeText: false)
    }

    func testAccountUsageEntryIsReachableInEnglishAtLargestTextSize() {
        inspectAccountUsage(language: "en", largeText: true)
    }

    private func inspectAccountUsage(language: String, largeText: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-settings", "-AppleLanguages", "(\(language))",
            "-UIPreferredContentSizeCategoryName", largeText ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launchEnvironment["AEGIS_ACCESS_LOCAL_V2RAY_CONFIG"] = ""
        app.launchEnvironment["AEGIS_ACCOUNT_SIM_ORIGIN"] = "http://127.0.0.1:1"
        app.launchEnvironment["AEGIS_ACCOUNT_SIM_ACTION"] = "clear"
        app.launch()
        defer { app.terminate() }
        let entry = app.buttons["access-usage-link"]
        XCTAssertTrue(reveal(entry, app))
        assertInsideWindow(entry, app)
        XCTAssertEqual(entry.label, language == "en" ? "IP location privacy" : "隐藏地理位置服务")
        if language == "zh-Hans" { capture("设置-隐私保护", app) }
        entry.tap()
        let page = app.descendants(matching: .any).matching(identifier: "access-usage-page").firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars[language == "en" ? "IP location privacy" : "隐藏地理位置服务"].exists)
        // 当前产品使用订阅用量页；没有配置时显示查询不可用，不能把未知额度当成零。
        XCTAssertFalse(app.descendants(matching: .any)["access-usage-progress"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["access-usage-used"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["access-proxy-configured-node"].exists)
        let emptyState = app.staticTexts[language == "en"
            ? "Allowance query unavailable; this does not mean the balance is zero"
            : "额度查询不可用，不代表余额为零"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5))
        XCTAssertTrue(reveal(emptyState, app))
        assertInsideWindow(emptyState, app)
        let refresh = app.buttons["access-usage-refresh"]
        XCTAssertTrue(reveal(refresh, app)); XCTAssertTrue(refresh.isEnabled)
        refresh.tap()
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["access-usage-used"].exists)
        capture("账号与用量-\(language)-\(largeText ? "最大字体" : "普通字体")", app)
    }

    #if DEBUG
    func testWebsiteAccelerationBetaIsReadableAtLargestTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-settings", "-AppleLanguages", "(en)",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchEnvironment["AEGIS_ACCESS_LOCAL_V2RAY_CONFIG"] = ""
        app.launch()
        defer { app.terminate() }
        let domestic = app.buttons["domestic-acceleration-link"]
        XCTAssertTrue(reveal(domestic, app))
        domestic.tap()
        let smart = app.buttons["website-acceleration-smart"]
        XCTAssertTrue(reveal(smart, app))
        smart.tap()
        let categories = app.buttons["website-acceleration-categories"]
        XCTAssertTrue(reveal(categories, app))
        XCTAssertEqual(categories.label, "Acceleration Categories Beta")
        XCTAssertEqual(categories.value as? String, "Debian")
        assertInsideWindow(categories, app)
        capture("Acceleration Categories Beta - Largest Text", app)
        XCTAssertFalse(app.staticTexts["Beta"].exists, "The visual tag is part of the single accessible navigation row")
        categories.tap()
        let meituan = app.buttons["website-acceleration-category-MEITUAN"]
        XCTAssertTrue(reveal(meituan, app))
        assertInsideWindow(meituan, app)
        XCTAssertEqual(meituan.value as? String, "Includes Dianping")
        capture("Acceleration Categories - Largest Text", app)
    }

    func testWebsiteAccelerationBetaIsHiddenInPrivateSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AEGIS_ACCESS_LOCAL_V2RAY_CONFIG"] = ""
        app.launch()
        defer { app.terminate() }
        let more = app.buttons["browser-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        openSettings(app)
        let domestic = app.buttons["domestic-acceleration-link"]
        XCTAssertTrue(reveal(domestic, app))
        domestic.tap()
        let smart = app.buttons["website-acceleration-smart"]
        XCTAssertTrue(reveal(smart, app))
        smart.tap()
        XCTAssertTrue(app.buttons["website-acceleration-categories"].waitForExistence(timeout: 5))
        app.navigationBars["国内加速"].buttons.element(boundBy: 0).tap()
        app.buttons["settings-done"].tap()

        more.tap()
        let profiles = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "profile-menu", "普通")).firstMatch
        XCTAssertTrue(profiles.waitForExistence(timeout: 5))
        profiles.tap()
        let privateProfile = app.buttons["私密"]
        XCTAssertTrue(privateProfile.waitForExistence(timeout: 5))
        privateProfile.tap()
        XCTAssertEqual(app.buttons["page-protection"].value as? String, "私密浏览：不记录历史，保存和发送资料前需确认")
        openSettings(app)
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
        XCTAssertFalse(domestic.exists)
        XCTAssertFalse(app.buttons["overseas-acceleration-link"].exists)
        XCTAssertFalse(app.buttons["website-acceleration-categories"].exists)
        capture("私密浏览-设置隐藏国内加速", app)
    }

    func testWebsiteAccelerationBetaSelectionAndPersistence() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-settings", "--ui-testing-geosite-cache",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AEGIS_ACCESS_LOCAL_V2RAY_CONFIG"] = ""
        app.launch()
        defer { app.terminate() }

        func openDomesticAcceleration() {
            XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
            let entry = app.buttons["domestic-acceleration-link"]
            XCTAssertTrue(reveal(entry, app))
            entry.tap()
        }

        openDomesticAcceleration()
        let manual = app.buttons["website-acceleration-manual"]
        let smart = app.buttons["website-acceleration-smart"]
        let categories = app.buttons["website-acceleration-categories"]
        XCTAssertTrue(manual.waitForExistence(timeout: 5))
        XCTAssertTrue(manual.isSelected)
        XCTAssertFalse(categories.exists)
        XCTAssertTrue(reveal(smart, app))
        smart.tap()
        capture("网站加速-智能-Beta 入口", app)
        XCTAssertTrue(categories.waitForExistence(timeout: 5), "智能模式必须显示可导航的加速分类 Beta")
        XCTAssertEqual(categories.label, "加速分类 Beta")
        XCTAssertEqual(categories.value as? String, "Debian")
        XCTAssertTrue(reveal(categories, app))
        categories.tap()

        let debian = app.buttons["website-acceleration-category-DEBIAN"]
        let douban = app.buttons["website-acceleration-category-DOUBAN"]
        let meituan = app.buttons["website-acceleration-category-MEITUAN"]
        XCTAssertTrue(app.navigationBars["加速分类"].waitForExistence(timeout: 5))
        XCTAssertTrue(debian.isSelected)
        XCTAssertFalse(douban.isSelected)
        XCTAssertFalse(meituan.isSelected)
        XCTAssertEqual(douban.label, "豆瓣")
        XCTAssertEqual(meituan.label, "美团")
        XCTAssertEqual(meituan.value as? String, "含大众点评")
        douban.tap()
        XCTAssertTrue(douban.isSelected)
        debian.tap()
        XCTAssertFalse(debian.isSelected)
        meituan.tap()
        XCTAssertTrue(meituan.isSelected)
        meituan.tap()
        XCTAssertFalse(meituan.isSelected)
        capture("加速分类-豆瓣单选", app)

        let back = app.navigationBars["加速分类"].buttons.element(boundBy: 0)
        back.tap()
        XCTAssertEqual(categories.value as? String, "豆瓣")
        manual.tap()
        XCTAssertFalse(categories.exists)
        smart.tap()
        XCTAssertTrue(reveal(categories, app))
        XCTAssertEqual(categories.value as? String, "豆瓣")
        categories.tap()
        douban.tap()
        XCTAssertFalse(douban.isSelected)
        back.tap()
        XCTAssertEqual(categories.value as? String, "未选择")
        XCTAssertTrue(app.staticTexts["未选择加速分类。"].exists)

        app.terminate()
        app.launchArguments.append("--ui-testing-geosite-cache-keep")
        app.launch()
        openDomesticAcceleration()
        XCTAssertTrue(reveal(categories, app))
        XCTAssertEqual(categories.value as? String, "未选择")
        categories.tap()
        XCTAssertFalse(debian.isSelected)
        XCTAssertFalse(douban.isSelected)
        XCTAssertFalse(meituan.isSelected)
        capture("加速分类-重新启动后保留空选", app)
    }

    func testWebsiteAccelerationConsentAndRelaunch() throws {
        guard ProcessInfo.processInfo.environment["AEGIS_GEOSITE_METADATA"] != nil else {
            throw XCTSkip("First prepare the GeoSite consent cache with the isolated HTTPS fixture")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-settings", "--ui-testing-geosite-consent-fixture",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AEGIS_ACCESS_LOCAL_V2RAY_CONFIG"] = ""
        defer { app.terminate() }

        func open() {
            app.launch()
            XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
            let entry = app.buttons["domestic-acceleration-link"]
            XCTAssertTrue(reveal(entry, app))
            entry.tap()
            let link = app.buttons["website-acceleration-categories"]
            XCTAssertTrue(reveal(link, app))
            link.tap()
            XCTAssertTrue(app.navigationBars["加速分类"].waitForExistence(timeout: 5))
        }

        func control(_ identifier: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }

        open()
        let douban = app.buttons["website-acceleration-category-DOUBAN"]
        XCTAssertTrue(douban.isSelected)
        XCTAssertEqual(douban.value as? String, "等待确认")
        let details = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@",
            "豆瓣", "website-acceleration-category-DOUBAN")).firstMatch
        let candidate = control("website-acceleration-candidate-DOUBAN")
        let approve = app.buttons["website-acceleration-approve-DOUBAN"]
        XCTAssertFalse(candidate.exists)
        XCTAssertFalse(approve.exists)
        XCTAssertTrue(reveal(details, app))
        details.tap()
        XCTAssertTrue(reveal(candidate, app))
        XCTAssertTrue(reveal(app.staticTexts["expanded.example.com"], app))
        XCTAssertTrue(reveal(approve, app))
        approve.tap()
        XCTAssertTrue(approve.waitForNonExistence(timeout: 10))
        XCTAssertFalse(candidate.exists)
        XCTAssertTrue(douban.isSelected)

        app.terminate()
        open()
        XCTAssertTrue(douban.isSelected)
        XCTAssertNotEqual(douban.value as? String, "等待确认")
        XCTAssertTrue(reveal(details, app))
        details.tap()
        XCTAssertFalse(approve.exists)
        let verifiedDomains = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "expanded.example.com")).firstMatch
        XCTAssertTrue(reveal(verifiedDomains, app))
        capture("加速分类-批准新增范围并重新启动", app)
    }

    func testOverseasSettingsRequiresExplicitConfirmationAndRestoresChoice() throws {
        guard ProcessInfo.processInfo.environment["AEGIS_OVERSEAS_UI_READY"] == "1" else {
            throw XCTSkip("The hosted overseas snapshot fixture must be staged first")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-settings", "--ui-testing-overseas-fixture",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AEGIS_ACCESS_LOCAL_V2RAY_CONFIG"] = ""
        app.launch()
        defer { app.terminate() }
        func open() {
            XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
            let domestic = app.buttons["domestic-acceleration-link"]
            XCTAssertTrue(reveal(domestic, app))
            let domesticPage = app.navigationBars["国内加速"]
            // The first settings update after launch can recreate the link.
            domestic.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
            if !domesticPage.waitForExistence(timeout: 3), domestic.exists, domestic.isHittable {
                domestic.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
            }
            XCTAssertTrue(domesticPage.waitForExistence(timeout: 5))
            let smart = app.buttons["website-acceleration-smart"]
            XCTAssertTrue(smart.waitForExistence(timeout: 5))
            if !smart.isSelected { smart.tap() }
            let overseas = app.buttons["overseas-acceleration-link"]
            XCTAssertTrue(reveal(overseas, app))
            overseas.tap()
            XCTAssertTrue(app.navigationBars["海外加速（针对大陆地区）"].waitForExistence(timeout: 5))
        }
        open()
        let disabled = app.staticTexts["overseas-disabled"]
        XCTAssertTrue(disabled.exists)
        let ai = app.switches["overseas-category-AI"]
        XCTAssertTrue(reveal(ai, app))
        XCTAssertEqual(ai.value as? String, "0")
        ai.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(ai.value as? String, "1")
        let review = app.buttons["overseas-review-choice"]
        XCTAssertTrue(reveal(review, app))
        review.tap()
        let confirm = app.buttons["overseas-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(reveal(disabled, app))
        XCTAssertTrue(reveal(review, app))
        review.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let disable = app.buttons["overseas-disable"]
        XCTAssertTrue(disable.waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        open()
        XCTAssertTrue(disable.waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(ai, app))
        XCTAssertEqual(ai.value as? String, "1")
        XCTAssertTrue(reveal(disable, app))
        disable.tap()
        XCTAssertTrue(disabled.waitForExistence(timeout: 5))
    }

    func testWebsiteAccelerationModesInDevSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-settings", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AEGIS_ACCESS_LOCAL_V2RAY_CONFIG"] = ""
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
        let entry = app.buttons["domestic-acceleration-link"]
        XCTAssertTrue(reveal(entry, app), "设置中的国内加速入口必须可见且可点击")
        assertInsideWindow(entry, app)
        XCTAssertEqual(entry.label, "国内加速")
        entry.tap()
        XCTAssertTrue(app.navigationBars["国内加速"].waitForExistence(timeout: 5))
        let website = app.descendants(matching: .any)["website-acceleration-section"]
        XCTAssertTrue(website.waitForExistence(timeout: 5))
        XCTAssertEqual(website.label, "网站加速")
        XCTAssertFalse(app.staticTexts["位置加速"].exists)

        let manual = app.buttons["website-acceleration-manual"]
        let smart = app.buttons["website-acceleration-smart"]
        let manualHint = app.staticTexts.matching(NSPredicate(format: "label == %@", "自行选择要加速的网站。"))
        let smartHint = app.staticTexts.matching(NSPredicate(format: "label == %@", "按所选分类加速网站。"))
        let serviceNotice = app.staticTexts.matching(NSPredicate(format: "label == %@", "加速服务未配置。"))
        let smartPrivacyNotice = app.descendants(matching: .any)["website-acceleration-smart-location-privacy"]
        let engineeringDetails = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@ OR label CONTAINS %@ OR label CONTAINS %@",
            "debian.org", "系统代理", "原有的选路规则"
        ))
        XCTAssertTrue(manual.waitForExistence(timeout: 5))
        XCTAssertTrue(smart.waitForExistence(timeout: 5))
        XCTAssertEqual(manual.label, "手动")
        XCTAssertEqual(smart.label, "智能")
        // --ui-testing resets the isolated preferences suite on launch.
        XCTAssertTrue(manual.isSelected)
        XCTAssertFalse(smart.isSelected)
        XCTAssertEqual(manualHint.count, 1)
        XCTAssertFalse(smartHint.firstMatch.exists)
        XCTAssertEqual(serviceNotice.count, 1)
        XCTAssertEqual(serviceNotice.firstMatch.identifier, "website-acceleration-service-unavailable")
        capture("国内加速-网站加速-手动", app)

        XCTAssertTrue(reveal(smart, app))
        smart.tap()
        XCTAssertTrue(smart.isSelected)
        XCTAssertFalse(manual.isSelected)
        XCTAssertEqual(smartHint.count, 1)
        XCTAssertFalse(manualHint.firstMatch.exists)
        XCTAssertFalse(engineeringDetails.firstMatch.exists)
        // Without a configured service there is no default location-privacy attempt to replace.
        XCTAssertFalse(smartPrivacyNotice.exists)
        XCTAssertEqual(serviceNotice.count, 1)
        XCTAssertEqual(serviceNotice.firstMatch.identifier, "website-acceleration-service-unavailable")
        capture("国内加速-网站加速-智能", app)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(reveal(entry, app))
        entry.tap()
        XCTAssertTrue(smart.waitForExistence(timeout: 5))
        XCTAssertTrue(smart.isSelected)
        XCTAssertEqual(smartHint.count, 1)
        XCTAssertFalse(manualHint.firstMatch.exists)

        app.terminate()
        app.launchArguments.append("--ui-testing-preferences-keep")
        app.launch()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(entry, app))
        entry.tap()
        XCTAssertTrue(smart.waitForExistence(timeout: 5))
        XCTAssertTrue(smart.isSelected)
        XCTAssertFalse(manual.isSelected)
        XCTAssertEqual(smartHint.count, 1)
        XCTAssertFalse(manualHint.firstMatch.exists)

        XCTAssertTrue(reveal(manual, app))
        manual.tap()
        XCTAssertTrue(manual.isSelected)
        XCTAssertFalse(smart.isSelected)
        XCTAssertEqual(manualHint.count, 1)
        XCTAssertFalse(smartHint.firstMatch.exists)
    }
    #endif

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
            // iPad 的最大字体表单会在中央命中主题菜单，沿列表右边缘滚动。
            XCTAssertTrue(reveal(link, app, dragOffsetX: 0.96), "关于中的链接必须可达：\(identifier)")
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
        for _ in 0..<26 {
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
        let website = app.buttons["website-settings"]
        XCTAssertTrue(reveal(website, app)); website.tap()
        app.buttons["current-site-settings"].tap()
        for title in ["网页缩放", "网站模式", "JavaScript", "系统加固", "严格指纹限制（实验）", "相机", "麦克风"] {
            // SwiftUI 菜单在不同系统快照中可报告为按钮或弹出菜单。
            let control = app.descendants(matching: .any).matching(NSPredicate(
                format: "(elementType == %d OR elementType == %d) AND label BEGINSWITH %@",
                XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.popUpButton.rawValue, title
            )).firstMatch
            XCTAssertTrue(reveal(control, app, dragOffsetX: 0.96), title)
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
        XCTAssertFalse(app.buttons["aegis-gestures-settings"].exists)
        XCTAssertFalse(app.buttons["aegis-tools-settings"].exists)
        let experiments = app.buttons["aegis-experiments-settings"]
        XCTAssertTrue(reveal(experiments, app))
        assertInsideWindow(experiments, app)
        experiments.tap()
        XCTAssertTrue(app.navigationBars["实验功能"].waitForExistence(timeout: 5))
        app.buttons["网站设置与权限"].tap()
        XCTAssertTrue(app.staticTexts["已保存的网站设置"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
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
        capture("Aegis 设置入口", app)
    }

    private func openSettings(_ app: XCUIApplication, title: String = "设置") {
        app.buttons["browser-more"].tap()
        let settings = app.buttons[title]
        _ = settings.waitForExistence(timeout: 5)
        // 原生菜单的行可能被裁剪，或以虚拟节点报告；按实际容器定位后点击坐标。
        func viewport() -> CGRect {
            guard settings.exists, !settings.identifier.isEmpty else { return app.frame }
            return app.otherElements.containing(.button, identifier: settings.identifier).allElementsBoundByIndex
                .map { $0.frame.intersection(app.frame) }
                .filter { !$0.isEmpty && $0.width >= settings.frame.width && $0.height >= 44 }
                .min { $0.width * $0.height < $1.width * $1.height } ?? app.frame
        }
        for _ in 0..<8 {
            let bounds = viewport()
            if settings.exists, settings.isHittable, bounds.contains(settings.frame) { break }
            let down = !settings.exists || settings.frame.midY < bounds.midY
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: bounds.midX - app.frame.minX,
                dy: bounds.minY + bounds.height * (down ? 0.3 : 0.7) - app.frame.minY))
            let end = origin.withOffset(CGVector(dx: bounds.midX - app.frame.minX,
                dy: bounds.minY + bounds.height * (down ? 0.7 : 0.3) - app.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(settings.exists)
        XCTAssertTrue(settings.isHittable)
        XCTAssertTrue(viewport().contains(settings.frame))
        let frame = settings.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: frame.midX - app.frame.minX, dy: frame.midY - app.frame.minY)).tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }

    private func reveal(_ element: XCUIElement, _ app: XCUIApplication, scrollDown: Bool? = nil,
                        dragOffsetX: CGFloat = 0.96) -> Bool {
        _ = element.waitForExistence(timeout: 3)
        for _ in 0..<14 {
            // iPad 可同时保留背景表单和前台编辑器，优先选目标所属的列表。
            let lists = app.collectionViews.allElementsBoundByIndex
            let containing = element.exists && !element.identifier.isEmpty
                ? app.collectionViews.containing(.any, identifier: element.identifier).allElementsBoundByIndex : []
            let surface = containing.last ?? lists.last ?? app
            let bounds = surface.frame.intersection(app.frame)
            let top = max(bounds.minY, app.navigationBars.allElementsBoundByIndex.last?.frame.maxY ?? bounds.minY)
            var bottom = bounds.maxY
            // 系统底部搜索栏覆盖列表时，AX 仍可能把被遮住的行报告为可点击。
            let search = app.searchFields.firstMatch
            if search.exists, search.isHittable, search.frame.minY > top {
                bottom = min(bottom, search.frame.minY - 8)
            }
            let frame = element.exists ? element.frame : .null
            if element.exists, element.isHittable {
                if frame.height <= bottom - top {
                    if frame.minY >= top - 1, frame.maxY <= bottom + 1 { return true }
                } else if frame.midY >= top, frame.midY <= bottom { return true }
            }
            let down = scrollDown ?? (!frame.isNull && !frame.isEmpty && frame.minY < top)
            let height = max(1, bottom - top)
            var distance = height * 0.4
            if !frame.isNull, !frame.isEmpty {
                let clipped = down ? top - frame.minY : frame.maxY - bottom
                if clipped > 0 { distance = min(distance, max(32, clipped + 16)) }
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let startX = bounds.minX + bounds.width * dragOffsetX - app.frame.minX
            let startY = top + height * (down ? 0.3 : 0.7) - app.frame.minY
            origin.withOffset(CGVector(dx: startX, dy: startY)).press(forDuration: 0.1,
                thenDragTo: origin.withOffset(CGVector(dx: startX, dy: startY + (down ? distance : -distance))))

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
