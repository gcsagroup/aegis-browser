import AccessKit
import Network
import os
import UIKit
import WebKit
import XCTest
@testable import Aegis
@testable import BrowserKit

/// Failed page reloads through the app HTTP CONNECT listener, not a test-only proxy socket.
@MainActor
final class AccessHostRecoveryWebKitTests: XCTestCase {
    func testExplicitOnCannotSendToOriginWhilePreparationFails() async throws {
        let origin = OriginReceipt(port: 18_274)
        try await origin.start()
        defer { origin.stop() }
        let publisher = AccessProxyEntryPublisher { _, _ in throw AccessSiteSessionError.nodeUnavailable }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        browser.hostCoordinator = coordinator
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        let window = show(tab.webView)
        defer { window.isHidden = true }
        let host = try AccessSiteHost("127.0.0.1")
        coordinator.setProxyEnabled(true, host: host, scopeID: tab.browsingScopeID, isPrivate: false)
        tab.load(URL(string: "http://127.0.0.1:18274/must-not-be-direct")!)
        try await waitUntil { tab.loadingError != nil }
        XCTAssertTrue(origin.transcript.isEmpty)
        XCTAssertTrue(tab.loadingErrorAllowsProxyRetry)
        XCTAssertNil(tab.boundHostName)
        coordinator.setSiteProxyEnabled(false, for: tab, displayedHost: host)
        try await waitUntil {
            self.attach(tab.webView, to: window)
            return origin.transcript.contains("GET /must-not-be-direct ")
        }
    }

    func testExplicitSiteRoutesShareEntryAndTurningOneOffKeepsTheOtherProxied() async throws {
        let opener = AnsweringOpener(finishAfterRecording: true)
        let listener = try await makeListener(port: 18_273, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let publisher = readyPublisher(port: 18_273)
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, channel: .alpha)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        browser.hostCoordinator = coordinator
        defer { browser.closeWindow() }
        let a = try XCTUnwrap(browser.activeTab)
        let b = browser.newTab()
        try await a.prepareContentRulesForTests()
        try await b.prepareContentRulesForTests()
        let wa = show(a.webView), wb = show(b.webView)
        defer { wa.isHidden = true; wb.isHidden = true }
        let ha = try AccessSiteHost("site-a.invalid"), hb = try AccessSiteHost("site-b.invalid")
        for host in [ha, hb] {
            coordinator.setProxyEnabled(true, host: host, scopeID: a.browsingScopeID, isPrivate: false)
        }
        let ua = URL(string: "https://site-a.invalid/first")!
        a.load(ua)
        b.load(URL(string: "https://site-b.invalid/first")!)
        try await waitUntil(seconds: 10, {
            self.attach(a.webView, to: wa); self.attach(b.webView, to: wb)
            return opener.authorities.contains("site-a.invalid:443") && opener.authorities.contains("site-b.invalid:443")
        }, message: "\(opener.authorities)")
        XCTAssertEqual(publisher.provisionCount, 1)
        XCTAssertEqual(a.boundHostName, ha.rawValue)
        XCTAssertEqual(b.boundHostName, hb.rawValue)
        let bStore = b.websiteDataStore
        // The fixture proves real CONNECT routing but cannot commit a TLS page.
        // Supply only the trusted control host; actual document rendering and
        // the visible switch are covered by the opt-in real-node UI test.
        a.commitPendingMainFrameForTests()
        b.commitPendingMainFrameForTests()
        _ = coordinator.setAutoRecoveryEnabled(true, for: a)
        coordinator.setSiteProxyEnabled(false, for: a, displayedHost: ha)
        a.load(URL(string: "https://site-a.invalid:444/after-off")!)
        b.stop()
        b.load(URLRequest(url: URL(string: "https://site-b.invalid:444/still-on")!))
        try await waitUntil(seconds: 10, {
            self.attach(a.webView, to: wa); self.attach(b.webView, to: wb)
            return opener.authorities.contains("site-b.invalid:444")
        }, message: "\(opener.authorities) loading=\(b.isLoading) error=\(b.loadingError ?? "none") bound=\(b.boundHostName ?? "none")")
        XCTAssertFalse(opener.authorities.contains("site-a.invalid:444"))
        XCTAssertTrue(a.websiteDataStore === a.originalWebsiteDataStore)
        XCTAssertNil(a.boundHostName)
        XCTAssertTrue(b.websiteDataStore === bStore)
        XCTAssertTrue(listener.isListening)
        XCTAssertFalse(coordinator.requiresProxy(tab: a, url: ua))
        browser.closeWindow()
        try await waitUntil {
            coordinator.releaseIdleResources()
            return publisher.currentEndpoint == nil
        }
        XCTAssertNil(publisher.currentEndpoint)
    }

