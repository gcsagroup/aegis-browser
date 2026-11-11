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
        // Prefer the already-bound WKNavigation when present; otherwise the
        // production nil-navigation path owns the single unbound allow. Do not
        // pump the run loop here — that races real WebKit callbacks.
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

        tab.load(request)
        deliver(tab, code: NSURLErrorNotConnectedToInternet)
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)

        tab.load(request)
        deliver(tab, code: NSURLErrorAppTransportSecurityRequiresSecureConnection)
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)

        tab.load(request)
        deliver(tab, code: NSURLErrorHTTPTooManyRedirects)
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)

        tab.load(request)
        deliver(tab, code: NSURLErrorTimedOut)
        XCTAssertTrue(tab.loadingErrorAllowsProxyRetry)

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

    func testUncommittedRequestDoesNotAuthorizeTheToggleHost() throws {
        let coordinator = AccessHostStoreCoordinator()
        let tab = makeTab()
        tab.hostCoordinator = coordinator
        tab.load(URLRequest(url: URL(string: "https://example.invalid/draft")!))
        XCTAssertNil(coordinator.snapshot(for: tab).host)
        tab.commitPendingMainFrameForTests()
        XCTAssertEqual(coordinator.snapshot(for: tab).host, try AccessSiteHost("example.invalid"))
    }

    func testPostFailureDoesNotReuseThePreviousGetTicket() throws {
        let tab = makeTab()
        var get = URLRequest(url: URL(string: "https://example.invalid/page")!)
        get.httpMethod = "GET"
        tab.load(get)
        deliver(tab)
        XCTAssertTrue(tab.loadingErrorAllowsProxyRetry)
        XCTAssertEqual(tab.lastMainFrameFailure?.method, "GET")

        var post = URLRequest(url: URL(string: "https://example.invalid/submit")!)
        post.httpMethod = "POST"
        tab.load(post)
        tab.webView(tab.webView, didFailProvisionalNavigation: nil, withError: NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotFindHost
        ))
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
        XCTAssertNotEqual(tab.lastMainFrameFailure?.method, "GET")
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

    func testSameHostInPageFailureKeepsNavigationIdentity() throws {
        let tab = makeTab()
        tab.load(URLRequest(url: URL(string: "https://shop.example/home")!))
        tab.commitPendingMainFrameForTests()
        tab.webView(tab.webView, didFinish: tab.currentNavigationForTests)
        XCTAssertNil(tab.lastMainFrameFailure)
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)

        let cart = URL(string: "https://shop.example/cart")!
        tab.adoptPolicyMainFrameNavigationForTests(url: cart, method: "GET")
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        tab.webView(tab.webView, didFailProvisionalNavigation: nil, withError: error)
        XCTAssertEqual(tab.lastMainFrameFailure?.url, cart)
        XCTAssertEqual(tab.lastMainFrameFailure?.method, "GET")
        XCTAssertTrue(tab.loadingErrorAllowsProxyRetry)
    }

    func testFinishedPageDoesNotReuseStaleAttemptForNilNavigationFailure() throws {
        let tab = makeTab()
        tab.load(URLRequest(url: URL(string: "https://shop.example/home")!))
        tab.commitPendingMainFrameForTests()
        tab.webView(tab.webView, didFinish: tab.currentNavigationForTests)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        tab.webView(tab.webView, didFailProvisionalNavigation: nil, withError: error)
        XCTAssertNil(tab.lastMainFrameFailure)
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
    }

    func testInterleavedSameHostNavigationKeepsDistinctURLAndMethod() async throws {
        let tab = makeTab()
        var post = URLRequest(url: URL(string: "https://shop.example/checkout")!)
        post.httpMethod = "POST"
        tab.load(post)
        await waitUntil { tab.currentNavigationForTests != nil }
        let postNavigation = try XCTUnwrap(tab.currentNavigationForTests)

        let getURL = URL(string: "https://shop.example/cart")!
        tab.adoptPolicyMainFrameNavigationForTests(
            url: getURL,
            method: "GET",
            continuesExistingNavigation: false
        )
        // Competing GET must not rewrite the still-pending POST identity in the map.
        let postError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        tab.webView(tab.webView, didFailProvisionalNavigation: postNavigation, withError: postError)
        XCTAssertEqual(tab.lastMainFrameFailure?.method, "POST")
        XCTAssertEqual(tab.lastMainFrameFailure?.url.path, "/checkout")
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
    }

    func testStopBeforeDeferredLoadDoesNotSend() async throws {
        let tab = makeTab()
        var request = URLRequest(url: URL(string: "https://example.invalid/stop")!)
        request.httpMethod = "GET"
        tab.load(request)
        let loadsBeforeStop = tab.recoveryLoadCount
        tab.stop()
        await waitUntil { true }
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(tab.recoveryLoadCount, loadsBeforeStop)
        XCTAssertNil(tab.currentNavigationForTests)
    }

    func testLateForeignFailureDoesNotClearNewerPendingNavigation() async throws {
        let tab = makeTab()
        tab.load(URLRequest(url: URL(string: "https://shop.example/a")!))
        await waitUntil { tab.currentNavigationForTests != nil }
        let first = try XCTUnwrap(tab.currentNavigationForTests)
        tab.load(URLRequest(url: URL(string: "https://shop.example/b")!))
        await waitUntil { tab.currentNavigationForTests != nil && tab.currentNavigationForTests !== first }
        let second = try XCTUnwrap(tab.currentNavigationForTests)
        XCTAssertTrue(second !== first)
        let late = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        tab.webView(tab.webView, didFailProvisionalNavigation: first, withError: late)
        XCTAssertEqual(tab.currentNavigationForTests, second)
        XCTAssertTrue(tab.isLoading)
        XCTAssertNotEqual(tab.lastMainFrameFailure?.url.path, "/a")
    }

    func testStopRetiresNavigationIdentitySoLateFailureCannotRetry() async throws {
        let tab = makeTab()
        tab.load(URLRequest(url: URL(string: "https://shop.example/pending")!))
        await waitUntil { tab.currentNavigationForTests != nil }
        let navigation = try XCTUnwrap(tab.currentNavigationForTests)
        tab.stop()
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        tab.webView(tab.webView, didFailProvisionalNavigation: navigation, withError: error)
        XCTAssertNil(tab.lastMainFrameFailure)
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
    }

    func testGetWithBodyDoesNotAllowAutomaticProxyRetry() throws {
        let tab = makeTab()
        var request = URLRequest(url: URL(string: "https://shop.example/search")!)
        request.httpMethod = "GET"
        request.httpBody = Data("q=1".utf8)
        tab.load(request)
        deliver(tab)
        XCTAssertEqual(tab.lastMainFrameFailure?.hasReplayableBody, true)
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
    }

    func testOtherNavigationWithoutPendingMintsFreshAttempt() throws {
        let tab = makeTab()
        tab.load(URLRequest(url: URL(string: "https://shop.example/home")!))
        tab.commitPendingMainFrameForTests()
        tab.webView(tab.webView, didFinish: tab.currentNavigationForTests)
        let next = URL(string: "https://shop.example/scripted")!
        // Script-driven `.other` with no pending navigation must not continue the finished page.
        tab.adoptPolicyMainFrameNavigationForTests(
            url: next,
            method: "GET",
            continuesExistingNavigation: false
        )
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        tab.webView(tab.webView, didFailProvisionalNavigation: nil, withError: error)
        XCTAssertEqual(tab.lastMainFrameFailure?.url, next)
        XCTAssertTrue(tab.loadingErrorAllowsProxyRetry)
    }

    func testOtherNavigationTypeDoesNotContinueExistingAttempt() {
        XCTAssertFalse(
            BrowserTab.continuesExistingMainFrameNavigationTypeForTests(.other),
            "`.other` includes script jumps; only server-redirect callbacks may rewrite identity"
        )
        XCTAssertFalse(BrowserTab.continuesExistingMainFrameNavigationTypeForTests(.linkActivated))
    }

    func testNilNavigationFailureWithMultipleUnboundAllowsShowsOrdinaryError() throws {
        let tab = makeTab()
        tab.adoptPolicyMainFrameNavigationForTests(
            url: URL(string: "https://shop.example/a")!,
            method: "GET"
        )
        tab.adoptPolicyMainFrameNavigationForTests(
            url: URL(string: "https://shop.example/b")!,
            method: "POST",
            continuesExistingNavigation: false
        )
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        tab.webView(tab.webView, didFailProvisionalNavigation: nil, withError: error)
        XCTAssertNil(tab.lastMainFrameFailure)
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
    }

    func testNewerAllowBecomesCurrentWhenOlderProvisionalIsStillMapped() async throws {
        let tab = makeTab()
        tab.load(URLRequest(url: URL(string: "https://shop.example/a")!))
        await waitUntil { tab.currentNavigationForTests != nil }
        let first = try XCTUnwrap(tab.currentNavigationForTests)
        tab.adoptPolicyMainFrameNavigationForTests(
            url: URL(string: "https://shop.example/b")!,
            method: "GET",
            continuesExistingNavigation: false
        )
        tab.load(URLRequest(url: URL(string: "https://shop.example/b")!))
        await waitUntil { tab.currentNavigationForTests != nil && tab.currentNavigationForTests !== first }
        let second = try XCTUnwrap(tab.currentNavigationForTests)
        XCTAssertTrue(second !== first)
        tab.webView(tab.webView, didCommit: second)
        XCTAssertEqual(tab.url?.path, "/b")
    }
}
