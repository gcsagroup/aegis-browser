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
        tab.commitPendingMainFrameForTests()
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

    func testAutoRecoveryOnACommittedPageDoesNotPrepareOrCreateAStore() async throws {
        let publisher = AccessProxyEntryPublisher { generation, _ in ready(generation, port: 18_100) }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessManualPreparationClock())
        let tab = try committedTab(coordinator: coordinator, url: "https://shop.example/home")
        let before = coordinator.registry.ordinaryStores().count
        let change = coordinator.setAutoRecoveryEnabled(
            true,
            for: tab,
            members: [try AccessSiteHost("login.example")]
        )
        guard case .armed(let group) = change else {
            return XCTFail("expected armed, got \(change)")
        }
        XCTAssertEqual(group.memberHosts.map(\.rawValue), ["shop.example", "login.example"])
        XCTAssertEqual(publisher.provisionCount, 0)
        XCTAssertEqual(coordinator.registry.ordinaryStores().count, before)
        XCTAssertNil(coordinator.registry.store(
            scopeID: "ordinary",
            host: try AccessSiteHost("shop.example"),
            isPrivate: false
        ))
        XCTAssertFalse(coordinator.snapshot(for: tab).toggleOn)
        XCTAssertEqual(coordinator.snapshot(for: tab).autoRecoveryLine, AccessAutoRecoveryCopy.armed)
        XCTAssertEqual(tab.recoveryLoadCount, 0)
    }

    func testAuthorizedMemberFailureRecoversOnceAndSkipsAnOutsideHost() async throws {
        let publisher = AccessProxyEntryPublisher { generation, _ in ready(generation, port: 18_101) }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessManualPreparationClock())
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        retainedSessions.append(browser)
        browser.hostCoordinator = coordinator
        let shop = try XCTUnwrap(browser.activeTab)
        shop.load(URLRequest(url: URL(string: "https://shop.example/home")!))
        shop.commitPendingMainFrameForTests()
        let loginHost = try AccessSiteHost("login.example")
        guard case .armed(let group) = coordinator.setAutoRecoveryEnabled(true, for: shop, members: [loginHost]) else {
            return XCTFail("shop should arm without preparing")
        }
        XCTAssertEqual(group.memberHosts.map(\.rawValue), ["shop.example", "login.example"])
        let probes = coordinator.probeInvocationCount
        let login = browser.newTab()
        fail(login, url: "https://login.example/session")
        await settle { login.recoveryLoadCount == 1 }
        XCTAssertEqual(login.recoveryLoadCount, 1)
        XCTAssertEqual(publisher.provisionCount, 1)
        let outside = browser.newTab()
        fail(outside, url: "https://other.example/page")
        await settle(seconds: 0.3) { false }
        XCTAssertEqual(outside.recoveryLoadCount, 0)
        XCTAssertEqual(publisher.provisionCount, 1)
        XCTAssertEqual(coordinator.probeInvocationCount, probes)
        login.noteRecoveryCommittedForTests()
        XCTAssertEqual(
            coordinator.snapshot(for: login).autoRecoveryLine,
            AccessAutoRecoveryCopy.openedMember
        )
    }

    func testTwoMembersDoNotInvalidateEachOthersTickets() async throws {
        let clock = AccessManualPreparationClock()
        let publisher = AccessProxyEntryPublisher { generation, _ in
            try await clock.sleep(until: .seconds(5))
            return ready(generation, port: 18_102)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: clock, channel: .dev)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        retainedSessions.append(browser)
        browser.hostCoordinator = coordinator
        let shop = try XCTUnwrap(browser.activeTab)
        shop.load(URLRequest(url: URL(string: "https://shop.example/")!))
        shop.commitPendingMainFrameForTests()
        let login = try AccessSiteHost("login.example")
        let api = try AccessSiteHost("api.example")
        _ = coordinator.setAutoRecoveryEnabled(true, for: shop, members: [login, api])
        let generation = coordinator.registry.switchGeneration
        let loginTab = browser.newTab()
        let apiTab = browser.newTab()
        fail(loginTab, url: "https://login.example/in")
        fail(apiTab, url: "https://api.example/in")
        let started = Date().addingTimeInterval(2)
        while publisher.provisionCount == 0, Date() < started {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(publisher.provisionCount, 1)
        XCTAssertEqual(coordinator.registry.switchGeneration, generation)
        clock.advance(to: .seconds(5))
        await settle { loginTab.recoveryLoadCount == 1 && apiTab.recoveryLoadCount == 1 }
        XCTAssertEqual(loginTab.recoveryLoadCount, 1)
        XCTAssertEqual(apiTab.recoveryLoadCount, 1)
        XCTAssertEqual(coordinator.registry.switchGeneration, generation)
    }

    func testCancellingOneAutoRecoveryWaiterStillSendsTheOther() async throws {
        let clock = AccessManualPreparationClock()
        let publisher = AccessProxyEntryPublisher { generation, _ in
            try await clock.sleep(until: .seconds(5))
            return ready(generation, port: 18_103)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: clock)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        retainedSessions.append(browser)
        browser.hostCoordinator = coordinator
        let shop = try XCTUnwrap(browser.activeTab)
        shop.load(URLRequest(url: URL(string: "https://shop.example/")!))
        shop.commitPendingMainFrameForTests()
        _ = coordinator.setAutoRecoveryEnabled(true, for: shop, members: [])
        let first = browser.newTab()
        let second = browser.newTab()
        fail(first, url: "https://shop.example/one")
        fail(second, url: "https://shop.example/two")
        let started = Date().addingTimeInterval(2)
        while publisher.provisionCount == 0, Date() < started {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(50))
        browser.close(first.id)
        clock.advance(to: .seconds(5))
        await settle { second.recoveryLoadCount == 1 }
        XCTAssertEqual(first.recoveryLoadCount, 0)
        XCTAssertEqual(second.recoveryLoadCount, 1)
        XCTAssertEqual(publisher.provisionCount, 1)
    }

    func testOverlappingRevokeReleasesTheBindingOnlyAfterTheLastGrant() async throws {
        let publisher = AccessProxyEntryPublisher { generation, _ in ready(generation, port: 18_104) }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessManualPreparationClock())
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        retainedSessions.append(browser)
        browser.hostCoordinator = coordinator
        let shop = try XCTUnwrap(browser.activeTab)
        shop.load(URLRequest(url: URL(string: "https://shop.example/")!))
        shop.commitPendingMainFrameForTests()
        let login = try AccessSiteHost("login.example")
        _ = coordinator.setAutoRecoveryEnabled(true, for: shop, members: [login])
        let account = browser.newTab()
        account.load(URLRequest(url: URL(string: "https://account.example/")!))
        account.commitPendingMainFrameForTests()
        _ = coordinator.setAutoRecoveryEnabled(true, for: account, members: [login])
        let loginTab = browser.newTab()
        fail(loginTab, url: "https://login.example/start")
        await settle { loginTab.recoveryLoadCount == 1 }
        XCTAssertNotNil(coordinator.registry.store(scopeID: "ordinary", host: login, isPrivate: false))
        XCTAssertEqual(coordinator.setAutoRecoveryEnabled(false, for: shop), .revoked)
        XCTAssertNotNil(coordinator.registry.store(scopeID: "ordinary", host: login, isPrivate: false))
        XCTAssertTrue(coordinator.snapshot(for: loginTab).autoRecoveryEnabled)
        XCTAssertEqual(coordinator.setAutoRecoveryEnabled(false, for: account), .revoked)
        XCTAssertNil(coordinator.registry.store(scopeID: "ordinary", host: login, isPrivate: false))
        XCTAssertFalse(coordinator.snapshot(for: loginTab).autoRecoveryEnabled)
    }

    func testDowngradedGroupDoesNotAutoExecute() async throws {
        let publisher = AccessProxyEntryPublisher { generation, _ in ready(generation, port: 18_105) }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessManualPreparationClock(), channel: .release)
        let primary = try AccessSiteHost("shop.example")
        let wide = try AccessSiteRuleGroup(
            scopeID: "ordinary",
            isPrivate: false,
            primaryHost: primary,
            memberHosts: (0..<16).map { try AccessSiteHost("m\($0).example") },
            generation: 4,
            channel: .dev
        )
        coordinator.preserveAutoRecoveryGroup(wide)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        retainedSessions.append(browser)
        browser.hostCoordinator = coordinator
        let tab = try XCTUnwrap(browser.activeTab)
        fail(tab, url: "https://m0.example/")
        await settle(seconds: 0.3) { false }
        XCTAssertEqual(tab.recoveryLoadCount, 0)
        XCTAssertEqual(publisher.provisionCount, 0)
        XCTAssertFalse(wide.isExecutable(on: .release))
        XCTAssertEqual(coordinator.autoRecoveryGroups(for: tab).first?.generation, 4)
    }

    func testPrivateAutoRecoveryEndsWithTheSession() async throws {
        let clock = AccessManualPreparationClock()
        let publisher = AccessProxyEntryPublisher { generation, _ in
            try await clock.sleep(until: .seconds(20))
            return ready(generation, port: 18_106)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: clock)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        retainedSessions.append(browser)
        browser.hostCoordinator = coordinator
        browser.switchProfile(to: .privateMode)
        let tab = try XCTUnwrap(browser.activeTab)
        tab.load(URLRequest(url: URL(string: "https://shop.example/private")!))
        tab.commitPendingMainFrameForTests()
        XCTAssertEqual(coordinator.setAutoRecoveryEnabled(true, for: tab).isArmed, true)
        let login = browser.newTab()
        fail(login, url: "https://shop.example/login")
        browser.discardPrivateSession()
        clock.advance(to: .seconds(20))
        await settle(seconds: 0.4) { false }
        XCTAssertEqual(login.recoveryLoadCount, 0)
    }

    func testChannelBoundaryRejectsTheNextDistinctHost() throws {
        for (channel, limit) in [
            (AccessReleaseChannel.release, 16),
            (AccessReleaseChannel.beta, 32),
            (AccessReleaseChannel.alpha, 64),
            (AccessReleaseChannel.dev, 128)
        ] {
            let coordinator = AccessHostStoreCoordinator(channel: channel)
            let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
            retainedSessions.append(browser)
            browser.hostCoordinator = coordinator
            let tab = try XCTUnwrap(browser.activeTab)
            tab.load(URLRequest(url: URL(string: "https://shop.example/")!))
            tab.commitPendingMainFrameForTests()
            let members = try (0..<(limit - 1)).map { try AccessSiteHost("h\($0).\(channel.rawValue).example") }
            guard case .armed(let group) = coordinator.setAutoRecoveryEnabled(true, for: tab, members: members) else {
                return XCTFail(channel.rawValue)
            }
            XCTAssertEqual(group.memberHosts.count, limit)
            let rejected = coordinator.appendAutoRecoveryMember(
                try AccessSiteHost("overflow.\(channel.rawValue).example"),
                for: tab
            )
            XCTAssertEqual(rejected, .rejected(.tooManyMembers))
            XCTAssertEqual(coordinator.autoRecoveryGroups(for: tab).first?.memberHosts.count, limit)
        }
    }

    func testRepeatedPrimaryDoesNotConsumeAMemberSlot() throws {
        let coordinator = AccessHostStoreCoordinator(channel: .release)
        let tab = try committedTab(coordinator: coordinator, url: "https://shop.example/home")
        let primary = try AccessSiteHost("shop.example")
        let login = try AccessSiteHost("login.example")
        guard case .armed(let group) = coordinator.setAutoRecoveryEnabled(
            true,
            for: tab,
            members: [primary, login, login]
        ) else {
            return XCTFail("expected one shop group")
        }
        XCTAssertEqual(group.memberHosts, [primary, login])
    }

    func testPostOfflineAndPolicyDoNotAutoRecover() async throws {
        let publisher = AccessProxyEntryPublisher { generation, _ in ready(generation, port: 18_107) }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessManualPreparationClock())
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        retainedSessions.append(browser)
        browser.hostCoordinator = coordinator
        let shop = try XCTUnwrap(browser.activeTab)
        shop.load(URLRequest(url: URL(string: "https://shop.example/")!))
        shop.commitPendingMainFrameForTests()
        _ = coordinator.setAutoRecoveryEnabled(true, for: shop, members: [])
        var post = URLRequest(url: URL(string: "https://shop.example/submit")!)
        post.httpMethod = "POST"
        let posted = browser.newTab()
        posted.load(post)
        posted.webView(posted.webView, didFailProvisionalNavigation: posted.currentNavigationForTests, withError: NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotFindHost
        ))
        let offline = browser.newTab()
        offline.load(URLRequest(url: URL(string: "https://shop.example/offline")!))
        offline.webView(offline.webView, didFailProvisionalNavigation: offline.currentNavigationForTests, withError: NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet
        ))
        let ats = browser.newTab()
        ats.load(URLRequest(url: URL(string: "https://shop.example/ats")!))
        ats.webView(ats.webView, didFailProvisionalNavigation: ats.currentNavigationForTests, withError: NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorAppTransportSecurityRequiresSecureConnection
        ))
        await settle(seconds: 0.3) { false }
        XCTAssertEqual(posted.recoveryLoadCount, 0)
        XCTAssertEqual(offline.recoveryLoadCount, 0)
        XCTAssertEqual(ats.recoveryLoadCount, 0)
        XCTAssertEqual(publisher.provisionCount, 0)
    }

    func testStaleGroupAndEntryFailureDoNotSend() async throws {
        let clock = AccessManualPreparationClock()
        let publisher = AccessProxyEntryPublisher { generation, _ in
            try await clock.sleep(until: .seconds(5))
            return ready(generation, port: 18_108)
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: clock)
        let tab = try failedTab(coordinator: coordinator, url: "https://shop.example/down")
        XCTAssertEqual(coordinator.setAutoRecoveryEnabled(true, for: tab).isRecovering, true)
        let replaced = coordinator.setAutoRecoveryEnabled(
            true,
            for: tab,
            members: [try AccessSiteHost("login.example")]
        )
        XCTAssertTrue(replaced.isArmed || replaced.isRecovering)
        XCTAssertEqual(coordinator.autoRecoveryGroups(for: tab).first?.generation, 2)
        clock.advance(to: .seconds(5))
        await settle(seconds: 0.4) { coordinator.lastRecoveryFailure == "这次准备已经失效" }
        XCTAssertEqual(tab.recoveryLoadCount, 0)
        XCTAssertNil(coordinator.registry.store(
            scopeID: "ordinary",
            host: try AccessSiteHost("shop.example"),
            isPrivate: false
        ))

        let failing = AccessProxyEntryPublisher { _, _ in throw AccessSiteSessionError.nodeUnavailable }
        let failedCoordinator = AccessHostStoreCoordinator(publisher: failing, clock: AccessManualPreparationClock())
        let broken = try failedTab(coordinator: failedCoordinator, url: "https://shop.example/broken")
        XCTAssertEqual(failedCoordinator.setAutoRecoveryEnabled(true, for: broken).isRecovering, true)
        await settle { failedCoordinator.snapshot(for: broken).autoRecoveryLine == AccessAutoRecoveryCopy.unavailable }
        XCTAssertEqual(broken.recoveryLoadCount, 0)
        XCTAssertNil(failedCoordinator.registry.store(
            scopeID: "ordinary",
            host: try AccessSiteHost("shop.example"),
            isPrivate: false
        ))
        XCTAssertEqual(coordinator.suggestProbe(candidates: [try AccessSiteHost("shop.example")]), nil)
        let dev = AccessHostStoreCoordinator(channel: .dev)
        let plan = dev.suggestProbe(candidates: [
            try AccessSiteHost("a.example"),
            try AccessSiteHost("b.example"),
            try AccessSiteHost("c.example"),
            try AccessSiteHost("d.example")
        ])
        XCTAssertEqual(plan?.hosts.count, 3)
        XCTAssertEqual(AccessProductChannel.resolve(infoValue: nil), .release)
        XCTAssertEqual(AccessProductChannel.resolve(infoValue: "disabled"), .release)
        XCTAssertEqual(AccessProductChannel.resolve(infoValue: "alpha"), .alpha)
    }

    func testUncommittedHostIsNotArmed() throws {
        let coordinator = AccessHostStoreCoordinator()
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        retainedSessions.append(browser)
        let tab = try XCTUnwrap(browser.activeTab)
        tab.hostCoordinator = coordinator
        tab.load(URLRequest(url: URL(string: "https://shop.example/draft")!))
        XCTAssertEqual(coordinator.setAutoRecoveryEnabled(true, for: tab), .rejected(.noTrustedHost))
    }

    func testDevChannelExposesReadOnlyMembersAndProbeEntry() async throws {
        // Fixture session never dials; already-proxied hosts short-circuit before networking.
        let fixture = AccessSiteProbeRunner(sessionFactory: {
            XCTFail("probe must not dial when the candidate already requires proxy")
            return URLSession(configuration: .ephemeral)
        })
        let coordinator = AccessHostStoreCoordinator(channel: .dev, probeRunner: fixture)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        retainedSessions.append(browser)
        browser.hostCoordinator = coordinator
        let tab = try XCTUnwrap(browser.activeTab)
        tab.load(URLRequest(url: URL(string: "https://shop.example/home")!))
        tab.commitPendingMainFrameForTests()
        let login = try AccessSiteHost("login.example")
        _ = coordinator.setAutoRecoveryEnabled(true, for: tab, members: [login])
        coordinator.setProxyEnabled(
            true,
            host: login,
            scopeID: tab.browsingScopeID,
            isPrivate: tab.profile.isPrivate
        )
        let snap = coordinator.snapshot(for: tab)
        XCTAssertEqual(snap.debugMemberHosts, ["shop.example", "login.example"])
        XCTAssertTrue(coordinator.showsDebugSiteGroupDetails)
        XCTAssertTrue(coordinator.runProbe(for: tab, candidates: [login]))
        await settle { !coordinator.snapshot(for: tab).probeBusy }
        let after = coordinator.snapshot(for: tab)
        XCTAssertFalse(after.probeSuggestionLines.isEmpty)
        XCTAssertTrue(after.probeSuggestionLines.contains { $0.contains("已要求代理") })

        let release = AccessHostStoreCoordinator(channel: .release)
        let releaseTab = try committedTab(coordinator: release, url: "https://shop.example/home")
        _ = release.setAutoRecoveryEnabled(true, for: releaseTab, members: [login])
        XCTAssertEqual(release.snapshot(for: releaseTab).debugMemberHosts, [])
        XCTAssertFalse(release.runProbe(for: releaseTab))
    }

    func testNewSiteProbeClearsThePreviousSitesSuggestionsImmediately() async throws {
        let fixture = AccessSiteProbeRunner(sessionFactory: {
            XCTFail("proxy-required probe candidates must not dial directly")
            return URLSession(configuration: .ephemeral)
        })
        let coordinator = AccessHostStoreCoordinator(channel: .dev, probeRunner: fixture)
        let tab = try committedTab(coordinator: coordinator, url: "https://a.example/home")
        let first = try AccessSiteHost("login-a.example")
        let second = try AccessSiteHost("login-b.example")
        _ = coordinator.setAutoRecoveryEnabled(true, for: tab, members: [first])
        coordinator.setProxyEnabled(true, host: first, scopeID: "ordinary", isPrivate: false)
        XCTAssertTrue(coordinator.runProbe(for: tab, candidates: [first]))
        await settle { !coordinator.snapshot(for: tab).probeBusy }
        XCTAssertFalse(coordinator.snapshot(for: tab).probeSuggestionLines.isEmpty)

        tab.stop()
        tab.load(URLRequest(url: URL(string: "https://b.example/home")!))
        tab.commitPendingMainFrameForTests()
        _ = coordinator.setAutoRecoveryEnabled(true, for: tab, members: [second])
        coordinator.setProxyEnabled(true, host: second, scopeID: "ordinary", isPrivate: false)
        XCTAssertTrue(coordinator.runProbe(for: tab, candidates: [second]))
        let starting = coordinator.snapshot(for: tab)
        XCTAssertEqual(starting.host?.rawValue, "b.example")
        XCTAssertTrue(starting.probeBusy)
        XCTAssertTrue(starting.probeSuggestionLines.isEmpty)
        await settle { !coordinator.snapshot(for: tab).probeBusy }
        XCTAssertFalse(coordinator.snapshot(for: tab).probeSuggestionLines.isEmpty)
    }

    func testSameHostInPageFailureAutoRecoversOnce() async throws {
        let publisher = AccessProxyEntryPublisher { generation, _ in ready(generation, port: 18_109) }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessManualPreparationClock())
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        retainedSessions.append(browser)
        browser.hostCoordinator = coordinator
        let tab = try XCTUnwrap(browser.activeTab)
        tab.load(URLRequest(url: URL(string: "https://shop.example/home")!))
        tab.commitPendingMainFrameForTests()
        tab.webView(tab.webView, didFinish: tab.currentNavigationForTests)
        XCTAssertEqual(coordinator.setAutoRecoveryEnabled(true, for: tab).isArmed, true)
        XCTAssertEqual(publisher.provisionCount, 0)

        let cart = URL(string: "https://shop.example/cart")!
        tab.adoptPolicyMainFrameNavigationForTests(url: cart, method: "GET")
        tab.webView(tab.webView, didFailProvisionalNavigation: nil, withError: NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotFindHost
        ))
        await settle { tab.recoveryLoadCount == 1 }
        XCTAssertEqual(tab.recoveryLoadCount, 1)
        XCTAssertEqual(tab.lastMainFrameFailure?.url, cart)
        XCTAssertEqual(publisher.provisionCount, 1)
    }

    func testHealthyNewTabDoesNotInheritExecutingHostStore() async throws {
        let publisher = AccessProxyEntryPublisher { generation, _ in ready(generation, port: 18_110) }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessManualPreparationClock())
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        retainedSessions.append(browser)
        browser.hostCoordinator = coordinator
        let origin = try XCTUnwrap(browser.activeTab)
        fail(origin, url: "https://shop.example/broken")
        let change = coordinator.setAutoRecoveryEnabled(true, for: origin)
        XCTAssertTrue(change.isArmed || change.isRecovering)
        await settle {
            origin.recoveryLoadCount >= 1
        }
        XCTAssertGreaterThanOrEqual(origin.recoveryLoadCount, 1)
        let healthy = browser.newTab()
        let url = URL(string: "https://shop.example/fresh")!
        let routed = coordinator.dataStoreForMainFrame(tab: healthy, url: url)
        XCTAssertNil(routed, "healthy tab without manual intent must keep its original store")
    }

    func testTabRecoveredOnOneHostDoesNotInheritAnotherHostStore() async throws {
        let publisher = AccessProxyEntryPublisher { generation, _ in ready(generation, port: 18_113) }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessManualPreparationClock())
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        retainedSessions.append(browser)
        browser.hostCoordinator = coordinator
        let left = try XCTUnwrap(browser.activeTab)
        fail(left, url: "https://shop.example/broken")
        _ = coordinator.setAutoRecoveryEnabled(true, for: left)
        await settle { left.recoveryLoadCount >= 1 }

        let right = browser.newTab()
        fail(right, url: "https://other.example/broken")
        _ = coordinator.setAutoRecoveryEnabled(true, for: right)
        await settle { right.recoveryLoadCount >= 1 }

        let cross = coordinator.dataStoreForMainFrame(
            tab: left,
            url: URL(string: "https://other.example/fresh")!
        )
        XCTAssertNil(cross, "tab recovered on shop.example must not inherit other.example store")
    }

    func testTurningOffAutoRecoveryKeepsIndependentManualProxyIntent() async throws {
        let publisher = AccessProxyEntryPublisher { generation, _ in ready(generation, port: 18_111) }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessManualPreparationClock())
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        retainedSessions.append(browser)
        browser.hostCoordinator = coordinator
        let tab = try XCTUnwrap(browser.activeTab)
        fail(tab, url: "https://shop.example/manual")
        XCTAssertNotNil(coordinator.retryViaProxy(tab: tab))
        await settle { tab.recoveryLoadCount >= 1 && coordinator.snapshot(for: tab).toggleOn }
        XCTAssertTrue(coordinator.snapshot(for: tab).toggleOn)
        _ = coordinator.setAutoRecoveryEnabled(true, for: tab)
        XCTAssertTrue(coordinator.snapshot(for: tab).autoRecoveryEnabled || coordinator.snapshot(for: tab).toggleOn)
        _ = coordinator.setAutoRecoveryEnabled(false, for: tab)
        XCTAssertTrue(coordinator.snapshot(for: tab).toggleOn, "manual proxy must survive auto-recovery off")
        XCTAssertFalse(coordinator.snapshot(for: tab).autoRecoveryEnabled)
        let routed = coordinator.dataStoreForMainFrame(
            tab: tab,
            url: URL(string: "https://shop.example/manual")!
        )
        XCTAssertNotNil(routed, "manual proxy intent must keep the host store after auto-recovery off")
    }

    func testDuplicateFailureCallbackDoesNotPrepareTwice() async throws {
        let publisher = AccessProxyEntryPublisher { generation, _ in ready(generation, port: 18_112) }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessManualPreparationClock())
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        retainedSessions.append(browser)
        browser.hostCoordinator = coordinator
        let tab = try XCTUnwrap(browser.activeTab)
        tab.load(URLRequest(url: URL(string: "https://shop.example/home")!))
        tab.commitPendingMainFrameForTests()
        tab.webView(tab.webView, didFinish: tab.currentNavigationForTests)
        XCTAssertEqual(coordinator.setAutoRecoveryEnabled(true, for: tab).isArmed, true)
        let cart = URL(string: "https://shop.example/cart")!
        tab.adoptPolicyMainFrameNavigationForTests(url: cart, method: "GET")
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        let navigation = tab.currentNavigationForTests
        tab.webView(tab.webView, didFailProvisionalNavigation: navigation, withError: error)
        let firstCount = publisher.provisionCount
        await settle { tab.recoveryLoadCount == 1 }
        // Replay the same failure identity; a second prepare/send must not occur.
        tab.webView(tab.webView, didFailProvisionalNavigation: navigation, withError: error)
        await settle(seconds: 0.3) { false }
        XCTAssertEqual(publisher.provisionCount, max(firstCount, 1))
        XCTAssertEqual(tab.recoveryLoadCount, 1)
    }

    private func committedTab(coordinator: AccessHostStoreCoordinator, url: String) throws -> BrowserTab {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        retainedSessions.append(browser)
        browser.hostCoordinator = coordinator
        let tab = try XCTUnwrap(browser.activeTab)
        tab.load(URLRequest(url: URL(string: url)!))
        tab.commitPendingMainFrameForTests()
        return tab
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
