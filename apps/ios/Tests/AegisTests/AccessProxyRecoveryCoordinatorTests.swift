import AccessKit
@testable import BrowserKit
import WebKit
import XCTest
@testable import Aegis

@MainActor
final class AccessProxyRecoveryCoordinatorTests: XCTestCase {
    private var retainedSessions: [BrowserSession] = []

    override func tearDown() async throws {
        for session in retainedSessions {
            session.standardTabs.forEach { $0.stop() }
            session.privateTabs.forEach { $0.stop() }
        }
        retainedSessions.removeAll()
        try await super.tearDown()
    }
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

    func testExactFifteenAndAQueuedRemainderDoNotSend() async throws {
        let clock = AccessManualPreparationClock()
        let publisher = AccessProxyEntryPublisher { generation, _ in
            try await clock.sleep(until: .seconds(10))
            try await clock.sleep(until: .seconds(15))
            return ready(generation, port: 18_084)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: clock)
        let tab = try failedTab(coordinator: coordinator, url: "https://example.invalid/queued")
        XCTAssertNotNil(coordinator.retryViaProxy(tab: tab))
        clock.advance(to: .seconds(10))
        await settle()
        XCTAssertEqual(tab.recoveryLoadCount, 0)
        clock.advance(to: .seconds(15))
        await settle { coordinator.lastRecoveryFailure == "代理在 15 秒内没有就绪" }
        XCTAssertEqual(tab.recoveryLoadCount, 0)
        XCTAssertEqual(coordinator.lastRecoveryFailure, "代理在 15 秒内没有就绪")
    }

    func testRepeatedClickDoesNotExtendTheBudget() async throws {
        let clock = AccessManualPreparationClock()
        let publisher = AccessProxyEntryPublisher { _, _ in
            try await clock.sleep(until: .seconds(30))
            throw AccessSiteSessionError.nodeUnavailable
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: clock)
        let tab = try failedTab(coordinator: coordinator, url: "https://example.invalid/reuse")
        let first = coordinator.retryViaProxy(tab: tab)
        clock.advance(to: .seconds(10))
        let second = coordinator.retryViaProxy(tab: tab)
        XCTAssertEqual(first, second)
        clock.advance(to: .seconds(15))
        await settle(seconds: 0.4) { false }
        XCTAssertEqual(tab.recoveryLoadCount, 0)
    }

    func testLateSuccessAfterCloseDoesNotSend() async throws {
        let clock = AccessManualPreparationClock()
        let publisher = AccessProxyEntryPublisher { generation, _ in
            try await clock.sleep(until: .seconds(20))
            return ready(generation, port: 18_085)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: clock)
        let tab = try failedTab(coordinator: coordinator, url: "https://example.invalid/closed")
        XCTAssertNotNil(coordinator.retryViaProxy(tab: tab))
        coordinator.setProxyEnabled(false, for: tab)
        clock.advance(to: .seconds(20))
        await settle(seconds: 0.4) { false }
        XCTAssertEqual(tab.recoveryLoadCount, 0)
        let host = try AccessSiteHost("example.invalid")
        XCTAssertNil(coordinator.registry.store(
            scopeID: "ordinary",
            host: host,
            isPrivate: false
        ))
    }

    func testAnotherToggleRejectsThePreparingTicket() async throws {
        let clock = AccessManualPreparationClock()
        let publisher = AccessProxyEntryPublisher { generation, _ in
            try await clock.sleep(until: .seconds(5))
            return ready(generation, port: 18_086)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: clock)
        let tab = try failedTab(coordinator: coordinator, url: "https://example.invalid/generation")
        XCTAssertNotNil(coordinator.retryViaProxy(tab: tab))
        coordinator.setProxyEnabled(
            true,
            host: try AccessSiteHost("other.example"),
            scopeID: "ordinary",
            isPrivate: false
        )
        clock.advance(to: .seconds(5))
        await settle(seconds: 0.4) { false }
        XCTAssertEqual(tab.recoveryLoadCount, 0)
    }

