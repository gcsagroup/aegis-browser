@testable import BrowserKit
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Aegis

@MainActor
final class AccessProxyRecoveryViewTests: XCTestCase {
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
}
