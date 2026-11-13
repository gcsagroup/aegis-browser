import AccessKit
@testable import BrowserKit
import WebKit
import Network
import Synchronization
import UIKit
import XCTest
@testable import Aegis

@MainActor
final class AccessNavigationRecoveryTests: XCTestCase {
    func testUnsafeReplaySurvivesCompletionAndOrdinaryStop() throws {
        for variant in 0..<3 {
            let tab = makeTab()
            var request = URLRequest(url: URL(string: "https://unsafe-completed.invalid/submission")!)
            request.httpMethod = variant == 1 ? "HEAD" : "GET"
            if variant == 0 { request.httpBody = Data("body".utf8) }
            if variant == 1 { request.httpBodyStream = InputStream(data: Data("stream".utf8)) }
            if variant == 2 { request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization") }
            tab.load(request)
            tab.commitPendingMainFrameForTests()
            tab.webView(tab.webView, didFinish: tab.currentNavigationForTests)
            XCTAssertNil(tab.safeRouteReloadRequest)
            tab.stop()
            XCTAssertNil(tab.safeRouteReloadRequest)
            let fresh = URL(string: "https://unsafe-completed.invalid/fresh")!
            tab.loadFromAddressBar(fresh)
            XCTAssertEqual(tab.safeRouteReloadRequest?.url, fresh)
        }
    }

    func testDeferredAddressSubmissionKeepsItsIdentityAndEarlyChoice() async throws {
        let tab = makeTab()
        tab.loadFromAddressBar(URL(string: "https://192.0.2.1/old-document")!)
        let oldView = tab.webView
        XCTAssertNotNil(tab.holdForProxy(try XCTUnwrap(tab.safeRouteReloadRequest)))
        let next = URL(string: "https://192.0.2.1/new-address")!
        tab.loadFromAddressBar(next)
        let pending = try XCTUnwrap(tab.pendingAddressNavigation)
        var oldDocumentStopped = false
        tab.afterCurrentDocumentBecomesInert { oldDocumentStopped = true }
        await waitUntil({ oldDocumentStopped && tab.currentNavigationForTests != nil }, timeout: 10)
        XCTAssertTrue(oldDocumentStopped)
        XCTAssertNotNil(tab.currentNavigationForTests)
        XCTAssertEqual(tab.pendingAddressNavigation, pending)
        XCTAssertTrue(tab.matchesPendingAddressNavigation(pending))
        XCTAssertNil(oldView.load(URLRequest(url: next)))
    }

    func testMemoryTrimWaitsForRetiringProxyDocument() async throws {
        let tab = makeTab()
        let coordinator = AccessHostStoreCoordinator()
        tab.hostCoordinator = coordinator
        let host = try AccessSiteHost("retiring.invalid")
        coordinator.setProxyEnabled(true, host: host, scopeID: tab.browsingScopeID, isPrivate: false)
        coordinator.registry.setEndpoint(AccessManagedProxyEndpoint(identity: "fixture", generation: 1,
            loopbackHost: "127.0.0.1", port: 18081, state: .ready), scopeID: tab.browsingScopeID, host: host, isPrivate: false)
        tab.loadFromAddressBar(URL(string: "https://retiring.invalid/old")!)
        let oldView = tab.webView
        let oldStore = tab.websiteDataStore
        XCTAssertEqual(oldStore.proxyConfigurations.count, 1)
        tab.loadFromAddressBar(URL(string: "https://192.0.2.1/new")!)
        coordinator.releaseIdleResources()
        XCTAssertEqual(oldStore.proxyConfigurations.count, 1, "Old realm still owns its mandatory route")
        await waitUntil { tab.currentNavigationForTests != nil }
        coordinator.releaseIdleResources()
        XCTAssertTrue(oldStore.proxyConfigurations.isEmpty)
        XCTAssertNil(oldView.load(URLRequest(url: URL(string: "https://192.0.2.1/late")!)))
    }

    func testDisposeWaitsForDocumentAlreadyHeldBeforeClose() async throws {
        let tab = makeTab()
        tab.loadFromAddressBar(URL(string: "https://192.0.2.1/held-close")!)
        let oldView = tab.webView
        XCTAssertNotNil(tab.holdForProxy(try XCTUnwrap(tab.safeRouteReloadRequest)))
        var completed = false
        tab.dispose { completed = true }
        XCTAssertFalse(completed, "held old view must become inert before releasing its store")
        XCTAssertNil(oldView.load(URLRequest(url: URL(string: "https://192.0.2.1/resurrect")!)))
        await waitUntil { completed }
        XCTAssertTrue(completed)
    }

    func testSameStoreResumeRebuildsHooksWithoutReenablingRetiredController() throws {
        let tab = makeTab()
        tab.loadFromAddressBar(URL(string: "https://192.0.2.1/held-hooks")!)
        let oldView = tab.webView
        let oldController = oldView.configuration.userContentController
        let store = tab.websiteDataStore
        XCTAssertNotNil(tab.holdForProxy(try XCTUnwrap(tab.safeRouteReloadRequest)))
        XCTAssertTrue(oldController.userScripts.isEmpty)
        tab.rebindWebsiteDataStore(store, host: nil)
        let replacement = tab.webView
        XCTAssertFalse(replacement.configuration.userContentController === oldController)
        XCTAssertTrue(replacement.configuration.userContentController.userScripts.contains { $0.source.contains("__aegisHasEdits") })
        XCTAssertTrue(oldController.userScripts.isEmpty)
    }

    func testExplicitAddressProxyHoldIgnoresOldDirectTimeout() async throws {
        let clock = AccessManualPreparationClock()
        let publisher = AccessProxyEntryPublisher { generation, _ in
            try await clock.sleep(until: .seconds(5))
            return AccessProxyEntryPublisher.Provision(
                endpoint: AccessManagedProxyEndpoint(identity: "held-address", generation: generation,
                    loopbackHost: "127.0.0.1", port: 18_081, state: .ready),
                listenerReady: true, runtimeHealthy: true, bridgeInstalled: true)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: clock)
        let tab = makeTab()
        tab.hostCoordinator = coordinator
        tab.loadFromAddressBar(URL(string: "https://192.0.2.1/held-deadline")!)
        await waitUntil { tab.currentNavigationForTests != nil }
        let oldNavigation = try XCTUnwrap(tab.currentNavigationForTests)
        let oldView = tab.webView
        let pending = try XCTUnwrap(tab.pendingAddressNavigation)
        XCTAssertNotNil(coordinator.openPendingAddressViaProxy(tab: tab, pending: pending))
        tab.webView(oldView, didFailProvisionalNavigation: oldNavigation, withError: URLError(.timedOut))
        XCTAssertTrue(tab.matchesPendingAddressNavigation(pending))
        await waitUntil { publisher.provisionCount == 1 }
        clock.advance(to: .seconds(5))
        await waitUntil { tab.recoveryLoadCount == 1 }
        XCTAssertEqual(tab.recoveryLoadCount, 1)
    }

    func testRepeatedRoutePausePreservesUnsafeGetAndHeadUntilNewNavigation() throws {
        for variant in 0..<3 {
            let tab = makeTab()
            var request = URLRequest(url: URL(string: "https://unsafe-pause.invalid/submission")!)
            request.httpMethod = variant == 1 ? "HEAD" : "GET"
            if variant == 0 { request.httpBody = Data("submission".utf8) }
            if variant == 1 { request.httpBodyStream = InputStream(data: Data("stream".utf8)) }
            if variant == 2 { request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization") }
            tab.load(request)
            XCTAssertNil(tab.safeRouteReloadRequest)
            tab.pauseAfterRouteChange()
            XCTAssertNil(tab.safeRouteReloadRequest)
            tab.pauseAfterRouteChange()
            XCTAssertNil(tab.safeRouteReloadRequest, "Repeated toggles must not erase replay restrictions")
            let fresh = URL(string: "https://unsafe-pause.invalid/fresh")!
            tab.load(fresh)
            XCTAssertEqual(tab.safeRouteReloadRequest?.url, fresh)
        }
    }

    func testAddressPresentationKeepsFailedTargetUntilANewNavigationSupersedesIt() async throws {
        let tab = makeTab()
        tab.load(URL(string: "aegis://start")!)
        await waitUntil { tab.url?.absoluteString == "aegis://start" && !tab.isLoading }
        XCTAssertEqual(tab.url?.absoluteString, "aegis://start")
        let target = URL(string: "https://192.0.2.1/failed-page")!
        tab.loadFromAddressBar(target)
        XCTAssertEqual(tab.addressBarURL, target)
        await waitUntil { tab.currentNavigationForTests != nil }
        let navigation = try XCTUnwrap(tab.currentNavigationForTests)
        tab.webView(tab.webView, didFailProvisionalNavigation: navigation, withError: URLError(.timedOut))
        XCTAssertFalse(tab.isLoading)
        XCTAssertEqual(tab.lastMainFrameFailure?.url, target)
        XCTAssertEqual(tab.addressBarURL, target, "An internal or older WebKit document must not replace the failed address")
        XCTAssertEqual(tab.requestedURL, target, "A manual retry must retain the failed destination")
        let next = URL(string: "https://192.0.2.2/next")!
        tab.loadFromAddressBar(next)
        XCTAssertNil(tab.lastMainFrameFailure)
        XCTAssertEqual(tab.addressBarURL, next)
    }

    func testAlreadyArmedAddressUsesItsRouteWithoutOfferingAnotherProxyChoice() throws {
        let coordinator = AccessHostStoreCoordinator()
        let tab = makeTab()
        tab.hostCoordinator = coordinator
        let host = try AccessSiteHost("192.0.2.1")
        coordinator.registry.setEndpoint(readyEndpoint(), scopeID: tab.browsingScopeID, host: host, isPrivate: false)
        coordinator.setProxyEnabled(true, host: host, scopeID: tab.browsingScopeID, isPrivate: false)
        tab.loadFromAddressBar(URL(string: "https://192.0.2.1/already-on")!)
        XCTAssertNil(tab.pendingAddressNavigation)
        XCTAssertEqual(tab.boundHostName, host.rawValue)
        XCTAssertFalse(tab.websiteDataStore === tab.originalWebsiteDataStore)
    }

    func testProvisionalTimeoutRecordsFailureBeforeReentrantCancellation() async throws {
        let tab = makeTab()
        tab.load(URLRequest(url: URL(string: "https://192.0.2.1/timeout")!, timeoutInterval: 30))
        await waitUntil { tab.currentNavigationForTests != nil }
        let navigation = try XCTUnwrap(tab.currentNavigationForTests)
        var stopped = false
        tab.failProvisionalNavigationOnTimeout(navigation) {
            stopped = true
            XCTAssertNotNil(tab.lastMainFrameFailure)
            XCTAssertTrue(tab.loadingErrorAllowsProxyRetry)
            tab.webView(tab.webView, didFailProvisionalNavigation: navigation, withError: URLError(.cancelled))
        }
        XCTAssertTrue(stopped)
        XCTAssertFalse(tab.isLoading)
        XCTAssertTrue(tab.loadingErrorAllowsProxyRetry)
        let failureID = try XCTUnwrap(tab.lastMainFrameFailure?.failureID)
        tab.webView(tab.webView, didFailProvisionalNavigation: navigation, withError: URLError(.cancelled))
        tab.failProvisionalNavigationOnTimeout(navigation) { XCTFail("An expired timeout must be retired") }
        XCTAssertEqual(tab.lastMainFrameFailure?.failureID, failureID)
        XCTAssertTrue(tab.loadingErrorAllowsProxyRetry)
    }

    func testExpiredOldNavigationCannotStopOrFailItsReplacement() async throws {
        let tab = makeTab()
        tab.load(URLRequest(url: URL(string: "https://192.0.2.1/old")!))
        await waitUntil { tab.currentNavigationForTests != nil }
        let old = try XCTUnwrap(tab.currentNavigationForTests)
        tab.load(URLRequest(url: URL(string: "https://192.0.2.2/new")!))
        tab.failProvisionalNavigationOnTimeout(old) { XCTFail("Old deadline stopped its replacement") }
        XCTAssertTrue(tab.isLoading)
        XCTAssertNil(tab.lastMainFrameFailure)
        XCTAssertEqual(tab.requestedURL?.host, "192.0.2.2")
    }

    func testTimeoutDoesNotStopAutomaticallyStartedProxyRecovery() async throws {
        let coordinator = AccessHostStoreCoordinator()
        let tab = makeTab()
        tab.hostCoordinator = coordinator
        let host = try AccessSiteHost("192.0.2.1")
        tab.load(URLRequest(url: URL(string: "https://192.0.2.1/timeout")!))
        await waitUntil { tab.currentNavigationForTests != nil }
        let navigation = try XCTUnwrap(tab.currentNavigationForTests)
        coordinator.registry.setEndpoint(readyEndpoint(), scopeID: "ordinary", host: host, isPrivate: false)
        coordinator.setProxyEnabled(true, host: host, scopeID: "ordinary", isPrivate: false)
        tab.failProvisionalNavigationOnTimeout(navigation) { XCTFail("Timeout stopped the newly started proxy recovery") }
        XCTAssertEqual(tab.recoveryLoadCount, 1)
        XCTAssertTrue(tab.isLoading)
        tab.webView(tab.webView, didFailProvisionalNavigation: navigation, withError: URLError(.cancelled))
        XCTAssertEqual(tab.recoveryLoadCount, 1)
        XCTAssertTrue(tab.isLoading)
    }

    func testAddressSubmissionOffersChoiceBeforeWebKitStartsWithoutInventingFailure() throws {
        let coordinator = AccessHostStoreCoordinator()
        let tab = makeTab()
        tab.hostCoordinator = coordinator
        let target = URL(string: "https://192.0.2.1/address")!
        tab.loadFromAddressBar(target)
        let pending = try XCTUnwrap(tab.pendingAddressNavigation)
        XCTAssertEqual(pending.url, target)
        XCTAssertEqual(pending.navigationID, tab.currentAttemptIDForTests)
        XCTAssertTrue(tab.matchesPendingAddressNavigation(pending))
        XCTAssertNil(tab.currentNavigationForTests)
        XCTAssertNil(tab.lastMainFrameFailure)
        XCTAssertNil(tab.loadingError)
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
        XCTAssertNil(coordinator.snapshot(for: tab).host)
        XCTAssertEqual(tab.recoveryLoadCount, 0)
    }

    func testOnlySafeExplicitAddressSubmissionOffersEarlyProxy() throws {
        let tab = makeTab()
        let target = URL(string: "https://192.0.2.1/address")!
        tab.load(target)
        XCTAssertNil(tab.pendingAddressNavigation)
        for raw in ["http://192.0.2.1/", "https://user:secret@192.0.2.1/", "https://192.0.2.1:8443/", "aegis://start"] {
            tab.loadFromAddressBar(URL(string: raw)!)
            XCTAssertNil(tab.pendingAddressNavigation, raw)
        }
        var post = URLRequest(url: target)
        post.httpMethod = "POST"
        post.httpBody = Data("private".utf8)
        tab.load(post)
        XCTAssertNil(tab.pendingAddressNavigation)
    }

    func testPendingAddressRedirectChangesVisibleTargetAndRequiresANewClick() throws {
        let coordinator = AccessHostStoreCoordinator()
        let tab = makeTab()
        tab.hostCoordinator = coordinator
        tab.loadFromAddressBar(URL(string: "https://192.0.2.1/old")!)
        let old = try XCTUnwrap(tab.pendingAddressNavigation)
        let redirected = URL(string: "https://192.0.2.2/actual")!
        tab.adoptPolicyMainFrameNavigationForTests(url: redirected, continuesExistingNavigation: true)
        let current = try XCTUnwrap(tab.pendingAddressNavigation)
        XCTAssertEqual(current.url, redirected)
        XCTAssertFalse(tab.matchesPendingAddressNavigation(old))
        XCTAssertTrue(tab.matchesPendingAddressNavigation(current))
        XCTAssertNil(coordinator.openPendingAddressViaProxy(tab: tab, pending: old))
        XCTAssertEqual(tab.recoveryLoadCount, 0)
        XCTAssertNil(coordinator.snapshot(for: tab).host)
        tab.adoptPolicyMainFrameNavigationForTests(url: redirected, continuesExistingNavigation: true, hasReplayableBody: true)
        XCTAssertNil(tab.pendingAddressNavigation)
        XCTAssertNil(coordinator.openPendingAddressViaProxy(tab: tab, pending: current))
    }

    func testStopSupersedeCommitAndFailureRetireThePendingAddressChoice() throws {
        let tab = makeTab()
        let target = URL(string: "https://192.0.2.1/address")!
        tab.loadFromAddressBar(target)
        let first = try XCTUnwrap(tab.pendingAddressNavigation)
        tab.stop()
        XCTAssertNil(tab.pendingAddressNavigation)
        XCTAssertFalse(tab.matchesPendingAddressNavigation(first))
        tab.loadFromAddressBar(target)
        let second = try XCTUnwrap(tab.pendingAddressNavigation)
        tab.loadFromAddressBar(URL(string: "https://192.0.2.1/new")!)
        XCTAssertFalse(tab.matchesPendingAddressNavigation(second))
        tab.commitPendingMainFrameForTests()
        XCTAssertNil(tab.pendingAddressNavigation)
        tab.loadFromAddressBar(target)
        deliver(tab)
        XCTAssertNil(tab.pendingAddressNavigation)
        XCTAssertNotNil(tab.lastMainFrameFailure)
        XCTAssertTrue(tab.loadingErrorAllowsProxyRetry)
    }

    func testExplicitPendingAddressChoicePreparesManagedEntryAndSendsOnce() async throws {
        let publisher = AccessProxyEntryPublisher { generation, _ in
            AccessProxyEntryPublisher.Provision(
                endpoint: AccessManagedProxyEndpoint(identity: "address-entry", generation: generation,
                    loopbackHost: "127.0.0.1", port: 18_081, state: .ready),
                listenerReady: true, runtimeHealthy: true, bridgeInstalled: true)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessManualPreparationClock())
        let tab = makeTab()
        tab.hostCoordinator = coordinator
        let host = try AccessSiteHost("192.0.2.1")
        coordinator.setProxyEnabled(false, host: host, scopeID: tab.browsingScopeID, isPrivate: false)
        let originalStore = tab.websiteDataStore
        XCTAssertTrue(originalStore.proxyConfigurations.isEmpty)
        tab.loadFromAddressBar(URL(string: "https://192.0.2.1/address")!)
        let pending = try XCTUnwrap(tab.pendingAddressNavigation)
        XCTAssertEqual(publisher.provisionCount, 0)
        let first = coordinator.openPendingAddressViaProxy(tab: tab, pending: pending)
        XCTAssertNotNil(first)
        XCTAssertEqual(coordinator.openPendingAddressViaProxy(tab: tab, pending: pending), first)
        XCTAssertTrue(coordinator.isPreparingAddressProxy(tab: tab))
        await waitUntil { tab.recoveryLoadCount == 1 }
        XCTAssertEqual(tab.recoveryLoadCount, 1)
        XCTAssertEqual(publisher.provisionCount, 1)
        XCTAssertEqual(tab.boundHostName, "192.0.2.1")
        let managedStore = tab.websiteDataStore
        XCTAssertFalse(managedStore === originalStore)
        XCTAssertTrue(tab.webView.configuration.websiteDataStore === managedStore)
        XCTAssertFalse(managedStore.proxyConfigurations.isEmpty)
        XCTAssertFalse(try XCTUnwrap(managedStore.proxyConfigurations.first).allowFailover)
        XCTAssertTrue(coordinator.dataStoreForMainFrame(tab: tab, url: URL(string: "https://192.0.2.1/redirected")!) === managedStore)
        XCTAssertNil(tab.pendingAddressNavigation)
        XCTAssertNil(tab.lastMainFrameFailure)
        XCTAssertNil(coordinator.openPendingAddressViaProxy(tab: tab, pending: pending))
    }

    func testPendingPreparationCannotSendAfterStopSupersedeCommitOrClose() async throws {
        for action in ["stop", "supersede", "commit", "close", "redirect"] {
            var release: CheckedContinuation<AccessProxyEntryPublisher.Provision, Never>?
            let publisher = AccessProxyEntryPublisher { _, _ in
                await withCheckedContinuation { release = $0 }
            }
            let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessManualPreparationClock())
            let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
            let tab = try XCTUnwrap(browser.activeTab)
            tab.hostCoordinator = coordinator
            tab.loadFromAddressBar(URL(string: "https://192.0.2.1/old")!)
            let pending = try XCTUnwrap(tab.pendingAddressNavigation)
            XCTAssertNotNil(coordinator.openPendingAddressViaProxy(tab: tab, pending: pending))
            await waitUntil { release != nil }
            let continuation = try XCTUnwrap(release)
            switch action {
            case "stop": tab.stop()
            case "supersede": tab.loadFromAddressBar(URL(string: "https://192.0.2.1/new")!)
            case "commit": tab.commitPendingMainFrameForTests()
            case "close": browser.close(tab.id)
            default: tab.adoptPolicyMainFrameNavigationForTests(url: URL(string: "https://192.0.2.2/actual")!, continuesExistingNavigation: true)
            }
            XCTAssertFalse(coordinator.isPreparingAddressProxy(tab: tab), action)
            continuation.resume(returning: AccessProxyEntryPublisher.Provision(
                endpoint: AccessManagedProxyEndpoint(identity: "late-entry", generation: 1,
                    loopbackHost: "127.0.0.1", port: 18_081, state: .ready),
                listenerReady: true, runtimeHealthy: true, bridgeInstalled: true))
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(tab.recoveryLoadCount, 0, action)
            XCTAssertNil(coordinator.registry.endpoint(scopeID: "ordinary", host: try AccessSiteHost("192.0.2.1"), isPrivate: false), action)
            browser.standardTabs.forEach { $0.stop() }
        }
    }

    func testPrivatePendingChoiceDoesNotAuthorizeOrdinaryScopeOrSiblingTab() async throws {
        let publisher = AccessProxyEntryPublisher { generation, _ in
            AccessProxyEntryPublisher.Provision(
                endpoint: AccessManagedProxyEndpoint(identity: "private-address-entry", generation: generation,
                    loopbackHost: "127.0.0.1", port: 18_081, state: .ready),
                listenerReady: true, runtimeHealthy: true, bridgeInstalled: true)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessManualPreparationClock())
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer {
            browser.standardTabs.forEach { $0.stop() }
            browser.privateTabs.forEach { $0.stop() }
        }
        let ordinary = try XCTUnwrap(browser.activeTab)
        ordinary.hostCoordinator = coordinator
        browser.switchProfile(to: .privateMode)
        let privateTab = try XCTUnwrap(browser.activeTab)
        privateTab.hostCoordinator = coordinator
        privateTab.loadFromAddressBar(URL(string: "https://192.0.2.1/private")!)
        let pending = try XCTUnwrap(privateTab.pendingAddressNavigation)
        XCTAssertNil(coordinator.openPendingAddressViaProxy(tab: ordinary, pending: pending))
        XCTAssertNotNil(coordinator.openPendingAddressViaProxy(tab: privateTab, pending: pending))
        await waitUntil { privateTab.recoveryLoadCount == 1 }
        XCTAssertEqual(privateTab.recoveryLoadCount, 1)
        XCTAssertTrue(privateTab.profile.isPrivate)
        let host = try AccessSiteHost("192.0.2.1")
        XCTAssertNotNil(coordinator.registry.endpoint(scopeID: privateTab.browsingScopeID, host: host, isPrivate: true))
        XCTAssertNil(coordinator.registry.endpoint(scopeID: "ordinary", host: host, isPrivate: false))
        XCTAssertFalse(privateTab.websiteDataStore === privateTab.originalWebsiteDataStore)
        XCTAssertTrue(privateTab.webView.configuration.websiteDataStore === privateTab.websiteDataStore)
        XCTAssertFalse(privateTab.websiteDataStore.isPersistent)
        XCTAssertFalse(privateTab.websiteDataStore.proxyConfigurations.isEmpty)
        XCTAssertFalse(try XCTUnwrap(privateTab.websiteDataStore.proxyConfigurations.first).allowFailover)
        XCTAssertEqual(ordinary.recoveryLoadCount, 0)
        XCTAssertTrue(ordinary.websiteDataStore === ordinary.originalWebsiteDataStore)
    }

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

        // A store replacement now waits for the old document's terminal receipt.
        await waitUntil { tab.currentNavigationForTests != nil }
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
        XCTAssertNil(tab.lastMainFrameFailure)
        XCTAssertEqual(tab.requestedURL, getURL)
        XCTAssertTrue(tab.isLoading)
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
        // The new GET retains its own retry eligibility after the old POST fails.
        tab.webView(tab.webView, didFailProvisionalNavigation: nil, withError: postError)
        XCTAssertEqual(tab.lastMainFrameFailure?.url, getURL)
        XCTAssertEqual(tab.lastMainFrameFailure?.method, "GET")
        XCTAssertTrue(tab.loadingErrorAllowsProxyRetry)
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

    func testRetryIssuesADocumentLoadForTheFailedNavigation() async throws {
        let tab = makeTab()
        var request = URLRequest(url: URL(string: "https://example.invalid/a")!)
        request.httpMethod = "GET"
        tab.load(request)
        deliver(tab)
        let failure = try XCTUnwrap(tab.lastMainFrameFailure)
        XCTAssertTrue(tab.retryFailedNavigation(
            request,
            expectedNavigationID: failure.navigationID,
            recoveryOperationID: UUID()
        ))
        await waitUntil { tab.currentNavigationForTests != nil }
        XCTAssertNotNil(tab.currentNavigationForTests)
        XCTAssertNil(tab.lastMainFrameFailure)
    }

    func testOlderProvisionalCancelDoesNotAbortANewerDeferredLoad() async throws {
        let tab = makeTab()
        tab.load(URLRequest(url: URL(string: "https://shop.example/a")!))
        await waitUntil { tab.currentNavigationForTests != nil }
        let first = try XCTUnwrap(tab.currentNavigationForTests)
        tab.load(URLRequest(url: URL(string: "https://shop.example/b")!))
        tab.webView(
            tab.webView,
            didFailProvisionalNavigation: first,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        )
        await waitUntil { tab.currentNavigationForTests != nil && tab.currentNavigationForTests !== first }
        XCTAssertNotEqual(tab.currentNavigationForTests, first)
    }

    func testProductionCoordinatorPreservesApprovedActionsUntilTheirStarts() throws {
        let tab = makeTab()
        let coordinator = AccessHostStoreCoordinator()
        tab.hostCoordinator = coordinator
        // WKNavigation.init does not create WebKit's backing object. Use identities
        // returned by real loads, with callbacks driven explicitly in this test.
        tab.webView.navigationDelegate = nil
        let first = try XCTUnwrap(tab.webView.loadHTMLString("<html>A</html>", baseURL: nil))
        let second = try XCTUnwrap(tab.webView.loadHTMLString("<html>B</html>", baseURL: nil))
        tab.webView.navigationDelegate = tab
        tab.adoptPolicyMainFrameNavigationForTests(url: URL(string: "https://shop.example/a")!)
        tab.adoptPolicyMainFrameNavigationForTests(url: URL(string: "https://shop.example/b")!, method: "POST")
        tab.webView(tab.webView, didStartProvisionalNavigation: first)
        tab.webView(tab.webView, didStartProvisionalNavigation: second)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        tab.webView(tab.webView, didFailProvisionalNavigation: first, withError: error)
        XCTAssertNil(tab.lastMainFrameFailure)
        XCTAssertTrue(tab.isLoading)
        tab.webView(tab.webView, didFailProvisionalNavigation: second, withError: error)
        XCTAssertEqual(tab.lastMainFrameFailure?.url.path, "/b")
        XCTAssertEqual(tab.lastMainFrameFailure?.method, "POST")
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
        XCTAssertEqual(tab.recoveryLoadCount, 0)
    }

    func testProductionCoordinatorDoesNotGiveAnAmbiguousNilFailureTheNewestURL() {
        let tab = makeTab()
        let coordinator = AccessHostStoreCoordinator()
        tab.hostCoordinator = coordinator
        tab.adoptPolicyMainFrameNavigationForTests(url: URL(string: "https://shop.example/a")!, method: "POST")
        tab.adoptPolicyMainFrameNavigationForTests(url: URL(string: "https://shop.example/b")!)
        tab.webView(tab.webView, didFailProvisionalNavigation: nil, withError: NSError(
            domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost
        ))
        XCTAssertNil(tab.lastMainFrameFailure)
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
        XCTAssertNotNil(tab.loadingError)
        XCTAssertEqual(tab.recoveryLoadCount, 0)
    }

    func testIdenticalPageActionsStillRequireDistinctCallbackOwners() {
        let tab = makeTab()
        let coordinator = AccessHostStoreCoordinator()
        tab.hostCoordinator = coordinator
        let url = URL(string: "https://shop.example/repeated")!
        tab.adoptPolicyMainFrameNavigationForTests(url: url)
        tab.adoptPolicyMainFrameNavigationForTests(url: url)
        tab.webView(tab.webView, didFailProvisionalNavigation: nil, withError: NSError(
            domain: NSURLErrorDomain, code: NSURLErrorTimedOut
        ))
        XCTAssertNil(tab.lastMainFrameFailure)
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
    }

    func testOlderFinishDoesNotCancelNewerDeferredLoadWithProductionCoordinator() async throws {
        let tab = makeTab()
        let coordinator = AccessHostStoreCoordinator()
        tab.hostCoordinator = coordinator
        tab.load(URLRequest(url: URL(string: "https://shop.example/a")!))
        await waitUntil { tab.currentNavigationForTests != nil }
        let first = try XCTUnwrap(tab.currentNavigationForTests)
        tab.load(URLRequest(url: URL(string: "https://shop.example/b")!))
        tab.webView(tab.webView, didFinish: first)
        await waitUntil { tab.currentNavigationForTests != nil && tab.currentNavigationForTests !== first }
        XCTAssertNotNil(tab.currentNavigationForTests)
        XCTAssertNotEqual(tab.currentNavigationForTests, first)
        XCTAssertTrue(tab.isLoading)
    }

    func testOlderFailureCannotReplaceANewerFinishedPage() async throws {
        let tab = makeTab()
        let coordinator = AccessHostStoreCoordinator()
        tab.hostCoordinator = coordinator
        tab.load(URLRequest(url: URL(string: "https://shop.example/a")!))
        await waitUntil { tab.currentNavigationForTests != nil }
        let first = try XCTUnwrap(tab.currentNavigationForTests)
        tab.load(URLRequest(url: URL(string: "https://shop.example/b")!))
        await waitUntil { tab.currentNavigationForTests != nil && tab.currentNavigationForTests !== first }
        let second = try XCTUnwrap(tab.currentNavigationForTests)
        tab.webView(tab.webView, didCommit: second)
        tab.webView(tab.webView, didFinish: second)
        tab.webView(tab.webView, didFailProvisionalNavigation: first, withError: NSError(
            domain: NSURLErrorDomain, code: NSURLErrorTimedOut
        ))
        XCTAssertEqual(tab.committedMainFrameURL?.path, "/b")
        XCTAssertNil(tab.lastMainFrameFailure)
        XCTAssertNil(tab.loadingError)
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
        XCTAssertFalse(tab.isLoading)
        XCTAssertEqual(tab.recoveryLoadCount, 0)
    }

    func testFirstURLLoadThroughDedicatedStoreSurvivesColdContentRules() async throws {
        let tab = makeTab()
        let coordinator = AccessHostStoreCoordinator()
        tab.hostCoordinator = coordinator
        let host = try AccessSiteHost("shop.example")
        coordinator.registry.setEndpoint(readyEndpoint(), scopeID: "ordinary", host: host, isPrivate: false)
        coordinator.setProxyEnabled(true, host: host, scopeID: "ordinary", isPrivate: false)
        let original = tab.websiteDataStore
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        tab.load(URL(string: "https://shop.example/first")!)
        XCTAssertFalse(tab.websiteDataStore === original)
        tab.webView.frame = window.bounds
        window.rootViewController?.view.addSubview(tab.webView)
        await waitUntil({ tab.currentNavigationForTests != nil || tab.loadingError != nil }, timeout: 10)
        XCTAssertNotNil(tab.currentNavigationForTests, tab.loadingError ?? "cold load never issued")
    }

    private func attachPage(_ tab: BrowserTab, at url: URL) async throws -> UIWindow {
        try await tab.prepareContentRulesForTests()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        tab.webView.frame = window.bounds
        window.rootViewController?.view.addSubview(tab.webView)
        tab.load(url)
        await waitUntil({ tab.committedMainFrameURL == url && !tab.isLoading }, timeout: 10)
        XCTAssertEqual(tab.committedMainFrameURL, url)
        return window
    }

    func testLinkAndFormServerRedirectsKeepTheStartedNavigation() async throws {
        for (status, submit, fails) in [(307, false, false), (308, true, false), (307, true, true), (308, true, true)] {
            let origin = try PreservingRedirectOrigin(status: status, finishRedirect: !fails)
            defer { origin.stop() }
            let page = try await origin.redirectURL().deletingLastPathComponent().appendingPathComponent("page")
            let tab = makeTab()
            let window = try await attachPage(tab, at: page)
            defer { window.isHidden = true }
            let trace = PageNavigationTrace(tab)
            tab.webView.navigationDelegate = trace
            defer { tab.webView.navigationDelegate = tab }
            let script = submit ? "document.forms[0].requestSubmit()" : "document.querySelector('a').click()"
            _ = try await tab.webView.evaluateJavaScript(script)
            await waitUntil({ origin.redirectedMethod != nil && trace.redirect != nil }, timeout: 10)
            let started = try XCTUnwrap(trace.started)
            XCTAssertTrue(started === trace.redirect)
            XCTAssertEqual(trace.firstType, submit ? .formSubmitted : .linkActivated)
            XCTAssertEqual(origin.redirectedMethod, submit ? "POST" : "GET")
            if submit {
                XCTAssertEqual(origin.redirectedBody, "item=one")
            }
            if fails {
                tab.webView(tab.webView, didFailProvisionalNavigation: started, withError: NSError(
                    domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
                XCTAssertEqual(tab.lastMainFrameFailure?.url.path, "/kept")
                XCTAssertEqual(tab.lastMainFrameFailure?.method, "POST")
                XCTAssertEqual(tab.lastMainFrameFailure?.navigationID, trace.startedAttemptID)
                XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
            } else {
                await waitUntil({ trace.finished != nil && !tab.isLoading }, timeout: 10)
                XCTAssertTrue(started === trace.finished)
                XCTAssertEqual(tab.committedMainFrameURL?.path, "/kept")
                XCTAssertEqual(tab.currentAttemptIDForTests, trace.startedAttemptID)
            }
            XCTAssertFalse(tab.isLoading)
        }
    }

    func testSameSiteHistoryReachesBothItemsAndRefreshesControls() async throws {
        let origin = try PreservingRedirectOrigin(status: 307)
        defer { origin.stop() }
        let root = try await origin.redirectURL().deletingLastPathComponent()
        let first = root.appendingPathComponent("page")
        let second = root.appendingPathComponent("next")
        let tab = makeTab()
        let window = try await attachPage(tab, at: first)
        defer { window.isHidden = true }
        tab.load(second)
        await waitUntil({ tab.committedMainFrameURL == second && !tab.isLoading }, timeout: 10)
        XCTAssertTrue(tab.canGoBack)
        let trace = PageNavigationTrace(tab)
        tab.webView.navigationDelegate = trace
        defer { tab.webView.navigationDelegate = tab }
        for destination in [first, second] {
            trace.finished = nil
            if destination == first { tab.goBack() } else { tab.goForward() }
            let issued = try XCTUnwrap(tab.currentNavigationForTests)
            let identity = tab.currentAttemptIDForTests
            await waitUntil({ trace.finished != nil && !tab.isLoading }, timeout: 10)
            XCTAssertTrue(issued === trace.finished)
            XCTAssertEqual(tab.currentAttemptIDForTests, identity)
            XCTAssertNil(tab.currentNavigationForTests)
            XCTAssertFalse(tab.isLoading)
            XCTAssertEqual(tab.committedMainFrameURL, destination)
            XCTAssertEqual(tab.url, destination)
            XCTAssertEqual(tab.canGoBack, destination == second)
            XCTAssertEqual(tab.canGoForward, destination == first)
        }
    }

    func testReal307308And303RedirectsNeverInventSafePostReplay() async throws {
        for status in [307, 308, 303] {
            let origin = try PreservingRedirectOrigin(status: status)
            defer { origin.stop() }
            let tab = makeTab()
            let coordinator = AccessHostStoreCoordinator()
            tab.hostCoordinator = coordinator
            try await tab.prepareContentRulesForTests()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = UIViewController()
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            tab.webView.frame = window.bounds
            window.rootViewController?.view.addSubview(tab.webView)
            var request = URLRequest(url: try await origin.redirectURL())
            request.httpMethod = "POST"
            tab.load(request)
            await waitUntil({ origin.redirectedMethod != nil }, timeout: 10)
            XCTAssertEqual(origin.redirectedMethod, status == 303 ? "GET" : "POST", "HTTP \(status)")
            let navigation = try XCTUnwrap(tab.currentNavigationForTests)
            tab.webView(tab.webView, didFailProvisionalNavigation: navigation, withError: NSError(
                domain: NSURLErrorDomain, code: NSURLErrorTimedOut
            ))
            XCTAssertEqual(tab.lastMainFrameFailure?.method, "POST", "HTTP \(status)")
            XCTAssertFalse(tab.loadingErrorAllowsProxyRetry, "HTTP \(status)")
            XCTAssertEqual(tab.recoveryLoadCount, 0)
            tab.stop()
        }
    }
}

// Interpose only the observed callbacks; the product delegate still handles each decision.
@MainActor
private final class PageNavigationTrace: NSObject, WKNavigationDelegate {
    let tab: BrowserTab
    var firstType: WKNavigationType?
    var started: WKNavigation?
    var redirect: WKNavigation?
    var finished: WKNavigation?
    var startedAttemptID: String?
    init(_ tab: BrowserTab) { self.tab = tab }

    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        firstType = firstType ?? action.navigationType
        print("WK policy type=\(action.navigationType.rawValue) \(action.request.httpMethod ?? "?") \(action.request.url?.path ?? "?")")
        tab.webView(view, decidePolicyFor: action, preferences: preferences, decisionHandler: decisionHandler)
    }
    func webView(_ view: WKWebView, didStartProvisionalNavigation nav: WKNavigation!) {
        started = nav
        tab.webView(view, didStartProvisionalNavigation: nav)
        startedAttemptID = tab.currentAttemptIDForTests
        print("WK start \(ObjectIdentifier(nav))")
    }
    func webView(_ view: WKWebView, didReceiveServerRedirectForProvisionalNavigation nav: WKNavigation!) {
        redirect = nav
        print("WK redirect \(ObjectIdentifier(nav))")
        tab.webView(view, didReceiveServerRedirectForProvisionalNavigation: nav)
    }
    func webView(_ view: WKWebView, didCommit nav: WKNavigation!) {
        print("WK commit \(ObjectIdentifier(nav))")
        tab.webView(view, didCommit: nav)
    }
    func webView(_ view: WKWebView, didFinish nav: WKNavigation!) {
        finished = nav
        print("WK finish \(ObjectIdentifier(nav))")
        tab.webView(view, didFinish: nav)
    }
}

private final class PreservingRedirectOrigin: @unchecked Sendable {
    private let listener: NWListener
    private let status: Int
    private let finishRedirect: Bool
    private let request = Mutex<(String, String)?>(nil)
    private let connections = Mutex<[NWConnection]>([])
    var redirectedMethod: String? { request.withLock { $0?.0 } }

    var redirectedBody: String? { request.withLock { $0?.1 } }

    init(status: Int, finishRedirect: Bool = false) throws {
        self.finishRedirect = finishRedirect
        self.status = status
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: DispatchQueue(label: "aegis.tests.preserving-redirect"))
    }

    func redirectURL() async throws -> URL {
        let deadline = Date().addingTimeInterval(3)
        while (listener.port?.rawValue ?? 0) == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let port = try XCTUnwrap(listener.port)
        XCTAssertGreaterThan(port.rawValue, 0)
        return try XCTUnwrap(URL(string: "http://127.0.0.1:\(port.rawValue)/redirect"))
    }

    private func accept(_ connection: NWConnection) {
        connections.withLock { $0.append(connection) }
        connection.start(queue: DispatchQueue(label: "aegis.tests.redirect-connection"))
        receive(connection, buffered: Data())
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else { return }
            let bytes = buffered + data
            guard bytes.count < 65_536 else { connection.cancel(); return }
            let text = String(decoding: bytes, as: UTF8.self)
            guard let split = text.range(of: "\r\n\r\n") else { self.receive(connection, buffered: bytes); return }
            let headers = text[..<split.lowerBound].components(separatedBy: "\r\n")
            let body = String(text[split.upperBound...])
            let length = headers.first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
            guard body.utf8.count >= length else { self.receive(connection, buffered: bytes); return }
            let first = headers[0].split(separator: " ")
            guard first.count >= 2 else { return }
            let response: String
            if first[1] == "/redirect", let port = self.listener.port {
                response = "HTTP/1.1 \(self.status) Redirect\r\nLocation: http://127.0.0.1:\(port.rawValue)/kept\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            } else {
                if first[1] == "/kept" {
                    self.request.withLock { $0 = (String(first[0]), body) }
                    guard self.finishRedirect else { return }
                }
                let html = "<a href='/redirect'>link</a><form action='/redirect' method='post'><input name='item' value='one'></form>"
                response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html
            }
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() {
        listener.cancel()
        connections.withLock { active in
            active.forEach { $0.cancel() }
            active.removeAll()
        }
    }
}