    func testOldFailureDoesNotReplaceANewerReadyEntry() async throws {
        let publisher = GenerationScript()
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessManualPreparationClock())
        let tab = try failedTab(coordinator: coordinator, url: "https://example.invalid/generation-race")
        XCTAssertNotNil(coordinator.retryViaProxy(tab: tab))
        await settle { tab.recoveryLoadCount == 1 }
        XCTAssertEqual(tab.recoveryLoadCount, 1)
        let host = try AccessSiteHost("example.invalid")
        publisher.emit(AccessManagedProxyEndpoint(
            identity: "entry-script",
            generation: 1,
            loopbackHost: "127.0.0.1",
            port: 18_087,
            state: .failed
        ))
        await settle(seconds: 0.4) { false }
        XCTAssertEqual(
            coordinator.registry.endpoint(scopeID: "ordinary", host: host, isPrivate: false)?.state,
            .ready
        )
        XCTAssertEqual(
            coordinator.registry.endpoint(scopeID: "ordinary", host: host, isPrivate: false)?.generation,
            2
        )
    }

    func testOnlyTheClickedWindowReloadsAndTheSwitchMatchesTheButton() async throws {
        let coordinator = AccessHostStoreCoordinator(
            publisher: AccessProxyEntryPublisher { generation, _ in ready(generation, port: 18_088) },
            clock: AccessManualPreparationClock()
        )
        let left = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        let right = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer {
            left.standardTabs.forEach { $0.stop() }
            right.standardTabs.forEach { $0.stop() }
        }
        left.hostCoordinator = coordinator
        right.hostCoordinator = coordinator
        let origin = try XCTUnwrap(left.activeTab)
        let other = try XCTUnwrap(right.activeTab)
        fail(origin, url: "https://example.invalid/left")
        fail(other, url: "https://example.invalid/right")
        XCTAssertTrue(origin.loadingErrorAllowsProxyRetry)
        XCTAssertNotNil(coordinator.retryViaProxy(tab: origin))
        await settle { origin.recoveryLoadCount == 1 }
        XCTAssertEqual(origin.recoveryLoadCount, 1)
        XCTAssertEqual(other.recoveryLoadCount, 0)
        XCTAssertTrue(coordinator.snapshot(for: origin).toggleOn)
        XCTAssertEqual(coordinator.snapshot(for: origin).intent, coordinator.snapshot(for: other).intent)
        let replacement = left.newTab()
        left.activate(replacement.id)
        XCTAssertEqual(origin.recoveryLoadCount, 1)
        left.close(origin.id)
        XCTAssertEqual(origin.recoveryLoadCount, 1)
    }

    func testSameHostSecondTabDoesNotReloadWhenOriginRetries() async throws {
        let coordinator = AccessHostStoreCoordinator(
            publisher: AccessProxyEntryPublisher { generation, _ in ready(generation, port: 18_091) },
            clock: AccessManualPreparationClock()
        )
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        retainedSessions.append(browser)
        browser.hostCoordinator = coordinator
        let origin = try XCTUnwrap(browser.activeTab)
        let sibling = browser.newTab()
        fail(origin, url: "https://example.invalid/origin")
        fail(sibling, url: "https://example.invalid/sibling")
        XCTAssertNotNil(coordinator.retryViaProxy(tab: origin))
        await settle { origin.recoveryLoadCount == 1 }
        XCTAssertEqual(origin.recoveryLoadCount, 1)
        XCTAssertEqual(sibling.recoveryLoadCount, 0)
        XCTAssertTrue(coordinator.snapshot(for: origin).toggleOn)
        XCTAssertTrue(coordinator.snapshot(for: sibling).toggleOn)
    }

    func testClosingTheOriginTabCancelsItsPreparingRecovery() async throws {
        let clock = AccessManualPreparationClock()
        let publisher = AccessProxyEntryPublisher { generation, _ in
            try await clock.sleep(until: .seconds(20))
            return ready(generation, port: 18_092)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: clock)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        retainedSessions.append(browser)
        browser.hostCoordinator = coordinator
        let origin = try XCTUnwrap(browser.activeTab)
        fail(origin, url: "https://example.invalid/close-origin")
        XCTAssertNotNil(coordinator.retryViaProxy(tab: origin))
        browser.close(origin.id)
        clock.advance(to: .seconds(20))
        await settle(seconds: 0.4) { false }
        XCTAssertEqual(origin.recoveryLoadCount, 0)
    }

    func testEnableWithoutFailureOnlyPreparesAndDisableReturnsOriginalStore() async throws {
        let clock = AccessManualPreparationClock()
        let publisher = AccessProxyEntryPublisher { generation, _ in ready(generation, port: 18_090) }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: clock)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        retainedSessions.append(browser)
        browser.hostCoordinator = coordinator
        let tab = try XCTUnwrap(browser.activeTab)
        let original = tab.websiteDataStore
        tab.load(URLRequest(url: URL(string: "https://example.invalid/prepare-only")!))
        XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
        coordinator.setProxyEnabled(true, for: tab)
        await settle {
            coordinator.registry.endpoint(
                scopeID: "ordinary",
                host: (try? AccessSiteHost("example.invalid"))!,
                isPrivate: false
            )?.state == .ready
        }
        XCTAssertEqual(tab.recoveryLoadCount, 0)
        let host = try AccessSiteHost("example.invalid")
        XCTAssertEqual(
            coordinator.registry.endpoint(scopeID: "ordinary", host: host, isPrivate: false)?.state,
            .ready
        )
        XCTAssertTrue(tab.websiteDataStore === original)
        let readySnap = coordinator.snapshot(for: tab)
        XCTAssertTrue(readySnap.toggleOn)
        XCTAssertEqual(readySnap.attachment, .notAttached)
        XCTAssertEqual(
            AccessSiteProxyToggleModel.attachmentLine(for: readySnap.attachment, intent: readySnap.intent),
            "尚未接入代理，当前页面仍使用原连接"
        )
        coordinator.setProxyEnabled(false, for: tab)
        XCTAssertTrue(tab.websiteDataStore === original)
        XCTAssertNil(coordinator.registry.store(scopeID: "ordinary", host: host, isPrivate: false))
        XCTAssertFalse(coordinator.snapshot(for: tab).toggleOn)
    }

    func testEndingThePrivateSessionDoesNotSendThatTab() async throws {
        let clock = AccessManualPreparationClock()
        let publisher = AccessProxyEntryPublisher { generation, _ in
            try await clock.sleep(until: .seconds(20))
            return ready(generation, port: 18_089)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: clock)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.standardTabs.forEach { $0.stop() } }
        browser.hostCoordinator = coordinator
        browser.switchProfile(to: .privateMode)
        let tab = try XCTUnwrap(browser.activeTab)
        fail(tab, url: "https://example.invalid/private")
        XCTAssertNotNil(coordinator.retryViaProxy(tab: tab))
        browser.discardPrivateSession()
        clock.advance(to: .seconds(20))
        await settle(seconds: 0.4) { false }
        XCTAssertEqual(tab.recoveryLoadCount, 0)
    }

    private func failedTab(coordinator: AccessHostStoreCoordinator, url: String) throws -> BrowserTab {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        retainedSessions.append(browser)
        browser.hostCoordinator = coordinator
        let tab = try XCTUnwrap(browser.activeTab)
        fail(tab, url: url)
        return tab
    }

    private func fail(_ tab: BrowserTab, url: String) {
        tab.load(URLRequest(url: URL(string: url)!))
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        tab.webView(tab.webView, didFailProvisionalNavigation: tab.currentNavigationForTests, withError: error)
    }

    private func settle(seconds: TimeInterval = 1, until condition: @MainActor () -> Bool = { true }) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private func ready(_ generation: UInt64, port: UInt16) -> AccessProxyEntryPublisher.Provision {
    AccessProxyEntryPublisher.Provision(
        endpoint: AccessManagedProxyEndpoint(
            identity: "entry-budget",
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

@MainActor
private final class GenerationScript: AccessProxyEntryPublishing {
    private var continuation: AsyncStream<AccessManagedProxyEndpoint>.Continuation?
    private var retained = Set<UUID>()
    private(set) var currentEndpoint: AccessManagedProxyEndpoint?

    var stateChanges: AsyncStream<AccessManagedProxyEndpoint> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func prepare(_ request: AccessProxyEntryPrepareRequest) async throws -> AccessProxyEntryPrepareResult {
        retained.insert(request.operationID)
        let endpoint = AccessManagedProxyEndpoint(
            identity: "entry-script",
            generation: 2,
            loopbackHost: "127.0.0.1",
            port: 18_087,
            state: .ready
        )
        currentEndpoint = endpoint
        return AccessProxyEntryPrepareResult(operationID: request.operationID, endpoint: endpoint)
    }

    func cancel(operationID: UUID) {
        retained.remove(operationID)
    }

    func validateReady(_ result: AccessProxyEntryPrepareResult) -> Bool {
        retained.contains(result.operationID) && result.endpoint.generation == 2 && result.endpoint.state == .ready
    }

    func retain(_ endpoint: AccessManagedProxyEndpoint, for key: AccessHostStoreKey) -> Bool {
        _ = key
        return endpoint.generation == 2 && endpoint.state == .ready
    }

    func release(for key: AccessHostStoreKey) {
        _ = key
    }

    func emit(_ endpoint: AccessManagedProxyEndpoint) {
        continuation?.yield(endpoint)
    }
}
