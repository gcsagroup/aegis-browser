@testable import AccessKit
import Network
import SwiftUI
import os
import Security
import UIKit
import WebKit
import XCTest
@testable import Aegis
@testable import BrowserKit

/// Failed page reloads through the app HTTP CONNECT listener, not a test-only proxy socket.
@MainActor
final class AccessHostRecoveryWebKitTests: XCTestCase {
    func testExplicitOriginalPendingNavigationOffersNoProxyAction() async throws {
        let original = AnsweringOpener()
        let managed = AnsweringOpener()
        let listener = try await makeListener(port: 18_431, tunnels: original)
        let managedListener = try await makeListener(port: 18_432, tunnels: managed)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await listener.start(at: now)
        defer { try? listener.stop() }
        try await managedListener.start(at: now)
        defer { try? managedListener.stop() }
        let coordinator = AccessHostStoreCoordinator(publisher: readyPublisher(port: 18_432), channel: .dev)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        browser.hostCoordinator = coordinator
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        try await tab.prepareContentRulesForTests()
        let store = tab.originalWebsiteDataStore
        let previousProxy = store.proxyConfigurations
        var observer = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: 18_431))
        observer.allowFailover = false
        store.proxyConfigurations = [observer]
        defer { store.proxyConfigurations = previousProxy }

        let originalHost = try AccessSiteHost("chosen-route.example.invalid")
        let chosen = try XCTUnwrap(URL(string: "https://chosen-route.example.invalid/explicit"))
        let unrestricted = try XCTUnwrap(URL(string: "https://optional-route.example.invalid/control"))
        tab.load(chosen)
        tab.webView(tab.webView, didFailProvisionalNavigation: tab.currentNavigationForTests,
                    withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        coordinator.setWebsiteRouteChoice(.original, for: tab, displayedHost: originalHost)
        XCTAssertEqual(coordinator.websiteRouteSelection(for: tab), .original)

        let contents = ActiveTabView(tab: tab, address: .constant(""), addressIsEditing: false,
                                     onEditAddress: {}, onFind: {}, onScroll: { _ in }, onImage: { _ in })
            .environmentObject(coordinator)
        let host = UIHostingController(rootView: contents)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }

        func proxyButton(in view: UIView) -> UIButton? {
            if let button = view as? UIButton, button.accessibilityIdentifier == "page-load-proxy-retry" { return button }
            return view.subviews.lazy.compactMap { proxyButton(in: $0) }.first
        }

        tab.loadFromAddressBar(unrestricted)
        try await waitUntil(seconds: 8, {
            host.view.layoutIfNeeded()
            return original.authorities.contains("optional-route.example.invalid:443") && proxyButton(in: host.view) != nil
        }, message: "An unrestricted pending request must reach the original listener and offer the configured service")
        tab.loadFromAddressBar(chosen)
        try await waitUntil(seconds: 8, {
            original.authorities.contains("chosen-route.example.invalid:443")
        }, message: "The explicitly original request must reach the original listener and remain pending")
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(tab.isLoading)
        XCTAssertEqual(tab.pendingAddressNavigation?.url, chosen)
        XCTAssertNil(proxyButton(in: host.view), "An explicitly original pending navigation must not offer a proxy action")
        let pending = try XCTUnwrap(tab.pendingAddressNavigation)
        XCTAssertNil(coordinator.openPendingAddressViaProxy(tab: tab, pending: pending))

        tab.loadFromAddressBar(unrestricted)
        try await waitUntil(seconds: 8, {
            host.view.layoutIfNeeded()
            return tab.pendingAddressNavigation?.url == unrestricted && proxyButton(in: host.view) != nil
        }, message: "The optional action must reappear for an unrestricted target")
        let button = try XCTUnwrap(proxyButton(in: host.view))
        XCTAssertTrue(button.isEnabled)
        button.sendActions(for: .touchUpInside)
        try await waitUntil(seconds: 8, {
            managed.authorities.contains("optional-route.example.invalid:443")
        }, message: "The visible action must send the unrestricted target to the managed listener")
        XCTAssertEqual(tab.boundHostName, "optional-route.example.invalid")
        XCTAssertFalse(managed.authorities.contains("chosen-route.example.invalid:443"))
    }

    func testListenerRetirementFencesColdLoadBeforeWebViewCreation() async throws {
        try await assertDeferredLoadRetiredWithoutWebView(warmRules: false)
    }

    func testListenerRetirementFencesParkedLoadBeforeWebViewCreation() async throws {
        try await assertDeferredLoadRetiredWithoutWebView(warmRules: true)
    }

    private func assertDeferredLoadRetiredWithoutWebView(warmRules: Bool) async throws {
        let publisher = AccessProxyEntryPublisher { _, _ in
            throw AccessSiteSessionError.nodeUnavailable
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, defaultLocationPrivacy: false)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = BrowserWindowStore()
        let windowID = UUID()
        let startup = SavedBrowserTab(id: UUID(), url: nil, groupID: nil)
        let inactive = SavedBrowserTab(id: UUID(), url: nil, groupID: nil)
        try windows.save(BrowserWindowSnapshot(id: windowID, tabs: [startup, inactive], activeTabID: startup.id))
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil),
                                     windowID: windowID, windowStore: windows,
                                     preferences: BrowserPreferences(defaults: defaults))
        defer { browser.closeWindow() }
        browser.hostCoordinator = coordinator
        // The active tab creates a startup view. This tab has never owned one.
        let tab = try XCTUnwrap(browser.standardTabs.first { $0.id == inactive.id })
        XCTAssertFalse(tab.isResident)
        if warmRules { try await tab.prepareContentRulesForTests() }
        let host = try AccessSiteHost("localhost")
        arm(tab, host: host, port: 18_253, coordinator: coordinator)
        let store = try XCTUnwrap(coordinator.registry.storeForTab(tabID: tab.instanceID.uuidString,
            scopeID: tab.browsingScopeID, isPrivate: false, targetHost: host, boundHost: nil, intent: .on))
        let url = try XCTUnwrap(URL(string: "http://localhost:1/retired-before-attachment"))
        tab.load(URLRequest(url: url))
        XCTAssertTrue(tab.websiteDataStore === store)
        XCTAssertTrue(tab.isLoading)
        XCTAssertFalse(tab.isResident)
        XCTAssertFalse(store.proxyConfigurations.isEmpty)
        XCTAssertEqual(tab.pendingAttachedLoadForTests?.url, warmRules ? url : nil)

        var receipt: (isLoading: Bool, loadingError: String?, isResident: Bool, parked: URLRequest?)?
        coordinator.retireManagedDocuments(identity: "window-terminal") {
            receipt = (tab.isLoading, tab.loadingError, tab.isResident, tab.pendingAttachedLoadForTests)
        }
        XCTAssertTrue(store.proxyConfigurations.isEmpty)
        let retired = try XCTUnwrap(receipt, "A tab that never owned a document must acknowledge synchronously")
        XCTAssertFalse(retired.isLoading, "Pending navigation must be fenced before acknowledging retirement")
        XCTAssertNotNil(retired.loadingError)
        XCTAssertFalse(retired.isResident)
        XCTAssertNil(retired.parked)

        browser.activate(tab.id)
        let window = show(tab.webView)
        defer { window.isHidden = true }
        try await tab.prepareContentRulesForTests()
        await Task.yield()
        XCTAssertNil(tab.currentNavigationForTests)
        XCTAssertNil(tab.heldProxyRequestForTests)
        XCTAssertNil(tab.pendingAttachedLoadForTests)
        XCTAssertFalse(tab.isLoading)
        XCTAssertNil(tab.webView.url)
        XCTAssertEqual(publisher.provisionCount, 0)
    }

    func testFirstPublicNavigationUsesTheDefaultProtectedRoute() async throws {
        let opener = AnsweringOpener(finishAfterRecording: true)
        let listener = try await makeListener(port: 18_277, tunnels: opener)
        try await listener.start()
        defer { try? listener.stop() }
        let coordinator = AccessHostStoreCoordinator(publisher: readyPublisher(port: 18_277), defaultLocationPrivacy: true)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        browser.hostCoordinator = coordinator
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        try await tab.prepareContentRulesForTests()
        let window = show(tab.webView)
        defer { window.isHidden = true }
        tab.loadFromAddressBar(URL(string: "https://location.example.invalid/first")!)
        try await waitUntil(seconds: 10, {
            self.attach(tab.webView, to: window)
            return opener.authorities.contains("location.example.invalid:443")
        }, message: "First visit must reach the controlled CONNECT listener")
        XCTAssertEqual(tab.boundHostName, "location.example.invalid")
        XCTAssertFalse(try XCTUnwrap(tab.websiteDataStore.proxyConfigurations.first).allowFailover)
        tab.commitPendingMainFrameForTests()
        _ = coordinator.setAutoRecoveryEnabled(true, for: tab)
        XCTAssertTrue(coordinator.snapshot(for: tab).autoRecoveryEnabled)
        let boundStore = tab.websiteDataStore
        let host = try AccessSiteHost("location.example.invalid")
        var endpoint = try XCTUnwrap(coordinator.registry.endpoint(scopeID: tab.browsingScopeID, host: host, isPrivate: false))
        endpoint.state = .unavailable
        coordinator.registry.setEndpoint(endpoint, scopeID: tab.browsingScopeID, host: host, isPrivate: false)
        XCTAssertEqual(coordinator.setAutoRecoveryEnabled(false, for: tab), .revoked)
        XCTAssertTrue(tab.websiteDataStore === boundStore)
        XCTAssertEqual(tab.boundHostName, host.rawValue)

    }

    func testUnavailableDefaultResumesOnlyTheHeldNavigationUsingItsOriginalStore() async throws {
        let publisher = AccessProxyEntryPublisher { _, _ in throw AccessSiteSessionError.nodeUnavailable }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, defaultLocationPrivacy: true)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        browser.hostCoordinator = coordinator
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        // Instrument the original store with a loopback witness. The managed service always fails.
        let witness = AnsweringOpener(finishAfterRecording: true)
        let listener = try await makeListener(port: 18_278, tunnels: witness)
        try await listener.start()
        defer { try? listener.stop() }
        let original = tab.originalWebsiteDataStore
        let prior = original.proxyConfigurations
        var observer = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: 18_278))
        observer.allowFailover = false
        original.proxyConfigurations = [observer]
        defer { original.proxyConfigurations = prior }
        let window = show(tab.webView)
        defer { window.isHidden = true }
        let url = URL(string: "https://default-off.invalid/page")!
        tab.loadFromAddressBar(url)
        XCTAssertNotNil(tab.heldProxyRequestForTests)
        let navigationID = tab.currentAttemptIDForTests
        try await waitUntil(seconds: 15, {
            self.attach(tab.webView, to: window)
            return witness.authorities.contains("default-off.invalid:443")
        }, message: "Cold fallback must actually send the original request")
        XCTAssertEqual(tab.currentAttemptIDForTests, navigationID)
        XCTAssertFalse(tab.canTryDefaultRoute(for: url))
        XCTAssertNil(tab.heldProxyRequestForTests)
        XCTAssertTrue(tab.websiteDataStore === tab.originalWebsiteDataStore)
        XCTAssertFalse(coordinator.requiresProxy(tab: tab, url: url))
        XCTAssertFalse(coordinator.requiresProxyPreparation(tab: tab, url: url))
        XCTAssertFalse(coordinator.snapshot(for: tab, forLocationControl: true).toggleOn)
        XCTAssertEqual(publisher.provisionCount, 1)
    }

    func testUnavailableDefaultPreservesLoadedDocumentAndBothHistoryDirections() async throws {
        try await assertOptionalPreparationRetiresOnlyWhenStoreChanges(succeeds: false)
    }

    func testReadyDefaultRetiresLoadedDocumentOnlyWhenBindingManagedStore() async throws {
        try await assertOptionalPreparationRetiresOnlyWhenStoreChanges(succeeds: true)
    }

    private func assertOptionalPreparationRetiresOnlyWhenStoreChanges(succeeds: Bool) async throws {
        let target = URL(string: "https://optional-history.invalid/destination")!
        let origin = OriginReceipt(port: 18_294, body: "<title>Direct history</title><a id='next' href='\(target.absoluteString)'>Next</a>")
        try await origin.start()
        defer { origin.stop() }
        let witness = AnsweringOpener(finishAfterRecording: true)
        let listener = try await makeListener(port: 18_295, tunnels: witness)
        try await listener.start()
        defer { try? listener.stop() }
        let gate = WindowPrepareGate()
        defer { gate.finish() }
        let publisher = AccessProxyEntryPublisher { generation, _ in
            await gate.wait()
            guard succeeds else { throw AccessSiteSessionError.nodeUnavailable }
            return .init(endpoint: .init(identity: "optional-history", generation: generation,
                loopbackHost: "127.0.0.1", port: 18_295, state: .ready),
                listenerReady: true, runtimeHealthy: true, bridgeInstalled: true)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, defaultLocationPrivacy: true)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        browser.hostCoordinator = coordinator
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        try await tab.prepareContentRulesForTests()
        let window = show(tab.webView)
        defer { window.isHidden = true }
        let first = URL(string: "http://localhost:\(origin.port)/first")!
        let second = URL(string: "http://localhost:\(origin.port)/second")!
        tab.load(first)
        try await waitUntil({ tab.committedMainFrameURL == first && !tab.isLoading }, message: "First direct page must commit")
        let view = tab.webView, store = tab.websiteDataStore
        let firstItem = try XCTUnwrap(view.backForwardList.currentItem)
        tab.load(second)
        try await waitUntil({ tab.committedMainFrameURL == second && !tab.isLoading }, message: "Second direct page must commit")
        let secondItem = try XCTUnwrap(view.backForwardList.currentItem)
        let backList = view.backForwardList.backList
        XCTAssertTrue(view.backForwardList.backItem === firstItem)
        _ = try await view.evaluateJavaScript("document.querySelector('#next').click(); true")
        try await waitUntil({ gate.started }, message: "The real page link must enter optional preparation")
        XCTAssertNotNil(tab.heldProxyRequestForTests)
        XCTAssertTrue(tab.webView === view, "Optional preparation must preserve the existing document before a store is selected")
        XCTAssertTrue(tab.websiteDataStore === store)
        XCTAssertTrue(view.backForwardList.currentItem === secondItem)
        XCTAssertEqual(view.backForwardList.backList, backList)
        XCTAssertNil(tab.boundHostName)
        XCTAssertFalse(coordinator.snapshot(for: tab, forLocationControl: true).toggleOn)
        gate.finish()

        if succeeds {
            try await waitUntil(seconds: 10, {
                self.attach(tab.webView, to: window)
                return witness.authorities.contains("optional-history.invalid:443")
            }, message: "The successful preparation must send through the managed listener")
            XCTAssertFalse(tab.webView === view)
            XCTAssertFalse(tab.websiteDataStore === store)
            XCTAssertEqual(tab.boundHostName, target.host)
            XCTAssertTrue(coordinator.registry.store(scopeID: tab.browsingScopeID,
                host: try AccessSiteHost("optional-history.invalid"), isPrivate: false) === tab.websiteDataStore)
            XCTAssertFalse(try XCTUnwrap(tab.websiteDataStore.proxyConfigurations.first).allowFailover)
            XCTAssertNil(view.load(URLRequest(url: first)), "A store switch must still terminally retire the old realm")
        } else {
            try await waitUntil({ tab.heldProxyRequestForTests == nil }, message: "The failed optional preparation must resume its request")
            XCTAssertTrue(tab.webView === view)
            XCTAssertTrue(tab.websiteDataStore === store)
            XCTAssertTrue(view.backForwardList.currentItem === secondItem)
            XCTAssertEqual(view.backForwardList.backList, backList)
            XCTAssertFalse(coordinator.requiresProxy(tab: tab, url: target))
            XCTAssertNil(tab.boundHostName)
            tab.stop()
            tab.goBack()
            try await waitUntil({ tab.committedMainFrameURL == first && !tab.isLoading }, message: "Back must reach the original live history item")
            XCTAssertTrue(view.backForwardList.currentItem === firstItem)
            XCTAssertTrue(view.backForwardList.forwardItem === secondItem)
            XCTAssertTrue(tab.canGoForward)
            tab.goForward()
            try await waitUntil({ tab.committedMainFrameURL == second && !tab.isLoading }, message: "Forward must return to the second live history item")
            XCTAssertTrue(view.backForwardList.currentItem === secondItem)
            XCTAssertTrue(view.backForwardList.backItem === firstItem)
            XCTAssertTrue(tab.webView === view); XCTAssertTrue(tab.websiteDataStore === store)
        }
        XCTAssertEqual(publisher.provisionCount, 1)
    }

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
        try await listener.start()
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
        try await listener.start()
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
        try await listener.start()
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
        try await listener.start()
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
            "当前页面仍使用原连接"
        )
        XCTAssertNil(snapshot.failureReason)
    }

    func testHttpsReloadRecordsConnectAuthority() async throws {
        let opener = AnsweringOpener()
        let listener = try await makeListener(port: 18_245, tunnels: opener)
        try await listener.start()
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
        try await listener.start()
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
        let opener = AnsweringOpener(body: "<html><body>proxy ready</body></html>")
        let listener = try await makeListener(port: 18_242, tunnels: opener)
        try await listener.start()
        defer { try? listener.stop() }
        let publisher = readyPublisher(port: 18_242)
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessContinuousPreparationClock())
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.standardTabs.forEach { $0.stop() } }
        let tab = try XCTUnwrap(browser.activeTab)
        tab.hostCoordinator = coordinator
        // This receipt measures routing, so finish the unrelated cold rule compile first.
        try await tab.prepareContentRulesForTests()
        let window = show(tab.webView)
        defer { window.isHidden = true }
        let sink = NavigationSink()
        let priorNavigation = tab.currentNavigationForTests
        tab.load(URLRequest(url: URL(string: "http://example.invalid/kept")!))
        tab.webView.navigationDelegate = sink
        // Failure ownership starts when the deferred load has its WKNavigation,
        // not merely when load() has queued the next MainActor turn.
        try await waitUntil({
            guard let navigation = tab.currentNavigationForTests else { return false }
            return navigation !== priorNavigation
        }, message: "The requested main-frame navigation must exist before failure injection")
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
            return opener.transcript.contains("GET /kept") && !tab.isLoading
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
        // A health failure belongs to the published entry's generation.
        var failed = try XCTUnwrap(publisher.currentEndpoint)
        failed.state = .failed
        coordinator.registry.setEndpoint(
            failed,
            scopeID: "ordinary",
            host: host,
            isPrivate: false
        )
        let nonce = UUID().uuidString
        let nextURL = URL(string: "http://example.invalid/again?n=\(nonce)")!
        tab.load(URLRequest(url: nextURL))
        // A failed health state retains the existing proxy route while the
        // still-healthy publisher restores readiness for the same entry.
        XCTAssertEqual(tab.requestedURL, nextURL)
        XCTAssertTrue(tab.websiteDataStore === store)
        XCTAssertEqual(store.proxyConfigurations.count, before)
        XCTAssertFalse(store.proxyConfigurations.isEmpty)
        XCTAssertFalse(try XCTUnwrap(store.proxyConfigurations.first).allowFailover)
        try await waitUntil(seconds: 10, {
            // A new WebView needs a window before the deferred load can run.
            attach(tab.webView, to: window)
            return opener.transcript.contains("GET /again?n=\(nonce)")
        }, message: "proxy=\(opener.transcript) loading=\(tab.isLoading) error=\(tab.loadingError ?? "none")")
        XCTAssertTrue(tab.websiteDataStore === store)
        XCTAssertFalse(try XCTUnwrap(store.proxyConfigurations.first).allowFailover)
    }

    func testAutoRecoverySendsTheMemberThroughTheProxyAndTheOutsideHostToOrigin() async throws {
        let origin = OriginReceipt(port: 18_247)
        try await origin.start()
        defer { origin.stop() }
        let opener = AnsweringOpener()
        let listener = try await makeListener(port: 18_246, tunnels: opener)
        try await listener.start()
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

    func testProtectionIncidentKeepsDetachedProxyDocumentUntilItsTerminalCommit() async throws {
        try await assertManagedDocumentRetirement(.protectionIncident)
    }

    func testInternalNavigationKeepsDetachedProxyDocumentUntilItsTerminalCommit() async throws {
        try await assertManagedDocumentRetirement(.internalNavigation)
    }

    private enum ManagedDocumentExit { case protectionIncident, internalNavigation }

    private func assertManagedDocumentRetirement(_ exit: ManagedDocumentExit) async throws {
        let title = "Managed retirement fixture"
        let opener = AnsweringOpener(body: "<title>\(title)</title>")
        let listenerPort: UInt16 = 18_254
        let listener = try await makeListener(port: listenerPort, tunnels: opener)
        try await listener.start()
        var cleanupListener: () -> Void = { try? listener.stop() }
        defer { cleanupListener() }
        let origin = OriginReceipt(port: 18_255)
        try await origin.start()
        defer { origin.stop() }
        let publisher = readyPublisher(port: listenerPort)
        let coordinator = AccessHostStoreCoordinator(publisher: publisher)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil),
                                     preferences: BrowserPreferences(defaults: defaults))
        browser.hostCoordinator = coordinator
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        try await tab.prepareContentRulesForTests()
        let host = try AccessSiteHost("localhost")
        let url = try XCTUnwrap(URL(string: "http://localhost:\(origin.port)/managed-retirement"))
        let endpoint = AccessManagedProxyEndpoint(identity: "detached-document", generation: 1,
            loopbackHost: "127.0.0.1", port: listenerPort, state: .ready)
        func retireListener(_ finish: @escaping @MainActor () -> Void) {
            listener.suspend()
            coordinator.retireManagedDocuments(identity: endpoint.identity, finish: finish)
        }
        let scope = tab.browsingScopeID
        coordinator.setProxyEnabled(true, host: host, scopeID: scope, isPrivate: false)
        XCTAssertTrue(coordinator.registry.setEndpoint(endpoint, scopeID: scope, host: host, isPrivate: false))
        cleanupListener = { retireListener { try? listener.stop() } }
        tab.load(url)
        let window = show(tab.webView)
        defer { window.isHidden = true }
        try await waitUntil(seconds: 10, {
            self.attach(tab.webView, to: window)
            return tab.committedMainFrameURL == url && tab.webView.title == title && !tab.isLoading
        }, message: "The managed fixture did not commit. Proxy transcript: \(opener.transcript)")
        let retainedView = tab.webView
        let store = try XCTUnwrap(coordinator.registry.store(scopeID: scope, host: host, isPrivate: false))
        guard tab.committedMainFrameURL == url, retainedView.title == title,
              retainedView.configuration.websiteDataStore === store,
              opener.transcript.contains("GET /managed-retirement")
        else { return XCTFail("Retirement requires a committed document on the owned proxy store") }
        XCTAssertFalse(origin.transcript.contains("/managed-retirement"))

        let blank = try XCTUnwrap(URL(string: "about:blank"))
        switch exit {
        case .protectionIncident:
            let blocked = try XCTUnwrap(URL(string: "http://paypal.login.account.verify.example.invalid/login"))
            guard BrowserNavigationPolicy.evaluate(blocked).kind == .blocked else {
                return XCTFail("Synthetic incident URL must be blocked before loading")
            }
            tab.load(blocked)
            XCTAssertEqual(tab.protectionIncident?.url, blocked)
            XCTAssertFalse(tab.isResident)
            // Queue a navigation behind this exact document's terminal receipt.
            // Retiring its listener must cancel it before the receipt arrives.
            tab.load(url)
            XCTAssertTrue(tab.isLoading)
            XCTAssertFalse(tab.isResident)
        case .internalNavigation:
            tab.load(blank)
            XCTAssertNil(tab.boundHostName)
            XCTAssertTrue(tab.websiteDataStore === tab.originalWebsiteDataStore)
        }
        // Mirror the listener's production shutdown ordering. Keep the real
        // loopback socket bound until the registry supplies the document receipt.
        var socketStop: Result<Void, Error>?
        var clearedStoreAtReceipt = false
        cleanupListener = {}
        retireListener {
            clearedStoreAtReceipt = store.proxyConfigurations.isEmpty
            socketStop = Result { try listener.stop() }
        }
        if exit == .protectionIncident {
            XCTAssertFalse(tab.isLoading)
            XCTAssertNotNil(tab.loadingError)
        }
        XCTAssertNil(socketStop, "Dropping the tab reference is not a document receipt")
        XCTAssertEqual(listener.boundPort, listenerPort)
        XCTAssertFalse(store.proxyConfigurations.isEmpty)
        if exit == .protectionIncident {
            tab.rebindWebsiteDataStore(tab.originalWebsiteDataStore, host: nil)
        }
        XCTAssertNil(socketStop, "Rebinding is not a document receipt")
        XCTAssertEqual(listener.boundPort, listenerPort)
        let terminalPolicy = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        XCTAssertTrue(retainedView.navigationDelegate?.responds(to: terminalPolicy) == true,
                      "WebKit must call the retained view's terminal navigation policy")
        XCTAssertNil(retainedView.loadHTMLString("<title>Cannot replace terminal navigation</title>", baseURL: nil))
        try await waitUntil(seconds: 10, { socketStop != nil }, message: "The retained view's terminal commit did not release the socket")
        try XCTUnwrap(socketStop).get()
        XCTAssertTrue(clearedStoreAtReceipt)
        XCTAssertNil(listener.boundPort)
        XCTAssertNil(coordinator.registry.store(scopeID: scope, host: host, isPrivate: false))
        XCTAssertTrue(store.proxyConfigurations.isEmpty)
        XCTAssertEqual(retainedView.url, blank)
        if exit == .protectionIncident {
            XCTAssertFalse(tab.isResident)
            XCTAssertFalse(tab.isLoading)
            XCTAssertNotNil(tab.loadingError)
            XCTAssertEqual(publisher.provisionCount, 0)
        }
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
        try await listener.start()
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
        try await listener.start()
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
        let url = try XCTUnwrap(URL(string: "http://localhost:18259/page"))
        ordinary.load(url)
        let window = show(ordinary.webView)
        defer { window.isHidden = true; browser.closeWindow() }
        try await waitUntil(seconds: 15, {
            attach(ordinary.webView, to: window)
            return ordinary.committedMainFrameURL == url && ordinary.webView.title == "Suspension fixture" && !ordinary.isLoading
        }, message: opener.transcript)
        let retainedView = ordinary.webView
        let store = try XCTUnwrap(coordinator.registry.store(scopeID: "ordinary", host: host, isPrivate: false))
        XCTAssertTrue(retainedView.configuration.websiteDataStore === store)
        browser.switchProfile(to: .privateMode)
        let privateTab = try XCTUnwrap(browser.activeTab)
        let suspended = await ordinary.suspendIfSafe()
        XCTAssertTrue(suspended)
        XCTAssertFalse(ordinary.isResident)
        var suspendedDocumentInert = false
        ordinary.afterCurrentDocumentBecomesInert { suspendedDocumentInert = true }
        browser.persistSession()
        let snapshot = try XCTUnwrap(windows.snapshot(browser.windowID))
        let requestCount = opener.transcript.components(separatedBy: "GET /page").count
        browser.closeWindow()
        let closedEpoch = ordinary.navigationEpoch
        XCTAssertTrue(ordinary.isDisposed)
        XCTAssertTrue(privateTab.isDisposed)
        XCTAssertFalse(ordinary.isResident)
        coordinator.registry.sweep(now: Date().addingTimeInterval(1801))
        if !suspendedDocumentInert {
            XCTAssertTrue(coordinator.registry.store(scopeID: "ordinary", host: host, isPrivate: false) === store)
            XCTAssertFalse(store.proxyConfigurations.isEmpty)
        }
        try await waitUntil(seconds: 10, {
            coordinator.registry.sweep(now: Date().addingTimeInterval(1801))
            return suspendedDocumentInert && coordinator.registry.store(scopeID: "ordinary", host: host, isPrivate: false) == nil
        }, message: "The closed tab's store did not retire after its retained view became inert")
        XCTAssertEqual(retainedView.url?.absoluteString, "about:blank")
        XCTAssertTrue(store.proxyConfigurations.isEmpty)
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
        try await listener.start()
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
        try await tab.prepareContentRulesForTests()
        try await sibling.prepareContentRulesForTests()
        let window = show(tab.webView), otherWindow = show(sibling.webView)
        tab.load(url); sibling.load(URL(string: "http://localhost:18261/page?sibling")!)
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
            earlier.stop()
            try await earlier.prepareContentRulesForTests()
            let attached = show(earlier.webView)
            earlier.load(URL(string: "http://localhost:18261/page?earlier")!)
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
        // 终止回执阻止新请求，但已发送的数据仍可能在繁忙 runner 上延后到达。
        // 等待连续一秒无流量，再核对静止页面与仍存活的兄弟页面。
        func retiredTraffic() -> [Int] {
            [opener.transcript.components(separatedBy: "/pulse?terminal").count,
             origin.transcript.components(separatedBy: "terminal").count,
             opener.transcript.components(separatedBy: "/pulse?earlier").count,
             origin.transcript.components(separatedBy: "earlier").count]
        }
        var lastTraffic = retiredTraffic(), quietSince = Date()
        try await waitUntil(seconds: 5, {
            let current = retiredTraffic()
            if current != lastTraffic { lastTraffic = current; quietSince = Date() }
            return Date().timeIntervalSince(quietSince) >= 1
        }, message: "Retired documents must stop emitting pulses after in-flight packets drain")
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
        try await waitUntil(seconds: 5, {
            opener.transcript.components(separatedBy: "/pulse?sibling").count > siblingCount
        }, message: "存活的兄弟页面必须继续发送请求")
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
        try await listener.start()
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
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BrowserPreferences(defaults: defaults)
        let windows = BrowserWindowStore()
        let first = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil),
                                   windowID: try windows.createWindow(), windowStore: windows,
                                   preferences: preferences)
        first.hostCoordinator = coordinator
        defer { first.closeWindow(); delayed.finish() }
        let old = try XCTUnwrap(first.activeTab), host = try AccessSiteHost("localhost")
        arm(old, host: host, port: 18_262, coordinator: coordinator)
        old.load(URL(string: "http://localhost:18263/page")!)
        let window = show(old.webView)
        defer { window.isHidden = true }
        try await waitUntil {
            attach(old.webView, to: window)
            return old.url?.path == "/page" && !old.isLoading
        }
        let oldView = old.webView, oldStore = old.websiteDataStore
        first.hostCoordinator = delayed
        first.closeWindow()
        try await waitUntil { delayed.pending.count == 1 }
        let restored = BrowserSession(dataStore: first.dataStore, windowID: first.windowID, windowStore: windows,
                                      preferences: preferences)
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
        _ = try XCTUnwrap(coordinator.retryViaProxy(tab: new))
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
        try await listener.start()
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
            lease: try AccessLease(generation: 1, expiresAt: Date().addingTimeInterval(60))
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

