import XCTest
import WebKit
@testable import BrowserKit

@MainActor
final class WebExtensionIntegrationTests: XCTestCase {
    func testSharedWebExtensionLoadsIntoWKWebViewController() async throws {
        let session = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        let deadline = Date().addingTimeInterval(8)
        while session.extensionStatus == "WebExtension 正在初始化", Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(session.extensionStatus, "Shared WebExtension 已加载")
        XCTAssertNotNil(session.activeTab?.webView.configuration.webExtensionController)
    }

    func testBundledExtensionDisablesAndReloadsWithRevokedSiteIsolated() async throws {
        let standard = WebExtensionRuntime(isPrivate: false)
        let privateMode = WebExtensionRuntime(isPrivate: true)
        try await standard.loadSharedResources(from: Bundle.main.bundleURL)
        try await privateMode.loadSharedResources(from: Bundle.main.bundleURL)
        let context = try XCTUnwrap(standard.context)
        let privateContext = try XCTUnwrap(privateMode.context)
        XCTAssertFalse(context === privateContext)
        XCTAssertTrue(standard.controller.configuration.isPersistent)
        XCTAssertFalse(privateMode.controller.configuration.isPersistent)
        XCTAssertTrue(context.isLoaded)
        XCTAssertTrue(privateContext.isLoaded)

        let site = try XCTUnwrap(URL(string: "https://aegis-extension-lifecycle.example/"))
        let other = try XCTUnwrap(URL(string: "https://aegis-extension-other.example/"))
        context.setPermissionStatus(.grantedExplicitly, for: site)
        context.setPermissionStatus(.grantedExplicitly, for: other)
        XCTAssertEqual(context.permissionStatus(for: site), .grantedExplicitly)
        XCTAssertNotEqual(privateContext.permissionStatus(for: site), .grantedExplicitly)
        try standard.revokeSitePermission(site)
        XCTAssertEqual(context.permissionStatus(for: site), .deniedExplicitly)
        XCTAssertEqual(context.permissionStatus(for: other), .grantedExplicitly)
        XCTAssertNotEqual(privateContext.permissionStatus(for: site), .deniedExplicitly)

        try standard.setEnabled(false)
        XCTAssertFalse(context.isLoaded)
        XCTAssertTrue(standard.controller.extensionContexts.isEmpty)
        XCTAssertTrue(privateContext.isLoaded)
        try standard.setEnabled(false)
        try standard.setEnabled(true)
        XCTAssertTrue(context.isLoaded)
        XCTAssertEqual(context.permissionStatus(for: site), .deniedExplicitly)
        XCTAssertTrue(privateMode.controller.extensionContexts.contains(privateContext))

        try standard.setEnabled(false)
        try privateMode.setEnabled(false)
    }

    func testFixtureNavigationUpdatesDocumentGeneration() async throws {
        let session = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        let tab = try XCTUnwrap(session.activeTab)
        let originalEpoch = tab.navigationEpoch
        let finished = expectation(description: "fixture navigation")
        tab.onNavigation = { updatedTab in
            if updatedTab.url?.absoluteString == "aegis://injection" { finished.fulfill() }
        }
        tab.load(try XCTUnwrap(URL(string: "aegis://injection")))
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertGreaterThan(tab.navigationEpoch, originalEpoch)
        XCTAssertEqual(tab.url?.absoluteString, "aegis://injection")
        XCTAssertFalse(tab.title.isEmpty)
    }
}