    func testFirstPendingAddressChoiceFromOffUsesManagedWebViewAndConnectListener() async throws {
        let opener = AnsweringOpener()
        let listener = try await makeListener(port: 18_271, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let coordinator = AccessHostStoreCoordinator(publisher: readyPublisher(port: 18_271))
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        tab.hostCoordinator = coordinator
        try await tab.prepareContentRulesForTests()
        let host = try AccessSiteHost("pending-address.invalid")
        coordinator.setProxyEnabled(false, host: host, scopeID: tab.browsingScopeID, isPrivate: false)
        let originalView = tab.webView
        let originalStore = tab.websiteDataStore
        XCTAssertTrue(originalStore.proxyConfigurations.isEmpty)
        let window = show(originalView)
        defer { window.isHidden = true }
        let target = URL(string: "https://pending-address.invalid/address")!
        tab.loadFromAddressBar(target)
        let pending = try XCTUnwrap(tab.pendingAddressNavigation)
        XCTAssertNotNil(coordinator.openPendingAddressViaProxy(tab: tab, pending: pending))
        try await waitUntil(seconds: 10, {
            self.attach(tab.webView, to: window)
            return opener.authorities.contains("pending-address.invalid:443")
        }, message: "authorities=\(opener.authorities) bound=\(tab.boundHostName ?? "nil") error=\(coordinator.lastRecoveryFailure ?? "nil")")
        let managed = tab.websiteDataStore
        XCTAssertFalse(tab.webView === originalView)
        XCTAssertFalse(managed === originalStore)
        XCTAssertTrue(tab.webView.configuration.websiteDataStore === managed)
        XCTAssertEqual(tab.boundHostName, host.rawValue)
        XCTAssertFalse(managed.proxyConfigurations.isEmpty)
        XCTAssertFalse(try XCTUnwrap(managed.proxyConfigurations.first).allowFailover)
        // This fixture records the real CONNECT route. It does not issue a
        // trusted TLS certificate or claim successful HTTPS document rendering.
        // The HTTP fixture cannot complete a TLS handshake. End that load and
        // use a distinct origin on the same host, so connection reuse cannot
        // masquerade as either a missing route or a second proxy connection.
        tab.stop()
        tab.load(URL(string: "https://pending-address.invalid:444/next")!)
        try await waitUntil(seconds: 10, {
            self.attach(tab.webView, to: window)
            return opener.authorities.contains("pending-address.invalid:444")
        }, message: "distinct same-host origin must retain the managed route: \(opener.authorities)")
        XCTAssertTrue(tab.websiteDataStore === managed)
        XCTAssertEqual(tab.boundHostName, host.rawValue)
        XCTAssertNil(coordinator.dataStoreForMainFrame(tab: tab, url: URL(string: "https://unrelated.invalid/")!))
    }

    func testPaidDownloadSelectionFollowsDisplayedSiteAfterFailedCrossHostNavigation() async throws {
        let first = OriginReceipt(port: 18_267)
        let second = OriginReceipt(port: 18_268)
        try await first.start()
        defer { first.stop() }
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.closeWindow() }
        let coordinator = AccessHostStoreCoordinator()
        browser.hostCoordinator = coordinator
        let panel = AccessSiteProxySessionStore()
        panel.hostRouting = coordinator
        let account = AccessAccountSession(client: nil, keychain: .init(service: UUID().uuidString))
        let tab = try XCTUnwrap(browser.activeTab)
        let window = show(tab.webView)
        defer { window.isHidden = true }
        let a = URL(string: "http://127.0.0.1:\(first.port)/first")!
        let b = URL(string: "http://localhost:\(second.port)/second")!
        tab.load(a)
        try await waitUntil({ tab.committedMainFrameURL == a && !tab.isLoading }, message: "A must commit")
        tab.load(b)
        try await waitUntil({ tab.lastMainFrameFailure?.url == b }, message: "B must fail before its origin starts")
        XCTAssertEqual(tab.committedMainFrameURL, a)
        XCTAssertEqual(panel.snapshot(for: tab).host?.rawValue, b.host)
        XCTAssertNil(panel.paidDownloadHost(for: tab))
        XCTAssertNil(panel.setProxyEnabled(true, for: tab, account: account))
        XCTAssertNil(tab.selectedAccessHost)

        try await second.start()
        defer { second.stop() }
        tab.load(b)
        try await waitUntil({ tab.committedMainFrameURL == b && !tab.isLoading }, message: "B must commit after retry")
        XCTAssertEqual(panel.snapshot(for: tab).host?.rawValue, b.host)
        let activeHost = try XCTUnwrap(panel.paidDownloadHost(for: tab))
        XCTAssertNil(panel.setProxyEnabled(true, for: tab, account: account, displayedHost: try AccessSiteHost("127.0.0.1")))
        XCTAssertNotNil(panel.setProxyEnabled(true, for: tab, account: account, displayedHost: activeHost))
        XCTAssertEqual(tab.selectedAccessHost, b.host)
        tab.onDownload?(b.appendingPathComponent("file"))
        XCTAssertEqual(browser.pendingAccessDownload?.host, b.host)
    }

    func testFailedPageReloadsOnceThroughTheListener() async throws {
        let nonce = UUID().uuidString
        let opener = AnsweringOpener()
        let listener = try await makeListener(port: 18_240, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let publisher = readyPublisher(port: 18_240)
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessContinuousPreparationClock())
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.standardTabs.forEach { $0.stop() } }
        let tab = try XCTUnwrap(browser.activeTab)
        tab.hostCoordinator = coordinator
        let window = show(tab.webView)
        defer { window.isHidden = true }