@MainActor
private final class PinnedFixtureNavigation: NSObject, WKNavigationDelegate {
    private let tab: BrowserTab
    private let hosts: Set<String>
    private let certificate: SecCertificate
    private let leaf: Data

    init(tab: BrowserTab, hosts: Set<String>, certificate: SecCertificate) {
        self.tab = tab
        self.hosts = hosts
        self.certificate = certificate
        leaf = SecCertificateCopyData(certificate) as Data
    }

    func webView(_ view: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        let host = space.host
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, hosts.contains(host),
              let trust = space.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let pinnedLeaf = leaf
        let matches = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard SecTrustEvaluateWithError(trust, nil),
                      let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: SecCertificateCopyData(certificate) as Data == pinnedLeaf)
            }
        }
        return matches ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }

    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        tab.webView(view, decidePolicyFor: action, preferences: preferences, decisionHandler: decisionHandler)
    }

    func webView(_ view: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        tab.webView(view, decidePolicyFor: response, decisionHandler: decisionHandler)
    }

    func webView(_ view: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab.webView(view, didStartProvisionalNavigation: navigation)
    }

    func webView(_ view: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        tab.webView(view, didReceiveServerRedirectForProvisionalNavigation: navigation)
    }

    func webView(_ view: WKWebView, didCommit navigation: WKNavigation!) {
        tab.webView(view, didCommit: navigation)
    }

    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        tab.webView(view, didFinish: navigation)
    }

    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        tab.webView(view, didFailProvisionalNavigation: navigation, withError: error)
    }

    func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tab.webView(view, didFail: navigation, withError: error)
    }
}

private final class FixtureOriginTunnels: AccessHTTPTunnelOpening, @unchecked Sendable {
    private let port: UInt16
    private let hosts: Set<String>
    private let connectDelay: Duration?
    private let observed = OSAllocatedUnfairLock(initialState: [String]())
    var authorities: [String] { observed.withLock { $0 } }

    init(port: UInt16, hosts: Set<String> = ["www.douban.com", "beta-hold-control.invalid"], connectDelay: Duration? = nil) {
        self.port = port
        self.hosts = hosts
        self.connectDelay = connectDelay
    }

    func open(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        observed.withLock { $0.append("\(host):\(port)") }
        guard port == 443, hosts.contains(host),
              let localPort = NWEndpoint.Port(rawValue: self.port) else { throw URLError(.cannotConnectToHost) }
        if let connectDelay { try await Task.sleep(for: connectDelay) }
        return FixtureOriginSocket(port: localPort)
    }

    private final class FixtureOriginSocket: AccessRealityPathStream, @unchecked Sendable {
        private let connection: NWConnection
        private let closed = OSAllocatedUnfairLock(initialState: false)
        var isOpen: Bool { closed.withLock { !$0 } }

        init(port: NWEndpoint.Port) {
            connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            connection.start(queue: DispatchQueue(label: "test.geosite.fixture-tunnel"))
        }

        func read(maxBytes: Int) async throws -> Data? {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: maxBytes) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: data) }
                }
            }
        }

        func write(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        }

        func close() {
            closed.withLock { $0 = true }
            connection.cancel()
        }
    }
}

