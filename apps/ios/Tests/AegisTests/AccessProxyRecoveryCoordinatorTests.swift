import AccessKit
@testable import BrowserKit
import WebKit
import XCTest
@testable import Aegis

@MainActor
final class AccessProxyRecoveryCoordinatorTests: XCTestCase {
    func testTimeoutDoesNotCreateAStoreOrSend() async throws {
        let publisher = AccessProxyEntryPublisher { _, _ in
            try await Task.sleep(for: .seconds(30))
            throw AccessSiteSessionError.nodeUnavailable
        }
        let clock = AccessManualPreparationClock()
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: clock)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.standardTabs.forEach { $0.stop() } }
        let tab = try XCTUnwrap(browser.activeTab)
        tab.hostCoordinator = coordinator
        var request = URLRequest(url: URL(string: "https://example.invalid/a")!)
        request.httpMethod = "GET"
        tab.load(request)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        tab.webView(tab.webView, didFailProvisionalNavigation: tab.currentNavigationForTests, withError: error)
        XCTAssertNotNil(coordinator.retryViaProxy(tab: tab))
        clock.advance(to: .seconds(15))
        let deadline = Date().addingTimeInterval(1)
        while tab.recoveryLoadCount == 0, Date() < deadline {
            await Task.yield()
        }
        XCTAssertEqual(tab.recoveryLoadCount, 0)
        let host = try AccessSiteHost("example.invalid")
        XCTAssertNil(coordinator.registry.storeForTab(
            tabID: tab.id.uuidString,
            scopeID: "ordinary",
            isPrivate: false,
            targetHost: host,
            boundHost: nil,
            intent: .on
        ))
    }

    func testOwnEnableRewritesOnlyThatTicket() async throws {
        let clock = AccessManualPreparationClock()
        let publisher = AccessProxyEntryPublisher { generation, _ in
            AccessProxyEntryPublisher.Provision(
                endpoint: AccessManagedProxyEndpoint(
                    identity: "entry-1",
                    generation: generation,
                    loopbackHost: "127.0.0.1",
                    port: 18_082,
                    state: .ready
                ),
                listenerReady: true,
                runtimeHealthy: true,
                bridgeInstalled: true
            )
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: clock)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer {
            browser.standardTabs.forEach { $0.stop() }
            browser.privateTabs.forEach { $0.stop() }
        }
        let first = try XCTUnwrap(browser.activeTab)
        let second = browser.newTab()
        first.hostCoordinator = coordinator
        second.hostCoordinator = coordinator
        var firstRequest = URLRequest(url: URL(string: "https://example.invalid/one")!)
        firstRequest.httpMethod = "GET"
        first.load(firstRequest)
        var secondRequest = URLRequest(url: URL(string: "https://other.example/two")!)
        secondRequest.httpMethod = "GET"
        second.load(secondRequest)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        first.webView(first.webView, didFailProvisionalNavigation: first.currentNavigationForTests, withError: error)
        second.webView(second.webView, didFailProvisionalNavigation: second.currentNavigationForTests, withError: error)
        _ = coordinator.retryViaProxy(tab: first)
        let limit = Date().addingTimeInterval(2)
        while first.recoveryLoadCount == 0, Date() < limit {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(first.recoveryLoadCount, 1)
        XCTAssertEqual(second.recoveryLoadCount, 0)
        XCTAssertTrue(coordinator.snapshot(for: first).toggleOn)
        XCTAssertFalse(coordinator.snapshot(for: second).toggleOn)
    }

    func testPrepareSucceedsJustBeforeTheBudgetAndFailsAtFifteen() async throws {
        let clock = AccessManualPreparationClock()
        let publisher = AccessProxyEntryPublisher { generation, _ in
            try await clock.sleep(until: .milliseconds(14_999))
            return AccessProxyEntryPublisher.Provision(
                endpoint: AccessManagedProxyEndpoint(
                    identity: "entry-budget",
                    generation: generation,
                    loopbackHost: "127.0.0.1",
                    port: 18_083,
                    state: .ready
                ),
                listenerReady: true,
                runtimeHealthy: true,
                bridgeInstalled: true
            )
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: clock)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.standardTabs.forEach { $0.stop() } }
        let tab = try XCTUnwrap(browser.activeTab)
        tab.hostCoordinator = coordinator
        tab.load(URLRequest(url: URL(string: "https://example.invalid/budget")!))
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        tab.webView(tab.webView, didFailProvisionalNavigation: tab.currentNavigationForTests, withError: error)
        XCTAssertNotNil(coordinator.retryViaProxy(tab: tab))
        clock.advance(to: .milliseconds(14_999))
        let limit = Date().addingTimeInterval(2)
        while tab.recoveryLoadCount == 0, Date() < limit {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(tab.recoveryLoadCount, 1)
    }
}