        var request = URLRequest(url: URL(string: "http://example.invalid/page?n=\(nonce)")!)
        request.httpMethod = "GET"
        let sink = NavigationSink()
        tab.load(request)
        tab.webView.navigationDelegate = sink
        tab.webView.stopLoading()
        deliverFailure(tab)
        XCTAssertTrue(tab.loadingErrorAllowsProxyRetry)
        let operation = coordinator.retryViaProxy(tab: tab)
        XCTAssertNotNil(operation)
        let deadline = Date().addingTimeInterval(15)
        while !(opener.transcript.contains(nonce) && opener.transcript.contains("cdn.invalid")), Date() < deadline {
            if tab.webView.superview == nil {
                tab.webView.frame = window.bounds
                window.addSubview(tab.webView)
                window.makeKeyAndVisible()
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(tab.recoveryLoadCount, 1, coordinator.lastRecoveryFailure ?? opener.transcript)
        XCTAssertTrue(opener.transcript.contains(nonce), "admission=\(listener.admissionSummary) body=\(opener.transcript)")
        XCTAssertTrue(opener.transcript.contains("cdn.invalid"), opener.transcript)
    }

    func testUnreadyTabKeepsTheOriginalStore() async throws {
        let opener = AnsweringOpener()
        let listener = try await makeListener(port: 18_244, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let publisher = AccessProxyEntryPublisher { _, _ in
            throw AccessSiteSessionError.nodeUnavailable
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessContinuousPreparationClock())
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.standardTabs.forEach { $0.stop() } }
        let tab = try XCTUnwrap(browser.activeTab)
        tab.hostCoordinator = coordinator
        let original = tab.websiteDataStore
        let window = show(tab.webView)
        defer { window.isHidden = true }
        tab.load(URLRequest(url: URL(string: "http://example.invalid/unready")!))
        tab.webView.navigationDelegate = NavigationSink()
        tab.webView.stopLoading()
        deliverFailure(tab)
        XCTAssertNotNil(coordinator.retryViaProxy(tab: tab))
        try await Task.sleep(for: .milliseconds(400))
        let host = try AccessSiteHost("example.invalid")
        XCTAssertNil(coordinator.registry.store(
            scopeID: "ordinary",
            host: host,
            isPrivate: false
        ))
        XCTAssertTrue(tab.websiteDataStore === original)
        XCTAssertEqual(tab.recoveryLoadCount, 0)
        XCTAssertFalse(opener.transcript.contains("example.invalid"))
        let snapshot = coordinator.snapshot(for: tab)
        XCTAssertTrue(snapshot.toggleOn)
        XCTAssertEqual(snapshot.attachment, .notAttached)
        XCTAssertEqual(
            AccessSiteProxyToggleModel.attachmentLine(for: snapshot.attachment, intent: snapshot.intent),
            "尚未接入代理，当前页面仍使用原连接"
        )
        XCTAssertNil(snapshot.failureReason)
    }

    func testHttpsReloadRecordsConnectAuthority() async throws {
        let opener = AnsweringOpener()
        let listener = try await makeListener(port: 18_245, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let publisher = readyPublisher(port: 18_245)
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessContinuousPreparationClock())
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.standardTabs.forEach { $0.stop() } }
        let tab = try XCTUnwrap(browser.activeTab)
        tab.hostCoordinator = coordinator
        let window = show(tab.webView)
        defer { window.isHidden = true }
        let sink = NavigationSink()
        tab.load(URLRequest(url: URL(string: "https://example.invalid/secure")!))
        tab.webView.navigationDelegate = sink
        tab.webView.stopLoading()
        deliverFailure(tab)
        XCTAssertNotNil(coordinator.retryViaProxy(tab: tab))
        let deadline = Date().addingTimeInterval(8)
        while !listener.admissionSummary.contains("example.invalid:443"), Date() < deadline {
            if tab.webView.superview == nil {
                tab.webView.frame = window.bounds
                window.addSubview(tab.webView)
                window.makeKeyAndVisible()
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(tab.recoveryLoadCount, 1)
        XCTAssertTrue(
            listener.admissionSummary.contains("example.invalid:443"),
            listener.admissionSummary
        )
        XCTAssertFalse(opener.transcript.contains("GET /secure"))
    }

    func testUnrelatedHostDoesNotEnterTheListener() async throws {
        let opener = AnsweringOpener()
        let listener = try await makeListener(port: 18_241, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.standardTabs.forEach { $0.stop() } }
        let tab = try XCTUnwrap(browser.activeTab)
        let window = show(tab.webView)
        defer { window.isHidden = true }
        tab.load(URLRequest(url: URL(string: "http://other.invalid/")!))
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(opener.transcript.contains("other.invalid"))
    }

    func testFailedEndpointKeepsTheProxyAndDisallowsDirectFailover() async throws {
        let opener = AnsweringOpener()
        let listener = try await makeListener(port: 18_242, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let publisher = readyPublisher(port: 18_242)
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessContinuousPreparationClock())
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.standardTabs.forEach { $0.stop() } }
        let tab = try XCTUnwrap(browser.activeTab)
        tab.hostCoordinator = coordinator
        let window = show(tab.webView)
        defer { window.isHidden = true }
        let sink = NavigationSink()
        tab.load(URLRequest(url: URL(string: "http://example.invalid/kept")!))
        tab.webView.navigationDelegate = sink
        tab.webView.stopLoading()
        deliverFailure(tab)
        XCTAssertTrue(tab.loadingErrorAllowsProxyRetry)
        _ = coordinator.retryViaProxy(tab: tab)
        try await waitUntil({
            if tab.webView.superview == nil {
                tab.webView.frame = window.bounds
                window.addSubview(tab.webView)
                window.makeKeyAndVisible()
            }
            return opener.transcript.contains("GET /kept")
        }, message: "proxy=\(opener.transcript) loads=\(tab.recoveryLoadCount) loading=\(tab.isLoading) failure=\(coordinator.lastRecoveryFailure ?? "") error=\(tab.loadingError ?? "")")
        let host = try AccessSiteHost("example.invalid")
        let store = try XCTUnwrap(coordinator.registry.storeForTab(
            tabID: tab.instanceID.uuidString,
            scopeID: "ordinary",
            isPrivate: false,
            targetHost: host,
            boundHost: host,
            intent: .on
        ))
        let before = store.proxyConfigurations.count
        coordinator.registry.setEndpoint(
            AccessManagedProxyEndpoint(
                identity: "entry-failed",
                generation: 9,
                loopbackHost: "127.0.0.1",
                port: 18_242,
                state: .failed
            ),
            scopeID: "ordinary",
            host: host,
            isPrivate: false
        )
        let nonce = UUID().uuidString
        let nextURL = URL(string: "http://example.invalid/again?n=\(nonce)")!
        tab.load(URLRequest(url: nextURL))
        // A failed health state retains the existing proxy route. WebKit may
        // still send through that proxy or report its failure; neither result
        // may replace this store or enable DIRECT fallback.
        try await waitUntil({ !tab.isLoading }, message: opener.transcript)
        XCTAssertEqual(tab.requestedURL, nextURL)
        XCTAssertTrue(tab.websiteDataStore === store)
        XCTAssertEqual(store.proxyConfigurations.count, before)
        XCTAssertFalse(store.proxyConfigurations.isEmpty)
        XCTAssertFalse(try XCTUnwrap(store.proxyConfigurations.first).allowFailover)
    }

    func testAutoRecoverySendsTheMemberThroughTheProxyAndTheOutsideHostToOrigin() async throws {
        let origin = OriginReceipt(port: 18_247)
        try await origin.start()
        defer { origin.stop() }
        let opener = AnsweringOpener()
        let listener = try await makeListener(port: 18_246, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let coordinator = AccessHostStoreCoordinator(
            publisher: readyPublisher(port: 18_246),
            clock: AccessContinuousPreparationClock()
        )
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.standardTabs.forEach { $0.stop() } }
        browser.hostCoordinator = coordinator
        let shop = try XCTUnwrap(browser.activeTab)
        let window = show(shop.webView)
        defer { window.isHidden = true }
        shop.load(URLRequest(url: URL(string: "https://shop.example/home")!))
        shop.commitPendingMainFrameForTests()
        let login = try AccessSiteHost("login.example")
        guard case .armed = coordinator.setAutoRecoveryEnabled(true, for: shop, members: [login]) else {
            return XCTFail("committed shop page should only arm")
        }
        XCTAssertEqual(coordinator.registry.ordinaryStores().count, 0)

        let member = browser.newTab()
        let nonce = UUID().uuidString
        member.load(URLRequest(url: URL(string: "http://login.example/start?n=\(nonce)")!))
        member.webView.navigationDelegate = NavigationSink()
        if member.webView.superview == nil {
            member.webView.frame = window.bounds
            window.addSubview(member.webView)
        }
        member.webView.stopLoading()
        deliverFailure(member)
        try await waitUntil(seconds: 15, {
            if member.webView.superview == nil {
                member.webView.frame = window.bounds
                window.addSubview(member.webView)
                window.makeKeyAndVisible()
            }
            return opener.transcript.contains(nonce) && opener.transcript.contains("cdn.invalid")
        }, message: "proxy=\(opener.transcript) loads=\(member.recoveryLoadCount) loading=\(member.isLoading) failure=\(coordinator.lastRecoveryFailure ?? "") error=\(member.loadingError ?? "") last=\(member.lastMainFrameFailure?.url.absoluteString ?? "")")
        guard opener.transcript.contains(nonce), opener.transcript.contains("cdn.invalid") else { return }
        XCTAssertEqual(member.recoveryLoadCount, 1)

        var probe = URLRequest(url: URL(string: "http://127.0.0.1:\(origin.port)/ping")!)
        probe.timeoutInterval = 3
        let probeResponse = try await URLSession.shared.data(for: probe).1 as? HTTPURLResponse
        XCTAssertEqual(probeResponse?.statusCode, 200, origin.transcript)
        XCTAssertTrue(origin.transcript.contains("GET /ping"), origin.transcript)

        let outside = UUID().uuidString
        let direct = browser.newTab()
        try await direct.prepareContentRulesForTests()
        direct.load(URLRequest(url: URL(string: "http://127.0.0.1:\(origin.port)/outside?n=\(outside)")!))
        direct.webView.frame = window.bounds
        window.addSubview(direct.webView)
        window.makeKeyAndVisible()
        try await waitUntil(seconds: 20, {
            if direct.webView.superview == nil {
                direct.webView.frame = window.bounds
                window.addSubview(direct.webView)
                window.makeKeyAndVisible()
            }
            return origin.transcript.contains(outside)
        }, message: "port=\(origin.port) origin=\(origin.transcript) url=\(direct.url?.absoluteString ?? "") requested=\(direct.requestedURL?.absoluteString ?? "") loading=\(direct.isLoading) error=\(direct.loadingError ?? "") proxies=\(direct.websiteDataStore.proxyConfigurations.count)")
        XCTAssertFalse(opener.transcript.contains(outside), opener.transcript)
        XCTAssertFalse(origin.transcript.contains(nonce))
        XCTAssertEqual(direct.websiteDataStore.proxyConfigurations.count, 0)
    }

    func testEnablingProxyStopsOldDirectDocumentBeforePreparationAndFailure() async throws {
        let html = """
        <title>Direct preparation fixture</title><script>
        setInterval(() => fetch('/pulse?proxy-hold', {cache:'no-store'}).catch(()=>{}), 40);
        </script>
        """
        let origin = OriginReceipt(port: 18_292, body: html)
        try await origin.start()
        defer { origin.stop() }
        let clock = AccessManualPreparationClock()
        let publisher = AccessProxyEntryPublisher { _, _ in
            try await clock.sleep(until: .seconds(10))
            throw AccessSiteSessionError.nodeUnavailable
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: clock)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        browser.hostCoordinator = coordinator
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        tab.load(URL(string: "http://localhost:\(origin.port)/page?proxy-hold")!)
        let window = show(tab.webView)
        defer { window.isHidden = true }
        try await waitUntil(seconds: 15, {
            attach(tab.webView, to: window)
            return origin.transcript.components(separatedBy: "/pulse?proxy-hold").count > 3
        }, message: origin.transcript)
        let oldView = tab.webView
        coordinator.setSiteProxyEnabled(true, for: tab, displayedHost: try AccessSiteHost("localhost"))
        try await waitUntil(seconds: 10, {
            oldView.url?.absoluteString == "about:blank" && publisher.provisionCount == 1
        }, message: "The old direct document must become inert before preparation starts")
        try await Task.sleep(for: .milliseconds(150))
        let stopped = origin.transcript.components(separatedBy: "/pulse?proxy-hold").count
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(origin.transcript.components(separatedBy: "/pulse?proxy-hold").count, stopped)
        XCTAssertNil(oldView.load(URLRequest(url: URL(string: "http://localhost:\(origin.port)/resurrect")!)))
        clock.advance(to: .seconds(10))
        try await waitUntil(seconds: 5, { !tab.isLoading && tab.loadingError != nil }, message: "Preparation must fail closed")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(origin.transcript.components(separatedBy: "/pulse?proxy-hold").count, stopped)
        XCTAssertFalse(origin.transcript.contains("/resurrect"))
    }

    func testRetainedClosedPageStopsBeforeHostStoreRetirement() async throws {
        let html = """
        <title>Terminal window fixture</title><script>
        window.pulses = 0;
        setInterval(() => { window.pulses++; fetch('/pulse' + location.search, {cache:'no-store'}).catch(()=>{}); }, 40);
        </script>
        """
        let origin = OriginReceipt(port: 18_257, body: html)
        try await origin.start()
        defer { origin.stop() }
        let opener = AnsweringOpener(body: html)
        let listener = try await makeListener(port: 18_256, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let coordinator = AccessHostStoreCoordinator(publisher: readyPublisher(port: 18_256))
        let windows = BrowserWindowStore()
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil),
                                     windowID: try windows.createWindow(), windowStore: windows)
        let other = BrowserSession(dataStore: browser.dataStore)
        browser.hostCoordinator = coordinator; other.hostCoordinator = coordinator
        defer { browser.closeWindow(); other.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        let sibling = try XCTUnwrap(other.activeTab)
        let host = try AccessSiteHost("localhost"), otherHost = try AccessSiteHost("127.0.0.1")
        for host in [host, otherHost] {
            coordinator.registry.setEndpoint(.init(identity: "terminal-test", generation: 1,
                loopbackHost: "127.0.0.1", port: 18_256, state: .ready), scopeID: "ordinary", host: host, isPrivate: false)
            coordinator.setProxyEnabled(true, host: host, scopeID: "ordinary", isPrivate: false)
        }
        let url = URL(string: "http://localhost:\(origin.port)/page?closed-window")!
        tab.load(url)
        sibling.load(URL(string: "http://127.0.0.1:\(origin.port)/page?open-window")!)
        let window = show(tab.webView), otherWindow = show(sibling.webView)
        defer { window.isHidden = true; otherWindow.isHidden = true }
        try await waitUntil(seconds: 15, {
            attach(tab.webView, to: window); attach(sibling.webView, to: otherWindow)
            return opener.transcript.components(separatedBy: "/pulse?closed-window").count > 3
                && origin.transcript.components(separatedBy: "/pulse?open-window").count > 3
        }, message: opener.transcript)
        let retainedView = tab.webView // Model UIKit retaining its view after scene discard.
        let retainedStore = tab.websiteDataStore
        XCTAssertFalse(retainedStore.proxyConfigurations.isEmpty)
        browser.persistSession()
        let snapshot = try XCTUnwrap(windows.snapshot(browser.windowID))
        browser.closeWindow()
        XCTAssertTrue(tab.isDisposed)
        XCTAssertFalse(tab.isResident)
        // While the old view is externally held, it must commit the inert page
        // before tabClosed allows the registry to clear its proxy configuration.
        try await waitUntil(seconds: 10, {
            coordinator.registry.sweep(now: Date().addingTimeInterval(1801))
            return coordinator.registry.store(scopeID: "ordinary", host: host, isPrivate: false) == nil
        }, message: "terminal document did not release its host binding")
        XCTAssertTrue(retainedStore.proxyConfigurations.isEmpty)
        let closedCount = opener.transcript.components(separatedBy: "/pulse?closed-window").count
        let directCount = origin.transcript.components(separatedBy: "closed-window").count
        let openCount = origin.transcript.components(separatedBy: "/pulse?open-window").count
        // Retaining/accessing the tab must not recreate or reactivate a document.
        tab.reload(); tab.load(url); tab.setActive(true)
        XCTAssertNil(tab.webView.load(URLRequest(url: url)))
        XCTAssertNil(retainedView.load(URLRequest(url: url)))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(opener.transcript.components(separatedBy: "/pulse?closed-window").count, closedCount)
        XCTAssertEqual(origin.transcript.components(separatedBy: "closed-window").count, directCount)
        XCTAssertGreaterThan(origin.transcript.components(separatedBy: "/pulse?open-window").count, openCount)
        XCTAssertNotNil(coordinator.registry.store(scopeID: "ordinary", host: otherHost, isPrivate: false))
        XCTAssertEqual(windows.snapshot(browser.windowID)?.tabs, snapshot.tabs)
        XCTAssertEqual(windows.snapshot(browser.windowID)?.activeTabID, snapshot.activeTabID)
        XCTAssertEqual(snapshot.tabs.first?.url, url)
        XCTAssertFalse(tab.isResident)
        withExtendedLifetime((browser, tab, retainedView)) {}
    }

    func testClosingPrivateWindowDoesNotReactivateSuspendedOrdinaryTab() async throws {
        let opener = AnsweringOpener(body: "<title>Suspension fixture</title><p>safe</p>")
        let listener = try await makeListener(port: 18_258, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let coordinator = AccessHostStoreCoordinator(publisher: readyPublisher(port: 18_258))
        let windows = BrowserWindowStore()
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil),
                                     windowID: try windows.createWindow(), windowStore: windows)
        browser.hostCoordinator = coordinator
        let host = try AccessSiteHost("localhost")
        coordinator.registry.setEndpoint(.init(identity: "suspend-test", generation: 1,
            loopbackHost: "127.0.0.1", port: 18_258, state: .ready), scopeID: "ordinary", host: host, isPrivate: false)
        coordinator.setProxyEnabled(true, host: host, scopeID: "ordinary", isPrivate: false)
        let ordinary = try XCTUnwrap(browser.activeTab)
        ordinary.load(URL(string: "http://localhost:18259/page")!)
        let window = show(ordinary.webView)
        defer { window.isHidden = true; browser.closeWindow() }
        try await waitUntil(seconds: 15, {
            attach(ordinary.webView, to: window)
            return ordinary.url?.path == "/page" && !ordinary.isLoading
        }, message: opener.transcript)
        browser.switchProfile(to: .privateMode)
        let privateTab = try XCTUnwrap(browser.activeTab)
        let suspended = await ordinary.suspendIfSafe()
        XCTAssertTrue(suspended)
        XCTAssertFalse(ordinary.isResident)
        browser.persistSession()
        let snapshot = try XCTUnwrap(windows.snapshot(browser.windowID))
        let requestCount = opener.transcript.components(separatedBy: "GET /page").count
        browser.closeWindow()
        let closedEpoch = ordinary.navigationEpoch
        XCTAssertTrue(ordinary.isDisposed)
        XCTAssertTrue(privateTab.isDisposed)
        XCTAssertFalse(ordinary.isResident)
        coordinator.registry.sweep(now: Date().addingTimeInterval(1801))
        XCTAssertNil(coordinator.registry.store(scopeID: "ordinary", host: host, isPrivate: false))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(ordinary.navigationEpoch, closedEpoch)
        XCTAssertEqual(opener.transcript.components(separatedBy: "GET /page").count, requestCount)
        XCTAssertFalse(ordinary.isResident)
        XCTAssertEqual(windows.snapshot(browser.windowID)?.tabs, snapshot.tabs)
        XCTAssertFalse(BrowserSession.openTabs().contains { $0.id == ordinary.id })
        // Nonterminal private discard must still return a live window to ordinary browsing.
        let live = BrowserSession(dataStore: browser.dataStore)
        let liveOrdinary = try XCTUnwrap(live.activeTab)
        live.switchProfile(to: .privateMode)
        live.discardPrivateSession()
        XCTAssertEqual(live.profile, .standard)
        XCTAssertTrue(live.activeTab === liveOrdinary)
        XCTAssertFalse(liveOrdinary.isDisposed)
        live.closeWindow()
    }

