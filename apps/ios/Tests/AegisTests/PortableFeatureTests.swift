import XCTest
import CryptoKit
import PDFKit
import UIKit
import WebKit
@testable import BrowserKit
@testable import AgentKit

@MainActor
final class PortableFeatureTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = "portable-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
    private func session(_ preferences: BrowserPreferences? = nil) -> BrowserSession {
        BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil),
            workspaceStore: WorkspaceStore(persistenceURL: folder.appendingPathComponent("workspaces.json")),
            preferences: preferences ?? BrowserPreferences(defaults: defaults))
    }
    private func loaded(_ browser: BrowserSession, path: String = "/article") async throws -> BrowserTab {
        let tab = try XCTUnwrap(browser.activeTab)
        tab.load(URL(string: "http://127.0.0.1:8768\(path)")!)
        try await waitUntil { tab.url?.path == path && !tab.isLoading }
        return tab
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(predicate(), "真实浏览器操作未在限定时间内完成")
    }

    func testSearchEncodingAndTemplateValidation() throws {
        let prefs = BrowserPreferences(defaults: defaults)
        var values = prefs.values
        values.searchEngine = .custom
        values.customSearch = "https://example.com/find?lang=zh&q=prefix{searchTerms}"
        try prefs.save(values)
        let query = "中文 & x=1+#/?"
        let url = try XCTUnwrap(BrowserPreferences.searchURL(query, values: prefs.values))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value, "prefix" + query)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count, 2)
        for invalid in ["http://example.com/?q={searchTerms}", "https://{searchTerms}.com/", "https://example.com/{searchTerms}", "https://user:pass@example.com/?q={searchTerms}", "https://example.com/?q={searchTerms}&x={searchTerms}", "https://example.com/?{searchTerms}=q"] {
            values.customSearch = invalid
            XCTAssertThrowsError(try prefs.save(values), invalid)
        }
        XCTAssertEqual(BrowserPreferences(defaults: defaults).values, prefs.values)
    }

    func testSearchEngineRemovalPersistsAndRestoresWithoutLosingCustomTemplate() throws {
        let prefs = BrowserPreferences(defaults: defaults)
        var values = prefs.values
        values.customSearch = "https://example.com/?q={searchTerms}"
        values.removeSearchEngine(.bing)
        XCTAssertEqual(values.searchEngine, .duckDuckGo)
        values.removeSearchEngine(.duckDuckGo)
        XCTAssertEqual(values.searchEngine, .google)
        try prefs.save(values)
        let reopened = BrowserPreferences(defaults: defaults)
        XCTAssertEqual(reopened.values.availableSearchEngines, [.google, .baidu, .custom])
        XCTAssertEqual(BrowserPreferences.searchURL("test", values: reopened.values)?.host, "www.google.com")
        for engine in values.availableSearchEngines { values.removeSearchEngine(engine) }
        try prefs.save(values)
        let empty = BrowserPreferences(defaults: defaults)
        XCTAssertNil(empty.error)
        XCTAssertNil(empty.values.searchEngine)
        XCTAssertTrue(empty.values.availableSearchEngines.isEmpty)
        XCTAssertNil(BrowserPreferences.searchURL("private search", values: empty.values))
        XCTAssertNil(BrowserSession.normalizedURL(from: "private search", preferences: empty.values))
        XCTAssertEqual(BrowserSession.normalizedURL(from: "example.com", preferences: empty.values)?.absoluteString, "https://example.com")
        XCTAssertEqual(BrowserSession.normalizedURL(from: "http://127.0.0.1:8768/article", preferences: empty.values)?.path, "/article")
        values.restoreSearchEngines(); try prefs.save(values)
        XCTAssertEqual(BrowserPreferences(defaults: defaults).values.availableSearchEngines, SearchEngine.allCases)
        XCTAssertEqual(prefs.values.searchEngine, .duckDuckGo)
        XCTAssertEqual(prefs.values.customSearch, "https://example.com/?q={searchTerms}")
    }

    func testLegacySearchSettingsMigrateAndRemovedSelectionCannotBeUsed() throws {
        var values = BrowserPreferenceValues(); values.searchEngine = .bing
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(values)) as? [String: Any])
        legacy.removeValue(forKey: "removedSearchEngines")
        let data = try JSONSerialization.data(withJSONObject: legacy)
        defaults.set(data, forKey: "browser.preferences.v1")
        let prefs = BrowserPreferences(defaults: defaults)
        XCTAssertNil(prefs.error)
        XCTAssertEqual(prefs.values.searchEngine, .bing)
        XCTAssertEqual(prefs.values.availableSearchEngines, SearchEngine.allCases)
        XCTAssertEqual(defaults.data(forKey: "browser.preferences.v1"), data)
        values.removedSearchEngines = [.bing]
        XCTAssertNil(BrowserPreferences.searchURL("test", values: values))
        try prefs.save(values)
        XCTAssertEqual(prefs.values.searchEngine, .duckDuckGo)
    }

    func testNoSearchEngineShowsExplanationWithoutNavigating() {
        let prefs = BrowserPreferences(defaults: defaults)
        var values = prefs.values
        for engine in SearchEngine.allCases { values.removeSearchEngine(engine) }
        XCTAssertNoThrow(try prefs.save(values))
        let browser = session(prefs)
        let before = browser.activeTab?.requestedURL
        browser.navigate(address: "do not send this search")
        XCTAssertEqual(browser.activeTab?.requestedURL, before)
        XCTAssertEqual(browser.sessionError, String(localized: "尚未启用搜索引擎，请输入网址，或在浏览设置中恢复搜索引擎。"))
    }

    func testSiteOriginsAndPreferenceClamping() throws {
        let prefs = BrowserPreferences(defaults: defaults)
        var rule = SitePreferences(); rule.camera = .deny; rule.javaScript = false; rule.zoom = 9
        try prefs.setSite(rule, for: URL(string: "https://EXAMPLE.com:443/a")!)
        XCTAssertEqual(prefs.site(for: URL(string: "https://example.com/b")!).zoom, 2)
        XCTAssertEqual(prefs.site(for: URL(string: "https://example.com/b")!).camera, .deny)
        XCTAssertEqual(prefs.site(for: URL(string: "http://example.com")!).camera, .ask)
        XCTAssertEqual(prefs.site(for: URL(string: "https://example.com:8443")!).camera, .ask)
        XCTAssertThrowsError(try prefs.setSite(rule, for: URL(string: "file:///tmp/local")!))
        try prefs.setSite(nil, for: URL(string: "https://example.com")!)
        XCTAssertTrue(prefs.values.sites.isEmpty)
    }

    func testCorruptPreferencesRemainUntouchedUntilExplicitSave() throws {
        let damaged = Data("unreadable".utf8)
        defaults.set(damaged, forKey: "browser.preferences.v1")
        let prefs = BrowserPreferences(defaults: defaults)
        XCTAssertNotNil(prefs.error)
        XCTAssertEqual(defaults.data(forKey: "browser.preferences.v1"), damaged)
        try prefs.save(prefs.values)
        XCTAssertNil(BrowserPreferences(defaults: defaults).error)
    }

    func testFilterUpdatesThrottleFailuresAndRecentSuccess() throws {
        let prefs = BrowserPreferences(defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertFalse(prefs.claimFilterUpdate(lastSuccess: nil, now: now))
        var values = prefs.values; values.automaticFilterUpdates = true; try prefs.save(values)
        XCTAssertTrue(prefs.claimFilterUpdate(lastSuccess: nil, now: now))
        XCTAssertFalse(prefs.claimFilterUpdate(lastSuccess: nil, now: now.addingTimeInterval(3599)))
        XCTAssertFalse(prefs.claimFilterUpdate(lastSuccess: now, now: now.addingTimeInterval(3601)))
        XCTAssertTrue(prefs.claimFilterUpdate(lastSuccess: now, now: now.addingTimeInterval(86_400)))
    }

    func testProtectionOptionsKeepCredentialAndSchemeBlocks() {
        for input in ["https://user:pass@example.com/", "javascript:alert(1)", "file:///tmp/private"] {
            XCTAssertEqual(BrowserNavigationPolicy.evaluate(URL(string: input)!, sanitizeLinks: false, checkPhishing: false).kind, .blocked)
        }
        let url = URL(string: "https://example.com/?utm_source=test&q=a")!
        XCTAssertEqual(BrowserNavigationPolicy.evaluate(url).kind, .sanitized)
        XCTAssertEqual(BrowserNavigationPolicy.evaluate(url, sanitizeLinks: false).effectiveURL, url.absoluteString)
    }

    func testHomeStartupZoomAndHistorySettingInRealWebKit() async throws {
        let prefs = BrowserPreferences(defaults: defaults)
        var values = prefs.values; values.startup = .homePage
        values.homepage = "http://127.0.0.1:8768/article"; values.zoom = 1.5; values.saveHistory = false
        values.newTabsUseHomepage = true; try prefs.save(values)
        let browser = session(prefs)
        let tab = try XCTUnwrap(browser.activeTab)
        try await waitUntil { tab.url?.path == "/article" && !tab.isLoading }
        XCTAssertEqual(tab.webView.pageZoom, 1.5)
        XCTAssertTrue(browser.dataStore.history.isEmpty)
        var site = SitePreferences(); site.zoom = 0.75
        try prefs.setSite(site, for: tab.url!)
        try await waitUntil { tab.webView.pageZoom == 0.75 }
        let next = browser.newTab()
        try await waitUntil { next.url?.path == "/article" && !next.isLoading }
        XCTAssertEqual(next.webView.pageZoom, 0.75)
        browser.visibleTabs.forEach { $0.stop() }
    }

    func testJavaScriptGlobalAndSiteRulesInRealWebKit() async throws {
        let prefs = BrowserPreferences(defaults: defaults)
        var values = prefs.values; values.javaScript = false; try prefs.save(values)
        let browser = session(prefs)
        let tab = try await loaded(browser, path: "/preferences")
        try await waitUntil { tab.title == "JavaScript disabled" }
        XCTAssertEqual(tab.webView.title, "JavaScript disabled")
        var site = SitePreferences(); site.javaScript = true
        try prefs.setSite(site, for: tab.url!)
        tab.reload(); try await waitUntil { !tab.isLoading && tab.title == "JavaScript enabled" }
        site.javaScript = false; try prefs.setSite(site, for: tab.url!)
        tab.reload(); try await waitUntil { !tab.isLoading && tab.title == "JavaScript disabled" }
        _ = try await tab.webView.callAsyncJavaScript("document.title = 'Updated title'", arguments: [:], in: nil, contentWorld: .defaultClient)
        try await waitUntil { tab.title == "Updated title" }
        tab.stop()
    }

    func testForegroundWatchDetectsRealReload() async throws {
        let browser = session(), watch = ForegroundPageWatch()
        let tab = try await loaded(browser, path: "/watch")
        watch.start(tab: tab, interval: 60)
        let deadline = Date().addingTimeInterval(70)
        while watch.checks < 2 && watch.error == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(watch.checks, 2)
        XCTAssertTrue(watch.changed)
        XCTAssertNil(watch.error)
        watch.stop(); tab.stop()
    }

    func testWebsiteDataClearAcrossWindowsPreservesPrivateTabs() async throws {
        let one = session(), two = session()
        _ = try await loaded(one)
        let normal = try await loaded(two)
        two.switchProfile(to: .privateMode)
        let privateTab = try await loaded(two)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "portable.example", .path: "/", .name: "portable", .value: "test"]))
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
        await one.clearWebsiteData()
        XCTAssertFalse(one.standardTabs.contains { $0.url?.path == "/article" })
        XCTAssertFalse(two.standardTabs.contains { $0.id == normal.id })
        XCTAssertEqual(two.privateTabs.first?.id, privateTab.id)
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        XCTAssertFalse(cookies.contains { $0.name == "portable" })
        privateTab.stop()
    }

    func testReadingLibraryEncryptionSearchArchiveAndRestart() throws {
        let file = folder.appendingPathComponent("library.aes"), key = SymmetricKey(size: .bits256)
        let library = ReadingLibrary(url: file, key: key)
        var record = ReadingRecord(title: "城市研究", sourceURL: URL(string: "https://example.com/article"), text: "这里是需要保存的原文 SENTINEL。")
        record.quote = "原文"; record.note = "本地批注"; record.translation = "Translated text"
        try library.save(record)
        XCTAssertNil(try Data(contentsOf: file).range(of: Data("SENTINEL".utf8)))
        let restored = ReadingLibrary(url: file, key: key)
        XCTAssertNil(restored.storageError)
        XCTAssertEqual(restored.search("本地批注").first?.id, record.id)
        XCTAssertEqual(restored.search("Translated").count, 1)
        try restored.setArchived(true, id: record.id)
        XCTAssertTrue(restored.search("").isEmpty)
        XCTAssertEqual(restored.search("", archived: true).count, 1)
        try restored.setArchived(false, id: record.id)
        XCTAssertEqual(ReadingLibrary(url: file, key: key).search("").count, 1)
        let beforeRemove = restored.records.first!
        XCTAssertThrowsError(try restored.remove(id: beforeRemove.id, replacing: .distantPast))
        try restored.remove(id: beforeRemove.id, replacing: beforeRemove.updatedAt)
        XCTAssertTrue(ReadingLibrary(url: file, key: key).records.isEmpty)
    }

    func testReadingRejectsWrongKeyCorruptionAndConcurrentOverwrite() throws {
        let file = folder.appendingPathComponent("library.aes"), key = SymmetricKey(size: .bits256)
        let library = ReadingLibrary(url: file, key: key)
        let stale = ReadingLibrary(url: file, key: key)
        let record = ReadingRecord(title: "记录", sourceURL: URL(string: "https://example.com"), text: "原文")
        try library.save(record)
        let original = try Data(contentsOf: file)
        XCTAssertThrowsError(try stale.save(record))
        let wrong = ReadingLibrary(url: file, key: SymmetricKey(size: .bits256))
        XCTAssertNotNil(wrong.storageError)
        XCTAssertThrowsError(try wrong.save(record))
        XCTAssertEqual(try Data(contentsOf: file), original)
        try Data("damaged".utf8).write(to: file)
        library.reload()
        XCTAssertNotNil(library.storageError)
        XCTAssertThrowsError(try library.save(record))
        XCTAssertEqual(try Data(contentsOf: file), Data("damaged".utf8))
    }

    func testReadingProtectsSourceQuotesAndStaleEditors() throws {
        let library = ReadingLibrary(url: folder.appendingPathComponent("library.aes"), key: SymmetricKey(size: .bits256))
        var record = ReadingRecord(title: "记录", sourceURL: URL(string: "https://example.com"), text: "原文")
        record.quote = "不是原文的一部分"
        XCTAssertThrowsError(try library.save(record))
        record.quote = "原文"; try library.save(record)
        let saved = try XCTUnwrap(library.records.first)
        var edited = saved; edited.note = "新批注"
        try library.save(edited, replacing: saved.updatedAt)
        XCTAssertThrowsError(try library.save(saved, replacing: saved.updatedAt))
        let changedSource = ReadingRecord(id: saved.id, title: saved.title, sourceURL: URL(string: "https://other.example"), text: saved.text)
        XCTAssertThrowsError(try library.save(changedSource, replacing: library.records.first!.updatedAt))
    }

    func testPDFTextPageAndUnavailablePage() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        let data = renderer.pdfData { context in
            context.beginPage(); ("Page one evidence" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            context.beginPage()
        }
        let record = try ReadingLibrary.pdfRecord(data: data, name: "证据.pdf", page: 1)
        XCTAssertEqual(record.pdfPage, 1)
        XCTAssertTrue(record.text.contains("Page one evidence"))
        XCTAssertThrowsError(try ReadingLibrary.pdfRecord(data: data, name: "证据.pdf", page: 2))
        XCTAssertThrowsError(try ReadingLibrary.pdfRecord(data: data, name: "证据.pdf", page: 3))
        XCTAssertThrowsError(try ReadingLibrary.pdfRecord(data: Data("bad".utf8), name: "坏文件.pdf", page: 1))
    }

    func testTranslationRejectsToolsBlankAndOversizedInput() throws {
        XCTAssertEqual(try ReadingTranslation.decode("{\"translation\":\"译文\"}"), "译文")
        for text in ["{\"translation\":\"\"}", "{\"translation\":\"ok\",\"tool\":\"run\"}", "```json\n{\"translation\":\"ok\"}\n```", "{\"translation\":12}"] {
            XCTAssertThrowsError(try ReadingTranslation.decode(text))
        }
        XCTAssertThrowsError(try ReadingTranslation.preparedText(String(repeating: "a", count: 24_001)))
        XCTAssertThrowsError(try ReadingTranslation.preparedText("password=my-secret-password"))
    }

    func testStrictModelPlanRejectsScriptAndNewURLs() throws {
        XCTAssertEqual(try BrowserPlanDecoder.decode("{\"steps\":[{\"kind\":\"groupTabs\",\"name\":\"研究\"}]}").first?.kind, .groupTabs)
        for text in ["{\"steps\":[{\"kind\":\"eval\"}]}", "{\"steps\":[{\"kind\":\"openURLs\",\"urls\":[\"https://evil.example\"]}]}", "{\"steps\":[],\"script\":\"x\"}", "{\"steps\":[{\"kind\":\"closeTabs\",\"name\":1}]}"] {
            XCTAssertThrowsError(try BrowserPlanDecoder.decode(text))
        }
    }

    func testConfirmedGroupAndWorkspaceExecuteOnceWithReadback() async throws {
        let browser = session(), executor = BrowserOperationExecutor()
        let tab = try await loaded(browser)
        let plan = try BrowserOperationPlan(browser: browser, selected: [tab.id], urls: [], steps: [
            BrowserOperationStep(kind: .groupTabs, name: "研究分组"), BrowserOperationStep(kind: .saveWorkspace, name: "研究工作区")])
        do { try await executor.execute(plan, in: browser, confirmed: false); XCTFail("必须先确认") } catch { }
        XCTAssertTrue(browser.groups.isEmpty)
        try await executor.execute(plan, in: browser, confirmed: true)
        XCTAssertEqual(executor.completedSteps, 2)
        XCTAssertEqual(browser.groups.first?.name, "研究分组")
        XCTAssertEqual(browser.visibleTabs.count, 1)
        XCTAssertEqual(browser.visibleTabs.first?.groupID, browser.groups.first?.id)
        let restored = WorkspaceStore(persistenceURL: folder.appendingPathComponent("workspaces.json"))
        XCTAssertEqual(restored.workspaces.first?.urls, [tab.url!])
        do { try await executor.execute(plan, in: browser, confirmed: true); XCTFail("同一计划不能重放") } catch { }
        XCTAssertEqual(executor.completedSteps, 0, "被拒绝的新请求不能沿用上次的完成步数")
        tab.stop()
    }

    func testOperationRejectsCrossWindowModeNavigationAndExpiration() async throws {
        let browser = session(), executor = BrowserOperationExecutor()
        let tab = try await loaded(browser)
        let now = Date()
        let plan = try BrowserOperationPlan(browser: browser, selected: [tab.id], urls: [], steps: [BrowserOperationStep(kind: .closeTabs)], now: now)
        do { try await executor.execute(plan, in: session(), confirmed: true); XCTFail("不允许跨窗口") } catch { }
        do { try await executor.execute(plan, in: browser, confirmed: true, now: now.addingTimeInterval(301)); XCTFail("不允许过期") } catch { }
        browser.switchProfile(to: .privateMode)
        do { try await executor.execute(plan, in: browser, confirmed: true); XCTFail("不允许跨模式") } catch { }
        browser.switchProfile(to: .standard)
        tab.reload(); try await waitUntil { !tab.isLoading }
        do { try await executor.execute(plan, in: browser, confirmed: true); XCTFail("导航后需要重新确认") } catch { }
        XCTAssertEqual(browser.standardTabs.first?.id, tab.id)
        tab.stop()
    }

    func testPlanRejectsUnknownTabsAndInvalidStepOrder() throws {
        let browser = session(), id = browser.activeTabID!
        XCTAssertThrowsError(try BrowserOperationPlan(browser: browser, selected: [UUID()], urls: [], steps: [BrowserOperationStep(kind: .closeTabs)]))
        XCTAssertThrowsError(try BrowserOperationPlan(browser: browser, selected: [id], urls: [], steps: [.init(kind: .reloadTabs), .init(kind: .closeTabs)]))
        XCTAssertThrowsError(try BrowserOperationPlan(browser: browser, selected: [], urls: [URL(string: "javascript:alert(1)")!], steps: [.init(kind: .openURLs)]))
    }

    func testForegroundWatchReadsStopsAndRejectsSensitivePage() async throws {
        let browser = session(), watch = ForegroundPageWatch()
        let tab = try await loaded(browser)
        watch.start(tab: tab, interval: 60)
        try await waitUntil { watch.checks == 1 }
        XCTAssertTrue(watch.running)
        watch.stop()
        XCTAssertFalse(watch.running)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(watch.checks, 1)
        _ = try await loaded(browser, path: "/sensitive")
        watch.start(tab: tab, interval: 60)
        try await waitUntil { watch.error != nil }
        XCTAssertFalse(watch.running)
        watch.start(tab: tab, interval: 0.1)
        XCTAssertFalse(watch.running)
        tab.stop()
    }

    func testOversizedHTTPDownloadKeepsCapacityFailureReason() async throws {
        let manager = DownloadManager(directory: folder.appendingPathComponent("downloads"), background: false, defaults: defaults)
        await manager.retryStorage(); try await waitUntil { manager.isReady }
        var rules = DownloadTransferPreferences(); rules.maximumBytes = 100_000_000
        try manager.setTransferPreferences(rules)
        let id = try manager.start("http://127.0.0.1:8768/oversize.bin")
        try await waitUntil { manager.items.first { $0.id == id }?.state == .failed }
        let item = try XCTUnwrap(manager.items.first { $0.id == id })
        XCTAssertEqual(item.message, DownloadError.tooLarge.localizedDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.fileURL(item).path))
    }

    func testResumedDownloadKeepsOriginalNetworkAndSizePolicy() async throws {
        let manager = DownloadManager(directory: folder.appendingPathComponent("downloads"), background: false, defaults: defaults)
        await manager.retryStorage(); try await waitUntil { manager.isReady }
        var rules = DownloadTransferPreferences(); rules.maximumBytes = 500_000_000; rules.allowsCellular = false
        try manager.setTransferPreferences(rules)
        let id = try manager.start("http://127.0.0.1:8768/slow.bin")
        try await waitUntil { manager.items.first { $0.id == id }!.received > 0 }
        manager.pause(id); try await waitUntil { manager.items.first { $0.id == id }?.state == .paused }
        rules.maximumBytes = 100_000_000; rules.allowsCellular = true; try manager.setTransferPreferences(rules)
        try manager.resume(id)
        try await waitUntil { manager.items.first { $0.id == id }?.state == .completed }
        XCTAssertEqual(manager.items.first { $0.id == id }?.maximumBytes, 500_000_000)
        XCTAssertEqual(manager.items.first { $0.id == id }?.transferPreferences?.allowsCellular, false)
    }

    func testDownloadRulesCapturedPerTaskAndPersisted() async throws {
        let manager = DownloadManager(directory: folder.appendingPathComponent("downloads"), background: false, defaults: defaults)
        await manager.retryStorage(); try await waitUntil { manager.isReady }
        var rules = DownloadTransferPreferences(); rules.maximumBytes = 500_000_000
        rules.allowsCellular = false; rules.allowsExpensive = false; rules.allowsConstrained = false
        try manager.setTransferPreferences(rules)
        let request = rules.request(for: URL(string: "https://example.com/file")!)
        XCTAssertFalse(request.allowsCellularAccess); XCTAssertFalse(request.allowsExpensiveNetworkAccess); XCTAssertFalse(request.allowsConstrainedNetworkAccess)
        let id = try manager.start("http://127.0.0.1:8768/download.bin")
        rules.maximumBytes = 100_000_000; try manager.setTransferPreferences(rules)
        XCTAssertEqual(manager.items.first { $0.id == id }?.maximumBytes, 500_000_000)
        try await waitUntil { manager.items.first { $0.id == id }?.state == .completed }
        let item = try XCTUnwrap(manager.items.first { $0.id == id })
        XCTAssertEqual(try DownloadManager.hashFile(manager.fileURL(item)), item.sha256)
        let restored = DownloadManager(directory: folder.appendingPathComponent("downloads"), background: false, defaults: defaults)
        await restored.retryStorage(); try await waitUntil { restored.isReady }
        XCTAssertEqual(restored.transferPreferences.maximumBytes, 100_000_000)
        XCTAssertEqual(restored.items.first { $0.id == id }?.maximumBytes, 500_000_000)
        let tooLarge = DownloadPlan(urls: [URL(string: "http://127.0.0.1:8768/download.bin")!], size: 100_000_001)
        XCTAssertThrowsError(try manager.start(tooLarge))
    }
}
