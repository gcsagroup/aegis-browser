import AccessKit
@testable import BrowserKit
import WebKit
import XCTest
@testable import Aegis

@MainActor
final class AccessNavigationRecoveryTests: XCTestCase {
    private func makeTab() -> BrowserTab {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        let tab = browser.activeTab!
        addTeardownBlock { [browser] in
            browser.standardTabs.forEach { $0.stop() }
            browser.privateTabs.forEach { $0.stop() }
        }
        return tab
    }

    private func readyEndpoint(generation: UInt64 = 1) -> AccessManagedProxyEndpoint {
        AccessManagedProxyEndpoint(
            identity: "entry-1",
            generation: generation,
            loopbackHost: "127.0.0.1",
            port: 18_081,
            state: .ready
        )
    }

    private func deliver(_ tab: BrowserTab, code: Int = NSURLErrorCannotFindHost) {
        let navigation = tab.currentNavigationForTests
        let error = NSError(domain: NSURLErrorDomain, code: code)
        tab.webView(tab.webView, didFailProvisionalNavigation: navigation, withError: error)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: TimeInterval = 2
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testAutomaticRecoveryIsOneAndExplicitClickAddsOne() async throws {
        let publisher = AccessProxyEntryPublisher { generation, _ in
            AccessProxyEntryPublisher.Provision(
                endpoint: AccessManagedProxyEndpoint(
                    identity: "entry-1",
                    generation: generation,
                    loopbackHost: "127.0.0.1",
                    port: 18_081,
                    state: .ready
                ),
                listenerReady: true,
                runtimeHealthy: true,
                bridgeInstalled: true
            )
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessManualPreparationClock())
        let tab = makeTab()
        tab.hostCoordinator = coordinator
        let host = try AccessSiteHost("example.invalid")
        coordinator.registry.setEndpoint(readyEndpoint(), scopeID: "ordinary", host: host, isPrivate: false)
        coordinator.setProxyEnabled(true, host: host, scopeID: "ordinary", isPrivate: false)
        var request = URLRequest(url: URL(string: "https://example.invalid/a")!)
        request.httpMethod = "GET"
        tab.load(request)
        deliver(tab)
        XCTAssertEqual(tab.recoveryLoadCount, 1)

        deliver(tab)
        XCTAssertEqual(tab.recoveryLoadCount, 1)
        XCTAssertTrue(tab.loadingErrorAllowsProxyRetry)

        _ = coordinator.retryViaProxy(tab: tab)
        await waitUntil { tab.recoveryLoadCount == 2 }
        XCTAssertEqual(tab.recoveryLoadCount, 2)

        deliver(tab)
        XCTAssertEqual(tab.recoveryLoadCount, 2)
    }

    func testRepeatedClickWhilePreparingReusesTheOperation() async throws {
        let publisher = AccessProxyEntryPublisher { _, _ in
            try await Task.sleep(for: .seconds(30))
            throw AccessSiteSessionError.nodeUnavailable
        }
        let clock = AccessManualPreparationClock()
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: clock)
        let tab = makeTab()
        tab.hostCoordinator = coordinator
        var request = URLRequest(url: URL(string: "https://example.invalid/a")!)
        request.httpMethod = "GET"
        tab.load(request)
        deliver(tab)
        let first = coordinator.retryViaProxy(tab: tab)
        let second = coordinator.retryViaProxy(tab: tab)
        XCTAssertEqual(first, second)
        XCTAssertNotNil(first)
        clock.advance(by: .seconds(15))
        await waitUntil { true }
    }

    func testHeadIsPreservedAndPostDoesNotRetry() throws {
        let coordinator = AccessHostStoreCoordinator()
        let tab = makeTab()
        tab.hostCoordinator = coordinator
        var head = URLRequest(url: URL(string: "https://example.invalid/a")!)
        head.httpMethod = "HEAD"
        tab.load(head)
        deliver(tab)
        XCTAssertEqual(tab.lastMainFrameFailure?.method, "HEAD")
        XCTAssertTrue(tab.loadingErrorAllowsProxyRetry)
        XCTAssertEqual(tab.recoveryLoadCount, 0)

        var post = URLRequest(url: URL(string: "https://example.invalid/submit")!)
        post.httpMethod = "POST"
        tab.load(post)
        deliver(tab)
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
        XCTAssertEqual(tab.recoveryLoadCount, 0)
    }

    func testCertificateCancelAndPolicyDoNotOfferProxyRetry() throws {
        let tab = makeTab()
        var request = URLRequest(url: URL(string: "https://example.invalid/a")!)
        request.httpMethod = "GET"
        tab.load(request)
        deliver(tab, code: NSURLErrorServerCertificateUntrusted)
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
        XCTAssertNotNil(tab.loadingError)

        tab.load(request)
        deliver(tab, code: NSURLErrorCancelled)
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)

        let host = try XCTUnwrap(LocalThreatDatabase.snapshot?.phishing.first)
        tab.load(URL(string: "https://\(host)/")!)
        XCTAssertEqual(tab.protectionIncident?.reasons, ["known_phishing_host"])
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
    }

    func testSameHostNewPathAndStopDropThePendingRecovery() async throws {
        let publisher = AccessProxyEntryPublisher { _, _ in
            try await Task.sleep(for: .seconds(30))
            throw AccessSiteSessionError.nodeUnavailable
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessManualPreparationClock())
        let tab = makeTab()
        tab.hostCoordinator = coordinator
        var request = URLRequest(url: URL(string: "https://example.invalid/old")!)
        request.httpMethod = "GET"
        tab.load(request)
        deliver(tab)
        let operation = coordinator.retryViaProxy(tab: tab)
        XCTAssertNotNil(operation)
        var next = URLRequest(url: URL(string: "https://example.invalid/new")!)
        next.httpMethod = "GET"
        tab.load(next)
        XCTAssertNil(tab.lastMainFrameFailure)
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
        XCTAssertEqual(tab.recoveryLoadCount, 0)
        tab.stop()
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
    }

    func testStaleWebViewCallbackDoesNotCreateAFailure() throws {
        let tab = makeTab()
        var request = URLRequest(url: URL(string: "https://example.invalid/a")!)
        request.httpMethod = "GET"
        tab.load(request)
        let oldView = tab.webView
        tab.rebindWebsiteDataStore(.nonPersistent(), host: nil)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        tab.webView(oldView, didFailProvisionalNavigation: nil, withError: error)
        XCTAssertNil(tab.lastMainFrameFailure)
        XCTAssertEqual(tab.recoveryLoadCount, 0)
    }

    func testDuplicateCallbackKeepsTheFailureIdentity() throws {
        let tab = makeTab()
        var request = URLRequest(url: URL(string: "https://example.invalid/a")!)
        request.httpMethod = "GET"
        tab.load(request)
        deliver(tab)
        let failureID = tab.lastMainFrameFailure?.failureID
        deliver(tab)
        XCTAssertEqual(tab.lastMainFrameFailure?.failureID, failureID)
        XCTAssertEqual(tab.recoveryLoadCount, 0)
    }
}
