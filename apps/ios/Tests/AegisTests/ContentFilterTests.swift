import XCTest
import WebKit
@testable import BrowserKit

@MainActor final class ContentFilterTests: XCTestCase {
    func testCompilerPreservesScopeAndSkipsUnsupportedModifiers() throws {
        let compiled = try ContentFilterCompiler.compile(["""
        [Adblock Plus 2.0]
        ||ads.example.com^$third-party,script
        ||stats.example.com/pixel$xmlhttprequest
        @@||ads.example.com/allowed.js$script
        ||unsafe.example.com^$redirect=noopjs
        ||scoped.example.com^$domain=one.example|~two.example
        ##.advertisement
        news.example##.sponsor
        news.example#@#.sponsor
        """])
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(compiled.json.utf8)) as? [[String: Any]])
        XCTAssertEqual(compiled.networkCount, 3)
        XCTAssertEqual(compiled.cosmeticCount, 1)
        XCTAssertEqual((rules.last?["action"] as? [String: String])?["type"], "ignore-previous-rules")
        XCTAssertTrue(compiled.json.contains("third-party"))
        XCTAssertFalse(compiled.json.contains("unsafe"))
        XCTAssertFalse(compiled.json.contains("scoped"))
        XCTAssertFalse(compiled.json.contains("sponsor"))
    }
    func testWebKitActuallyBlocksHTTPAndHidesAdsThenRestoresWhenRemoved() async throws {
        let compiled = try ContentFilterCompiler.compile(["||127.0.0.1/download.bin$xmlhttprequest\n##.test-ad"])
        let rule = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "aegis-ad-test-" + UUID().uuidString, encodedContentRuleList: compiled.json)
        let list = try XCTUnwrap(rule)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(list)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:8768/article")!))
        try await waitUntil { webView.url?.path == "/article" && !webView.isLoading }
        _ = try await webView.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend', '<div class=test-ad>广告样本</div><div id=normal-content>正文保留</div>')")
        let result = try await webView.callAsyncJavaScript("""
            const blocked = await fetch('/download.bin').then(() => false).catch(() => true);
            const normal = await fetch('/article-two').then(r => r.ok);
            return {blocked, normal, hidden: getComputedStyle(document.querySelector('.test-ad')).display === 'none', visible: getComputedStyle(document.querySelector('#normal-content')).display !== 'none'};
            """, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Bool]
        XCTAssertEqual(result, ["blocked": true, "normal": true, "hidden": true, "visible": true])
        configuration.userContentController.remove(list)
        let restored = try await webView.callAsyncJavaScript("return await fetch('/download.bin?restored=1').then(r => r.ok)", arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(restored, true)
        webView.stopLoading()
    }
    func testBundledSubscriptionsCompileInRealWebKit() async throws {
        let list = try await TrackingProtection.shared.ruleList()
        XCTAssertTrue(list.identifier.hasPrefix("aegis-trackers-"))
        XCTAssertGreaterThan(TrackingProtection.shared.networkCount, 1000)
        XCTAssertGreaterThan(TrackingProtection.shared.cosmeticCount, 100)
    }
    func testBrowserUsesBundledRulesAndRestoresSiteException() async throws {
        let url = URL(string: "http://127.0.0.1:8768/article")!
        let wasEnabled = TrackingProtection.enabled, wasExcepted = TrackingProtection.isExcepted(url)
        defer { TrackingProtection.enabled = wasEnabled; TrackingProtection.setException(wasExcepted, for: url) }
        TrackingProtection.enabled = true; TrackingProtection.setException(false, for: url)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        let tab = try XCTUnwrap(browser.activeTab)
        tab.load(url)
        try await waitUntil { tab.url == url && !tab.isLoading }
        XCTAssertTrue(tab.trackingProtectionReady)
        _ = try await tab.webView.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend', '<div class=adsbygoogle-box>广告样本</div>')")
        let result = try await tab.webView.callAsyncJavaScript("""
            return {blocked: await fetch('/download.bin?advertiser_id=fixture').then(() => false).catch(() => true), normal: await fetch('/download.bin').then(r => r.ok), hidden: getComputedStyle(document.querySelector('.adsbygoogle-box')).display === 'none'};
            """, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Bool]
        XCTAssertEqual(result, ["blocked": true, "normal": true, "hidden": true])
        TrackingProtection.setException(true, for: url)
        tab.reload()
        try await waitUntil { !tab.webView.isLoading && !tab.isLoading }
        XCTAssertFalse(tab.trackingProtectionReady)
        let restored = try await tab.webView.callAsyncJavaScript("return await fetch('/download.bin?advertiser_id=fixture').then(r => r.ok)", arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(restored, true)
        tab.stop()
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let limit = Date().addingTimeInterval(20)
        while !predicate() && Date() < limit { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(predicate())
    }
}