    func testClosingFinalPrivateTabTerminatesRetainedPagesBeforeRetiringScope() async throws {
        try await assertTerminalTabCleanup(.lastPrivate)
    }

    func testExplicitPrivateDiscardTerminatesRetainedPageBeforeRetiringScope() async throws {
        try await assertTerminalTabCleanup(.discardPrivate)
    }

    func testOrdinaryTabCloseTerminatesRetainedPageBeforeIdleRetirement() async throws {
        try await assertTerminalTabCleanup(.ordinary)
    }

    private enum TerminalEntry { case lastPrivate, discardPrivate, ordinary }

    private func assertTerminalTabCleanup(_ entry: TerminalEntry) async throws {
        let html = "<script>setInterval(()=>fetch('/pulse'+location.search,{cache:'no-store'}),40)</script>"
        let origin = OriginReceipt(port: 18_261, body: html)
        try await origin.start()
        defer { origin.stop() }
        let opener = AnsweringOpener(body: html)
        let listener = try await makeListener(port: 18_260, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let coordinator = AccessHostStoreCoordinator(publisher: readyPublisher(port: 18_260))
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        let other = BrowserSession(dataStore: browser.dataStore)
        browser.hostCoordinator = coordinator; other.hostCoordinator = coordinator
        defer { browser.closeWindow(); other.closeWindow() }
        if entry == .ordinary { other.switchProfile(to: .privateMode) }
        else { browser.switchProfile(to: .privateMode) }
        let host = try AccessSiteHost("localhost")
        let tab = try XCTUnwrap(browser.activeTab), sibling = try XCTUnwrap(other.activeTab)
        for tab in [tab, sibling] { arm(tab, host: host, port: 18_260, coordinator: coordinator) }
        let url = URL(string: "http://localhost:18261/page?terminal")!
        tab.load(url); sibling.load(URL(string: "http://localhost:18261/page?sibling")!)
        let window = show(tab.webView), otherWindow = show(sibling.webView)
        defer { window.isHidden = true; otherWindow.isHidden = true }
        try await waitUntil(seconds: 10, {
            attach(tab.webView, to: window); attach(sibling.webView, to: otherWindow)
            return opener.transcript.components(separatedBy: "/pulse?terminal").count > 3
                && opener.transcript.components(separatedBy: "/pulse?sibling").count > 3
        }, message: opener.transcript)
        let retainedView = tab.webView, store = tab.websiteDataStore, oldScope = tab.browsingScopeID
        var earlierView: WKWebView?
        var earlierWindow: UIWindow?
        defer { earlierWindow?.isHidden = true }
        if entry != .ordinary {
            let earlier = browser.newTab()
            earlier.load(URL(string: "http://localhost:18261/page?earlier")!)
            let attached = show(earlier.webView)
            earlierWindow = attached
            try await waitUntil {
                attach(earlier.webView, to: attached)
                return opener.transcript.components(separatedBy: "/pulse?earlier").count > 3
            }
            earlierView = earlier.webView
            if entry == .lastPrivate {
                // The final close must also wait for a previously removed tab
                // whose terminal document receipt has not arrived yet.
                browser.close(earlier.id)
            }
        }
        if entry == .discardPrivate {
            browser.discardPrivateSession()
            XCTAssertEqual(browser.profile, .standard)
        } else { browser.close(tab.id) }
        XCTAssertTrue(tab.isDisposed)
        XCTAssertFalse(store.proxyConfigurations.isEmpty, "the retained document has not committed its terminal page yet")
        if entry != .ordinary {
            browser.switchProfile(to: .privateMode)
            let replacement = try XCTUnwrap(browser.activeTab)
            XCTAssertNotEqual(replacement.browsingScopeID, oldScope)
            arm(replacement, host: host, port: 18_260, coordinator: coordinator)
            replacement.load(URL(string: "http://localhost:18261/page?replacement")!)
            attach(replacement.webView, to: window)
        }
        try await waitUntil(seconds: 10, {
            if let active = browser.activeTab { attach(active.webView, to: window) }
            coordinator.registry.sweep(now: Date().addingTimeInterval(1801))
            return coordinator.registry.store(scopeID: oldScope, host: host, isPrivate: tab.profile.isPrivate) == nil
        }, message: "scope retired before all terminal receipts or never retired")
        XCTAssertTrue(store.proxyConfigurations.isEmpty)
        XCTAssertNil(retainedView.load(URLRequest(url: url)))
        XCTAssertNil(tab.webView.load(URLRequest(url: url)))
        tab.load(url)
        let closedCount = opener.transcript.components(separatedBy: "/pulse?terminal").count
        let directCount = origin.transcript.components(separatedBy: "terminal").count
        let earlierCount = opener.transcript.components(separatedBy: "/pulse?earlier").count
        let earlierDirectCount = origin.transcript.components(separatedBy: "earlier").count
        let siblingCount = opener.transcript.components(separatedBy: "/pulse?sibling").count
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(opener.transcript.components(separatedBy: "/pulse?terminal").count, closedCount)
        XCTAssertEqual(origin.transcript.components(separatedBy: "terminal").count, directCount)
        XCTAssertEqual(opener.transcript.components(separatedBy: "/pulse?earlier").count, earlierCount)
        XCTAssertEqual(origin.transcript.components(separatedBy: "earlier").count, earlierDirectCount)
        XCTAssertGreaterThan(opener.transcript.components(separatedBy: "/pulse?sibling").count, siblingCount)
        XCTAssertFalse(sibling.websiteDataStore.proxyConfigurations.isEmpty)
        if entry != .ordinary {
            let replacement = try XCTUnwrap(browser.activeTab)
            try await waitUntil { opener.transcript.contains("/pulse?replacement") }
            XCTAssertFalse(replacement.websiteDataStore === store)
            XCTAssertFalse(replacement.websiteDataStore.proxyConfigurations.isEmpty)
        }
        withExtendedLifetime((browser, retainedView, earlierView)) {}
    }

    func testOldInstanceCleanupCannotUnbindRestoredTabOrCancelItsRecoveryAndProbe() async throws {
        let opener = AnsweringOpener(body: "<title>Restore ownership</title>")
        let listener = try await makeListener(port: 18_262, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let gate = WindowPrepareGate()
        defer { gate.finish() }
        let publisher = AccessProxyEntryPublisher { generation, _ in
            await gate.wait()
            return .init(endpoint: .init(identity: "ownership", generation: generation,
                loopbackHost: "127.0.0.1", port: 18_262, state: .ready),
                listenerReady: true, runtimeHealthy: true, bridgeInstalled: true)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher,
            clock: AccessManualPreparationClock(), channel: .dev,
            probeRunner: AccessSiteProbeRunner(sessionFactory: {
                XCTFail("already-proxied candidate must not issue a probe request")
                return URLSession(configuration: .ephemeral)
            }))
        let delayed = DelayedWindowTabCleanup(coordinator)
        let windows = BrowserWindowStore()
        let first = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil),
                                   windowID: try windows.createWindow(), windowStore: windows)
        first.hostCoordinator = delayed
        let old = try XCTUnwrap(first.activeTab), host = try AccessSiteHost("localhost")
        arm(old, host: host, port: 18_262, coordinator: coordinator)
        old.load(URL(string: "http://localhost:18263/page")!)
        let window = show(old.webView)
        defer { window.isHidden = true; first.closeWindow() }
        try await waitUntil {
            attach(old.webView, to: window)
            return old.url?.path == "/page" && !old.isLoading
        }
        let oldView = old.webView, oldStore = old.websiteDataStore
        first.closeWindow()
        try await waitUntil { delayed.pending.count == 1 }
        let restored = BrowserSession(dataStore: first.dataStore, windowID: first.windowID, windowStore: windows)
        restored.hostCoordinator = coordinator
        defer { restored.closeWindow() }
        let new = try XCTUnwrap(restored.activeTab)
        XCTAssertEqual(new.id, old.id)
        XCTAssertNotEqual(new.instanceID, old.instanceID)
        try await waitUntil {
            attach(new.webView, to: window)
            return new.url?.path == "/page" && !new.isLoading
        }
        XCTAssertTrue(new.websiteDataStore === oldStore)
        var unavailable = try XCTUnwrap(coordinator.registry.endpoint(scopeID: "ordinary", host: host, isPrivate: false))
        unavailable.state = .unavailable
        coordinator.registry.setEndpoint(unavailable, scopeID: "ordinary", host: host, isPrivate: false)
        new.stop()
        new.adoptPolicyMainFrameNavigationForTests(url: URL(string: "http://localhost:18263/recover")!)
        new.webView(new.webView, didFailProvisionalNavigation: nil,
                    withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost))
        XCTAssertNotNil(coordinator.retryViaProxy(tab: new))
        try await waitUntil { gate.started }
        XCTAssertTrue(coordinator.runProbe(for: new, candidates: [host]))
        XCTAssertTrue(coordinator.snapshot(for: new).probeBusy)
        delayed.finish()
        coordinator.pendingRecoveryInvalidated(tab: old) // Another late old-instance callback.
        coordinator.tabClosed(old) // Idempotent late close cannot target the replacement.
        XCTAssertTrue(coordinator.snapshot(for: new).probeBusy)
        coordinator.registry.sweep(now: Date().addingTimeInterval(1801))
        XCTAssertTrue(coordinator.registry.store(scopeID: "ordinary", host: host, isPrivate: false) === oldStore)
        XCTAssertFalse(oldStore.proxyConfigurations.isEmpty)
        gate.finish()
        try await waitUntil {
            attach(new.webView, to: window)
            return new.recoveryLoadCount == 1 && !coordinator.snapshot(for: new).probeBusy
        }
        XCTAssertFalse(coordinator.snapshot(for: new).probeSuggestionLines.isEmpty)
        restored.closeWindow()
        try await waitUntil {
            coordinator.registry.sweep(now: Date().addingTimeInterval(1801))
            return coordinator.registry.store(scopeID: "ordinary", host: host, isPrivate: false) == nil
        }
        withExtendedLifetime((first, old, oldView, restored)) {}
    }

    func testTerminalScrollSnapshotSurvivesDisappearAndCannotOverwriteRestoredWindow() async throws {
        let opener = AnsweringOpener(body: "<meta name='viewport' content='width=device-width'><div style='height:8000px'>Scroll restoration</div>")
        let listener = try await makeListener(port: 18_264, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let coordinator = AccessHostStoreCoordinator(publisher: readyPublisher(port: 18_264))
        let windows = BrowserWindowStore()
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil),
                                     windowID: try windows.createWindow(), windowStore: windows)
        browser.hostCoordinator = coordinator
        let tab = try XCTUnwrap(browser.activeTab), host = try AccessSiteHost("localhost")
        arm(tab, host: host, port: 18_264, coordinator: coordinator)
        tab.load(URL(string: "http://localhost:18265/scroll")!)
        let window = show(tab.webView)
        defer { window.isHidden = true; browser.closeWindow() }
        try await waitUntil {
            attach(tab.webView, to: window)
            return !tab.isLoading && tab.webView.scrollView.contentSize.height > 6000
        }
        _ = try await tab.webView.evaluateJavaScript("window.scrollTo(0,1000)")
        try await waitUntil({ tab.scrollOffset > 900 }, message: "initial scroll model=\(tab.scrollOffset) actual=\(tab.webView.scrollView.contentOffset.y) height=\(tab.webView.scrollView.contentSize.height) url=\(String(describing: tab.url))")
        let offset = tab.scrollOffset
        browser.closeWindow()
        browser.persistSession(); browser.persistSession() // Root onDisappear after terminal release.
        XCTAssertEqual(tab.scrollOffset, offset, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(windows.snapshot(browser.windowID)?.tabs.first?.scrollOffset), offset, accuracy: 1)
        let restored = BrowserSession(dataStore: browser.dataStore, windowID: browser.windowID, windowStore: windows)
        restored.hostCoordinator = coordinator
        defer { restored.closeWindow() }
        let active = try XCTUnwrap(restored.activeTab)
        try await waitUntil({
            attach(active.webView, to: window)
            return !active.isLoading && abs(active.webView.scrollView.contentOffset.y - offset) < 2
        }, message: "restore expected=\(offset) actual=\(active.webView.scrollView.contentOffset.y) model=\(active.scrollOffset) height=\(active.webView.scrollView.contentSize.height) inset=\(active.webView.scrollView.adjustedContentInset.top) url=\(String(describing: active.url))")
        XCTAssertEqual(active.id, tab.id)
        _ = try await active.webView.evaluateJavaScript("window.scrollTo(0,1700)")
        try await waitUntil { active.scrollOffset > 1600 }
        restored.persistSession()
        let current = try XCTUnwrap(windows.snapshot(browser.windowID))
        browser.persistSession(); browser.closeWindow(); browser.persistSession()
        XCTAssertEqual(windows.snapshot(browser.windowID), current)
        XCTAssertGreaterThan(try XCTUnwrap(current.tabs.first?.scrollOffset), offset)
        XCTAssertTrue(BrowserSession.openTabs().contains { $0 === active })
        XCTAssertFalse(BrowserSession.openTabs().contains { $0 === tab })
    }

    private func arm(_ tab: BrowserTab, host: AccessSiteHost, port: UInt16,
                     coordinator: AccessHostStoreCoordinator) {
        coordinator.registry.setEndpoint(.init(identity: "window-terminal", generation: 1,
            loopbackHost: "127.0.0.1", port: port, state: .ready),
            scopeID: tab.browsingScopeID, host: host, isPrivate: tab.profile.isPrivate)
        coordinator.setProxyEnabled(true, host: host, scopeID: tab.browsingScopeID, isPrivate: tab.profile.isPrivate)
    }

    private func readyPublisher(port: UInt16) -> AccessProxyEntryPublisher {
        AccessProxyEntryPublisher { generation, _ in
            AccessProxyEntryPublisher.Provision(
                endpoint: AccessManagedProxyEndpoint(
                    identity: "listener-\(port)",
                    generation: generation,
                    loopbackHost: "127.0.0.1",
                    port: port,
                    state: .ready
                ),
                listenerReady: true,
                runtimeHealthy: true,
                bridgeInstalled: true
            )
        }
    }

    private func makeListener(port: UInt16, tunnels: any AccessHTTPTunnelOpening) async throws -> AccessHTTPInboundListener {
        let registration = AccessRegistration(
            id: try AccessRegistrationID("reg-webkit-\(port)"),
            owner: try AccessOwner(channel: 1, profile: "ordinary", partition: "default"),
            transport: .http,
            endpoint: try AccessEndpoint(host: "127.0.0.1", port: port),
            credentialSlot: try AccessCredentialSlot(id: "cred-webkit-\(port)"),
            lease: try AccessLease(generation: 1, expiresAt: Date(timeIntervalSince1970: 1_700_000_060))
        )
        return try AccessHTTPInboundListener(registration: registration, tunnels: tunnels)
    }

    private func attach(_ view: WKWebView, to window: UIWindow) {
        if view.superview == nil { view.frame = window.bounds; window.addSubview(view) }
    }

    private func show(_ view: WKWebView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState != .unattached }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        view.frame = window.bounds
        window.addSubview(view)
        window.makeKeyAndVisible()
        return window
    }

    private func deliverFailure(_ tab: BrowserTab) {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        tab.webView(tab.webView, didFailProvisionalNavigation: tab.currentNavigationForTests, withError: error)
    }

    private func waitUntil(
        seconds: TimeInterval = 8,
        _ condition: @MainActor () -> Bool,
        message: @autoclosure () -> String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(condition(), message(), file: file, line: line)
    }
}