private final class OriginReceipt: @unchecked Sendable {
    private let requestedPort: UInt16
    var port: UInt16 { listener?.port?.rawValue ?? requestedPort }
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "access.auto-recovery.origin")
    private let lock = OSAllocatedUnfairLock(initialState: "")

    private let body: String
    private let tls: NWProtocolTLS.Options?
    private let redirects: [String: URL]
    private let responseDelay: TimeInterval
    init(port: UInt16, body: String = "ok", tls: NWProtocolTLS.Options? = nil, redirects: [String: URL] = [:],
         responseDelay: TimeInterval = 0) {
        requestedPort = port
        self.body = body
        self.tls = tls
        self.redirects = redirects
        self.responseDelay = responseDelay
    }

    var transcript: String { lock.withLock { $0 } }

    func start() async throws {
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: requestedPort) else { throw URLError(.badURL) }
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
        receiveRequestLine(connection, prefix: Data())
    }

    private func receiveRequestLine(_ connection: NWConnection, prefix: Data) {
        let remaining = 8192 - prefix.count
        guard remaining > 0 else { connection.cancel(); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var request = prefix
            if let data { request.append(data) }
            guard let end = request.range(of: Data([13, 10])) else {
                if complete { connection.cancel() }
                else { self.receiveRequestLine(connection, prefix: request) }
                return
            }
            self.respond(connection, requestLine: String(decoding: request[..<end.lowerBound], as: UTF8.self))
        }
    }

    private func respond(_ connection: NWConnection, requestLine: String) {
        lock.withLock { $0.append(requestLine + "\r\n") }
        let path = requestLine.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init)
        let response: String
        if let path, let target = redirects[path] {
            response = "HTTP/1.1 302 Found\r\nLocation: \(target.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        } else {
            response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        }
        queue.asyncAfter(deadline: .now() + responseDelay) {
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

private final class AnsweringOpener: AccessHTTPTunnelOpening, @unchecked Sendable {
    private let body: String?
    private let finishAfterRecording: Bool
    private let redirects: [String: URL]
    private let workerScript: String?
    private let responseDelay: Duration?
    init(body: String? = nil, finishAfterRecording: Bool = false, redirects: [String: URL] = [:],
         workerScript: String? = nil, responseDelay: Duration? = nil) {
        self.body = body
        self.finishAfterRecording = finishAfterRecording
        self.redirects = redirects
        self.workerScript = workerScript
        self.responseDelay = responseDelay
    }
    private let lock = OSAllocatedUnfairLock(initialState: "")
    private let authorityLock = OSAllocatedUnfairLock(initialState: [String]())
    private let heldTLS = OSAllocatedUnfairLock(initialState: [String: [AnsweringStream]]())
    var authorities: [String] { authorityLock.withLock { $0 } }

    func finishObservedTLS(to host: String) {
        let streams = heldTLS.withLock { $0.removeValue(forKey: host) ?? [] }
        for stream in streams { stream.close() }
    }
    var transcript: String {
        lock.withLock { $0 }
    }

    func open(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        authorityLock.withLock { $0.append("\(host):\(port)") }
        if finishAfterRecording { throw URLError(.secureConnectionFailed) }
        let stream = AnsweringStream(host: host, body: body, redirects: redirects, workerScript: workerScript,
                                     responseDelay: responseDelay)
        if port == 443 { heldTLS.withLock { $0[host, default: []].append(stream) } }
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
    private let redirects: [String: URL]
    private let workerScript: String?
    private let responseDelay: Duration?
    init(host: String, body: String? = nil, redirects: [String: URL] = [:], workerScript: String? = nil,
         responseDelay: Duration? = nil) {
        self.host = host
        self.body = body
        self.redirects = redirects
        self.workerScript = workerScript
        self.responseDelay = responseDelay
    }

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
            if let responseDelay { try await Task.sleep(for: responseDelay) }
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
        if let target = request.split(separator: " ").dropFirst().first,
           let destination = redirects[String(target)] {
            return Data("HTTP/1.1 302 Found\r\nLocation: \(destination.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        }
        let worker = request.hasPrefix("GET /geo-worker.js?") ? workerScript : nil
        let body = worker ?? self.body.map { request.contains("/pulse") ? "ok" : $0 } ?? (host == "cdn.invalid"
            ? "body{}"
            : "<link rel=\"stylesheet\" href=\"http://cdn.invalid/a.css\">")
        let type = worker != nil ? "text/javascript" : (host == "cdn.invalid" ? "text/css" : "text/html")
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
    private(set) var pending: [BrowserTab] = []
    private var released = false
    init(_ base: AccessHostStoreCoordinator) { self.base = base }
    func wouldSwitchStore(tab: BrowserTab, url: URL) -> Bool { base.wouldSwitchStore(tab: tab, url: url) }
    func dataStoreForMainFrame(tab: BrowserTab, url: URL) -> WKWebsiteDataStore? { base.dataStoreForMainFrame(tab: tab, url: url) }
    func mainFrameFailed(tab: BrowserTab, failure: BrowserMainFrameFailure, error: NSError) { base.mainFrameFailed(tab: tab, failure: failure, error: error) }
    func pendingRecoveryInvalidated(tab: BrowserTab) { base.pendingRecoveryInvalidated(tab: tab) }
    func tabClosed(_ tab: BrowserTab) {
        if released { base.tabClosed(tab) }
        else { pending.append(tab) }
    }
    func ordinaryHostStores() -> [WKWebsiteDataStore] { base.ordinaryHostStores() }
    func endPrivateSession(scopeID: String) { base.endPrivateSession(scopeID: scopeID) }
    func finish() {
        released = true
        let tabs = pending
        pending = []
        tabs.forEach { base.tabClosed($0) }
    }
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

extension AccessHostRecoveryWebKitTests {
    func testExactWebsiteChoiceRequiresTheOwningCoordinator() throws {
        let name = "test.geosite.exact-owner." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let url = try XCTUnwrap(URL(string: "https://choice.example.invalid/"))
        defaults.set(["choice.example.invalid": "service"], forKey: "browser.websiteAcceleration.siteChoices.v1")
        let owner = AccessHostStoreCoordinator(channel: .dev, defaultLocationPrivacy: false, locationPreferences: defaults)
        let otherOwner = AccessHostStoreCoordinator(channel: .dev, defaultLocationPrivacy: false)
        let tab = makeWebsiteAccelerationTab(profile: .standard, defaults: defaults)
        defer { tab.dispose {} }

        tab.hostCoordinator = owner
        XCTAssertTrue(owner.offersWebsiteAcceleration(for: tab))
        XCTAssertTrue(owner.requiresProxy(tab: tab, url: url))
        XCTAssertTrue(owner.requiresProxyPreparation(tab: tab, url: url))

        tab.hostCoordinator = otherOwner
        XCTAssertFalse(owner.offersWebsiteAcceleration(for: tab))
        XCTAssertFalse(owner.requiresProxy(tab: tab, url: url))
        XCTAssertFalse(owner.requiresProxyPreparation(tab: tab, url: url))
        XCTAssertTrue(otherOwner.offersWebsiteAcceleration(for: tab))
        XCTAssertFalse(otherOwner.requiresProxy(tab: tab, url: url))

        tab.hostCoordinator = nil
        XCTAssertFalse(owner.offersWebsiteAcceleration(for: tab))
        XCTAssertFalse(owner.requiresProxy(tab: tab, url: url))
        XCTAssertFalse(owner.requiresProxyPreparation(tab: tab, url: url))
    }

    func testWebsiteAccelerationSmartPreferenceSelectsMemberAndSkipsDefaultOnMiss() throws {
        let suiteName = "test.websiteAcceleration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("smart", forKey: "browser.websiteAcceleration.mode")

        let coordinator = AccessHostStoreCoordinator(channel: .dev, defaultLocationPrivacy: true,
                                                     locationPreferences: defaults)
        let tab = makeWebsiteAccelerationTab(profile: .standard, defaults: defaults)
        tab.hostCoordinator = coordinator
        defer { tab.dispose {} }
        let member = try XCTUnwrap(URL(string: "https://security.debian.org"))
        let nonmember = try XCTUnwrap(URL(string: "https://outside.invalid"))

        XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: member), "网站加速／智能命中时应选用代理")
        XCTAssertTrue(coordinator.requiresProxyPreparation(tab: tab, url: member), "网站加速／智能命中时应准备代理")
        XCTAssertFalse(coordinator.requiresProxy(tab: tab, url: nonmember), "网站加速／智能未命中时应使用原设置")
        XCTAssertFalse(coordinator.requiresProxyPreparation(tab: tab, url: nonmember), "网站加速／智能未命中时应跳过默认代理准备")

        let memberHost = try AccessSiteHost("security.debian.org")
        coordinator.setProxyEnabled(false, host: memberHost, scopeID: tab.browsingScopeID, isPrivate: false)
        XCTAssertFalse(coordinator.requiresProxy(tab: tab, url: member), "手动关闭应覆盖智能命中")
        XCTAssertFalse(coordinator.requiresProxyPreparation(tab: tab, url: member), "手动关闭后应跳过代理准备")

        let nonmemberHost = try AccessSiteHost("outside.invalid")
        coordinator.setProxyEnabled(true, host: nonmemberHost, scopeID: tab.browsingScopeID, isPrivate: false)
        XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: nonmember), "手动开启应覆盖智能未命中")
        XCTAssertTrue(coordinator.requiresProxyPreparation(tab: tab, url: nonmember), "手动开启后应准备代理")
    }

    func testWebsiteAccelerationRequiresDevOrdinaryScope() throws {
        let suiteName = "test.websiteAcceleration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let modeKey = "browser.websiteAcceleration.mode"
        defaults.set("smart", forKey: modeKey)

        let ordinaryTab = makeWebsiteAccelerationTab(profile: .standard, defaults: defaults)
        defer { ordinaryTab.dispose {} }
        let member = try XCTUnwrap(URL(string: "https://security.debian.org"))
        let nonmember = try XCTUnwrap(URL(string: "https://outside.invalid"))
        let dev = AccessHostStoreCoordinator(channel: .dev, defaultLocationPrivacy: false,
                                             locationPreferences: defaults)
        ordinaryTab.hostCoordinator = dev
        XCTAssertTrue(dev.requiresProxy(tab: ordinaryTab, url: member), "网站加速／智能应在 DEV 普通标签页生效")
        XCTAssertTrue(dev.requiresProxyPreparation(tab: ordinaryTab, url: member), "网站加速／智能应为 DEV 普通标签页准备代理")

        let otherChannels: [AccessReleaseChannel] = [.release, .alpha, .beta, .unknown]
        for channel in otherChannels {
            let coordinator = AccessHostStoreCoordinator(channel: channel, defaultLocationPrivacy: false,
                                                         locationPreferences: defaults)
            let context = "网站加速／智能，\(channel.rawValue)"
            XCTAssertFalse(coordinator.requiresProxy(tab: ordinaryTab, url: member), context)
            XCTAssertFalse(coordinator.requiresProxyPreparation(tab: ordinaryTab, url: member), context)
            XCTAssertFalse(coordinator.offersWebsiteAcceleration(for: ordinaryTab), context)
            coordinator.setWebsiteAccelerationMode(.manual, for: ordinaryTab)
            XCTAssertEqual(defaults.string(forKey: modeKey), "smart", context)
        }

        let privateTab = makeWebsiteAccelerationTab(profile: .privateMode, defaults: defaults)
        privateTab.browsingScopeID = UUID().uuidString
        defer { privateTab.dispose {} }
        XCTAssertFalse(dev.requiresProxy(tab: privateTab, url: member), "网站加速／智能，DEV 私密标签页")
        XCTAssertFalse(dev.requiresProxyPreparation(tab: privateTab, url: member), "网站加速／智能，DEV 私密标签页")
        XCTAssertFalse(dev.offersWebsiteAcceleration(for: privateTab))
        dev.setWebsiteAccelerationMode(.manual, for: privateTab)
        XCTAssertEqual(defaults.string(forKey: modeKey), "smart")

        let legacyPreferences: [(String?, String)] = [
            ("manual", "网站加速／手动"),
            (nil, "网站加速偏好缺失"),
            ("corrupt", "网站加速偏好无效")
        ]
        for (preference, context) in legacyPreferences {
            defaults.set(preference, forKey: modeKey)
            let coordinator = AccessHostStoreCoordinator(channel: .dev, defaultLocationPrivacy: true,
                                                         locationPreferences: defaults)
            ordinaryTab.hostCoordinator = coordinator
            for url in [member, nonmember] {
                XCTAssertFalse(coordinator.requiresProxy(tab: ordinaryTab, url: url), "\(context) \(url)")
                XCTAssertTrue(coordinator.requiresProxyPreparation(tab: ordinaryTab, url: url), "\(context) \(url)")
            }
        }
    }

    private func makeWebsiteAccelerationTab(profile: BrowserProfile, defaults: UserDefaults) -> BrowserTab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return BrowserTab(profile: profile, configuration: configuration,
                          preferences: BrowserPreferences(defaults: defaults))
    }

    func testGeoSitePinnedDomainClassification() throws {
        let (defaults, suite) = try makeSmartPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AccessHostStoreCoordinator(channel: .dev, locationPreferences: defaults)
        let tab = makeWebsiteAccelerationTab(profile: .standard, defaults: defaults)
        tab.hostCoordinator = coordinator
        defer { tab.dispose {} }
        let cases: [(String, Bool)] = [
            ("https://debian.org/", true),
            ("http://dotdeb.org/", true),
            ("https://security.mirror.debian.org/", true),
            ("https://archive.packages.dotdeb.org/", true),
            ("https://MiRrOr.DeBiAn.OrG./", true),
            ("https://notdebian.org/", false),
            ("https://bad..debian.org/", false),
            ("https://debian.org.attacker.invalid/", false),
            ("https://dotdeb.org.attacker.invalid/", false),
            ("https://outside.invalid/files/debian.org", false),
            ("https://debian.org@outside.invalid/", false),
            ("https://_broken.debian.org/", false),
            ("https://-broken.debian.org/", false),
            ("https://debian.org../", false),
            ("https://localhost/", false),
            ("https://127.0.0.1/", false),
            ("https://[::1]/", false),
            ("https://%64ebian.org/", true),
            ("https://www.食狮.debian.org/", true),
            ("https://www.%E9%A3%9F%E7%8B%AE.debian.org/", true),
            ("ftp://debian.org/", false),
            ("file:///debian.org", false)
        ]

        for (address, expected) in cases {
            let url = try XCTUnwrap(URL(string: address))
            XCTAssertEqual(AccessWebsiteRoutePolicy().matches(url), expected, address)
            XCTAssertEqual(coordinator.requiresProxy(tab: tab, url: url), expected, address)
        }
    }

    #if DEBUG
    func testSelectingDoubanRetiresOriginalRealmAndPreservesHeldDebianNavigation() async throws {
        try await assertSelectingDoubanDuringDebianHold(managedPort: 18_631, cancelDebian: false)
    }

    func testDeselectingDebianAfterDoubanRetirementRejectsLatePreparation() async throws {
        try await assertSelectingDoubanDuringDebianHold(managedPort: 18_633, cancelDebian: true)
    }

    func testSelectingDoubanDoesNotRetireTheLiveStartPage() async throws {
        try await assertSelectingDoubanDuringDebianHold(managedPort: 18_635, cancelDebian: false, visitingStart: true)
    }

    private func fixtureTLSIdentity() throws -> (NWProtocolTLS.Options, SecCertificate) {
        let resource = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "geosite-beta-hold-test-only",
                                                               withExtension: "p12"))
        var imported: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: "web-kit-fixture",
                                      kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(try Data(contentsOf: resource) as CFData, options as CFDictionary, &imported)
        XCTAssertEqual(status, errSecSuccess)
        let item = try XCTUnwrap((imported as? [[String: Any]])?.first?[kSecImportItemIdentity as String])
        let identity = item as! SecIdentity
        var importedCertificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(identity, &importedCertificate), errSecSuccess)
        let certificate = try XCTUnwrap(importedCertificate)
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, try XCTUnwrap(sec_identity_create(identity)))
        return (tls, certificate)
    }

    private func assertSelectingDoubanDuringDebianHold(managedPort: UInt16, cancelDebian: Bool,
                                                       visitingStart: Bool = false) async throws {
        let originalPort = managedPort + 1
        let marker = UUID().uuidString
        let html = """
        <title>Original Douban \(marker)</title>
        <script>if (location.hostname === 'www.douban.com') {
          setInterval(() => fetch('/pulse?\(marker)', {cache: 'no-store'}), 60);
        }</script>
        """
        // Xcode generates this identity in the test bundle. The two fixture
        // delegates pin its leaf and all tunnel connections stay on loopback.
        let (tls, certificate) = try fixtureTLSIdentity()
        let origin = OriginReceipt(port: 0, body: html, tls: tls)
        try await origin.start()
        defer { origin.stop() }
        let original = FixtureOriginTunnels(port: origin.port)
        let managed = AnsweringOpener(finishAfterRecording: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let managedListener = try await makeListener(port: managedPort, tunnels: managed)
        let originalListener = try await makeListener(port: originalPort, tunnels: original)
        defer { try? managedListener.stop(); try? originalListener.stop() }
        try await managedListener.start(at: now)
        try await originalListener.start(at: now)

        let (defaults, suite) = try makeSmartPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = WindowPrepareGate()
        defer { gate.finish() }
        var provisionReturned = false
        let publisher = AccessProxyEntryPublisher { generation, _ in
            await gate.wait()
            provisionReturned = true
            return .init(endpoint: .init(identity: "category-hold-\(managedPort)", generation: generation,
                loopbackHost: "127.0.0.1", port: managedPort, state: .ready),
                listenerReady: true, runtimeHealthy: true, bridgeInstalled: true)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, channel: .dev, locationPreferences: defaults)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        let otherBrowser = BrowserSession(dataStore: browser.dataStore, hostCoordinator: coordinator)
        let tab = try XCTUnwrap(browser.activeTab)
        let sibling = try XCTUnwrap(otherBrowser.activeTab)
        let restoreOriginal = try observeOriginalStore(of: tab, port: originalPort)
        defer { browser.closeWindow(); otherBrowser.closeWindow(); restoreOriginal() }
        try await tab.prepareContentRulesForTests()
        try await sibling.prepareContentRulesForTests()
        let originalView = tab.webView
        let window = show(originalView)
        let siblingWindow = show(sibling.webView)
        let douban = URL(string: "https://www.douban.com/page?\(marker)")!
        let control = URL(string: "https://beta-hold-control.invalid/page?control")!
        let originalNavigation = PinnedFixtureNavigation(tab: tab, hosts: ["www.douban.com"], certificate: certificate)
        let controlNavigation = PinnedFixtureNavigation(tab: sibling, hosts: ["beta-hold-control.invalid"], certificate: certificate)
        originalView.navigationDelegate = originalNavigation
        sibling.webView.navigationDelegate = controlNavigation
        defer {
            withExtendedLifetime((originalNavigation, controlNavigation)) {}
            window.isHidden = true
            siblingWindow.isHidden = true
            let receipt = XCTAttachment(string: "managed=\(managed.authorities)\noriginal=\(original.authorities)\n\(origin.transcript)")
            receipt.name = "Original Douban retirement and held Debian route"
            receipt.lifetime = .keepAlways
            add(receipt)
        }
        let debian = URL(string: "https://debian.org/held?\(marker)")!
        let pulse = "/pulse?\(marker)"
        func pulses() -> Int { origin.transcript.components(separatedBy: pulse).count - 1 }

        tab.loadFromAddressBar(douban)
        try await waitUntil({ tab.committedMainFrameURL == douban && !tab.isLoading && pulses() >= 3 },
                            message: "The real original Douban realm must commit and send pulses. \(original.authorities) \(origin.transcript)")
        _ = try XCTUnwrap(tab.committedMainFrameURL == douban && pulses() >= 3 ? originalView : nil)
        XCTAssertEqual(originalView.title, "Original Douban \(marker)")
        XCTAssertTrue(tab.websiteDataStore === tab.originalWebsiteDataStore)
        XCTAssertTrue(original.authorities.contains("www.douban.com:443"))
        XCTAssertTrue(managed.authorities.isEmpty)

        if visitingStart {
            let start = URL(string: "aegis://start")!
            tab.load(start)
            try await waitUntil({ originalView.url == start && !tab.isLoading },
                                message: "The built-in start page must commit in the original view")
            let document = try await originalView.evaluateJavaScript("window.categoryTestMarker = '\(marker)'")
            XCTAssertEqual(document as? String, marker)
            let initial = try XCTUnwrap(coordinator.websiteCategories(for: sibling))
            coordinator.setWebsiteCategory(.douban, selected: true, from: initial, for: sibling)
            XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: douban))
            XCTAssertTrue(tab.isResident)
            XCTAssertTrue(originalView.superview === window)
            XCTAssertNil(tab.loadingError)
            let retained = try await originalView.evaluateJavaScript("window.categoryTestMarker")
            XCTAssertEqual(retained as? String, marker, "The same start-page realm must stay alive")
            XCTAssertEqual(originalView.url, start)
            XCTAssertTrue(managed.authorities.isEmpty)
            XCTAssertFalse(original.authorities.contains("debian.org:443"))
            return
        }

        tab.loadFromAddressBar(debian)
        try await waitUntil({ gate.started }, message: "Debian must await the held publisher")
        let pending = try XCTUnwrap(tab.pendingAddressNavigation)
        XCTAssertEqual(pending.url, debian)
        XCTAssertTrue(tab.webView === originalView && tab.matchesPendingAddressNavigation(pending))
        XCTAssertTrue(coordinator.isPreparingAddressProxy(tab: tab))
        XCTAssertFalse(original.authorities.contains("debian.org:443"))

        let initial = try XCTUnwrap(coordinator.websiteCategories(for: sibling))
        XCTAssertEqual(initial.selected, [.debian])
        coordinator.setWebsiteCategory(.douban, selected: true, from: initial, for: sibling)
        XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: douban))
        XCTAssertNil(originalView.superview)
        XCTAssertNil(originalView.load(URLRequest(url: douban)), "The original view must reject further navigation")
        XCTAssertTrue(tab.matchesPendingAddressNavigation(pending), "Retiring Douban must preserve the exact Debian hold")
        XCTAssertFalse(tab.isSuspended)
        var inert = false
        tab.afterCurrentDocumentBecomesInert { inert = true }
        try await waitUntil({ inert }, message: "The old WebKit realm must report its terminal document")

        if cancelDebian {
            let both = try XCTUnwrap(coordinator.websiteCategories(for: sibling))
            coordinator.setWebsiteCategory(.debian, selected: false, from: both, for: sibling)
            XCTAssertFalse(tab.matchesPendingAddressNavigation(pending))
            XCTAssertNil(tab.pendingAddressNavigation)
            XCTAssertFalse(coordinator.isPreparingAddressProxy(tab: tab))
        }
        gate.finish()
        try await waitUntil({ provisionReturned }, message: "The held provision must return after release")
        if !cancelDebian {
            try await waitUntil(seconds: 8, {
                self.attach(tab.webView, to: window)
                return managed.authorities.contains("debian.org:443")
            }, message: "The exact Debian request must send a fresh managed CONNECT after preparation")
            XCTAssertEqual(tab.boundHostName, "debian.org")
            XCTAssertFalse(tab.websiteDataStore === tab.originalWebsiteDataStore)
            XCTAssertFalse(tab.webView === originalView)
        }

        // Allow any already-issued Douban pulses to drain, then prove that the
        // original listener can still observe a separate, newly committed page.
        var lastPulseCount = pulses(), quietSince = Date()
        try await waitUntil(seconds: 2, {
            if pulses() != lastPulseCount { lastPulseCount = pulses(); quietSince = Date() }
            return Date().timeIntervalSince(quietSince) >= 0.25
        }, message: "Terminal Douban realm must stop sending pulses")
        let pulseCount = pulses()
        sibling.loadFromAddressBar(control)
        try await waitUntil({ sibling.committedMainFrameURL == control && !sibling.isLoading },
                            message: "The sibling's independent original control must commit")
        XCTAssertTrue(original.authorities.contains("beta-hold-control.invalid:443"))
        XCTAssertFalse(managed.authorities.contains("beta-hold-control.invalid:443"))
        XCTAssertFalse(managed.authorities.contains("www.douban.com:443"), "Old Douban realm must also never replay")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(pulses(), pulseCount)
        XCTAssertFalse(original.authorities.contains("debian.org:443"))
        if cancelDebian { XCTAssertFalse(managed.authorities.contains("debian.org:443")) }
    }

    func testGeoSiteSelectedOfficialDoubanUsesManagedWebKitStore() async throws {
        let managedPort: UInt16 = 18_489
        let originalPort: UInt16 = 18_490
        let managed = AnsweringOpener(finishAfterRecording: true)
        let original = AnsweringOpener(finishAfterRecording: true)
        let managedListener = try await makeListener(port: managedPort, tunnels: managed)
        let originalListener = try await makeListener(port: originalPort, tunnels: original)
        defer { try? managedListener.stop(); try? originalListener.stop() }
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await managedListener.start(at: startedAt)
        try await originalListener.start(at: startedAt)

        let (defaults, suite) = try makeSmartPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["DOUBAN"], forKey: "browser.websiteAcceleration.categories")
        let gate = WindowPrepareGate()
        defer { gate.finish() }
        let publisher = AccessProxyEntryPublisher { generation, _ in
            await gate.wait()
            return .init(endpoint: .init(identity: "official-categories", generation: generation,
                loopbackHost: "127.0.0.1", port: managedPort, state: .ready),
                listenerReady: true, runtimeHealthy: true, bridgeInstalled: true)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, channel: .dev, locationPreferences: defaults)
        let session = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        let secondSession = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        let tab = try XCTUnwrap(session.activeTab)
        let sibling = try XCTUnwrap(secondSession.activeTab)
        try await tab.prepareContentRulesForTests()
        try await sibling.prepareContentRulesForTests()
        let restoreOriginal = try observeOriginalStore(of: tab, port: originalPort)
        defer {
            withExtendedLifetime(coordinator) { session.closeWindow(); secondSession.closeWindow() }
            restoreOriginal()
        }
        let window = show(tab.webView)
        let secondWindow = show(sibling.webView)
        defer {
            window.isHidden = true
            secondWindow.isHidden = true
            let receipt = XCTAttachment(string: "managed=\(managed.authorities)\noriginal=\(original.authorities)")
            receipt.name = "Official category CONNECT witnesses"
            receipt.lifetime = .keepAlways
            add(receipt)
        }

        // Both local observers stop at CONNECT, before TLS or DNS for the target.
        func witness(_ host: String, managed expectedManaged: Bool, tab: BrowserTab, window: UIWindow,
                     duringLoad: (@MainActor () async throws -> Void)? = nil) async throws {
            let url = try XCTUnwrap(URL(string: "https://\(host)/"))
            let authority = "\(host):443"
            let priorManaged = managed.authorities.filter { $0 == authority }.count
            let priorOriginal = original.authorities.filter { $0 == authority }.count
            tab.loadFromAddressBar(url)
            try await duringLoad?()
            try await waitUntil(seconds: 12, {
                self.attach(tab.webView, to: window)
                return managed.authorities.filter { $0 == authority }.count > priorManaged
                    || original.authorities.filter { $0 == authority }.count > priorOriginal
            }, message: "Expected either local listener to record CONNECT \(authority)")
            try await waitUntil(seconds: 12, { !tab.webView.isLoading },
                                message: "WebKit did not finish the controlled CONNECT attempt for \(authority)")
            XCTAssertEqual(managed.authorities.filter { $0 == authority }.count > priorManaged,
                           expectedManaged, "Managed CONNECT \(authority)")
            XCTAssertEqual(original.authorities.filter { $0 == authority }.count > priorOriginal,
                           !expectedManaged, "Original CONNECT \(authority)")
            XCTAssertEqual(tab.websiteDataStore === tab.originalWebsiteDataStore, !expectedManaged)
        }

        try await witness("original-control.geosite.invalid", managed: false, tab: tab, window: window)
        try await witness("notdouban.com", managed: false, tab: tab, window: window)
        try await witness("debian.org", managed: false, tab: tab, window: window)
        try await witness("www.meituan.com", managed: false, tab: tab, window: window)
        try await witness("www.douban.com", managed: true, tab: tab, window: window) {
            try await self.waitUntil { gate.started }
            let pending = try XCTUnwrap(tab.pendingAddressNavigation)
            let onlyDouban = try XCTUnwrap(coordinator.websiteCategories(for: sibling))
            coordinator.setWebsiteCategory(.meituan, selected: true, from: onlyDouban, for: sibling)
            let both = try XCTUnwrap(coordinator.websiteCategories(for: sibling))
            coordinator.setWebsiteCategory(.meituan, selected: false, from: both, for: sibling)
            XCTAssertEqual(tab.pendingAddressNavigation, pending)
            XCTAssertTrue(coordinator.isPreparingAddressProxy(tab: tab))
            gate.finish()
        }

        let initial = try XCTUnwrap(coordinator.websiteCategories(for: sibling))
        coordinator.setWebsiteCategory(.douban, selected: false, from: initial, for: sibling)
        XCTAssertTrue(tab.websiteDataStore === tab.originalWebsiteDataStore, "The same owner's managed document must detach")
        XCTAssertTrue(try XCTUnwrap(coordinator.websiteCategories(for: tab)).selected.isEmpty)
        try await witness("second-original-control.geosite.invalid", managed: false, tab: sibling, window: secondWindow)
        try await witness("www.douban.com", managed: false, tab: sibling, window: secondWindow)

        let empty = try XCTUnwrap(coordinator.websiteCategories(for: tab))
        coordinator.setWebsiteCategory(.debian, selected: true, from: empty, for: tab)
        let debian = try XCTUnwrap(coordinator.websiteCategories(for: tab))
        coordinator.setWebsiteCategory(.meituan, selected: true, from: debian, for: tab)
        try await witness("debian.org", managed: true, tab: sibling, window: secondWindow)
        try await witness("www.meituan.com", managed: true, tab: sibling, window: secondWindow)
        try await witness("www.dianping.com", managed: true, tab: sibling, window: secondWindow)
    }

    func testOverseasRuleListValidatesExactScopeAndCanonicalizesOrder() throws {
        let canonical = Data("listed.geosite.invalid\nsecond.geosite.invalid\n".utf8)
        let digest = AccessGeoSiteAdmission.sha256(canonical)
        let reversed = Data("second.geosite.invalid\r\nlisted.geosite.invalid\r\n".utf8)
        let list = try XCTUnwrap(AccessOverseasRuleList(data: reversed, expectedCount: 2, expectedDigest: digest))
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.canonicalData, canonical)
        XCTAssertTrue(list.contains(try AccessSiteHost("listed.geosite.invalid")))
        XCTAssertFalse(list.contains(try AccessSiteHost("sub.listed.geosite.invalid")))
        XCTAssertNil(AccessOverseasRuleList(data: Data("listed.geosite.invalid\nlisted.geosite.invalid\n".utf8),
                                           expectedCount: 2, expectedDigest: digest))
        XCTAssertNil(AccessOverseasRuleList(data: Data("added.geosite.invalid\nsecond.geosite.invalid\n".utf8),
                                           expectedCount: 2, expectedDigest: digest))
        XCTAssertNil(AccessOverseasRuleList(data: canonical))
    }

    func testOverseasSwitchChangesExactHostRouteAndPreservesExplicitChoice() async throws {
        let managedPort: UInt16 = 18_491
        let originalPort: UInt16 = 18_492
        let managed = AnsweringOpener(body: "<title>Managed overseas</title>")
        let original = AnsweringOpener(body: "<title>Original overseas</title>")
        let managedListener = try await makeListener(port: managedPort, tunnels: managed)
        defer { try? managedListener.stop() }
        let originalListener = try await makeListener(port: originalPort, tunnels: original)
        defer { try? originalListener.stop() }
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await managedListener.start(at: startedAt)
        try await originalListener.start(at: startedAt)

        let suite = "overseas-route-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let listed = "listed.geosite.invalid"
        let data = Data((listed + "\n").utf8)
        let digest = AccessGeoSiteAdmission.sha256(data)
        let rules = try XCTUnwrap(AccessOverseasRuleList(data: data, expectedCount: 1, expectedDigest: digest))
        let coordinator = AccessHostStoreCoordinator(publisher: readyPublisher(port: managedPort), channel: .dev,
            probeRunner: AccessSiteProbeRunner(sessionFactory: {
                XCTFail("A required overseas host must never open a direct diagnostic session")
                return URLSession(configuration: .ephemeral)
            }), locationPreferences: defaults, overseasRules: rules)
        let session = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        let tab = try XCTUnwrap(session.activeTab)
        tab.keepsExplicitHTTPForTesting = true
        try await tab.prepareContentRulesForTests()
        let restore = try observeOriginalStore(of: tab, port: originalPort)
        defer {
            withExtendedLifetime(coordinator) { session.closeWindow() }
            restore()
        }
        let window = show(tab.webView)
        defer { window.isHidden = true }

        func witness(_ host: String, path: String, useManaged: Bool) async throws {
            let url = try XCTUnwrap(URL(string: "http://\(host)/\(path)"))
            tab.loadFromAddressBar(url)
            let observer = useManaged ? managed : original
            let other = useManaged ? original : managed
            let title = useManaged ? "Managed overseas" : "Original overseas"
            try await waitUntil(seconds: 12, {
                self.attach(tab.webView, to: window)
                return tab.webView.title == title && observer.transcript.contains("GET /" + path + " ")
                    && tab.liveCommittedDocumentURL == url && !tab.isLoading
            }, message: "Expected the selected route to commit and finish the synthetic page")
            XCTAssertFalse(other.transcript.contains("GET /" + path + " "))
        }

        XCTAssertFalse(coordinator.overseasAccelerationEnabled)
        try await witness(listed, path: "off", useManaged: false)
        let originalView = tab.webView
        coordinator.setOverseasAccelerationEnabled(true, for: tab)
        XCTAssertTrue(coordinator.overseasAccelerationEnabled)
        try await waitUntil(seconds: 8, { originalView.url?.absoluteString == "about:blank" },
                            message: "The original document should retire when protection becomes required")
        XCTAssertEqual(coordinator.websiteAccelerationMode, .manual)
        try await witness("sub." + listed, path: "unlisted", useManaged: false)
        try await witness(listed, path: "on", useManaged: true)
        let listedHost = try AccessSiteHost(listed)
        let protectedView = tab.webView
        let protectedStore = tab.websiteDataStore
        XCTAssertTrue(coordinator.setAutoRecoveryEnabled(true, for: tab).isArmed)
        XCTAssertTrue(coordinator.runProbe(for: tab, candidates: [listedHost]))
        try await waitUntil({ !coordinator.snapshot(for: tab).probeBusy })
        XCTAssertTrue(coordinator.snapshot(for: tab).probeSuggestionLines.contains { $0.contains("跳过直连探测") })
        XCTAssertEqual(coordinator.setAutoRecoveryEnabled(false, for: tab), .revoked)
        XCTAssertTrue(tab.webView === protectedView && tab.websiteDataStore === protectedStore)
        XCTAssertEqual(tab.boundHostName, listed)
        coordinator.setWebsiteRouteChoice(.original, for: tab, displayedHost: listedHost)
        XCTAssertEqual(coordinator.websiteRouteChoice(for: tab), .original)
        try await witness(listed, path: "override", useManaged: false)
        coordinator.setWebsiteRouteChoice(nil, for: tab, displayedHost: listedHost)
        XCTAssertNil(coordinator.websiteRouteChoice(for: tab))
        try await witness(listed, path: "cleared-override", useManaged: true)
        let managedView = tab.webView
        coordinator.setOverseasAccelerationEnabled(false, for: tab)
        XCTAssertFalse(coordinator.overseasAccelerationEnabled)
        try await waitUntil(seconds: 8, { managedView.url?.absoluteString == "about:blank" },
                            message: "The managed document should retire when its authorization is revoked")
        try await witness(listed, path: "revoked", useManaged: false)
    }

    func testOverseasRuleDoesNotAuthorizeAnUnlistedHTTPSLanding() async throws {
        try await checkOverseasHTTPSRedirect(restoredWithoutList: false)
    }

    func testOverseasSnapshotRedirectRechecksExceptionBeforeSending() async throws {
        let fixture = AccessGeoSiteCacheTests.Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .smart, categories: []))
        try cache.requestOverseasPreview()
        typealias Vector = AccessGeoSiteTestVector
        let data = Vector.group("GFWLIST-CN", rules: [Vector.rule(2, "ampproject.org")])
            + Vector.group("GFWLIST-CN-EXCLUDE", rules: [Vector.rule(2, "www.ampproject.org")])
        let candidate = try Vector.admit(data, newer: true, includeOverseas: true)
        try await cache.apply(candidate, using: XCTUnwrap(cache.updateContext()))
        let confirmation = try await cache.overseasConfirmation(for: .init(enabled: true, mode: .all))
        try await cache.confirmOverseas(confirmation) { true }
        try await checkOverseasHTTPSRedirect(restoredWithoutList: false, verifiedCache: cache)
    }

    func testOverseasCategorySelectionsChooseManagedAndOriginalExits() async throws {
        try await checkOverseasCategoryExits(.categories)
    }

    func testOverseasOfficialCategoriesChooseManagedAndOriginalExits() async throws {
        try await checkOverseasCategoryExits(.officialCategories)
    }

    func testOverseasCategoryGrantSurvivesReusingLegacyStore() async throws {
        try await checkOverseasCategoryExits(.legacyReuse)
    }

    func testOverseasCanonicalLandingRecordsTheDestinationCategory() async throws {
        try await checkOverseasCategoryExits(.canonicalLanding)
    }

    func testOverseasGrantPersistsWithIndependentDomesticSmartMatch() async throws {
        try await checkOverseasCategoryExits(.domesticOverlap)
    }

    func testOverseasCategoryRoutesIndependentlyOfManualDomesticMode() async throws {
        try await checkOverseasCategoryExits(.domesticManual)
    }

    private enum OverseasExitScenario { case categories, officialCategories, legacyReuse, canonicalLanding, domesticOverlap, domesticManual }

    private func checkOverseasCategoryExits(_ scenario: OverseasExitScenario) async throws {
        typealias Vector = AccessGeoSiteTestVector
        let reusingLegacyStore = scenario == .legacyReuse
        let choices: [(category: AccessOverseasCategory, host: String, source: String)] = [
            (.video, "www.youtube.com", "YOUTUBE"), (.ai, "gemini.google.com", "GOOGLE-GEMINI"),
            (.web, "www.google.com", "GOOGLE"), (.social, "x.com", "TWITTER"),
            (.news, "www.bbc.com", "BBC"), (.development, "github.com", "GITHUB"),
            (.reference, "archive.org", "ARCHIVE"), (.cloud, "www.dropbox.com", "DROPBOX")
        ]
        let domesticHost = "www.debian.org"
        let hosts = Set(choices.map(\.host)).union(["google.com", domesticHost])
        let candidate: AccessGeoSiteAdmission.Candidate
        if scenario == .officialCategories {
            let (metadata, database, checksum) = try await Vector.frozenOfficialAssets()
            candidate = try AccessGeoSiteAdmission.admit(metadata: metadata, database: database, checksum: checksum,
                now: Vector.now, includeOverseas: true)
            XCTAssertEqual(candidate.receipt.releaseID, 453302649)
            XCTAssertEqual(candidate.receipt.tag, "20261120235103")
        } else {
            let domestic = scenario == .domesticOverlap ? Vector.selectedProjection : Data()
            let positives = choices.map { Vector.rule(3, $0.host) } + [Vector.rule(3, domesticHost)]
            let data = domestic + Vector.group("GFWLIST-CN", rules: positives)
                + Vector.group("GFWLIST-CN-EXCLUDE", rules: [])
                + choices.reduce(into: Data()) { data, entry in
                    data.append(Vector.group(entry.source, rules: [Vector.rule(3, entry.host)]))
                }
            candidate = try Vector.admit(data, newer: true, includeOverseas: true)
        }
        let fixture = AccessGeoSiteCacheTests.Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: scenario == .domesticManual ? .manual : .smart,
                                             categories: scenario == .domesticOverlap ? [.debian] : []))
        try cache.requestOverseasPreview()
        try await cache.apply(candidate, using: XCTUnwrap(cache.updateContext()))
        if reusingLegacyStore { try cache.setSelection(.init(mode: .manual, categories: [])) }

        let (managedTLS, certificate) = try fixtureTLSIdentity()
        let (originalTLS, _) = try fixtureTLSIdentity()
        let landing = try XCTUnwrap(URL(string: "https://www.google.com/web-landing"))
        let managedBody = reusingLegacyStore ? """
            <title>Managed category</title><script>
              if (location.pathname === '/selected-DEV') history.replaceState({}, '', '/repo');
            </script>
            """ : "<title>Managed category</title>"
        let managed = OriginReceipt(port: 0, body: managedBody, tls: managedTLS,
                                    redirects: ["/web-apex": landing])
        let original = OriginReceipt(port: 0, body: "<title>Original category</title>", tls: originalTLS)
        try await managed.start()
        defer { managed.stop() }
        try await original.start()
        defer { original.stop() }
        let managedPort: UInt16 = switch scenario {
        case .categories: 18_700
        case .legacyReuse: 18_702
        case .canonicalLanding: 18_704
        case .domesticOverlap: 18_706
        case .officialCategories: 18_708
        case .domesticManual: 18_710
        }
        let originalPort = managedPort + 1
        let proxy = try await makeListener(port: managedPort, tunnels: FixtureOriginTunnels(port: managed.port, hosts: hosts, connectDelay: .milliseconds(350)))
        let direct = try await makeListener(port: originalPort, tunnels: FixtureOriginTunnels(port: original.port, hosts: hosts, connectDelay: .milliseconds(350)))
        try await proxy.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? proxy.stop() }
        try await direct.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? direct.stop() }

        let coordinator = AccessHostStoreCoordinator(publisher: readyPublisher(port: managedPort), channel: .dev,
            defaultLocationPrivacy: reusingLegacyStore, geoSiteCache: cache)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        defer { browser.closeWindow() }
        browser.setWindowForeground(true)
        let tab = try XCTUnwrap(browser.activeTab)
        let restore = try observeOriginalStore(of: tab, port: originalPort)
        defer { restore() }
        try await tab.prepareContentRulesForTests()
        let window = show(tab.webView)
        defer { window.isHidden = true }
        let navigation = PinnedFixtureNavigation(tab: tab, hosts: hosts, certificate: certificate)
        try await waitUntil { tab.liveCommittedDocumentURL?.absoluteString == "aegis://start" && !tab.isLoading }

        func choose(_ category: AccessOverseasCategory) async throws {
            let offer = try await coordinator.overseasConfirmation(.init(enabled: true, categories: [category]), for: browser)
            try await coordinator.confirmOverseas(offer, for: browser) { true }
        }
        func witness(_ host: String, path: String, managed expectedManaged: Bool, committedPath: String? = nil) async throws {
            let url = try XCTUnwrap(URL(string: "https://\(host)/\(path)"))
            let committedURL = try XCTUnwrap(URL(string: "https://\(host)/\(committedPath ?? path)"))
            let marker = "GET /\(path) "
            let expected = expectedManaged ? managed : original
            let other = expectedManaged ? original : managed
            tab.loadFromAddressBar(url)
            // A store switch can start a cold WebContent process before the fixture sees the request.
            try await waitUntil(seconds: 45, {
                let view = tab.webView
                if view.navigationDelegate !== navigation { view.navigationDelegate = navigation }
                attach(view, to: window)
                return tab.liveCommittedDocumentURL == committedURL && !tab.isLoading && expected.transcript.contains(marker)
            }, message: "Expected \(host) on the selected exit for \(path)")
            XCTAssertFalse(other.transcript.contains(marker))
        }

        if scenario == .domesticOverlap {
            try await witness(domesticHost, path: "domestic-only", managed: true)
            XCTAssertNil(coordinator.snapshot(for: tab).overseasGrant)
            let offer = try await coordinator.overseasConfirmation(.init(enabled: true, mode: .all), for: browser)
            try await coordinator.confirmOverseas(offer, for: browser) { true }
            let previous = tab.liveCommittedDocumentURL
            _ = try await tab.webView.evaluateJavaScript("""
                const download = document.createElement('a');
                download.href = '/overseas-download';
                download.download = 'receipt.txt';
                document.body.appendChild(download);
                download.click();
                true;
                """)
            try await waitUntil { browser.pendingDownloadURL?.path == "/overseas-download" }
            XCTAssertEqual(tab.liveCommittedDocumentURL, previous)
            XCTAssertNil(coordinator.snapshot(for: tab).overseasGrant)
            XCTAssertFalse(managed.transcript.contains("GET /overseas-download "))
            try await witness(domesticHost, path: "domestic-and-overseas", managed: true)
            XCTAssertEqual(coordinator.snapshot(for: tab).overseasGrant, .all(release: candidate.receipt.tag))
            return
        }
        if scenario == .domesticManual {
            XCTAssertEqual(coordinator.websiteAccelerationMode, .manual)
            try await choose(.video)
            try await witness("www.youtube.com", path: "manual-video", managed: true)
            XCTAssertEqual(coordinator.snapshot(for: tab).overseasGrant, .categories([.video], release: candidate.receipt.tag))
            try await witness("github.com", path: "manual-unselected", managed: false)
            XCTAssertNil(coordinator.snapshot(for: tab).overseasGrant)
            return
        }
        if reusingLegacyStore {
            try await witness("github.com", path: "legacy", managed: true)
            let legacy = tab.websiteDataStore
            try cache.setSelection(.init(mode: .smart, categories: []))
            try await choose(.development)
            try await witness("github.com", path: "selected-DEV", managed: true, committedPath: "repo")
            XCTAssertTrue(tab.websiteDataStore === legacy)
            XCTAssertEqual(coordinator.snapshot(for: tab).overseasGrant, .categories([.development], release: candidate.receipt.tag))
            XCTAssertFalse(managed.transcript.contains("GET /repo "))
            return
        }
        if scenario == .canonicalLanding {
            try await choose(.web)
            try await witness("google.com", path: "landing-setup", managed: false)
            coordinator.setWebsiteRouteChoice(.service, for: tab, displayedHost: try AccessSiteHost("google.com"))
            tab.loadFromAddressBar(try XCTUnwrap(URL(string: "https://google.com/web-apex")))
            try await waitUntil(seconds: 10, {
                attach(tab.webView, to: window)
                if tab.webView.navigationDelegate !== navigation { tab.webView.navigationDelegate = navigation }
                return tab.liveCommittedDocumentURL == landing && !tab.isLoading
            }, message: "Expected the canonical landing to commit")
            XCTAssertTrue(managed.transcript.contains("GET /web-apex "))
            XCTAssertTrue(managed.transcript.contains("GET /web-landing "))
            XCTAssertFalse(original.transcript.contains("GET /web-landing "))
            XCTAssertEqual(tab.parentForProxyLanding(landing), "google.com")
            XCTAssertEqual(coordinator.snapshot(for: tab).overseasGrant, .categories([.web], release: candidate.receipt.tag))
            return
        }
        for (index, entry) in choices.enumerated() {
            try await choose(entry.category)
            try await witness(entry.host, path: "selected-\(entry.category.rawValue)", managed: true)
            XCTAssertEqual(coordinator.snapshot(for: tab).overseasGrant, .categories([entry.category], release: candidate.receipt.tag))
            let control = choices[(index + 1) % choices.count].host
            try await witness(control, path: "unselected-\(entry.category.rawValue)", managed: false)
            XCTAssertNil(coordinator.snapshot(for: tab).overseasGrant)
        }
    }

    func testOverseasWithdrawalRetiresLiveDocumentBeforeSnapshotWriteCompletes() async throws {
        try await checkOverseasRetirementBeforeJournal(disabling: false)
        try await checkOverseasRetirementBeforeJournal(disabling: true)
    }

    private func checkOverseasRetirementBeforeJournal(disabling: Bool) async throws {
        let gate = AccessGeoSiteCacheTests.WriteGate()
        let observed = OSAllocatedUnfairLock(initialState: (armed: false, detached: false, journalSawDetached: false))
        let fixture = AccessGeoSiteCacheTests.Fixture { step in
            if step == .writeOverseasJournal {
                observed.withLock { if $0.armed { $0.journalSawDetached = $0.detached } }
            }
            gate.wait(step)
        }
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .smart, categories: []))
        try cache.requestOverseasPreview()
        let host = "ampproject.org"
        let source = try XCTUnwrap(URL(string: "https://\(host)/approved"))
        let v1 = try AccessGeoSiteCacheTests.overseas(1, positive: [host], excluding: [])
        try await cache.apply(v1, using: XCTUnwrap(cache.updateContext()))
        let choice = AccessOverseasSelection(enabled: true, mode: .all)
        try await cache.confirmOverseas(cache.overseasConfirmation(for: choice)) { true }
        let (tls, certificate) = try fixtureTLSIdentity()
        let origin = OriginReceipt(port: 0, body: "<title>Overseas authorization</title>", tls: tls)
        try await origin.start()
        defer { origin.stop() }
        let port: UInt16 = disabling ? 18_499 : 18_498
        let managed = try await makeListener(port: port, tunnels: FixtureOriginTunnels(port: origin.port, hosts: [host], connectDelay: .milliseconds(350)))
        try await managed.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? managed.stop() }
        let coordinator = AccessHostStoreCoordinator(publisher: readyPublisher(port: port), channel: .dev, geoSiteCache: cache)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        try await tab.prepareContentRulesForTests()
        let window = show(tab.webView)
        let navigation = PinnedFixtureNavigation(tab: tab, hosts: [host], certificate: certificate)
        defer { window.isHidden = true }
        try await waitUntil { tab.liveCommittedDocumentURL?.absoluteString == "aegis://start" && !tab.isLoading }
        tab.loadFromAddressBar(source)
        try await waitUntil(seconds: 8, {
            attach(tab.webView, to: window)
            if tab.webView.navigationDelegate !== navigation { tab.webView.navigationDelegate = navigation }
            return tab.liveCommittedDocumentURL == source && !tab.isLoading && origin.transcript.contains("GET /approved ")
        }, message: "The managed source must be live before verifying its withdrawal")
        XCTAssertEqual(coordinator.snapshot(for: tab).overseasGrant, .all(release: v1.receipt.tag))
        let withdrawnView = tab.webView
        let v2 = try AccessGeoSiteCacheTests.overseas(2, positive: [], excluding: [])
        let context = try XCTUnwrap(cache.updateContext())
        let flight = disabling ? nil : try cache.beginOverseasRefresh(using: context)
        defer { cache.endOverseasRefresh(flight) }
        let publishView = cache.onChange
        cache.onChange = { view in
            publishView?(view)
            if tab.boundHostName == nil { observed.withLock { $0.detached = true } }
        }
        defer { cache.onChange = publishView }
        observed.withLock { $0.armed = true }
        if disabling {
            try cache.disableOverseas()
            XCTAssertTrue(observed.withLock { $0.journalSawDetached })
            try await waitUntil { withdrawnView.url?.absoluteString == "about:blank" }
            XCTAssertNil(tab.boundHostName)
            return
        }
        gate.arm()
        let update = Task { try await cache.apply(v2, using: context) }
        defer { gate.release.signal() }
        try await waitUntil(seconds: 3, {
            gate.entered && withdrawnView.url?.absoluteString == "about:blank"
        }, message: "WebKit must retire the live document while the snapshot write is paused")
        XCTAssertNil(tab.boundHostName)
        XCTAssertTrue(observed.withLock { $0.journalSawDetached })
        gate.release.signal()
        try await update.value
    }

    func testOverseasMissingListPreservesAnExplicitServiceRedirect() async throws {
        try await checkOverseasHTTPSRedirect(restoredWithoutList: true)
    }

    func testOverseasSwitchOffPreservesAnExplicitOriginalHTTPSRedirect() async throws {
        try await checkOverseasHTTPSRedirect(restoredWithoutList: false, switchOffAfterRedirect: true)
    }

    private func checkOverseasHTTPSRedirect(restoredWithoutList: Bool, switchOffAfterRedirect: Bool = false,
                                            verifiedCache: AccessGeoSiteCache? = nil) async throws {
        let host = verifiedCache == nil ? "overseas-landing.invalid" : "ampproject.org"
        let child = "www." + host
        let hosts: Set<String> = [host, child]
        let marker = UUID().uuidString
        let targetPath = "/unlisted?\(marker)"
        let source = try XCTUnwrap(URL(string: "https://\(host)/approved"))
        let landing = try XCTUnwrap(URL(string: "https://\(child)\(targetPath)"))
        let (managedTLS, managedCertificate) = try fixtureTLSIdentity()
        let (originalTLS, _) = try fixtureTLSIdentity()
        let managedOrigin = OriginReceipt(port: 0, body: "<title>Access \(marker)</title>", tls: managedTLS,
                                          redirects: ["/approved": landing])
        let originalOrigin = OriginReceipt(port: 0, body: "<title>Original \(marker)</title>", tls: originalTLS,
                                           responseDelay: switchOffAfterRedirect ? 2 : 0)
        try await managedOrigin.start()
        defer { managedOrigin.stop() }
        try await originalOrigin.start()
        defer { originalOrigin.stop() }
        let managed = FixtureOriginTunnels(port: managedOrigin.port, hosts: hosts, connectDelay: .milliseconds(350))
        let original = FixtureOriginTunnels(port: originalOrigin.port, hosts: hosts, connectDelay: .milliseconds(350))
        let managedPort: UInt16 = 18_495
        let originalPort: UInt16 = 18_496
        let proxy = try await makeListener(port: managedPort, tunnels: managed)
        let direct = try await makeListener(port: originalPort, tunnels: original)
        try await proxy.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? proxy.stop() }
        try await direct.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? direct.stop() }
        let suite = "AccessOverseasRedirect.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if restoredWithoutList {
            defaults.set(true, forKey: "browser.websiteAcceleration.overseasEnabled.v1")
            defaults.set([host: "service"], forKey: "browser.websiteAcceleration.siteChoices.v1")
        } else if switchOffAfterRedirect {
            defaults.set([child: "original"], forKey: "browser.websiteAcceleration.siteChoices.v1")
        }
        let rules = restoredWithoutList || verifiedCache != nil ? nil : try makeOverseasRule(host)
        let coordinator = AccessHostStoreCoordinator(publisher: readyPublisher(port: managedPort), channel: .dev,
                                                     locationPreferences: defaults, geoSiteCache: verifiedCache, overseasRules: rules)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        let tab = try XCTUnwrap(browser.activeTab)
        let restore = try observeOriginalStore(of: tab, port: originalPort)
        defer { browser.closeWindow(); restore() }
        try await tab.prepareContentRulesForTests()
        let window = show(tab.webView)
        let navigation = PinnedFixtureNavigation(tab: tab, hosts: hosts, certificate: managedCertificate)
        defer {
            window.isHidden = true
            withExtendedLifetime(navigation) {}
        }
        if !restoredWithoutList && verifiedCache == nil { coordinator.setOverseasAccelerationEnabled(true, for: tab) }
        func attachPinnedNavigation() {
            let view = tab.webView
            attach(view, to: window)
            if view.navigationDelegate !== navigation { view.navigationDelegate = navigation }
        }
        try await waitUntil(seconds: 8, {
            tab.liveCommittedDocumentURL?.absoluteString == "aegis://start" && !tab.isLoading
        }, message: "Expected the initial WebKit document to finish before redirect testing")
        tab.loadFromAddressBar(source)
        if switchOffAfterRedirect {
            try await waitUntil {
                attachPinnedNavigation()
                return originalOrigin.transcript.contains("GET \(targetPath) ")
            }
            XCTAssertTrue(tab.isLoading)
            XCTAssertTrue(tab.websiteDataStore === tab.originalWebsiteDataStore)
            coordinator.setOverseasAccelerationEnabled(false, for: tab)
        }
        let expectedTitle = "\(restoredWithoutList ? "Access" : "Original") \(marker)"
        try await waitUntil(seconds: 12, {
            attachPinnedNavigation()
            return tab.liveCommittedDocumentURL == landing && !tab.isLoading && tab.webView.title == expectedTitle
        }, message: "Expected the HTTPS landing to commit in its selected store")
        XCTAssertEqual(tab.webView.title, expectedTitle)
        XCTAssertTrue(managedOrigin.transcript.contains("GET /approved "))
        XCTAssertEqual(originalOrigin.transcript.contains("GET \(targetPath) "), !restoredWithoutList)
        XCTAssertEqual(managedOrigin.transcript.contains("GET \(targetPath) "), restoredWithoutList)
        XCTAssertFalse(originalOrigin.transcript.contains("GET /approved "))
        if verifiedCache != nil {
            XCTAssertFalse(managed.authorities.contains("\(child):443"))
            XCTAssertTrue(original.authorities.contains("\(child):443"))
        }
        XCTAssertEqual(coordinator.requiresProxy(tab: tab, url: landing), restoredWithoutList)
        XCTAssertEqual(tab.parentForProxyLanding(landing), restoredWithoutList ? host : nil)
        XCTAssertEqual(tab.websiteDataStore === tab.originalWebsiteDataStore, !restoredWithoutList)
        let key = AccessHostStoreKey(scopeID: "ordinary", host: try AccessSiteHost(child), isPrivate: false)
        XCTAssertEqual(coordinator.registry.endpointSnapshot[key] != nil, restoredWithoutList)
    }

    func testOverseasSwitchCancelsAnUnsentOptionalHoldWithoutRetiringTheOriginalDocument() async throws {
        let host = "overseas-unsent.invalid"
        let target = try XCTUnwrap(URL(string: "https://\(host)/held"))
        let origin = OriginReceipt(port: 0, body: "<a id='next' href='\(target.absoluteString)'>Next</a>")
        try await origin.start()
        defer { origin.stop() }
        let gate = WindowPrepareGate()
        defer { gate.finish() }
        let publisher = AccessProxyEntryPublisher { _, _ in
            await gate.wait()
            throw AccessSiteSessionError.nodeUnavailable
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, channel: .dev, defaultLocationPrivacy: true,
                                                     overseasRules: try makeOverseasRule(host))
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        try await tab.prepareContentRulesForTests()
        let view = tab.webView
        let window = show(view)
        defer { window.isHidden = true }
        let original = try XCTUnwrap(URL(string: "http://localhost:\(origin.port)/first"))
        tab.load(original)
        try await waitUntil { tab.liveCommittedDocumentURL == original && !tab.isLoading }
        _ = try await view.evaluateJavaScript("window.unsavedValue = 'retained'; document.getElementById('next').click(); true")
        try await waitUntil { gate.started && tab.pendingAddressNavigation?.url == target }
        XCTAssertNil(tab.activeMainFrameNavigationURL)
        coordinator.setOverseasAccelerationEnabled(true, for: tab)
        XCTAssertNil(tab.pendingAddressNavigation)
        XCTAssertTrue(tab.webView === view)
        XCTAssertEqual(tab.liveCommittedDocumentURL, original)
        let retained = try await view.evaluateJavaScript("window.unsavedValue")
        XCTAssertEqual(retained as? String, "retained")
    }

    func testOverseasSwitchKeepsARequiredDefaultReload() async throws {
        try await checkOverseasSwitchKeepsARequiredDefaultReload(switchOff: false)
    }

    func testOverseasSwitchOffKeepsARequiredDefaultReload() async throws {
        try await checkOverseasSwitchKeepsARequiredDefaultReload(switchOff: true)
    }

    private func checkOverseasSwitchKeepsARequiredDefaultReload(switchOff: Bool) async throws {
        let host = try AccessSiteHost("overseas-default-reload.invalid")
        let port: UInt16 = 18_505
        let tunnel = AnsweringOpener(body: "<title>Protected reload</title>")
        let listener = try await makeListener(port: port, tunnels: tunnel)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let gate = WindowPrepareGate()
        defer { gate.finish() }
        let publisher = AccessProxyEntryPublisher { generation, _ in
            if generation > 1 { await gate.wait() }
            return .init(endpoint: .init(identity: "overseas-default-reload", generation: generation,
                loopbackHost: "127.0.0.1", port: port, state: .ready),
                listenerReady: true, runtimeHealthy: true, bridgeInstalled: true)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, channel: .dev, defaultLocationPrivacy: true,
                                                     overseasRules: try makeOverseasRule(host.rawValue))
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        tab.keepsExplicitHTTPForTesting = true
        try await tab.prepareContentRulesForTests()
        let window = show(tab.webView)
        defer { window.isHidden = true }
        let first = try XCTUnwrap(URL(string: "http://\(host.rawValue)/first"))
        tab.loadFromAddressBar(first)
        try await waitUntil {
            self.attach(tab.webView, to: window)
            return tab.liveCommittedDocumentURL == first && !tab.isLoading
        }
        XCTAssertEqual(tab.boundHostName, host.rawValue)
        if switchOff { coordinator.setOverseasAccelerationEnabled(true, for: tab) }
        publisher.closeCurrentGeneration()
        try await waitUntil { coordinator.snapshot(for: tab).attachment == .attachedUnavailable }
        let target = try XCTUnwrap(URL(string: "http://\(host.rawValue)/reload"))
        tab.loadFromAddressBar(target)
        try await waitUntil { gate.started && tab.pendingAddressNavigation?.url == target }
        let pending = try XCTUnwrap(tab.pendingAddressNavigation)
        XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: target))
        coordinator.setOverseasAccelerationEnabled(!switchOff, for: tab)
        XCTAssertEqual(tab.pendingAddressNavigation, pending)
        gate.finish()
        try await waitUntil {
            self.attach(tab.webView, to: window)
            return tab.liveCommittedDocumentURL == target && !tab.isLoading
        }
        XCTAssertEqual(tab.boundHostName, host.rawValue)
        XCTAssertTrue(tunnel.transcript.contains("GET /reload "))
    }

    func testOverseasSwitchOffPreservesTheExplicitServiceStatus() async throws {
        let host = "overseas-explicit-service.invalid"
        let port: UInt16 = 18_506
        let tunnel = AnsweringOpener(body: "<title>Explicit Access</title>")
        let listener = try await makeListener(port: port, tunnels: tunnel)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let suite = "AccessOverseasExplicitService.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([host: "service"], forKey: "browser.websiteAcceleration.siteChoices.v1")
        let coordinator = AccessHostStoreCoordinator(publisher: readyPublisher(port: port), channel: .dev,
                                                     defaultLocationPrivacy: true, locationPreferences: defaults,
                                                     overseasRules: try makeOverseasRule(host))
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        tab.keepsExplicitHTTPForTesting = true
        try await tab.prepareContentRulesForTests()
        let window = show(tab.webView)
        defer { window.isHidden = true }
        let target = try XCTUnwrap(URL(string: "http://\(host)/explicit"))
        tab.loadFromAddressBar(target)
        try await waitUntil {
            self.attach(tab.webView, to: window)
            return tab.liveCommittedDocumentURL == target && !tab.isLoading
        }
        XCTAssertFalse(coordinator.overseasAccelerationEnabled)
        XCTAssertEqual(coordinator.websiteRouteChoice(for: tab), .service)
        let snapshot = coordinator.snapshot(for: tab)
        XCTAssertTrue(snapshot.toggleOn)
        XCTAssertEqual(snapshot.connection, .ready)
        XCTAssertFalse(snapshot.autoRecoveryEnabled)

        coordinator.setWebsiteAccelerationMode(.smart, for: tab)
        let explicit = coordinator.snapshot(for: tab)
        XCTAssertEqual(AccessSiteProxyToggleModel.siteStatusLine(explicit), "服务连接已就绪")
        let next = target.appendingPathComponent("next")
        tab.loadFromAddressBar(next)
        try await waitUntil { tab.liveCommittedDocumentURL == next && !tab.isLoading }
        XCTAssertTrue(coordinator.setAutoRecoveryEnabled(true, for: tab).isArmed)
        XCTAssertEqual(coordinator.snapshot(for: tab).autoRecoveryLine, AccessAutoRecoveryCopy.armedOnCurrentConnection)
    }

    func testOverseasRecognizesAnApprovedActionBeforeItsProvisionalCallback() throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        let destination = try XCTUnwrap(URL(string: "https://overseas-awaiting-callback.invalid/submit"))
        tab.adoptPolicyMainFrameNavigationForTests(url: destination, method: "POST", hasReplayableBody: true)
        XCTAssertNil(tab.currentNavigationForTests)
        XCTAssertEqual(tab.activeMainFrameNavigationURL, destination)
        tab.stop()
        XCTAssertNil(tab.activeMainFrameNavigationURL)
    }

    func testOverseasSwitchStopsSentHTTPSWhileAddressOfferRemainsVisible() async throws {
        let host = "overseas-landing.invalid"
        let (tls, certificate) = try fixtureTLSIdentity()
        let origin = OriginReceipt(port: 0, tls: tls, responseDelay: 12)
        try await origin.start()
        defer { origin.stop() }
        let original = FixtureOriginTunnels(port: origin.port, hosts: [host])
        let managed = AnsweringOpener()
        let directPort: UInt16 = 18_507
        let managedPort: UInt16 = 18_508
        let directListener = try await makeListener(port: directPort, tunnels: original)
        let managedListener = try await makeListener(port: managedPort, tunnels: managed)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await directListener.start(at: now)
        defer { try? directListener.stop() }
        try await managedListener.start(at: now)
        defer { try? managedListener.stop() }

        let coordinator = AccessHostStoreCoordinator(publisher: readyPublisher(port: managedPort), channel: .dev,
            defaultLocationPrivacy: true, overseasRules: try makeOverseasRule(host))
        let first = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        let second = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        let tab = try XCTUnwrap(first.activeTab)
        let sibling = try XCTUnwrap(second.activeTab)
        let restore = try observeOriginalStore(of: tab, port: directPort)
        defer { first.closeWindow(); second.closeWindow(); restore() }
        try await tab.prepareContentRulesForTests()
        try await sibling.prepareContentRulesForTests()
        let originalView = tab.webView
        let window = show(originalView)
        let siblingWindow = show(sibling.webView)
        let navigation = PinnedFixtureNavigation(tab: tab, hosts: [host], certificate: certificate)
        originalView.navigationDelegate = navigation
        defer {
            withExtendedLifetime(navigation) {}
            window.isHidden = true
            siblingWindow.isHidden = true
        }
        coordinator.setWebsiteAccelerationMode(.smart, for: tab)
        let source = try XCTUnwrap(URL(string: "https://\(host)/slow-original"))
        let warm = try XCTUnwrap(URL(string: "https://\(host)/warm"))
        tab.loadFromAddressBar(source)
        try await waitUntil { origin.transcript.contains("GET /slow-original ") && tab.isLoading }
        XCTAssertEqual(tab.pendingAddressNavigation?.url, source)
        XCTAssertEqual(tab.activeMainFrameNavigationURL, source)
        coordinator.setWebsiteAccelerationMode(.manual, for: sibling)
        sibling.loadFromAddressBar(warm)
        try await waitUntil {
            self.attach(sibling.webView, to: siblingWindow)
            return managed.authorities.contains(host + ":443") && sibling.boundHostName == host
        }
        XCTAssertTrue(tab.websiteDataStore === tab.originalWebsiteDataStore)
        XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: source))
        coordinator.setOverseasAccelerationEnabled(true, for: sibling)
        try await waitUntil { originalView.url?.absoluteString == "about:blank" }
        XCTAssertNil(tab.liveCommittedDocumentURL)
    }

    func testOverseasSwitchRetiresAnOriginalDocumentWithAWarmSiblingHost() async throws {
        try await checkOriginalPageWithWarmSibling(listed: true, provisional: false)
    }

    func testOverseasSwitchStopsAnOriginalProvisionalLoadWithAWarmSiblingHost() async throws {
        try await checkOriginalPageWithWarmSibling(listed: true, provisional: true)
    }

    func testOverseasSwitchLeavesAnUnlistedWarmOriginalDocumentAlone() async throws {
        try await checkOriginalPageWithWarmSibling(listed: false, provisional: false)
    }

    private func checkOriginalPageWithWarmSibling(listed: Bool, provisional: Bool) async throws {
        let host = "overseas-warm.geosite.invalid"
        let direct = AnsweringOpener(body: "<title>Original warm</title>", responseDelay: provisional ? .seconds(20) : nil)
        let managed = AnsweringOpener(body: "<title>Managed warm</title>")
        let directPort: UInt16 = 18_497
        let managedPort: UInt16 = 18_498
        let directListener = try await makeListener(port: directPort, tunnels: direct)
        let managedListener = try await makeListener(port: managedPort, tunnels: managed)
        try await directListener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? directListener.stop() }
        try await managedListener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? managedListener.stop() }
        let publisher = AccessProxyEntryPublisher { generation, _ in
            if generation == 1 { throw AccessSiteSessionError.nodeUnavailable }
            return .init(endpoint: .init(identity: "overseas-warm", generation: generation,
                loopbackHost: "127.0.0.1", port: managedPort, state: .ready),
                listenerReady: true, runtimeHealthy: true, bridgeInstalled: true)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, channel: .dev, defaultLocationPrivacy: true,
                                                     overseasRules: try makeOverseasRule(listed ? host : "unrelated.invalid"))
        let first = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        let second = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        let tab = try XCTUnwrap(first.activeTab)
        let sibling = try XCTUnwrap(second.activeTab)
        let restore = try observeOriginalStore(of: tab, port: directPort)
        defer { first.closeWindow(); second.closeWindow(); restore() }
        tab.keepsExplicitHTTPForTesting = true
        sibling.keepsExplicitHTTPForTesting = true
        try await tab.prepareContentRulesForTests()
        try await sibling.prepareContentRulesForTests()
        let originalView = tab.webView
        let window = show(originalView)
        let siblingWindow = show(sibling.webView)
        defer { window.isHidden = true; siblingWindow.isHidden = true }
        let source = try XCTUnwrap(URL(string: "http://\(host)/original"))
        let warm = try XCTUnwrap(URL(string: "http://\(host)/warm"))
        tab.loadFromAddressBar(source)
        if provisional {
            try await waitUntil { tab.isLoading && direct.transcript.contains("GET /original ") }
            XCTAssertNil(tab.liveCommittedDocumentURL)
        } else {
            try await waitUntil {
                tab.liveCommittedDocumentURL == source && !tab.isLoading && direct.transcript.contains("GET /original ")
            }
        }
        XCTAssertTrue(tab.websiteDataStore === tab.originalWebsiteDataStore)
        sibling.loadFromAddressBar(warm)
        try await waitUntil {
            self.attach(sibling.webView, to: siblingWindow)
            return sibling.liveCommittedDocumentURL == warm && !sibling.isLoading
                && managed.transcript.contains("GET /warm ")
        }
        XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: source), "The warm host influences the next navigation")
        XCTAssertTrue(tab.websiteDataStore === tab.originalWebsiteDataStore)
        coordinator.setOverseasAccelerationEnabled(true, for: sibling)
        if listed {
            try await waitUntil { originalView.url?.absoluteString == "about:blank" }
            if !provisional {
                let snapshot = coordinator.snapshot(for: tab)
                XCTAssertEqual(snapshot.intentStatus, .overseasOnNextOpen)
                XCTAssertEqual(snapshot.connection, .idle)
            }
        } else {
            XCTAssertTrue(tab.webView === originalView)
            XCTAssertEqual(tab.liveCommittedDocumentURL, source)
        }
        XCTAssertEqual(sibling.liveCommittedDocumentURL, warm)
    }

    func testOverseasSwitchPreservesAUserAuthorizedPendingAddress() async throws {
        try await checkOverseasPendingAddress(expire: false)
    }

    func testOverseasSwitchPreservesTheOriginalPreparationDeadline() async throws {
        try await checkOverseasPendingAddress(expire: true)
    }

    private func checkOverseasPendingAddress(expire: Bool) async throws {
        let host = "overseas-pending.invalid"
        let port: UInt16 = 18_499
        let tunnel = AnsweringOpener()
        let listener = try await makeListener(port: port, tunnels: tunnel)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let gate = WindowPrepareGate()
        defer { gate.finish() }
        let publisher = AccessProxyEntryPublisher { generation, _ in
            await gate.wait()
            return .init(endpoint: .init(identity: "overseas-pending", generation: generation,
                loopbackHost: "127.0.0.1", port: port, state: .ready),
                listenerReady: true, runtimeHealthy: true, bridgeInstalled: true)
        }
        let clock = AccessManualPreparationClock()
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: clock, channel: .dev,
                                                     overseasRules: try makeOverseasRule(host))
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        try await tab.prepareContentRulesForTests()
        let window = show(tab.webView)
        defer { window.isHidden = true }
        let target = try XCTUnwrap(URL(string: "https://\(host)/held"))
        tab.loadFromAddressBar(target)
        let pending = try XCTUnwrap(tab.pendingAddressNavigation)
        let operation = try XCTUnwrap(coordinator.openPendingAddressViaProxy(tab: tab, pending: pending))
        try await waitUntil { gate.started }
        clock.advance(to: .seconds(10))
        coordinator.setOverseasAccelerationEnabled(true, for: tab)
        XCTAssertTrue(tab.matchesPendingAddressNavigation(pending))
        XCTAssertEqual(coordinator.openPendingAddressViaProxy(tab: tab, pending: pending), operation)
        if expire {
            clock.advance(to: .seconds(15))
            try await waitUntil { tab.lastMainFrameFailure?.url == target && !tab.isLoading }
            gate.finish()
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertEqual(tab.recoveryLoadCount, 0)
            XCTAssertTrue(tunnel.authorities.isEmpty)
            let snapshot = coordinator.snapshot(for: tab)
            XCTAssertEqual(snapshot.intentStatus, .overseasUnavailable)
            XCTAssertEqual(snapshot.connection, .unavailable)
            XCTAssertFalse(snapshot.toggleOn)
            return
        }
        gate.finish()
        try await waitUntil {
            self.attach(tab.webView, to: window)
            return tunnel.authorities.contains(host + ":443")
        }
        XCTAssertEqual(publisher.provisionCount, 1)
        XCTAssertEqual(tab.recoveryLoadCount, 1)
        XCTAssertEqual(tab.boundHostName, host)
    }

    func testOverseasFailureShowsAccessUnavailableBeforeAttaching() async throws {
        let host = "overseas-unavailable.invalid"
        let coordinator = AccessHostStoreCoordinator(channel: .dev, overseasRules: try makeOverseasRule(host))
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        let target = try XCTUnwrap(URL(string: "https://\(host)/unavailable"))
        coordinator.setOverseasAccelerationEnabled(true, for: tab)
        tab.loadFromAddressBar(target)
        try await waitUntil { tab.lastMainFrameFailure?.url == target && !tab.isLoading }
        let status = coordinator.snapshot(for: tab)
        XCTAssertEqual(status.connection, .unavailable)
        XCTAssertEqual(status.intentStatus, .overseasUnavailable)
        XCTAssertEqual(AccessSiteProxyToggleModel.siteStatusLine(status), "海外加速连接不可用")
        XCTAssertFalse(status.toggleOn)
        XCTAssertNil(tab.boundHostName)
    }

    func testOverseasPendingPreparationSurvivesAnEquivalentExplicitServiceChoice() async throws {
        let host = try AccessSiteHost("overseas-equivalent.invalid")
        let managed = AnsweringOpener()
        let original = AnsweringOpener()
        let managedPort: UInt16 = 18_503
        let originalPort: UInt16 = 18_504
        let proxy = try await makeListener(port: managedPort, tunnels: managed)
        let direct = try await makeListener(port: originalPort, tunnels: original)
        try await proxy.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? proxy.stop() }
        try await direct.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? direct.stop() }
        let gate = WindowPrepareGate()
        defer { gate.finish() }
        let publisher = AccessProxyEntryPublisher { generation, _ in
            await gate.wait()
            return .init(endpoint: .init(identity: "overseas-equivalent", generation: generation,
                loopbackHost: "127.0.0.1", port: managedPort, state: .ready),
                listenerReady: true, runtimeHealthy: true, bridgeInstalled: true)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, channel: .dev,
                                                     overseasRules: try makeOverseasRule(host.rawValue))
        let first = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        let second = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        let waiting = try XCTUnwrap(first.activeTab)
        let donor = try XCTUnwrap(second.activeTab)
        let restore = try observeOriginalStore(of: donor, port: originalPort)
        defer { first.closeWindow(); second.closeWindow(); restore() }
        try await waiting.prepareContentRulesForTests()
        try await donor.prepareContentRulesForTests()
        let waitingWindow = show(waiting.webView)
        let donorWindow = show(donor.webView)
        defer { waitingWindow.isHidden = true; donorWindow.isHidden = true }
        let displayed = try XCTUnwrap(URL(string: "https://\(host.rawValue)/settings"))
        donor.loadFromAddressBar(displayed)
        try await commitGeoSiteReviewConnect(displayed, tab: donor, window: donorWindow, observer: original)
        coordinator.setOverseasAccelerationEnabled(true, for: donor)
        XCTAssertEqual(coordinator.websiteAccelerationHost(for: donor), host)
        let target = try XCTUnwrap(URL(string: "https://\(host.rawValue)/waiting"))
        waiting.loadFromAddressBar(target)
        try await waitUntil { gate.started }
        let pending = try XCTUnwrap(waiting.pendingAddressNavigation)
        let operation = try XCTUnwrap(coordinator.openPendingAddressViaProxy(tab: waiting, pending: pending))
        coordinator.setWebsiteRouteChoice(.service, for: donor, displayedHost: host)
        XCTAssertEqual(coordinator.websiteRouteChoice(for: donor), .service)
        XCTAssertEqual(coordinator.openPendingAddressViaProxy(tab: waiting, pending: pending), operation)
        gate.finish()
        try await waitUntil {
            self.attach(waiting.webView, to: waitingWindow)
            return managed.authorities.contains(host.rawValue + ":443")
        }
        XCTAssertEqual(waiting.recoveryLoadCount, 1)
        XCTAssertEqual(publisher.provisionCount, 1)
    }

    func testOverseasPolicyDoesNotKeepARevokedRecoveryGroupExecuting() async throws {
        let host = "overseas-group.invalid"
        let managed = AnsweringOpener()
        let original = AnsweringOpener()
        let managedPort: UInt16 = 18_501
        let originalPort: UInt16 = 18_502
        let managedListener = try await makeListener(port: managedPort, tunnels: managed)
        let originalListener = try await makeListener(port: originalPort, tunnels: original)
        try await managedListener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? managedListener.stop() }
        try await originalListener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? originalListener.stop() }
        let coordinator = AccessHostStoreCoordinator(publisher: readyPublisher(port: managedPort), channel: .dev,
                                                     overseasRules: try makeOverseasRule(host))
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        let tab = try XCTUnwrap(browser.activeTab)
        let restore = try observeOriginalStore(of: tab, port: originalPort)
        defer { browser.closeWindow(); restore() }
        try await tab.prepareContentRulesForTests()
        let window = show(tab.webView)
        defer { window.isHidden = true }
        coordinator.setWebsiteAccelerationMode(.smart, for: tab)

        let source = try XCTUnwrap(URL(string: "https://\(host)/first"))
        tab.loadFromAddressBar(source)
        try await commitGeoSiteReviewConnect(source, tab: tab, window: window, observer: original)
        XCTAssertTrue(coordinator.setAutoRecoveryEnabled(true, for: tab).isArmed)
        let failing = try XCTUnwrap(URL(string: "https://\(host)/failure"))
        tab.loadFromAddressBar(failing)
        try await waitUntil {
            tab.webView.url == failing && tab.currentNavigationForTests != nil
        }
        deliverFailure(tab)
        try await commitGeoSiteReviewConnect(failing, tab: tab, window: window, observer: managed)
        XCTAssertEqual(tab.recoveryLoadCount, 1)

        let reloaded = try XCTUnwrap(URL(string: "https://\(host)/reloaded"))
        let previousConnects = managed.authorities.filter { $0 == host + ":443" }.count
        tab.loadFromAddressBar(reloaded)
        try await commitGeoSiteReviewConnect(reloaded, tab: tab, window: window, observer: managed, after: previousConnects)
        XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: reloaded))
        coordinator.setOverseasAccelerationEnabled(true, for: tab)
        let retainedView = tab.webView
        XCTAssertEqual(coordinator.setAutoRecoveryEnabled(false, for: tab), .revoked)
        XCTAssertTrue(tab.webView === retainedView)
        XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: reloaded))
        XCTAssertTrue(coordinator.setAutoRecoveryEnabled(true, for: tab).isArmed)
        coordinator.setOverseasAccelerationEnabled(false, for: tab)
        XCTAssertFalse(coordinator.requiresProxy(tab: tab, url: reloaded))
        XCTAssertNil(tab.boundHostName)
    }

    func testOverseasOnlyAttachmentStaysIndependentWhenItsEntryFails() async throws {
        let host = "overseas-attached.invalid"
        let port: UInt16 = 18_500
        let managed = AnsweringOpener(body: "<title>Protected page</title>")
        let listener = try await makeListener(port: port, tunnels: managed)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let publisher = readyPublisher(port: port)
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, channel: .dev,
            defaultLocationPrivacy: true, overseasRules: try makeOverseasRule(host))
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        tab.keepsExplicitHTTPForTesting = true
        try await tab.prepareContentRulesForTests()
        let window = show(tab.webView)
        defer { window.isHidden = true }
        let url = try XCTUnwrap(URL(string: "http://\(host)/protected"))
        coordinator.setOverseasAccelerationEnabled(true, for: tab)
        tab.loadFromAddressBar(url)
        try await waitUntil {
            self.attach(tab.webView, to: window)
            return tab.liveCommittedDocumentURL == url && !tab.isLoading
        }
        let attached = coordinator.snapshot(for: tab)
        XCTAssertEqual(attached.intentStatus, .overseasProtected)
        XCTAssertFalse(attached.toggleOn)
        publisher.closeCurrentGeneration()
        try await waitUntil {
            coordinator.snapshot(for: tab).attachment == .attachedUnavailable
        }
        let failed = coordinator.snapshot(for: tab)
        XCTAssertEqual(AccessSiteProxyToggleModel.siteStatusLine(failed), "连接失败，未切回原连接")
        XCTAssertFalse(failed.toggleOn)
        XCTAssertEqual(tab.boundHostName, host)
    }

    private func makeOverseasRule(_ host: String) throws -> AccessOverseasRuleList {
        let data = Data((host + "\n").utf8)
        return try XCTUnwrap(AccessOverseasRuleList(
            data: data, expectedCount: 1, expectedDigest: AccessGeoSiteAdmission.sha256(data)))
    }

    func testOverseasListLossBlocksNewRoutesUntilOptOutAndUsesExistingOwnerGate() throws {
        let suite = "overseas-policy-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "browser.websiteAcceleration.overseasEnabled.v1")
        defaults.set(Data("invalid.geosite.invalid\n".utf8), forKey: "browser.websiteAcceleration.overseasHosts.v1")
        let url = try XCTUnwrap(URL(string: "https://listed.geosite.invalid/"))

        let coordinator = AccessHostStoreCoordinator(channel: .dev, locationPreferences: defaults)
        let session = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        defer { session.closeWindow() }
        let tab = try XCTUnwrap(session.activeTab)
        XCTAssertTrue(coordinator.overseasAccelerationEnabled)
        XCTAssertEqual(coordinator.overseasAccelerationHostCount, 0)
        XCTAssertTrue(coordinator.isMainFrameRouteIndeterminate(tab: tab, url: url))
        XCTAssertFalse(coordinator.installOverseasAccelerationList(Data(), for: tab))
        let other = AccessHostStoreCoordinator(channel: .dev)
        let otherSession = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: other)
        defer { otherSession.closeWindow() }
        let otherTab = try XCTUnwrap(otherSession.activeTab)
        coordinator.setOverseasAccelerationEnabled(false, for: otherTab)
        XCTAssertTrue(coordinator.overseasAccelerationEnabled)
        XCTAssertTrue(defaults.bool(forKey: "browser.websiteAcceleration.overseasEnabled.v1"))
        coordinator.setOverseasAccelerationEnabled(false, for: tab)
        XCTAssertFalse(coordinator.isMainFrameRouteIndeterminate(tab: tab, url: url))
        XCTAssertFalse(defaults.bool(forKey: "browser.websiteAcceleration.overseasEnabled.v1"))

        defaults.set(true, forKey: "browser.websiteAcceleration.overseasEnabled.v1")
        let release = AccessHostStoreCoordinator(channel: .release, locationPreferences: defaults)
        let releaseSession = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: release)
        defer { releaseSession.closeWindow() }
        let releaseTab = try XCTUnwrap(releaseSession.activeTab)
        XCTAssertFalse(release.offersWebsiteAcceleration(for: releaseTab))
        XCTAssertFalse(release.overseasAccelerationEnabled)
        XCTAssertFalse(release.isMainFrameRouteIndeterminate(tab: releaseTab, url: url))
    }

    @MainActor
    func testGeoSiteTopLevelNavigationSelectsManagedOrOriginal() async throws {
        let managedPort: UInt16 = 18_471
        let originalPort: UInt16 = 18_472
        let managed = AnsweringOpener(finishAfterRecording: true)
        let original = AnsweringOpener(finishAfterRecording: true)
        let managedListener = try await makeListener(port: managedPort, tunnels: managed)
        defer { try? managedListener.stop() }
        let originalListener = try await makeListener(port: originalPort, tunnels: original)
        defer { try? originalListener.stop() }

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await managedListener.start(at: startedAt)
        try await originalListener.start(at: startedAt)

        let (defaults, suite) = try makeSmartPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AccessHostStoreCoordinator(publisher: readyPublisher(port: managedPort), channel: .dev,
            defaultLocationPrivacy: true, locationPreferences: defaults, websiteRoutePolicy: .geositeFixture)
        let session = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        let tab = try XCTUnwrap(session.activeTab)
        try await tab.prepareContentRulesForTests()

        let restoreOriginal = try observeOriginalStore(of: tab, port: originalPort)
        defer {
            withExtendedLifetime(coordinator) { session.closeWindow() }
            restoreOriginal()
        }

        let window = show(tab.webView)
        defer { window.isHidden = true }

        let cases: [(host: String, expectsManaged: Bool)] = [
            ("debian.org.geosite.invalid", true),
            ("notdebian.org.geosite.invalid", false),
            ("packages.dotdeb.org.geosite.invalid", true),
            ("debian.org.attacker.geosite.invalid", false)
        ]

        func assertRoute(for authority: String, expectsManaged: Bool) {
            XCTAssertEqual(managed.authorities.contains(authority), expectsManaged, "Managed CONNECT \(authority)")
            XCTAssertEqual(original.authorities.contains(authority), !expectsManaged, "Original CONNECT \(authority)")
        }

        // Both observers finish after recording CONNECT. The witness is proxy
        // selection, with no TLS handshake or page-load assertion.
        for (host, expectsManaged) in cases {
            let authority = "\(host):443"
            let url = try XCTUnwrap(URL(string: "https://\(authority)/"))
            tab.stop()
            tab.loadFromAddressBar(url)
            try await waitUntil(seconds: 12, {
                self.attach(tab.webView, to: window)
                return managed.authorities.contains(authority) || original.authorities.contains(authority)
            }, message: "Expected either listener to record CONNECT \(authority)")
            try await waitUntil(seconds: 12, { !tab.webView.isLoading },
                                message: "WebKit did not finish the controlled CONNECT attempt for \(authority)")
            assertRoute(for: authority, expectsManaged: expectsManaged)
        }

        tab.stop()
        let receipt = XCTAttachment(string: "managed=\(managed.authorities)\noriginal=\(original.authorities)")
        receipt.name = "GeoSite top-level CONNECT witnesses"
        receipt.lifetime = .keepAlways
        add(receipt)

        for (host, expectsManaged) in cases {
            assertRoute(for: "\(host):443", expectsManaged: expectsManaged)
        }
    }

    func testGeoSiteUnavailableEntryKeepsMatchedNavigationOffOriginal() async throws {
        let port: UInt16 = 18_473
        let original = AnsweringOpener(finishAfterRecording: true)
        let listener = try await makeListener(port: port, tunnels: original)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }

        let publisher = AccessProxyEntryPublisher { _, _ in throw AccessSiteSessionError.nodeUnavailable }
        let (defaults, suite) = try makeSmartPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, channel: .dev,
            defaultLocationPrivacy: true, locationPreferences: defaults, websiteRoutePolicy: .geositeFixture)
        let session = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        let tab = try XCTUnwrap(session.activeTab)
        try await tab.prepareContentRulesForTests()
        let restoreOriginal = try observeOriginalStore(of: tab, port: port)
        defer {
            withExtendedLifetime(coordinator) { session.closeWindow() }
            restoreOriginal()
        }
        let window = show(tab.webView)
        defer { window.isHidden = true }

        let member = "security.debian.org.geosite.invalid"
        let outside = "control.geosite.invalid"
        tab.loadFromAddressBar(try XCTUnwrap(URL(string: "https://\(member)/")))
        try await waitUntil(seconds: 12, {
            self.attach(tab.webView, to: window)
            return tab.loadingError != nil
        }, message: "The unavailable managed entry must terminate the matched navigation")
        XCTAssertEqual(publisher.provisionCount, 1)
        XCTAssertTrue(tab.loadingErrorAllowsProxyRetry)

        tab.loadFromAddressBar(try XCTUnwrap(URL(string: "https://\(outside)/")))
        try await waitUntil(seconds: 12, {
            self.attach(tab.webView, to: window)
            return original.authorities.contains("\(outside):443")
        }, message: "The original listener must positively witness the control navigation")
        try await waitUntil(seconds: 12, { !tab.webView.isLoading },
                            message: "WebKit did not finish the control navigation")
        tab.stop()
        XCTAssertFalse(original.authorities.contains("\(member):443"))
        let receipt = XCTAttachment(string: "provisions=\(publisher.provisionCount)\noriginal=\(original.authorities)")
        receipt.name = "GeoSite unavailable entry witness"
        receipt.lifetime = .keepAlways
        add(receipt)
    }
    #endif

    private func makeSmartPreferences() throws -> (UserDefaults, String) {
        let name = "test.geosite." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set("smart", forKey: "browser.websiteAcceleration.mode")
        return (defaults, name)
    }

    func testWebsiteAccelerationExactStoreCannotCrossOwners() async throws {
        let suite = "test.website-route-owner." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = try AccessSiteHost("ready-owner.example.invalid")
        let coldHost = try AccessSiteHost("cold-owner.example.invalid")
        let target = try XCTUnwrap(URL(string: "https://\(host.rawValue)/"))
        let coldTarget = try XCTUnwrap(URL(string: "https://\(coldHost.rawValue)/"))
        defaults.set([host.rawValue: "service", coldHost.rawValue: "service"],
                     forKey: "browser.websiteAcceleration.siteChoices.v1")
        let publisher = readyPublisher(port: 20_404)
        let owner = AccessHostStoreCoordinator(publisher: publisher, channel: .dev, locationPreferences: defaults)
        let otherOwner = AccessHostStoreCoordinator(channel: .dev)
        func makeTab(for coordinator: AccessHostStoreCoordinator) -> BrowserTab {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let tab = BrowserTab(profile: .standard, configuration: configuration,
                                 preferences: BrowserPreferences(defaults: defaults))
            tab.configurationFactory = { store in
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = store
                return configuration
            }
            tab.hostCoordinator = coordinator
            return tab
        }
        let owned = makeTab(for: owner)
        let foreign = makeTab(for: otherOwner)
        defer {
            owner.tabClosed(owned)
            owner.tabClosed(foreign)
            owner.releaseIdleResources()
        }

        XCTAssertTrue(owner.requiresProxy(tab: owned, url: target))
        XCTAssertTrue(owner.requiresProxyPreparation(tab: owned, url: target))
        let prepared = try await publisher.prepare(.init(operationID: UUID(), deadline: owner.clock.now + owner.prepareBudget))
        defer { publisher.cancel(operationID: prepared.operationID) }
        let key = AccessHostStoreKey(scopeID: "ordinary", host: host, isPrivate: false)
        XCTAssertTrue(owner.retainLandingEndpoint(prepared.endpoint, for: key))
        let store = try XCTUnwrap(owner.dataStoreForMainFrame(tab: owned, url: target))
        XCTAssertFalse(store.isPersistent)
        XCTAssertEqual(store.proxyConfigurations.count, 1)
        owned.rebindWebsiteDataStore(store, host: host.rawValue)
        XCTAssertTrue(owned.websiteDataStore === store)
        XCTAssertTrue(owner.canSendMainFrame(tab: owned, url: target))
        XCTAssertFalse(owner.requiresProxyPreparation(tab: owned, url: target))

        for coordinator in [otherOwner, nil] as [AccessHostStoreCoordinator?] {
            foreign.hostCoordinator = coordinator
            let tabState = coordinator == nil ? "detached" : "foreign"
            XCTAssertFalse(owner.requiresProxy(tab: foreign, url: target), "\(tabState) tab received the owner's route")
            XCTAssertFalse(owner.wouldSwitchStore(tab: foreign, url: target), "\(tabState) tab was routed to the owner's store")
            XCTAssertNil(owner.dataStoreForMainFrame(tab: foreign, url: target), "\(tabState) tab acquired the owner's store")
            XCTAssertFalse(owner.registry.isBound(foreign.instanceID.uuidString, to: key),
                           "\(tabState) tab entered the owner's registry")
        }
        XCTAssertTrue(owner.registry.isBound(owned.instanceID.uuidString, to: key))
        XCTAssertTrue(owner.dataStoreForMainFrame(tab: owned, url: target) === store)

        foreign.hostCoordinator = otherOwner
        foreign.adoptPolicyMainFrameNavigationForTests(url: coldTarget)
        XCTAssertTrue(owner.requiresProxyPreparation(tab: owned, url: coldTarget))
        XCTAssertFalse(owner.requiresProxyPreparation(tab: foreign, url: coldTarget), "Foreign tab received a preparation grant")
        XCTAssertFalse(owner.prepareProxyNavigation(tab: foreign, request: URLRequest(url: coldTarget)),
                       "Foreign tab started the owner's preparation")
        XCTAssertNil(foreign.heldProxyRequestForTests, "Foreign tab's load was held by the owner")
        XCTAssertEqual(owner.retainedOperationCount, 0, "Owner retained a foreign preparation")
        XCTAssertEqual(owner.registry.endpointSnapshot, [key: prepared.endpoint])

        owned.hostCoordinator = otherOwner
        XCTAssertFalse(owner.canSendMainFrame(tab: owned, url: target), "Stale owner authorized a send on its old store")
        XCTAssertNil(owner.dataStoreForMainFrame(tab: owned, url: target), "Stale owner returned its old store")
    }

    func testWebsiteAccelerationSiteChoicesOverrideInBothDirectionsAndRestoreAcrossWindows() throws {
        let (defaults, suite) = try makeSmartPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let publisher = readyPublisher(port: 18_474)
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, channel: .dev, locationPreferences: defaults)
        let first = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        let second = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        defer { first.closeWindow(); second.closeWindow() }
        let tab = try XCTUnwrap(first.activeTab)
        let sibling = try XCTUnwrap(second.activeTab)
        let member = try XCTUnwrap(URL(string: "https://debian.org/site"))
        let memberHost = try AccessSiteHost("debian.org")
        let miss = try XCTUnwrap(URL(string: "https://outside.invalid/site"))
        let missHost = try AccessSiteHost("outside.invalid")

        tab.adoptPolicyMainFrameNavigationForTests(url: member)
        tab.commitPendingMainFrameForTests()
        coordinator.setWebsiteRouteChoice(.original, for: tab, displayedHost: missHost)
        XCTAssertTrue(coordinator.requiresProxy(tab: sibling, url: member), "A stale displayed host cannot change the site's choice")
        coordinator.setWebsiteRouteChoice(.original, for: tab, displayedHost: memberHost)
        XCTAssertFalse(coordinator.requiresProxy(tab: sibling, url: member))
        XCTAssertFalse(coordinator.requiresProxyPreparation(tab: sibling, url: member))

        tab.adoptPolicyMainFrameNavigationForTests(url: miss)
        tab.commitPendingMainFrameForTests()
        coordinator.setWebsiteRouteChoice(.service, for: tab, displayedHost: missHost)
        XCTAssertTrue(coordinator.requiresProxy(tab: sibling, url: miss))
        XCTAssertTrue(coordinator.requiresProxyPreparation(tab: sibling, url: miss))

        let recreated = AccessHostStoreCoordinator(publisher: publisher, channel: .dev, locationPreferences: defaults)
        first.hostCoordinator = recreated
        second.hostCoordinator = recreated
        XCTAssertEqual(recreated.websiteAccelerationMode, .smart)
        XCTAssertFalse(recreated.requiresProxy(tab: sibling, url: member))
        XCTAssertTrue(recreated.requiresProxy(tab: sibling, url: miss))
        recreated.setWebsiteRouteChoice(nil, for: tab, displayedHost: missHost)
        XCTAssertFalse(recreated.requiresProxy(tab: sibling, url: miss))
        tab.adoptPolicyMainFrameNavigationForTests(url: member)
        tab.commitPendingMainFrameForTests()
        recreated.setWebsiteRouteChoice(nil, for: tab, displayedHost: memberHost)
        XCTAssertTrue(recreated.requiresProxy(tab: sibling, url: member))
        recreated.setWebsiteAccelerationMode(.manual, for: tab)
        XCTAssertFalse(recreated.requiresProxy(tab: sibling, url: member))
        XCTAssertEqual(AccessHostStoreCoordinator(channel: .dev, locationPreferences: defaults).websiteAccelerationMode, .manual)
        XCTAssertEqual(publisher.provisionCount, 0)
    }

    func testWebsiteAccelerationPauseKeepsOnlyTheVerifiedDisplayedSiteEditable() throws {
        let (defaults, suite) = try makeSmartPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let publisher = readyPublisher(port: 18_474)
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, channel: .dev, locationPreferences: defaults)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        let site = try XCTUnwrap(URL(string: "https://debian.org/site"))
        let host = try AccessSiteHost("debian.org")

        tab.adoptPolicyMainFrameNavigationForTests(url: site)
        tab.commitPendingMainFrameForTests()
        coordinator.setWebsiteAccelerationMode(.manual, for: tab)
        XCTAssertFalse(tab.isLoading)
        XCTAssertEqual(coordinator.websiteAccelerationHost(for: tab), host)
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)

        tab.adoptPolicyMainFrameNavigationForTests(url: site, method: "POST")
        XCTAssertNil(coordinator.websiteAccelerationHost(for: tab), "A new navigation to the same URL invalidates the paused site's choice.")
        coordinator.setWebsiteRouteChoice(.service, for: tab, displayedHost: host)
        XCTAssertFalse(coordinator.requiresProxy(tab: tab, url: site))

        tab.commitPendingMainFrameForTests()
        coordinator.setWebsiteAccelerationMode(.smart, for: tab)
        XCTAssertFalse(tab.isLoading)
        XCTAssertNil(coordinator.websiteAccelerationHost(for: tab), "Pausing a POST cannot make its site editable.")
        coordinator.setWebsiteRouteChoice(.original, for: tab, displayedHost: host)
        XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: site))
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
        XCTAssertEqual(tab.recoveryLoadCount, 0)
        XCTAssertEqual(publisher.provisionCount, 0)
    }

    #if DEBUG
    func testWebsiteAccelerationDiscardsLateReadyAfterModeChangeSiteChangeOrLeaving() async throws {
        enum Change: CaseIterable { case manual, original, leave }
        for change in Change.allCases {
            let gate = WindowPrepareGate()
            defer { gate.finish() }
            let publisher = AccessProxyEntryPublisher { generation, _ in
                await gate.wait()
                return .init(endpoint: .init(identity: "late-geosite", generation: generation,
                    loopbackHost: "127.0.0.1", port: 18_474, state: .ready),
                    listenerReady: true, runtimeHealthy: true, bridgeInstalled: true)
            }
            let (defaults, suite) = try makeSmartPreferences()
            defer { defaults.removePersistentDomain(forName: suite) }
            let coordinator = AccessHostStoreCoordinator(publisher: publisher, channel: .dev, locationPreferences: defaults,
                                                         websiteRoutePolicy: .geositeFixture)
            let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
            let anotherWindow = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
            defer { browser.closeWindow(); anotherWindow.closeWindow() }
            let tab = try XCTUnwrap(browser.activeTab)
            let sibling = try XCTUnwrap(anotherWindow.activeTab)
            let host = try AccessSiteHost("debian.org.geosite.invalid")
            let target = try XCTUnwrap(URL(string: "https://\(host.rawValue)/held"))
            sibling.adoptPolicyMainFrameNavigationForTests(url: target)
            sibling.commitPendingMainFrameForTests()
            tab.loadFromAddressBar(target)
            try await waitUntil({ gate.started }, message: "The matched request must start preparation")
            XCTAssertNotNil(tab.heldProxyRequestForTests)
            switch change {
            case .manual: coordinator.setWebsiteAccelerationMode(.manual, for: sibling)
            case .original: coordinator.setWebsiteRouteChoice(.original, for: sibling, displayedHost: host)
            case .leave: tab.load(try XCTUnwrap(URL(string: "aegis://start")))
            }
            XCTAssertNil(tab.heldProxyRequestForTests)
            gate.finish()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(tab.recoveryLoadCount, 0)
            XCTAssertNil(publisher.currentEndpoint)
            XCTAssertNil(coordinator.registry.endpoint(scopeID: "ordinary", host: host, isPrivate: false))
            XCTAssertNil(coordinator.registry.store(scopeID: "ordinary", host: host, isPrivate: false))
            XCTAssertTrue(tab.websiteDataStore === tab.originalWebsiteDataStore)
        }
    }

    func testWebsiteAccelerationRequiredPreparationTimesOutWithoutDefaultFallback() async throws {
        let (defaults, suite) = try makeSmartPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = AccessManualPreparationClock()
        let publisher = AccessProxyEntryPublisher { _, _ in
            try await clock.sleep(until: .seconds(20))
            throw AccessSiteSessionError.nodeUnavailable
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: clock, channel: .dev,
            defaultLocationPrivacy: true, locationPreferences: defaults, websiteRoutePolicy: .geositeFixture)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        let target = try XCTUnwrap(URL(string: "https://dotdeb.org.geosite.invalid/hold"))
        tab.loadFromAddressBar(target)
        try await waitUntil { publisher.provisionCount == 1 }
        clock.advance(to: .seconds(15))
        try await waitUntil { tab.loadingError != nil && tab.pendingAddressNavigation == nil }
        XCTAssertTrue(tab.canTryDefaultRoute(for: target), "A required route never records a first-visit fallback")
        XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: target))
        XCTAssertFalse(tab.isLoading)
        XCTAssertEqual(tab.recoveryLoadCount, 0)
        XCTAssertTrue(coordinator.registry.endpointSnapshot.isEmpty)
    }

