import XCTest
import WebKit
@testable import BrowserKit

@MainActor
final class WorkspaceAndDownloadTests: XCTestCase {
    func testWebsiteDataClearRemovesCookiesAndPreservesBookmarks() async throws {
        let store = BrowserDataStore(persistenceURL: nil)
        _ = store.toggleBookmark(title: "保留收藏", url: URL(string: "https://example.com")!, isPrivate: false)
        let browser = BrowserSession(dataStore: store)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "aegis-test.example", .path: "/", .name: "session-test", .value: "synthetic"]))
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
        await browser.clearWebsiteData()
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        XCTAssertFalse(cookies.contains { $0.name == "session-test" })
        XCTAssertEqual(store.bookmarks.count, 1)
        XCTAssertTrue(browser.workspaceStore.sessionURLs.isEmpty)
    }

    func testLivePageSnapshotOmitsHiddenAndFormText() async throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        let tab = try XCTUnwrap(browser.activeTab)
        tab.load(URL(string: "http://127.0.0.1:8768/article")!)
        try await waitUntil { tab.url?.path == "/article" && !tab.isLoading }
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('main').insertAdjacentHTML('beforeend', '<p style=display:none>HIDDEN_SENTINEL</p><input value=FORM_SENTINEL>')")
        let snapshot = try await tab.snapshot()
        XCTAssertTrue(snapshot.text.contains("12 公顷"))
        XCTAssertFalse(snapshot.text.contains("HIDDEN_SENTINEL"))
        XCTAssertFalse(snapshot.text.contains("FORM_SENTINEL"))
        tab.stop()
    }

    func testBookmarkLinkCheckUsesActualHTTPStatus() async throws {
        let good = await BookmarkLinkChecker.check(id: UUID(), title: "有效", url: URL(string: "http://127.0.0.1:8768/article")!)
        let missing = await BookmarkLinkChecker.check(id: UUID(), title: "失效", url: URL(string: "http://127.0.0.1:8768/missing")!)
        XCTAssertEqual(good.status, .reachable)
        XCTAssertEqual(missing.status, .missing)
    }

    func testHTTPDownloadPauseResumeHashMismatchAndCancel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = DownloadManager(directory: directory, background: false)
        let id = try manager.start("http://127.0.0.1:8768/slow.bin")
        try await waitUntil { manager.items.first { $0.id == id }!.received > 0 }
        manager.pause(id)
        try await waitUntil { manager.items.first { $0.id == id }!.state == .paused }
        try manager.resume(id)
        try await waitUntil { manager.items.first { $0.id == id }!.state == .completed }
        let file = try XCTUnwrap(manager.items.first { $0.id == id })
        XCTAssertEqual(try DownloadManager.hashFile(manager.fileURL(file)), file.sha256)
        let bad = try manager.start("http://127.0.0.1:8768/download.bin", expectedSHA256: String(repeating: "0", count: 64))
        try await waitUntil { manager.items.first { $0.id == bad }!.state == .failed }
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.fileURL(manager.items.first { $0.id == bad }!).path))
        let cancelled = try manager.start("http://127.0.0.1:8768/slow.bin")
        manager.cancel(cancelled)
        XCTAssertEqual(manager.items.first { $0.id == cancelled }?.state, .cancelled)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(predicate(), "真实 HTTP 操作未在 20 秒内达到预期状态")
    }

    func testSharedTrackingRulesCompileInWebKit() async throws {
        let rules = try await TrackingProtection.shared.ruleList()
        XCTAssertTrue(rules.identifier.hasPrefix("aegis-trackers-"))
    }
    func testWorkspaceRoundTripStripsSensitiveParametersAndPreservesSearch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspaces.json")
        let store = WorkspaceStore(persistenceURL: url)
        let saved = try store.save(name: "研究", urls: [URL(string: "https://example.com/search?q=swift&utm_source=feed&token=secret#details")!])
        XCTAssertEqual(saved.urls[0].absoluteString, "https://example.com/search?q=swift")
        try store.saveSession(urls: saved.urls)
        let restarted = WorkspaceStore(persistenceURL: url)
        XCTAssertEqual(restarted.workspaces, [saved])
        XCTAssertEqual(restarted.sessionURLs, saved.urls)
        XCTAssertThrowsError(try store.save(name: "无效", urls: [URL(string: "file:///private/data")!]))
    }

    func testWorkspaceRenameExportPreviewImportAndRemove() throws {
        let original = WorkspaceStore()
        let saved = try original.save(name: "原名", urls: [URL(string: "https://example.com/article?token=secret")!])
        try original.rename(saved.id, to: "新名称")
        let preview = try WorkspaceStore.previewImport(original.exportData())
        XCTAssertEqual(preview.first?.name, "新名称")
        XCTAssertEqual(preview.first?.urls.first?.absoluteString, "https://example.com/article")
        let destination = WorkspaceStore()
        try destination.importWorkspaces(preview)
        XCTAssertNotEqual(destination.workspaces.first?.id, saved.id)
        try destination.remove(destination.workspaces[0].id)
        XCTAssertTrue(destination.workspaces.isEmpty)
        XCTAssertThrowsError(try WorkspaceStore.previewImport(Data("[]".utf8)))
    }

    func testPrivateWorkspaceIsRejectedAndRestorePreservesExistingTabs() throws {
        let workspaces = WorkspaceStore()
        let saved = try workspaces.save(name: "测试", urls: [URL(string: "https://example.com")!])
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), workspaceStore: workspaces)
        let first = browser.standardTabs[0].id
        let opened = browser.restoreWorkspace(saved)
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(browser.standardTabs.contains { $0.id == first })
        browser.switchProfile(to: .privateMode)
        XCTAssertThrowsError(try browser.saveWorkspace(name: "私密"))
        XCTAssertTrue(browser.restoreWorkspace(saved).isEmpty)
    }

    func testDownloadValidationRejectsDangerousTargetsAndNormalizesFilename() throws {
        for input in ["file:///etc/passwd", "javascript:alert(1)", "https://user:pass@example.com/a", "http://paypal.example.top/login/paypal"] {
            XCTAssertThrowsError(try DownloadManager.validatedURL(input))
        }
        XCTAssertEqual(try DownloadManager.validatedURL("https://example.com/a?utm_source=x").absoluteString, "https://example.com/a")
        XCTAssertEqual(DownloadManager.safeFilename("../../report.txt"), "report.txt")
        XCTAssertEqual(DownloadManager.safeFilename(".."), "download.bin")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data("abc".utf8).write(to: temporary)
        XCTAssertEqual(try DownloadManager.hashFile(temporary), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