private final class NavigationSink: NSObject, WKNavigationDelegate {}

private final class OriginReceipt: @unchecked Sendable {
    let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "access.auto-recovery.origin")
    private let lock = OSAllocatedUnfairLock(initialState: "")

    private let body: String
    init(port: UInt16, body: String = "ok") { self.port = port; self.body = body }

    var transcript: String { lock.withLock { $0 } }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw URLError(.badURL) }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(connection)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let once = OSAllocatedUnfairLock(initialState: false)
                    listener.stateUpdateHandler = { state in
                        let first = once.withLock { taken -> Bool in
                            if taken { return false }
                            switch state {
                            case .ready, .failed, .cancelled:
                                taken = true
                                return true
                            default:
                                return false
                            }
                        }
                        guard first else { return }
                        switch state {
                        case .ready:
                            continuation.resume()
                        case .failed(let error):
                            continuation.resume(throwing: error)
                        default:
                            continuation.resume(throwing: URLError(.cannotConnectToHost))
                        }
                    }
                    listener.start(queue: self.queue)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw URLError(.timedOut)
            }
            try await group.next()
            group.cancelAll()
        }
        self.listener = listener
    }

    func stop() { listener?.cancel() }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            if let data {
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                self?.lock.withLock { $0.append(text) }
            }
            let body = self?.body ?? "ok"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