#if DEBUG && targetEnvironment(simulator)
    func testOfficialGeoSiteConsentAndWithdrawalRetireOnlyAffectedLiveTraffic() async throws {
        let fixture = try GeoSiteHTTPSFixture()
        try await fixture.select("expand", version: 1, reset: true)
        let simulatedOffset = OSAllocatedUnfairLock(initialState: 0.0)
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AccessGeoSiteStorage(directory: location, service: "geosite-switch." + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: location)
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: storage.service] as CFDictionary)
        }
        let cache = AccessGeoSiteCache(storage: storage, time: .init(wall: { Date().addingTimeInterval(simulatedOffset.withLock { $0 }) }))
        await cache.restore(migrating: .init(mode: .smart, categories: [.debian, .douban]))
        XCTAssertEqual(cache.status, .ready)

        func page(_ title: String) -> String {
            """
            <title>\(title)</title><script>
            const path = location.pathname;
            fetch('/pulse-resource' + path, {cache: 'no-store'});
            setInterval(() => fetch('/pulse-script' + path, {cache: 'no-store'}), 80);
            window.worker = new Worker('/geo-worker.js?' + path);
            </script>
            """
        }
        let script = """
        const path = self.location.search.slice(1);
        setInterval(() => fetch('/pulse-worker' + path, {cache: 'no-store'}), 100);
        """
        let managed = AnsweringOpener(body: page("Managed GeoSite"), workerScript: script)
        let original = AnsweringOpener(body: page("Original GeoSite"), workerScript: script)
        let managedPort: UInt16 = 18_641
        let originalPort: UInt16 = 18_642
        let managedListener = try await makeListener(port: managedPort, tunnels: managed)
        defer { try? managedListener.stop() }
        let originalListener = try await makeListener(port: originalPort, tunnels: original)
        defer { try? originalListener.stop() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await managedListener.start(at: date)
        try await originalListener.start(at: date)
        let coordinator = AccessHostStoreCoordinator(publisher: readyPublisher(port: managedPort), channel: .dev,
            geoSiteCache: cache, geoSiteTransport: fixture.transport())
        let (defaults, suite) = try makeSmartPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BrowserPreferences(defaults: defaults)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), preferences: preferences,
                                     hostCoordinator: coordinator)
        let other = BrowserSession(dataStore: browser.dataStore, preferences: preferences, hostCoordinator: coordinator)
        let tab = try XCTUnwrap(browser.activeTab)
        let sibling = try XCTUnwrap(other.activeTab)
        tab.keepsExplicitHTTPForTesting = true
        sibling.keepsExplicitHTTPForTesting = true
        let restoreOriginal = try observeOriginalStore(of: tab, port: originalPort)
        defer { browser.closeWindow(); other.closeWindow(); restoreOriginal() }
        try await tab.prepareContentRulesForTests()
        try await sibling.prepareContentRulesForTests()
        let window = show(tab.webView)
        let otherWindow = show(sibling.webView)
        defer {
            window.isHidden = true
            otherWindow.isHidden = true
            let receipt = XCTAttachment(string: """
            original authorities=\(Set(original.authorities).sorted())
            managed authorities=\(Set(managed.authorities).sorted())
            original resource=\(requests(original, "/pulse-resource/original")) script=\(requests(original, "/pulse-script/original")) worker=\(requests(original, "/pulse-worker/original"))
            managed write=\(requests(managed, "POST /written")) script=\(requests(managed, "/pulse-script/written")) worker=\(requests(managed, "/pulse-worker/written"))
            independent script=\(requests(managed, "/pulse-script/independent")) worker=\(requests(managed, "/pulse-worker/independent"))
            """)
            receipt.name = "GeoSite switch listener witnesses"
            receipt.lifetime = .keepAlways
            add(receipt)
        }

        func requests(_ listener: AnsweringOpener, _ path: String) -> Int {
            listener.transcript.components(separatedBy: path + " ").count - 1
        }
        func route(_ path: String, host: String = "expanded.example.com") -> URL {
            URL(string: "http://\(host)/\(path)")!
        }
        func awaitPage(_ tab: BrowserTab, in window: UIWindow, title: String,
                       listener: AnsweringOpener, path: String) async throws {
            func pageIsLive() -> Bool {
                self.attach(tab.webView, to: window)
                return tab.webView.title == title && requests(listener, "/pulse-resource/" + path) > 0
                    && requests(listener, "/pulse-script/" + path) > 1 && requests(listener, "/pulse-worker/" + path) > 1
            }
            try await waitUntil(seconds: 12, pageIsLive, message: "Expected page, resource, script and worker at \(path)")
            _ = try XCTUnwrap(pageIsLive() ? tab.webView.title : nil,
                "Fixture traffic never became live. Title: \(tab.webView.title ?? "") error: \(tab.loadingError ?? "")")
        }
        func proveStopped(_ oldView: WKWebView, listener: AnsweringOpener, path: String) async throws {
            try await waitUntil(seconds: 8, { oldView.url?.absoluteString == "about:blank" },
                                message: "The affected WebKit document must become inert")
            XCTAssertNil(oldView.load(URLRequest(url: route("resurrect"))))
            try await Task.sleep(for: .milliseconds(180))
            let scriptCount = requests(listener, "/pulse-script/" + path)
            let workerCount = requests(listener, "/pulse-worker/" + path)
            let controlCount = requests(managed, "/pulse-worker/independent")
            try await Task.sleep(for: .milliseconds(420))
            XCTAssertEqual(requests(listener, "/pulse-script/" + path), scriptCount)
            XCTAssertEqual(requests(listener, "/pulse-worker/" + path), workerCount)
            XCTAssertGreaterThan(requests(managed, "/pulse-worker/independent"), controlCount)
        }

        // The active tabs schedule their own start-page loads. Let those
        // commits settle before sending either test document.
        func windowsAreReady() -> Bool {
            [tab, sibling].allSatisfy {
                $0.liveCommittedDocumentURL?.absoluteString == "aegis://start" && !$0.isLoading
            }
        }
        try await waitUntil(seconds: 8, windowsAreReady, message: "Both initial WebKit documents must finish")
        guard windowsAreReady() else { throw CocoaError(.featureUnsupported) }
        let oldOriginal = tab.webView
        tab.load(route("original"))
        sibling.load(route("independent", host: "independent.dotdeb.org"))
        try await awaitPage(tab, in: window, title: "Original GeoSite", listener: original, path: "original")
        try await awaitPage(sibling, in: otherWindow, title: "Managed GeoSite", listener: managed, path: "independent")
        XCTAssertFalse(managed.authorities.contains("expanded.example.com:80"))
        XCTAssertFalse(original.authorities.contains("independent.dotdeb.org:80"))

        other.setWindowForeground(true)
        try await waitUntil(seconds: 8, { cache.highWater?.releaseID == 1001 }, message: "First official response should stage Douban")
        XCTAssertTrue(tab.webView === oldOriginal, "Refreshing alone does not provide consent")
        let stale = try XCTUnwrap(coordinator.websiteCategoryProposal(.douban, for: other))
        XCTAssertEqual(stale.addedRules.map(\.host), ["expanded.example.com"])

        try await fixture.select("expand", version: 2)
        simulatedOffset.withLock { $0 += 86_401 }
        coordinator.checkpointGeoSiteClock()
        try await waitUntil(seconds: 8, { cache.highWater?.releaseID == 1002 }, message: "Second official candidate should replace the first")
        XCTAssertEqual(try XCTUnwrap(cache.highWater).releaseID, 1002)
        let staleAccepted = await coordinator.confirmWebsiteCategory(stale, for: other)
        XCTAssertFalse(staleAccepted)
        XCTAssertTrue(tab.webView === oldOriginal)
        let fresh = try XCTUnwrap(coordinator.websiteCategoryProposal(.douban, for: other))
        XCTAssertNotEqual(stale.version, fresh.version)
        let accepted = await coordinator.confirmWebsiteCategory(fresh, for: other)
        XCTAssertTrue(accepted)
        try await proveStopped(oldOriginal, listener: original, path: "original")

        tab.load(route("entry"))
        try await awaitPage(tab, in: window, title: "Managed GeoSite", listener: managed, path: "entry")
        var post = URLRequest(url: route("written"))
        post.httpMethod = "POST"
        post.httpBody = Data("test-write".utf8)
        tab.load(post)
        try await awaitPage(tab, in: window, title: "Managed GeoSite", listener: managed, path: "written")
        let oldManaged = tab.webView
        let oldStore = tab.websiteDataStore
        XCTAssertFalse(oldStore.proxyConfigurations.isEmpty)
        XCTAssertEqual(requests(managed, "POST /written"), 1)
        XCTAssertEqual(requests(original, "POST /written"), 0)

        try await fixture.select("removed", version: 3)
        simulatedOffset.withLock { $0 += 86_401 }
        coordinator.checkpointGeoSiteClock()
        try await waitUntil(seconds: 8, { cache.highWater?.releaseID == 1003 }, message: "Valid newer withdrawal should commit")
        try await proveStopped(oldManaged, listener: managed, path: "written")
        XCTAssertTrue(oldStore.proxyConfigurations.isEmpty, "Release the withdrawn store after its final document stops")
        XCTAssertEqual(requests(managed, "POST /written"), 1)
        XCTAssertEqual(requests(original, "POST /written"), 0)
        XCTAssertFalse(original.transcript.contains("/pulse-script/written"))
        XCTAssertFalse(managed.transcript.contains("/pulse-script/original"))

        tab.load(route("reopened"))
        try await awaitPage(tab, in: window, title: "Original GeoSite", listener: original, path: "reopened")
        XCTAssertFalse(managed.transcript.contains("/pulse-script/reopened"))
    }

