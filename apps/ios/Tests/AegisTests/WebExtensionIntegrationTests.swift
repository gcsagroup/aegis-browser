import XCTest
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