private final class AnsweringOpener: AccessHTTPTunnelOpening, @unchecked Sendable {
    private let body: String?
    private let finishAfterRecording: Bool
    init(body: String? = nil, finishAfterRecording: Bool = false) {
        self.body = body
        self.finishAfterRecording = finishAfterRecording
    }
    private let lock = OSAllocatedUnfairLock(initialState: "")
    private let authorityLock = OSAllocatedUnfairLock(initialState: [String]())
    var authorities: [String] { authorityLock.withLock { $0 } }
    var transcript: String {
        lock.withLock { $0 }
    }

    func open(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        authorityLock.withLock { $0.append("\(host):\(port)") }
        if finishAfterRecording { throw URLError(.secureConnectionFailed) }
        let stream = AnsweringStream(host: host, body: body)
        stream.onRequest = { [weak self] request in
            self?.append(request)
        }
        return stream
    }

    fileprivate func append(_ request: String) {
        lock.withLock { $0.append(request) }
    }
}

private final class AnsweringStream: AccessRealityPathStream, @unchecked Sendable {
    private struct State {
        var request = Data()
        var response = Data()
        var closed = false
        var readers: [CheckedContinuation<Data?, Error>] = []
        var announced = false
    }

    let host: String
    var onRequest: ((String) -> Void)?
    private let lock = OSAllocatedUnfairLock(initialState: State())

