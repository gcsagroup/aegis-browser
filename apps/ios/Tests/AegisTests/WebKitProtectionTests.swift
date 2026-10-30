import AegisPolicyKit
import CryptoKit
import WebKit
import XCTest
@testable import BrowserKit

@MainActor
final class WebKitProtectionTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var tabs: [BrowserTab] = []
    override func setUp() async throws {
        suite = "webkit-protection-\(UUID().uuidString)"; defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() async throws {
        tabs.forEach { $0.stop() }; tabs = []
        defaults.removePersistentDomain(forName: suite)
    }
    private func tab(strict: Bool = false, hardened: Bool = false, isPrivate: Bool = false) throws -> BrowserTab {
        let prefs = BrowserPreferences(defaults: defaults)
        var values = prefs.values; values.strictFingerprinting = strict; values.hardenedSecurity = hardened
        try prefs.save(values)
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let tab = BrowserTab(profile: isPrivate ? .privateMode : .standard, configuration: config,
            preferences: prefs, securityRuleStore: SecurityRuleStore(fixtureRules: true))
        tabs.append(tab); return tab
    }
    private func wait(_ condition: () -> Bool, seconds: Double = 20) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "未等到预期的真实 WebKit 状态")
    }
    private func load(_ tab: BrowserTab, _ path: String) async throws {
        tab.load(URL(string: "http://127.0.0.1:8768" + path)!)
        try await wait { !tab.isLoading && (tab.url?.path == path.components(separatedBy: "?")[0] || tab.protectionIncident != nil) }
        XCTAssertNil(tab.loadingError)
    }
    private func js(_ tab: BrowserTab, _ script: String) async throws -> Any? {
        try await tab.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }
    private func counts(_ marker: String) async throws -> [String: Int] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8768/test-request-counts?case=" + marker)!)
        return try JSONDecoder().decode([String: Int].self, from: data)
    }

    func testRegisteredDomainsIncludePrivateWildcardExceptionAndIDNA() {
        XCTAssertEqual(RegisteredDomain.of("login.example.co.uk"), "example.co.uk")
        XCTAssertEqual(RegisteredDomain.of("a.user.github.io"), "user.github.io")
        XCTAssertEqual(RegisteredDomain.of("a.b.ck"), "a.b.ck")
        XCTAssertEqual(RegisteredDomain.of("www.ck"), "www.ck")
        XCTAssertEqual(RegisteredDomain.of("a.city.kawasaki.jp"), "city.kawasaki.jp")
        XCTAssertEqual(RegisteredDomain.of("www.食狮.com.cn"), "xn--85x722f.com.cn")
        XCTAssertNil(RegisteredDomain.of("co.uk"))
        XCTAssertFalse(PhishingScorer.scoreURL("https://apple.co.uk/").reasons.contains { $0.code == "brand_spoof_host" })
    }

    func testWeakURLSignalsWarnWithoutBlockingLocalOrInternationalLogin() {
        for raw in ["http://127.0.0.1/login", "http://192.168.1.1/login", "http://xn--85x722f.xyz/login"] {
            let result = BrowserNavigationPolicy.evaluate(URL(string: raw)!)
            XCTAssertNotEqual(result.kind, .blocked, raw)
            XCTAssertGreaterThanOrEqual(result.phishingScore, 55)
        }
        XCTAssertEqual(BrowserNavigationPolicy.evaluate(URL(string: "http://paypal.example.top/login")!).kind, .blocked)
    }

    func testSignedSnapshotRejectsDamageExpiryRollbackWrongKeyAndOversize() throws {
        let key = Curve25519.Signing.PrivateKey(), now = Date()
        let snapshot = SecurityRuleSnapshot(version: 2, created: now.timeIntervalSince1970 - 10,
            expires: now.timeIntervalSince1970 + 60, phishing: ["bad.example"], mining: [], fingerprinting: [])
        let data = try JSONEncoder().encode(snapshot), sig = try key.signature(for: data)
        XCTAssertEqual(try SecurityRuleSnapshot.verify(data, signature: sig, key: key.publicKey.rawRepresentation, minimumVersion: 1).version, 2)
        var damaged = data; damaged[0] ^= 1
        for invalid in [damaged, Data(repeating: 0, count: 8_000_001)] {
            XCTAssertThrowsError(try SecurityRuleSnapshot.verify(invalid, signature: sig, key: key.publicKey.rawRepresentation))
        }
        XCTAssertThrowsError(try SecurityRuleSnapshot.verify(data, signature: sig, key: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        XCTAssertThrowsError(try SecurityRuleSnapshot.verify(data, signature: sig, key: key.publicKey.rawRepresentation, minimumVersion: 2))
        XCTAssertThrowsError(try SecurityRuleSnapshot.verify(data, signature: sig, key: key.publicKey.rawRepresentation, now: now.addingTimeInterval(61)))
        XCTAssertEqual(LocalThreatDatabase.version, 2026101201)
        XCTAssertEqual(LocalThreatDatabase.snapshot?.phishing.count, 190191)
    }

    func testKnownPhishingHostBlocksExactHostBeforeWebViewCreation() throws {
        let tab = try tab()
        let host = try XCTUnwrap(LocalThreatDatabase.snapshot?.phishing.first)
        tab.load(URL(string: "https://" + host + "/")!)
        XCTAssertEqual(tab.protectionIncident?.reasons, ["known_phishing_host"])
        XCTAssertFalse(tab.isResident)
        XCTAssertFalse(LocalThreatDatabase.contains(URL(string: "https://" + host + ".safe.example/")!))
        XCTAssertFalse(LocalThreatDatabase.contains(URL(string: "https://example.com/?next=" + host)!))
    }

    func testLegitimateSameSiteAndFederatedLoginRemainAvailable() throws {
        func assessment(_ page: String, _ action: String) throws -> PhishAssessment {
            let url = URL(string: page)!
            return try XCTUnwrap(PageProtection.assessment(["url":page, "title":"Sign in with Microsoft", "passwords":1, "forms":1, "actions":[action]], url: url))
        }
        XCTAssertFalse(PageProtection.shouldUnload(try assessment("https://login.example.co.uk/", "https://auth.example.co.uk")))
        XCTAssertFalse(PageProtection.shouldUnload(try assessment("https://login.example.com/", "https://login.microsoftonline.com")))
        XCTAssertFalse(PhishingScorer.scoreURL("https://食狮.com.cn/").shouldBlock)
        XCTAssertNil(PageProtection.assessment(["url":"https://old.example/", "passwords":32, "forms":1, "actions":[], "title":""], url: URL(string:"https://new.example/")!))
    }

    func testResourcesAreBlockedWithAdsOffAndTemporaryRecoveryActuallyRequestsThem() async throws {
        let original = TrackingProtection.enabled; TrackingProtection.enabled = false
        defer { TrackingProtection.enabled = original }
        let tab = try tab(), marker = "SECURITY_" + UUID().uuidString
        try await load(tab, "/security/resources?case=" + marker)
        XCTAssertTrue(tab.securityRulesReady); XCTAssertFalse(tab.trackingProtectionReady)
        try await Task.sleep(for: .milliseconds(500))
        let blocked = try await counts(marker)
        XCTAssertEqual(blocked["mining", default:0], 0); XCTAssertEqual(blocked["fingerprinting", default:0], 0)
        tab.temporarilyRestoreSecurityResources()
        try await wait { !tab.isLoading }
        try await Task.sleep(for: .milliseconds(500))
        let allowed = try await counts(marker)
        XCTAssertEqual(allowed["mining"], 3); XCTAssertEqual(allowed["fingerprinting"], 2)
        XCTAssertTrue(tab.securityResourcesTemporarilyAllowed)
        tab.expireTemporaryPermissions(now: Date().addingTimeInterval(601))
        XCTAssertFalse(tab.securityResourcesTemporarilyAllowed)
        tab.reload()
        try await wait { !tab.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        let restored = try await counts(marker)
        XCTAssertEqual(restored, allowed)
    }

    func testDynamicCredentialPageUnloadsAndExceptionStaysInOnePrivateTab() async throws {
        let tab = try tab(isPrivate: true)
        try await load(tab, "/security/dynamic")
        try await wait { tab.protectionIncident?.fromPage == true }
        XCTAssertFalse(tab.isResident); XCTAssertFalse(tab.webView.configuration.websiteDataStore.isPersistent)
        tab.continueProtectedPageOnce()
        try await wait { !tab.isLoading && tab.url?.path == "/security/dynamic" }
        try await Task.sleep(for: .seconds(3))
        XCTAssertNil(tab.protectionIncident)
        let other = try self.tab(isPrivate: true)
        try await load(other, "/security/dynamic")
        try await wait { other.protectionIncident != nil }
        try await load(tab, "/article")
        try await load(tab, "/security/dynamic")
        try await wait { tab.protectionIncident != nil }
        XCTAssertNil(defaults.object(forKey: "protection.exceptions"))
    }

    func testSafePageAndNewNavigationIgnoreOldStructure() async throws {
        let tab = try tab()
        try await load(tab, "/security/safe")
        try await Task.sleep(for: .milliseconds(300)); XCTAssertNil(tab.protectionIncident)
        try await load(tab, "/security/dynamic")
        try await load(tab, "/article")
        try await Task.sleep(for: .seconds(3))
        XCTAssertNil(tab.protectionIncident); XCTAssertEqual(tab.url?.path, "/article")
    }

    func testPageLinkNavigationClearsPreviousProtectionNotices() async throws {
        let tab = try tab()
        try await load(tab, "/security/safe")
        try await wait { tab.protectionNotice != nil }
        _ = try await js(tab, "setTimeout(() => location.href='/article', 100); return true;")
        try await wait { tab.url?.path == "/article" && !tab.isLoading }
        XCTAssertNil(tab.protectionNotice)
        try await load(tab, "/security/canvas")
        try await wait { !tab.fingerprintSignals.isEmpty }
        _ = try await js(tab, "setTimeout(() => location.href='/article', 100); return true;")
        try await wait { tab.url?.path == "/article" && !tab.isLoading }
        XCTAssertTrue(tab.fingerprintSignals.isEmpty)
        XCTAssertNil(tab.protectionNotice)
    }

    func testSameDocumentPathChangeStillChecksDynamicCredentialForms() async throws {
        let tab = try tab()
        try await load(tab, "/article")
        _ = try await js(tab, """
        history.pushState({}, '', '/security/spa-login');
        document.title = 'PayPal verify urgent';
        const form = document.createElement('form'); form.action='https://collector.example/';
        const password = document.createElement('input'); password.type='password';
        form.append(password); document.body.append(form); return true;
        """)
        try await wait { tab.protectionIncident?.fromPage == true }
        XCTAssertEqual(tab.protectionIncident?.url.path, "/security/spa-login")
        XCTAssertFalse(tab.isResident)
    }

    func testRedirectGetsNavigationProtection() async throws {
        let tab = try tab()
        tab.load(URL(string:"http://127.0.0.1:8768/security/redirect")!)
        try await wait { tab.protectionIncident != nil }
        XCTAssertEqual(tab.protectionIncident?.url.host, "paypal.example.top")
        XCTAssertFalse(tab.isResident)
    }

    func testStrictFingerprintLimitsReadsButKeepsDrawingAndSiteRecovery() async throws {
        let tab = try tab(strict: true)
        try await load(tab, "/security/canvas")
        let result1 = try await js(tab, "return drawingWorked;") as? Bool
        XCTAssertEqual(result1, true)
        let result2 = try await js(tab, "return canvasReadable;") as? Bool
        XCTAssertEqual(result2, false)
        let result3 = try await js(tab, "return audioReadable;") as? Bool
        XCTAssertEqual(result3, false)
        let result4 = try await js(tab, "return canvasError;") as? String
        XCTAssertEqual(result4, "SecurityError")
        var site = SitePreferences(); site.strictFingerprinting = false
        try tab.preferences.setSite(site, for: URL(string:"http://127.0.0.1:8768/")!)
        try await load(tab, "/security/canvas")
        let result5 = try await js(tab, "return canvasReadable && audioReadable;") as? Bool
        XCTAssertEqual(result5, true)
        XCTAssertNil(tab.protectionIncident)
    }

    func testWorkerOffscreenBypassAndForgedSignalsNeverCauseAutomaticBlocking() async throws {
        let tab = try tab(strict: true)
        try await load(tab, "/security/canvas")
        let result = try await js(tab, """
        return await new Promise(resolve => {const w=new Worker('/security/worker');w.onmessage=e=>{w.terminate();resolve(e.data)};w.postMessage('read');});
        """) as? [String:Bool]
        XCTAssertEqual(result?["offscreen"], true)
        XCTAssertEqual(result?["readable"], true) // 记录真实边界，不将页面包装器宣称为 Worker 引擎保护。
        _ = try await js(tab, "Object.prototype.worker=100; Object.prototype.wasm=100; return true;")
        try await Task.sleep(for: .seconds(3))
        XCTAssertNil(tab.protectionIncident)
    }

    func testStrictProtectionAlsoWrapsCrossOriginFrameAPIs() async throws {
        let tab = try tab(strict: true)
        try await load(tab, "/article")
        let readable = try await js(tab, """
        return await new Promise(resolve => {
          const frame=document.createElement('iframe');
          const timer=setTimeout(()=>resolve('timeout'),5000);
          window.addEventListener('message',function receive(e){
            if(e.origin==='http://localhost:8768' && e.data.kind==='security-frame') {
              clearTimeout(timer);window.removeEventListener('message',receive);frame.remove();resolve(e.data.readable);
            }
          });frame.src='http://localhost:8768/security/canvas';document.body.append(frame);
        });
        """) as? Bool
        XCTAssertEqual(readable, false)
    }

    func testClosedTabDoesNotWaitForObservationWindowToRelease() async throws {
        var current: BrowserTab? = try tab()
        try await load(current!, "/security/safe")
        weak let released = current
        current?.stop(); tabs.removeAll(); current = nil
        try await wait { released == nil }
    }

    func testPopupInheritsRequestedHardening() async throws {
        let prefs = BrowserPreferences(defaults: defaults)
        var values = prefs.values; values.hardenedSecurity = true; values.allowPopups = true
        try prefs.save(values)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), workspaceStore: WorkspaceStore(), preferences: prefs)
        let parent = try XCTUnwrap(browser.activeTab)
        try await load(parent, "/article")
        _ = try await js(parent, "window.open('/security/safe','_blank'); return true;")
        try await wait { browser.standardTabs.count == 2 }
        let child = try XCTUnwrap(browser.activeTab)
        XCTAssertNotEqual(parent.id, child.id); XCTAssertTrue(child.inheritedHardenedSecurity)
        try await wait { !child.isLoading }
        XCTAssertEqual(child.url?.path, "/security/safe")
        parent.stop(); child.stop()
    }

    func testInternalFixtureStillLoadsWithProtection() async throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), workspaceStore: WorkspaceStore(), preferences: BrowserPreferences(defaults: defaults))
        let tab = try XCTUnwrap(browser.activeTab)
        tab.load(URL(string: "aegis://injection")!)
        try await wait { !tab.isLoading }
        let heading = try await js(tab, "return document.querySelector('h1')?.textContent || document.body.innerText;") as? String
        XCTAssertEqual(heading, "页面提示注入已隔离", "实际网址：\(tab.url?.absoluteString ?? "nil")")
        tab.stop()
    }

    func testSystemPreferencesPreserveLockdownAndHardenedPageLoads() async throws {
        let prefs = WKWebpagePreferences(); prefs.isLockdownModeEnabled = true
        PageProtection.applySystem(prefs, hardened: false)
        XCTAssertTrue(prefs.isLockdownModeEnabled)
        XCTAssertEqual(prefs.preferredHTTPSNavigationPolicy, .userMediatedFallbackToHTTP)
        let tab = try tab(hardened: true)
        XCTAssertTrue(tab.webView.configuration.preferences.isFraudulentWebsiteWarningEnabled)
        XCTAssertTrue(tab.webView.configuration.upgradeKnownHostsToHTTPS)
        if #available(iOS 26.5, *) { XCTAssertEqual(tab.webView.configuration.defaultWebpagePreferences.securityRestrictionMode, .maximizeCompatibility) }
        try await load(tab, "/article")
        XCTAssertNil(tab.protectionIncident)
        let result6 = try await js(tab,"return document.querySelector('h1').textContent;") as? String
        XCTAssertEqual(result6, "城市绿地观察")
    }

    func testSystemRestrictionModeFollowsPagePreferenceAndPreservesLockdown() throws {
        guard #available(iOS 26.5, *) else {
            throw XCTSkip("Security restriction mode requires iOS 26.5")
        }
        let preferences = WKWebpagePreferences()
        PageProtection.applySystem(preferences, hardened: true)
        XCTAssertEqual(preferences.securityRestrictionMode, .maximizeCompatibility)
        PageProtection.applySystem(preferences, hardened: false)
        XCTAssertEqual(preferences.securityRestrictionMode, .none)
        preferences.securityRestrictionMode = .lockdown
        PageProtection.applySystem(preferences, hardened: false)
        XCTAssertEqual(preferences.securityRestrictionMode, .lockdown)
    }
}
