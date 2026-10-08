import XCTest
import WebKit
import UIKit
@testable import BrowserKit

@MainActor final class TabLifecycleTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let limit = Date().addingTimeInterval(20)
        while !condition(), Date() < limit { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "页面状态等待超时")
    }

    func testRestore10And30And50TabsLoadsOnlySelectedPage() async throws {
        var measurements: [[String: Any]] = []
        for count in [10, 30, 50] {
            let store = BrowserWindowStore()
            let id = UUID()
            let tabs = (0..<count).map { index in
                SavedBrowserTab(id: UUID(), url: URL(string: "http://127.0.0.1:8768/article?tab=\(index)")!,
                                groupID: nil, title: "合成标签 \(index)")
            }
            try store.save(BrowserWindowSnapshot(id: id, tabs: tabs, activeTabID: tabs[0].id))
            let start = Date()
            let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), windowID: id, windowStore: store)
            try await waitUntil { browser.activeTab?.url?.path == "/article" && browser.activeTab?.isLoading == false }
            XCTAssertEqual(browser.residentTabCount, 1)
            XCTAssertEqual(browser.standardTabs.count, count)
            XCTAssertTrue(browser.standardTabs.dropFirst().allSatisfy(\.isSuspended))
            let restoreTime = Date().timeIntervalSince(start)
            let activation = Date()
            browser.activate(tabs[count - 1].id)
            try await waitUntil { browser.activeTab?.isLoading == false }
            XCTAssertEqual(browser.activeTab?.url, tabs[count - 1].url)
            browser.persistSession()
            XCTAssertEqual(store.snapshot(id)?.tabs.count, count)
            XCTAssertEqual(store.snapshot(id)?.tabs.map(\.url), tabs.map(\.url))
            measurements.append(["tabs": count, "residentAfterRestore": 1,
                                 "restoreSeconds": restoreTime, "activateSeconds": Date().timeIntervalSince(activation)])
            browser.standardTabs.forEach { $0.stop() }
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted]), uniformTypeIdentifier: "public.json")
        attachment.name = "标签恢复实测时间与驻留数量（模拟器）"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testIdlePageReleasesAndRestoresScrollWhileEditedPageStaysResident() async throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        let tab = try XCTUnwrap(browser.activeTab)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        let controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        tab.webView.frame = controller.view.bounds
        controller.view.addSubview(tab.webView)
        tab.load(URL(string: "http://127.0.0.1:8768/long-article")!)
        try await waitUntil { !tab.isLoading && tab.url?.path == "/long-article" && tab.webView.scrollView.contentSize.height > 1000 }
        _ = try await tab.webView.evaluateJavaScript("window.scrollTo(0, 600)")
        try await waitUntil { tab.scrollOffset > 100 }
        let scroll = tab.scrollOffset
        XCTAssertGreaterThan(scroll, 100)
        let releasedView = tab.webView
        _ = browser.newTab()
        releasedView.removeFromSuperview()
        _ = await browser.releaseInactiveTabs()
        XCTAssertTrue(tab.isSuspended)
        XCTAssertFalse(tab.isResident)
        tab.webViewWebContentProcessDidTerminate(releasedView)
        tab.webView(releasedView, didFinish: nil)
        XCTAssertFalse(tab.isResident, "迟到回调不能唤醒已休眠的页面")
        browser.activate(tab.id)
        tab.webView.frame = controller.view.bounds
        controller.view.addSubview(tab.webView)
        try await waitUntil { !tab.isLoading }
        XCTAssertEqual(tab.url?.path, "/long-article")
        try await waitUntil { abs(tab.webView.scrollView.contentOffset.y - scroll) < 10 }
        XCTAssertEqual(tab.scrollOffset, scroll, accuracy: 10)
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('input').dispatchEvent(new Event('input', {bubbles: true}))")
        _ = browser.newTab()
        _ = await browser.releaseInactiveTabs()
        XCTAssertTrue(tab.isResident, "编辑过表单的页面必须保留")
        browser.standardTabs.forEach { $0.stop() }
    }

    func testMemoryWarningKeepsFramesAndReleasesSafeIdlePage() async throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        let framed = try XCTUnwrap(browser.activeTab)
        framed.load(URL(string: "http://127.0.0.1:8768/article")!)
        try await waitUntil { !framed.isLoading && framed.url?.path == "/article" }
        _ = try await framed.webView.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend', '<iframe src=about:blank></iframe>')")
        let safe = browser.newTab()
        safe.load(URL(string: "http://127.0.0.1:8768/article-two")!)
        try await waitUntil { !safe.isLoading && safe.url?.path == "/article-two" }
        _ = browser.newTab()
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await waitUntil { safe.isSuspended }
        XCTAssertTrue(framed.isResident)
        // 已释放视图的迟到回调不能重新创建页面。
        browser.standardTabs.forEach { $0.stop() }
    }

    func testAssistantPinsAndHistoryProtectPagesAndCrashLoopStops() async throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        let tab = try XCTUnwrap(browser.activeTab)
        tab.load(URL(string: "http://127.0.0.1:8768/article")!)
        try await waitUntil { !tab.isLoading && tab.url?.path == "/article" }
        browser.protectAssistantTabs([tab.id])
        _ = browser.newTab()
        _ = await browser.releaseInactiveTabs()
        XCTAssertTrue(tab.isResident)
        browser.protectAssistantTabs([])
        browser.activate(tab.id)
        tab.load(URL(string: "http://127.0.0.1:8768/article-two")!)
        try await waitUntil { !tab.isLoading && tab.url?.path == "/article-two" }
        _ = browser.newTab()
        _ = await browser.releaseInactiveTabs()
        XCTAssertTrue(tab.isResident, "真实浏览历史必须保留")
        browser.activate(tab.id)
        // 模拟系统委托回调，验证连续终止时不会无限重载。
        tab.webViewWebContentProcessDidTerminate(tab.webView)
        tab.webViewWebContentProcessDidTerminate(tab.webView)
        XCTAssertNotNil(tab.loadingError)
        XCTAssertFalse(tab.isLoading)
        tab.reload()
        try await waitUntil { !tab.isLoading }
        XCTAssertNil(tab.loadingError)
        browser.standardTabs.forEach { $0.stop() }
    }
}