    private let body: String?
    init(host: String, body: String? = nil) { self.host = host; self.body = body }

    var isOpen: Bool {
        lock.withLock { !$0.closed }
    }

    func read(maxBytes: Int) async throws -> Data? {
        return try await withCheckedThrowingContinuation { continuation in
            if let immediate = self.takeResponse(maxBytes: maxBytes, continuation: continuation) {
                continuation.resume(returning: immediate)
            }
        }
    }

    func write(_ data: Data) async throws {
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            onRequest?(text)
        }
        let finished = appendRequest(data)
        if let finished {
            enqueue(answer(for: finished))
        }
    }

    func close() {
        let pending = closeLocked()
        pending.forEach { $0.resume(returning: nil) }
    }

    private func appendRequest(_ data: Data) -> String? {
        lock.withLock { state in
            state.request.append(data)
            guard !state.announced,
                  let text = String(data: state.request, encoding: .utf8),
                  text.contains("\r\n\r\n") else {
                return nil
            }
            state.announced = true
            return text
        }
    }

    private func answer(for request: String) -> Data {
        let body = self.body.map { request.contains("/pulse") ? "ok" : $0 } ?? (host == "cdn.invalid"
            ? "body{}"
            : "<link rel=\"stylesheet\" href=\"http://cdn.invalid/a.css\">")
        let type = host == "cdn.invalid" ? "text/css" : "text/html"
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = request
        return Data(header.utf8)
    }

    private func enqueue(_ data: Data) {
        let reader: CheckedContinuation<Data?, Error>? = lock.withLock { state in
            if state.readers.isEmpty {
                state.response.append(data)
                return nil
            }
            return state.readers.removeFirst()
        }
        reader?.resume(returning: data)
    }

    private func takeResponse(maxBytes: Int, continuation: CheckedContinuation<Data?, Error>) -> Data?? {
        lock.withLock { state in
            if state.closed, state.response.isEmpty { return .some(nil) }
            if !state.response.isEmpty {
                let count = min(maxBytes, state.response.count)
                let chunk = Data(state.response.prefix(count))
                state.response.removeFirst(count)
                return .some(chunk)
            }
            state.readers.append(continuation)
            return nil
        }
    }

    private func closeLocked() -> [CheckedContinuation<Data?, Error>] {
        lock.withLock { state in
            state.closed = true
            let pending = state.readers
            state.readers.removeAll()
            return pending
        }
    }
}