#endif

    func testGeoSiteLoadsRedirectedPageAndItsResourcesAndDoesNotReplayWritesAcrossStores() async throws {
        let managedPort: UInt16 = 18_474
        let originalPort: UInt16 = 18_475
        let start = try XCTUnwrap(URL(string: "http://debian.org.geosite.invalid/redirect"))
        let final = try XCTUnwrap(URL(string: "http://packages.dotdeb.org.geosite.invalid/final"))
        let managed = AnsweringOpener(redirects: ["/redirect": final])
        let original = AnsweringOpener(finishAfterRecording: true)
        let managedListener = try await makeListener(port: managedPort, tunnels: managed)
        let originalListener = try await makeListener(port: originalPort, tunnels: original)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await managedListener.start(at: now)
        defer { try? managedListener.stop() }
        try await originalListener.start(at: now)
        defer { try? originalListener.stop() }
        let (defaults, suite) = try makeSmartPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let publisher = readyPublisher(port: managedPort)
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, channel: .dev,
            defaultLocationPrivacy: true, locationPreferences: defaults, websiteRoutePolicy: .geositeFixture)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        try await tab.prepareContentRulesForTests()
        let restoreOriginal = try observeOriginalStore(of: tab, port: originalPort)
        defer { restoreOriginal() }
        let window = show(tab.webView)
        defer { window.isHidden = true }

        var post = URLRequest(url: start.appendingPathComponent("cold-post"))
        post.httpMethod = "POST"
        tab.load(post)
        XCTAssertNotNil(tab.loadingError)
        XCTAssertEqual(publisher.provisionCount, 0)
        post.httpBody = Data("site-write".utf8)
        tab.load(post)
        XCTAssertNotNil(tab.loadingError)
        XCTAssertEqual(publisher.provisionCount, 0)

        tab.load(start)
        try await waitUntil(seconds: 15, {
            self.attach(tab.webView, to: window)
            return tab.committedMainFrameURL == final && !tab.isLoading && managed.transcript.contains("GET /a.css ")
        }, message: "A managed redirect must commit a real document and load its unmatched stylesheet: \(managed.transcript)")
        XCTAssertEqual(tab.boundHostName, final.host)
        XCTAssertTrue(managed.transcript.contains("GET /redirect "))
        XCTAssertTrue(managed.transcript.contains("GET /final "))
        XCTAssertTrue(managed.authorities.contains("cdn.invalid:80"))
        XCTAssertTrue(original.authorities.isEmpty)
        XCTAssertFalse(managed.transcript.contains("cold-post"))

        post.url = start.appendingPathComponent("cross-store-post")
        tab.load(post)
        XCTAssertNotNil(tab.loadingError)
        XCTAssertEqual(tab.boundHostName, final.host)
        XCTAssertFalse(managed.transcript.contains("cross-store-post"))

        post.url = final.appendingPathComponent("same-store-post")
        tab.load(post)
        try await waitUntil({ managed.transcript.contains("POST /final/same-store-post ") && !tab.isLoading },
                            message: "A write in its existing managed store must reach the listener")
        XCTAssertEqual(managed.transcript.components(separatedBy: "POST /final/same-store-post ").count, 2)
        XCTAssertEqual(publisher.provisionCount, 1)

        XCTAssertFalse(coordinator.snapshot(for: tab).autoRecoveryEnabled)
        XCTAssertTrue(coordinator.setAutoRecoveryEnabled(true, for: tab).isArmed)
        coordinator.setWebsiteAccelerationMode(.manual, for: tab)
        XCTAssertFalse(coordinator.requiresProxy(tab: tab, url: final), "An armed group does not inherit a Smart-only binding")
        XCTAssertTrue(tab.websiteDataStore === tab.originalWebsiteDataStore)
        XCTAssertTrue(coordinator.snapshot(for: tab).autoRecoveryEnabled, "The independent recovery grant stays armed")
    }

    func testGeoSiteReviewReloadRepreparesAuthorizedLanding() async throws {
        let initialPort: UInt16 = 18_476
        let replacementPort: UInt16 = 18_477
        let originalPort: UInt16 = 18_478
        let initial = AnsweringOpener(body: "<title>Initial entry</title>")
        let replacement = AnsweringOpener(body: "<title>Replacement entry</title>")
        let original = AnsweringOpener(body: "<title>Original route</title>")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let initialListener = try await makeListener(port: initialPort, tunnels: initial)
        try await initialListener.start(at: now)
        defer { try? initialListener.stop() }
        let replacementListener = try await makeListener(port: replacementPort, tunnels: replacement)
        try await replacementListener.start(at: now)
        defer { try? replacementListener.stop() }
        let originalListener = try await makeListener(port: originalPort, tunnels: original)
        try await originalListener.start(at: now)
        defer { try? originalListener.stop() }

        let (defaults, suite) = try makeSmartPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let publisher = AccessProxyEntryPublisher { generation, _ in
            if generation == 2 { throw AccessSiteSessionError.nodeUnavailable }
            return .init(endpoint: .init(identity: "review-landing-\(generation)", generation: generation,
                loopbackHost: "127.0.0.1", port: generation == 1 ? initialPort : replacementPort, state: .ready),
                listenerReady: true, runtimeHealthy: true, bridgeInstalled: true)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, channel: .dev, locationPreferences: defaults,
                                                     websiteRoutePolicy: .geositeFixture)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil),
            preferences: BrowserPreferences(defaults: defaults), hostCoordinator: coordinator)
        let tab = try XCTUnwrap(browser.activeTab)
        let restoreOriginal = try observeOriginalStore(of: tab, port: originalPort)
        defer { browser.closeWindow(); restoreOriginal() }
        try await tab.prepareContentRulesForTests()
        let window = show(tab.webView)
        defer { window.isHidden = true }

        // Grant service through Settings on a committed reserved apex. The child inherits this choice.
        let parent = try AccessSiteHost("review-landing.invalid")
        let child = try AccessSiteHost("www.review-landing.invalid")
        let settings = try XCTUnwrap(URL(string: "https://\(parent.rawValue)/review-settings"))
        let start = try XCTUnwrap(URL(string: "https://\(parent.rawValue)/review-start"))
        let landing = try XCTUnwrap(URL(string: "https://\(child.rawValue)/review-landing"))
        let childAuthority = "\(child.rawValue):443"
        tab.loadFromAddressBar(settings)
        try await commitGeoSiteReviewConnect(settings, tab: tab, window: window, observer: original)
        XCTAssertTrue(tab.websiteDataStore === tab.originalWebsiteDataStore)
        XCTAssertEqual(coordinator.websiteAccelerationHost(for: tab), parent)
        coordinator.setWebsiteRouteChoice(.service, for: tab, displayedHost: parent)
        XCTAssertEqual(coordinator.websiteRouteChoice(for: tab), .service)

        tab.loadFromAddressBar(start)
        try await commitGeoSiteReviewConnect(start, tab: tab, window: window, observer: initial)
        let firstEntry = try XCTUnwrap(publisher.currentEndpoint)
        let parentKey = AccessHostStoreKey(scopeID: tab.browsingScopeID, host: parent, isPrivate: false)
        let childKey = AccessHostStoreKey(scopeID: tab.browsingScopeID, host: child, isPrivate: false)
        XCTAssertEqual(tab.boundHostName, parent.rawValue)
        XCTAssertEqual(coordinator.registry.endpointSnapshot[parentKey], firstEntry)
        let parentStore = tab.websiteDataStore
        _ = try XCTUnwrap(tab.webView.load(URLRequest(url: landing)))
        try await commitGeoSiteReviewConnect(landing, tab: tab, window: window, observer: initial)
        XCTAssertEqual(tab.parentForProxyLanding(landing), parent.rawValue)
        XCTAssertEqual(tab.boundHostName, child.rawValue)
        XCTAssertFalse(tab.websiteDataStore === parentStore)
        XCTAssertFalse(tab.websiteDataStore === tab.originalWebsiteDataStore)
        XCTAssertEqual(coordinator.registry.endpointSnapshot[childKey], firstEntry)
        XCTAssertEqual(publisher.provisionCount, 1)
        XCTAssertFalse(original.authorities.contains(childAuthority))

        publisher.closeCurrentGeneration()
        // Closing the old listener models the transport loss independently of the publisher state.
        try initialListener.stop()
        try await waitUntil { coordinator.registry.endpointSnapshot[childKey]?.state == .failed }
        XCTAssertNil(publisher.currentEndpoint)
        XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: landing))
        tab.reload()
        try await waitUntil({ !tab.isLoading && tab.loadingError != nil },
                            message: "A failed replacement must settle the authorized landing reload")
        XCTAssertEqual(publisher.provisionCount, 2, "Reload must attempt to prepare the unavailable landing")
        XCTAssertEqual(tab.lastMainFrameFailure?.url, landing)
        XCTAssertTrue(tab.loadingErrorAllowsProxyRetry)
        XCTAssertEqual(coordinator.websiteAccelerationHost(for: tab), child)
        XCTAssertFalse(original.authorities.contains(childAuthority))

        tab.reload()
        try await waitUntil({
            self.attach(tab.webView, to: window)
            return replacement.authorities.contains(childAuthority) || (!tab.isLoading && tab.loadingError != nil)
        }, message: "The next reload must reach a replacement entry or report a failure")
        XCTAssertTrue(replacement.authorities.contains(childAuthority), "Reload must use the replacement entry.")
        XCTAssertFalse(original.authorities.contains(childAuthority))
        XCTAssertEqual(tab.boundHostName, child.rawValue)
        XCTAssertEqual(tab.parentForProxyLanding(landing), parent.rawValue)
        XCTAssertFalse(tab.websiteDataStore === tab.originalWebsiteDataStore)
        XCTAssertEqual(publisher.provisionCount, 3)
        let restored = try XCTUnwrap(publisher.currentEndpoint)
        XCTAssertGreaterThan(restored.generation, firstEntry.generation)
        XCTAssertEqual(coordinator.registry.endpointSnapshot[childKey], restored)
    }

    func testGeoSiteReviewSiteChoicePreservesUnrelatedPreparation() async throws {
        let managedPort: UInt16 = 18_479
        let originalPort: UInt16 = 18_480
        let managed = AnsweringOpener(body: "<title>Managed site B</title>")
        let original = AnsweringOpener(body: "<title>Original site A</title>")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let managedListener = try await makeListener(port: managedPort, tunnels: managed)
        try await managedListener.start(at: now)
        defer { try? managedListener.stop() }
        let originalListener = try await makeListener(port: originalPort, tunnels: original)
        try await originalListener.start(at: now)
        defer { try? originalListener.stop() }

        let gate = WindowPrepareGate()
        defer { gate.finish() }
        let publisher = AccessProxyEntryPublisher { generation, _ in
            await gate.wait()
            return .init(endpoint: .init(identity: "review-site-choice", generation: generation,
                loopbackHost: "127.0.0.1", port: managedPort, state: .ready),
                listenerReady: true, runtimeHealthy: true, bridgeInstalled: true)
        }
        let (defaults, suite) = try makeSmartPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessManualPreparationClock(), channel: .dev,
            defaultLocationPrivacy: true, locationPreferences: defaults, websiteRoutePolicy: .geositeFixture)
        let preferences = BrowserPreferences(defaults: defaults)
        let first = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), preferences: preferences, hostCoordinator: coordinator)
        let second = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), preferences: preferences, hostCoordinator: coordinator)
        let a = try XCTUnwrap(first.activeTab)
        let b = try XCTUnwrap(second.activeTab)
        let restoreOriginal = try observeOriginalStore(of: a, port: originalPort)
        defer { first.closeWindow(); second.closeWindow(); restoreOriginal() }
        try await a.prepareContentRulesForTests()
        try await b.prepareContentRulesForTests()
        let aWindow = show(a.webView)
        let bWindow = show(b.webView)
        defer { aWindow.isHidden = true; bWindow.isHidden = true }

        let siteA = try AccessSiteHost("review-site-a.invalid")
        let siteB = try AccessSiteHost("dotdeb.org.geosite.invalid")
        let aURL = try XCTUnwrap(URL(string: "https://\(siteA.rawValue)/review-site-a"))
        let bURL = try XCTUnwrap(URL(string: "http://\(siteB.rawValue)/review-held-b"))
        a.loadFromAddressBar(aURL)
        try await commitGeoSiteReviewConnect(aURL, tab: a, window: aWindow, observer: original)
        XCTAssertTrue(a.websiteDataStore === a.originalWebsiteDataStore)
        XCTAssertEqual(coordinator.websiteAccelerationHost(for: a), siteA)
        coordinator.setWebsiteRouteChoice(.service, for: a, displayedHost: siteA)
        XCTAssertEqual(coordinator.websiteRouteChoice(for: a), .service)

        b.loadFromAddressBar(bURL)
        try await waitUntil({ gate.started }, message: "Independent site B must reach the real publisher preparation")
        let pending = try XCTUnwrap(b.pendingAddressNavigation)
        XCTAssertEqual(pending.url, bURL)
        XCTAssertEqual(b.heldProxyRequestForTests?.url, bURL)
        XCTAssertTrue(coordinator.isPreparingAddressProxy(tab: b))
        XCTAssertEqual(publisher.provisionCount, 1)
        XCTAssertNil(publisher.currentEndpoint)

        coordinator.setWebsiteRouteChoice(nil, for: a, displayedHost: siteA)
        XCTAssertNil(coordinator.websiteRouteChoice(for: a))
        XCTAssertFalse(coordinator.requiresProxy(tab: a, url: aURL))
        XCTAssertTrue(coordinator.requiresProxy(tab: b, url: bURL))
        XCTAssertTrue(coordinator.isPreparingAddressProxy(tab: b), "Clearing A must keep B's operation live")
        XCTAssertEqual(b.pendingAddressNavigation, pending)
        XCTAssertEqual(b.heldProxyRequestForTests?.url, bURL)
        XCTAssertNil(b.loadingError)

        gate.finish()
        // A fresh authority distinguishes the new original-side CONNECT from an earlier pooled socket.
        let aAfterClear = try XCTUnwrap(URL(string: "https://\(siteA.rawValue):8443/review-site-a/cleared"))
        a.loadFromAddressBar(aAfterClear)
        try await waitUntil(seconds: 12, {
            self.attach(a.webView, to: aWindow)
            return original.authorities.contains("\(siteA.rawValue):8443")
        }, message: "A must send its reopened request through the original connection")
        XCTAssertEqual(a.requestedURL, aAfterClear)
        try await waitUntil(seconds: 12, {
            self.attach(b.webView, to: bWindow)
            return !b.isLoading && (b.committedMainFrameURL == bURL || b.loadingError != nil)
        }, message: "B must finish its original authorized navigation")
        XCTAssertTrue(a.websiteDataStore === a.originalWebsiteDataStore)
        XCTAssertEqual(b.committedMainFrameURL, bURL, "The surviving operation must still pass policy validation")
        XCTAssertEqual(b.currentAttemptIDForTests, pending.navigationID)
        XCTAssertEqual(b.recoveryLoadCount, 1)
        XCTAssertEqual(b.boundHostName, siteB.rawValue)
        XCTAssertFalse(b.websiteDataStore === b.originalWebsiteDataStore)
        XCTAssertNil(b.loadingError)
        XCTAssertEqual(publisher.provisionCount, 1)
        XCTAssertTrue(managed.transcript.contains("GET /review-held-b "))
        XCTAssertFalse(original.authorities.contains { $0.hasPrefix("\(siteB.rawValue):") })
        XCTAssertFalse(managed.authorities.contains { $0.hasPrefix("\(siteA.rawValue):") })
    }

    func testGeoSiteReviewSmartPreservesCommittedLegacyLanding() async throws {
        try await verifyCommittedLegacyLanding(managedPort: 18_481)
    }

    func testGeoSiteClearingServiceOverridePreservesInheritedLanding() async throws {
        try await verifyCommittedLegacyLanding(managedPort: 18_777, serviceOverride: .clearImmediately)
    }

    func testGeoSiteClearingServiceOverrideAfterReloadPreservesInheritedLanding() async throws {
        try await verifyCommittedLegacyLanding(managedPort: 18_779, serviceOverride: .reloadBeforeClearing)
    }

    func testClearingServiceOverrideKeepsOnlyTheDirectlyProtectedTab() async throws {
        let managed = AnsweringOpener(body: "<title>Direct legacy grant</title>")
        let original = AnsweringOpener(finishAfterRecording: true)
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let managedListener = try await makeListener(port: 18_793, tunnels: managed)
        try await managedListener.start(at: started)
        defer { try? managedListener.stop() }
        let originalListener = try await makeListener(port: 18_794, tunnels: original)
        try await originalListener.start(at: started)
        defer { try? originalListener.stop() }

        let (defaults, suite) = try makeSmartPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("manual", forKey: "browser.websiteAcceleration.mode")
        let coordinator = AccessHostStoreCoordinator(publisher: readyPublisher(port: 18_793), channel: .dev,
            defaultLocationPrivacy: true, locationPreferences: defaults, websiteRoutePolicy: .geositeFixture)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        let protected = try XCTUnwrap(browser.activeTab)
        let sibling = browser.newTab()
        let restoreOriginal = try observeOriginalStore(of: protected, port: 18_794)
        defer { browser.closeWindow(); restoreOriginal() }
        try await protected.prepareContentRulesForTests()
        try await sibling.prepareContentRulesForTests()
        let window = show(protected.webView)
        let otherWindow = show(sibling.webView)
        defer { window.isHidden = true; otherWindow.isHidden = true }
        let url = try XCTUnwrap(URL(string: "https://direct-legacy.geosite.invalid/check"))
        let host = try AccessSiteHost("direct-legacy.geosite.invalid")
        let authority = "\(host.rawValue):443"
        func managedConnects() -> Int { managed.authorities.filter { $0 == authority }.count }
        func originalConnects() -> Int { original.authorities.filter { $0 == authority }.count }

        protected.loadFromAddressBar(url)
        try await commitGeoSiteReviewConnect(url, tab: protected, window: window, observer: managed)
        XCTAssertNil(protected.parentForProxyLanding(url))
        coordinator.setWebsiteAccelerationMode(.smart, for: protected)
        XCTAssertTrue(coordinator.requiresProxy(tab: protected, url: url))
        XCTAssertFalse(coordinator.requiresProxy(tab: sibling, url: url))

        let heldStore = protected.websiteDataStore
        coordinator.setWebsiteRouteChoice(.service, for: protected, displayedHost: host)
        var before = managedConnects()
        protected.reload()
        try await commitGeoSiteReviewConnect(url, tab: protected, window: window, observer: managed, after: before)
        before = managedConnects()
        sibling.loadFromAddressBar(url)
        try await commitGeoSiteReviewConnect(url, tab: sibling, window: otherWindow, observer: managed, after: before)
        XCTAssertTrue(sibling.websiteDataStore === heldStore)
        XCTAssertTrue(original.authorities.isEmpty)

        coordinator.setWebsiteRouteChoice(nil, for: protected, displayedHost: host)
        XCTAssertTrue(coordinator.requiresProxy(tab: protected, url: url))
        XCTAssertTrue(protected.websiteDataStore === heldStore)
        XCTAssertFalse(coordinator.requiresProxy(tab: sibling, url: url))
        XCTAssertTrue(sibling.websiteDataStore === sibling.originalWebsiteDataStore)

        before = managedConnects()
        protected.reload()
        try await waitUntil({
            self.attach(protected.webView, to: window)
            return managedConnects() > before || original.authorities.contains(authority)
        }, message: "The tab with the original default-privacy grant must send its reload")
        XCTAssertGreaterThan(managedConnects(), before)
        XCTAssertFalse(original.authorities.contains(authority))
        protected.stop()
        before = managedConnects()
        let beforeOriginal = originalConnects()
        sibling.loadFromAddressBar(url)
        try await waitUntil({
            self.attach(sibling.webView, to: otherWindow)
            return originalConnects() > beforeOriginal
        }, message: "The override-only tab must send a new CONNECT through its original route after clearing")
        XCTAssertEqual(managedConnects(), before)

        // Simulate the registry releasing a tab before its old WebView has been replaced.
        coordinator.registry.unbind(protected.instanceID.uuidString)
        XCTAssertEqual(protected.boundHostName, host.rawValue)
        XCTAssertTrue(protected.websiteDataStore === heldStore)
        let registered = coordinator.registry.store(scopeID: protected.browsingScopeID, host: host, isPrivate: false)
        XCTAssertTrue(registered === heldStore)
        XCTAssertFalse(coordinator.requiresProxy(tab: protected, url: url))
    }

    private enum LandingServiceOverride {
        case clearImmediately
        case reloadBeforeClearing
    }

    private func verifyCommittedLegacyLanding(managedPort: UInt16, serviceOverride: LandingServiceOverride? = nil) async throws {
        // NWListener cancels asynchronously, so consecutive scenarios use separate port pairs.
        let originalPort = managedPort + 1
        let managed = AnsweringOpener(body: "<title>Legacy route</title>")
        let original = AnsweringOpener(finishAfterRecording: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let managedListener = try await makeListener(port: managedPort, tunnels: managed)
        try await managedListener.start(at: now)
        defer { try? managedListener.stop() }
        let originalListener = try await makeListener(port: originalPort, tunnels: original)
        try await originalListener.start(at: now)
        defer { try? originalListener.stop() }

        let (defaults, suite) = try makeSmartPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AccessWebsiteAccelerationMode.manual.rawValue, forKey: "browser.websiteAcceleration.mode")
        let publisher = readyPublisher(port: managedPort)
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, channel: .dev,
            defaultLocationPrivacy: true, locationPreferences: defaults, websiteRoutePolicy: .geositeFixture)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil),
            preferences: BrowserPreferences(defaults: defaults), hostCoordinator: coordinator)
        let tab = try XCTUnwrap(browser.activeTab)
        let restoreOriginal = try observeOriginalStore(of: tab, port: originalPort)
        defer { browser.closeWindow(); restoreOriginal() }
        try await tab.prepareContentRulesForTests()
        let window = show(tab.webView)
        defer { window.isHidden = true }

        let parent = try AccessSiteHost("review-legacy.invalid")
        let child = try AccessSiteHost("www.review-legacy.invalid")
        let start = try XCTUnwrap(URL(string: "https://\(parent.rawValue)/review-start"))
        let landing = try XCTUnwrap(URL(string: "https://\(child.rawValue)/review-landing"))
        let childAuthority = "\(child.rawValue):443"
        XCTAssertEqual(coordinator.websiteAccelerationMode, .manual)
        XCTAssertFalse(coordinator.requiresProxy(tab: tab, url: start))
        XCTAssertTrue(coordinator.requiresProxyPreparation(tab: tab, url: start))
        tab.loadFromAddressBar(start)
        try await commitGeoSiteReviewConnect(start, tab: tab, window: window, observer: managed)
        let entry = try XCTUnwrap(publisher.currentEndpoint)
        XCTAssertEqual(tab.boundHostName, parent.rawValue)
        XCTAssertNil(coordinator.websiteRouteChoice(for: tab))
        XCTAssertEqual(coordinator.registry.endpoint(scopeID: tab.browsingScopeID, host: parent, isPrivate: false), entry)
        let parentStore = tab.websiteDataStore
        _ = try XCTUnwrap(tab.webView.load(URLRequest(url: landing)))
        try await commitGeoSiteReviewConnect(landing, tab: tab, window: window, observer: managed)
        XCTAssertEqual(tab.parentForProxyLanding(landing), parent.rawValue)
        XCTAssertEqual(tab.boundHostName, child.rawValue)
        XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: landing))
        XCTAssertEqual(coordinator.registry.endpoint(scopeID: tab.browsingScopeID, host: child, isPrivate: false), entry)
        let childStore = tab.websiteDataStore
        XCTAssertFalse(childStore === parentStore)
        let childView = tab.webView
        let childEpoch = tab.navigationEpoch

        coordinator.setWebsiteAccelerationMode(.smart, for: tab)
        XCTAssertEqual(coordinator.websiteAccelerationMode, .smart)
        XCTAssertEqual(tab.boundHostName, child.rawValue)
        XCTAssertEqual(tab.parentForProxyLanding(landing), parent.rawValue)
        XCTAssertTrue(tab.websiteDataStore === childStore)
        XCTAssertTrue(tab.webView === childView)
        XCTAssertEqual(tab.navigationEpoch, childEpoch)
        XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: landing))
        XCTAssertNil(tab.loadingError)

        if let serviceOverride {
            coordinator.setWebsiteRouteChoice(.service, for: tab, displayedHost: child)
            XCTAssertEqual(coordinator.websiteRouteChoice(for: tab), .service)
            var expectedEpoch = childEpoch
            if serviceOverride == .reloadBeforeClearing {
                let priorConnects = managed.authorities.filter { $0 == childAuthority }.count
                tab.reload()
                try await commitGeoSiteReviewConnect(landing, tab: tab, window: window, observer: managed,
                                                      after: priorConnects)
                XCTAssertFalse(original.authorities.contains(childAuthority))
                XCTAssertEqual(tab.parentForProxyLanding(landing), parent.rawValue)
                expectedEpoch = tab.navigationEpoch
            }
            coordinator.setWebsiteRouteChoice(nil, for: tab, displayedHost: child)
            XCTAssertNil(coordinator.websiteRouteChoice(for: tab))
            XCTAssertEqual(tab.parentForProxyLanding(landing), parent.rawValue)
            XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: landing))
            XCTAssertTrue(tab.webView === childView)
            XCTAssertTrue(tab.websiteDataStore === childStore)
            XCTAssertEqual(tab.navigationEpoch, expectedEpoch)
        }

        let priorManagedConnects = managed.authorities.filter { $0 == childAuthority }.count
        tab.reload()
        try await waitUntil({
            self.attach(tab.webView, to: window)
            return managed.authorities.filter { $0 == childAuthority }.count > priorManagedConnects
                || original.authorities.contains(childAuthority) || (!tab.isLoading && tab.loadingError != nil)
        }, message: "The committed legacy landing must remain reloadable in Smart mode")
        XCTAssertGreaterThan(managed.authorities.filter { $0 == childAuthority }.count, priorManagedConnects)
        XCTAssertFalse(original.authorities.contains(childAuthority))
        XCTAssertEqual(publisher.provisionCount, 1)
        tab.stop()

        let cold = browser.newTab()
        try await cold.prepareContentRulesForTests()
        for target in [start, landing] {
            XCTAssertFalse(coordinator.requiresProxy(tab: cold, url: target))
            XCTAssertFalse(coordinator.requiresProxyPreparation(tab: cold, url: target))
        }
        let priorOriginalConnects = original.authorities.filter { $0 == childAuthority }.count
        let beforeColdLoad = managed.authorities.filter { $0 == childAuthority }.count
        attach(cold.webView, to: window)
        cold.load(landing)
        try await waitUntil({ original.authorities.filter { $0 == childAuthority }.count > priorOriginalConnects },
                            message: "An independent cold tab must use its original store for the same host")
        XCTAssertTrue(cold.websiteDataStore === cold.originalWebsiteDataStore)
        XCTAssertNil(cold.parentForProxyLanding(landing))
        XCTAssertEqual(managed.authorities.filter { $0 == childAuthority }.count, beforeColdLoad)

        browser.switchProfile(to: .privateMode)
        let privateTab = try XCTUnwrap(browser.activeTab)
        XCTAssertTrue(privateTab.profile.isPrivate)
        XCTAssertFalse(coordinator.offersWebsiteAcceleration(for: privateTab))
        XCTAssertTrue(privateTab.websiteDataStore === privateTab.originalWebsiteDataStore)
        for (host, target) in [(parent, start), (child, landing)] {
            XCTAssertFalse(coordinator.requiresProxy(tab: privateTab, url: target))
            XCTAssertTrue(coordinator.requiresProxyPreparation(tab: privateTab, url: target),
                          "Private windows keep their own optional legacy preparation")
            XCTAssertNil(coordinator.registry.endpoint(scopeID: privateTab.browsingScopeID, host: host, isPrivate: true))
        }
    }

    private func commitGeoSiteReviewConnect(_ url: URL, tab: BrowserTab, window: UIWindow,
                                           observer: AnsweringOpener, after priorConnects: Int = 0) async throws {
        let host = try XCTUnwrap(url.host)
        let authority = "\(host):443"
        try await waitUntil(seconds: 12, {
            self.attach(tab.webView, to: window)
            return tab.requestedURL == url && tab.webView.url == url && tab.currentNavigationForTests != nil
                && observer.authorities.filter { $0 == authority }.count > priorConnects
        }, message: "The owned WebKit navigation must send CONNECT for \(host)")
        let navigation = try XCTUnwrap(tab.currentNavigationForTests)
        let view = tab.webView
        // This listener records CONNECT and holds the tunnel. Model completion of that exact attempt.
        tab.commitPendingMainFrameForTests()
        tab.webView(view, didFinish: navigation)
        view.stopLoading()
        observer.finishObservedTLS(to: host)
        XCTAssertEqual(tab.committedMainFrameURL, url)
        XCTAssertEqual(tab.websiteRouteControlURL, url)
        XCTAssertFalse(tab.isLoading)
    }
    #endif

    #if DEBUG
    func testWebsiteAccelerationCanChangeTheDisplayedFailedSiteWithoutAConfiguredService() async throws {
        let (preferences, suite) = try makeSmartPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let coordinator = AccessHostStoreCoordinator(channel: .dev, locationPreferences: preferences,
                                                     websiteRoutePolicy: .geositeFixture)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        let member = try XCTUnwrap(URL(string: "https://security.debian.org.geosite.invalid/"))
        let host = try AccessSiteHost("security.debian.org.geosite.invalid")
        XCTAssertFalse(coordinator.offersLocationService)
        let previousDocument = member.appendingPathComponent("previous")
        tab.adoptPolicyMainFrameNavigationForTests(url: previousDocument)
        tab.commitPendingMainFrameForTests()
        XCTAssertEqual(coordinator.websiteAccelerationHost(for: tab), host)

        tab.loadFromAddressBar(member)
        XCTAssertNil(coordinator.websiteAccelerationHost(for: tab), "A pending request cannot authorize a site choice.")
        try await waitUntil({ tab.lastMainFrameFailure?.url == member })
        let failure = try XCTUnwrap(tab.lastMainFrameFailure)

        XCTAssertEqual(coordinator.websiteAccelerationHost(for: tab), host)
        XCTAssertEqual(coordinator.websiteRouteSelection(for: tab), .service)
        coordinator.setWebsiteRouteChoice(.original, for: tab, displayedHost: try AccessSiteHost("other.invalid"))
        XCTAssertNil(coordinator.websiteRouteChoice(for: tab))
        XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: member))
        coordinator.setWebsiteRouteChoice(.original, for: tab, displayedHost: host)
        XCTAssertEqual(coordinator.websiteRouteChoice(for: tab), .original)
        XCTAssertEqual(coordinator.websiteRouteSelection(for: tab), .original)
        XCTAssertFalse(coordinator.requiresProxy(tab: tab, url: member))
        XCTAssertEqual(tab.lastMainFrameFailure?.url, member, "Changing the next route must not resend a failed load.")
        coordinator.setWebsiteRouteChoice(nil, for: tab, displayedHost: host)
        XCTAssertNil(coordinator.websiteRouteChoice(for: tab))
        XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: member))

        coordinator.setWebsiteRouteChoice(.service, for: tab, displayedHost: host)
        XCTAssertEqual(coordinator.websiteRouteChoice(for: tab), .service)
        XCTAssertEqual(coordinator.websiteRouteSelection(for: tab), .service)
        XCTAssertFalse(coordinator.canSendMainFrame(tab: tab, url: member))
        coordinator.setWebsiteRouteChoice(nil, for: tab, displayedHost: host)
        XCTAssertNil(coordinator.websiteRouteChoice(for: tab))
        XCTAssertEqual(tab.lastMainFrameFailure, failure)
        XCTAssertFalse(tab.isLoading)
        XCTAssertEqual(tab.recoveryLoadCount, 0)

        tab.adoptPolicyMainFrameNavigationForTests(url: previousDocument)
        XCTAssertNil(coordinator.websiteAccelerationHost(for: tab), "The prior commit cannot authorize a new navigation to the same URL.")
        coordinator.setWebsiteRouteChoice(.original, for: tab, displayedHost: host)
        XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: member))

        tab.adoptPolicyMainFrameNavigationForTests(url: member, method: "POST")
        tab.commitPendingMainFrameForTests()
        XCTAssertNil(coordinator.websiteAccelerationHost(for: tab))
    }
    #endif

    private func observeOriginalStore(of tab: BrowserTab, port: UInt16) throws -> @MainActor () -> Void {
        let store = tab.originalWebsiteDataStore
        let saved = store.proxyConfigurations
        let observerPort = try XCTUnwrap(NWEndpoint.Port(rawValue: port))
        var observer = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: observerPort))
        observer.allowFailover = false
        store.proxyConfigurations = [observer]
        return { store.proxyConfigurations = saved }
    }

    func testSupersededAppLoadCancelsOnlyTheReplacedURLBeforeOwnPolicy() throws {
        let first = try XCTUnwrap(URL(string: "https://first.example.invalid/"))
        let second = try XCTUnwrap(URL(string: "https://second.example.invalid/"))
        let unrelated = try XCTUnwrap(URL(string: "https://unrelated.example.invalid/"))
        let delivered: [(navigationID: String, url: URL)] = [("first", first), ("second", second)]
        func decide(_ type: WKNavigationType = .other, awaiting: Bool = true, url: URL) -> Bool {
            BrowserTab.isSupersededAppLoad(navigationType: type, awaitingOwnPolicy: awaiting,
                                           currentNavigationID: "second", currentURL: second,
                                           url: url, delivered: delivered)
        }
        XCTAssertTrue(decide(url: first), "A late callback for the replaced load must be dropped")
        XCTAssertFalse(decide(awaiting: false, url: first),
                       "After the newer load's own policy, a redirect to the older URL is legitimate")
        XCTAssertFalse(decide(.linkActivated, url: first), "Links are never stale app loads")
        XCTAssertFalse(decide(.reload, url: first), "Reloads are never stale app loads")
        XCTAssertFalse(decide(url: second), "The current target is never stale")
        XCTAssertFalse(decide(url: unrelated), "A URL the app never issued is never stale")
    }

    func testSupersededAppLoadIgnoresTheCurrentLoadsOwnRecord() throws {
        let target = try XCTUnwrap(URL(string: "https://only.example.invalid/"))
        let other = try XCTUnwrap(URL(string: "https://other.example.invalid/"))
        let delivered: [(navigationID: String, url: URL)] = [("only", target)]
        XCTAssertFalse(BrowserTab.isSupersededAppLoad(
            navigationType: .other, awaitingOwnPolicy: true, currentNavigationID: "only",
            currentURL: other, url: target, delivered: delivered),
            "The record of the current load itself must not make it stale")
    }
}
