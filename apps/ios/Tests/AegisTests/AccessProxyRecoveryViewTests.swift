@testable import BrowserKit
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Aegis

@MainActor
final class AccessProxyRecoveryViewTests: XCTestCase {
    func testPendingAddressBannerHasOneTargetBoundChoiceWithoutFailureCopy() async throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.standardTabs.forEach { $0.stop() } }
        let tab = try XCTUnwrap(browser.activeTab)
        let target = URL(string: "https://192.0.2.1/address")!
        tab.loadFromAddressBar(target)
        var selected: BrowserPendingAddressNavigation?
        let host = UIHostingController(rootView: PageLoadFailureBanner(
            tab: tab, openAddressViaProxy: { _, pending in selected = pending },
            proxyRetry: { _ in XCTFail("A pending choice must not fabricate a failure retry") }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let buttons = Self.buttons(identifier: "page-load-proxy-retry", in: host.view)
        XCTAssertEqual(buttons.count, 1)
        XCTAssertNil(tab.loadingError)
        // SwiftUI's synthesized host/status accessibility nodes are verified
        // through XCUITest. Here the actual native button must capture exactly
        // the visible pending navigation, without fabricating a failure retry.
        let button = try XCTUnwrap(buttons.first)
        XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
        XCTAssertLessThan(button.bounds.height, 100)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected?.url, target)
        XCTAssertEqual(selected, tab.pendingAddressNavigation)
        XCTAssertNil(tab.lastMainFrameFailure)
    }

    func testNativeProxyButtonUpdatesItsCapturedTargetWithoutRecreation() async throws {
        var selected = ""
        let host = UIHostingController(rootView: ProxyRetryButton(title: "First") { selected = "first" })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let first = try XCTUnwrap(Self.find(identifier: "page-load-proxy-retry", in: host.view) as? UIButton)
        host.rootView = ProxyRetryButton(title: "Second") { selected = "second" }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let updated = try XCTUnwrap(Self.find(identifier: "page-load-proxy-retry", in: host.view) as? UIButton)
        XCTAssertTrue(first === updated)
        XCTAssertEqual(updated.title(for: .normal), "Second")
        updated.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, "second")
    }

    func testBannerShowsProxyRetryOnlyForRecoverableNavigation() async throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.standardTabs.forEach { $0.stop() } }
        let tab = try XCTUnwrap(browser.activeTab)
        var request = URLRequest(url: URL(string: "https://example.invalid/a")!)
        request.httpMethod = "GET"
        tab.load(request)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        tab.webView(
            tab.webView,
            didFailProvisionalNavigation: tab.currentNavigationForTests,
            withError: error
        )
        XCTAssertTrue(tab.loadingErrorAllowsProxyRetry)

        final class Hit: @unchecked Sendable {
            var tabID: UUID?
        }
        let hit = Hit()
        let host = UIHostingController(rootView: PageLoadFailureBanner(tab: tab) { failed in
            hit.tabID = failed.id
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let button = try XCTUnwrap(Self.find(identifier: "page-load-proxy-retry", in: host.view) as? UIButton)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(hit.tabID, tab.id)
        window.isHidden = true
    }

    private static func find(identifier: String, in object: Any?) -> NSObject? {
        if let view = object as? UIView {
            if view.accessibilityIdentifier == identifier { return view }
            for child in view.subviews {
                if let found = find(identifier: identifier, in: child) { return found }
            }
            for element in view.accessibilityElements ?? [] {
                if let found = find(identifier: identifier, in: element) { return found }
            }
        } else if let element = object as? UIAccessibilityElement, element.accessibilityIdentifier == identifier {
            return element
        }
        return nil
    }

    private static func buttons(identifier: String, in view: UIView) -> [UIButton] {
        let own = (view as? UIButton).flatMap { $0.accessibilityIdentifier == identifier ? $0 : nil }
        return (own.map { [$0] } ?? []) + view.subviews.flatMap { buttons(identifier: identifier, in: $0) }
    }
}