/// Delay only the old terminal receipt; all binding/recovery work uses the real coordinator.
@MainActor
private final class DelayedWindowTabCleanup: BrowserHostStoreCoordinating {
    let base: AccessHostStoreCoordinator
    var pending: [BrowserTab] = []
    init(_ base: AccessHostStoreCoordinator) { self.base = base }
    func wouldSwitchStore(tab: BrowserTab, url: URL) -> Bool { base.wouldSwitchStore(tab: tab, url: url) }
    func dataStoreForMainFrame(tab: BrowserTab, url: URL) -> WKWebsiteDataStore? { base.dataStoreForMainFrame(tab: tab, url: url) }
    func mainFrameFailed(tab: BrowserTab, failure: BrowserMainFrameFailure, error: NSError) { base.mainFrameFailed(tab: tab, failure: failure, error: error) }
    func pendingRecoveryInvalidated(tab: BrowserTab) { base.pendingRecoveryInvalidated(tab: tab) }
    func tabClosed(_ tab: BrowserTab) { pending.append(tab) }
    func ordinaryHostStores() -> [WKWebsiteDataStore] { base.ordinaryHostStores() }
    func endPrivateSession(scopeID: String) { base.endPrivateSession(scopeID: scopeID) }
    func finish() { let tabs = pending; pending = []; tabs.forEach { base.tabClosed($0) } }
}

@MainActor
private final class WindowPrepareGate {
    private(set) var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0; started = true }
    }
    func finish() { released = true; let pending = continuation; continuation = nil; pending?.resume() }
}
