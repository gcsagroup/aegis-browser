import WebKit
import XCTest
@testable import AccessKit

final class AccessHostStorePolicyTests: XCTestCase {
    private func host(_ raw: String) throws -> AccessSiteHost {
        try AccessSiteHost(raw)
    }

    private func record(
        host: String,
        scope: String = "ordinary",
        isPrivate: Bool = false,
        tabs: Set<String> = [],
        enabled: Bool = true,
        idleSince: Date? = nil
    ) throws -> AccessHostStoreRecord {
        AccessHostStoreRecord(
            key: AccessHostStoreKey(scopeID: scope, host: try self.host(host), isPrivate: isPrivate),
            boundTabIDs: tabs,
            proxyEnabled: enabled,
            idleSince: idleSince
        )
    }

    func testOrdinaryAndPrivateScopesStaySeparate() throws {
        let ordinary = AccessHostStoreKey(scopeID: "ordinary", host: try host("example.com"), isPrivate: false)
        let privateKey = AccessHostStoreKey(scopeID: "session-a", host: try host("example.com"), isPrivate: true)
        XCTAssertNotEqual(ordinary, privateKey)
        XCTAssertNotEqual(
            AccessHostStoreKey(scopeID: "session-a", host: try host("example.com"), isPrivate: true),
            AccessHostStoreKey(scopeID: "session-b", host: try host("example.com"), isPrivate: true)
        )
    }

    func testExactHostDoesNotIncludeSubdomain() throws {
        XCTAssertNotEqual(try host("example.com"), try host("www.example.com"))
    }

    func testProxyOffUsesOriginalStoreEvenWhenPreviouslyBound() throws {
        let decision = AccessHostRoutingPolicy.decide(AccessHostRoutingRequest(
            intent: .off,
            endpoint: .ready,
            targetHost: try host("example.com"),
            boundHost: try host("example.com")
        ))
        XCTAssertEqual(decision, .originalStore)
    }

    func testReadyEndpointSelectsDedicatedStore() throws {
        let decision = AccessHostRoutingPolicy.decide(AccessHostRoutingRequest(
            intent: .on,
            endpoint: .ready,
            targetHost: try host("example.com"),
            boundHost: nil
        ))
        XCTAssertEqual(decision, .useHostStore(try host("example.com")))
    }

    func testUnavailableEndpointDoesNotCreateStore() throws {
        let decision = AccessHostRoutingPolicy.decide(AccessHostRoutingRequest(
            intent: .on,
            endpoint: .unavailable,
            targetHost: try host("example.com"),
            boundHost: nil
        ))
        XCTAssertEqual(decision, .originalStore)
    }

    func testFailedEndpointKeepsExistingBinding() throws {
        let decision = AccessHostRoutingPolicy.decide(AccessHostRoutingRequest(
            intent: .on,
            endpoint: .failed,
            targetHost: try host("example.com"),
            boundHost: try host("example.com")
        ))
        XCTAssertEqual(decision, .keepBoundHostStore)
    }

    @MainActor
    func testListenerRetirementWaitsForAllBoundAndAlreadyDetachedDocuments() throws {
        let registry = AccessHostDataStoreRegistry()
        let ordinary = AccessHostStoreKey(scopeID: "ordinary", host: try host("one.invalid"), isPrivate: false)
        let privateKey = AccessHostStoreKey(scopeID: "private-scope", host: try host("two.invalid"), isPrivate: true)
        let unrelated = AccessHostStoreKey(scopeID: "ordinary", host: try host("three.invalid"), isPrivate: false)
        let old = AccessManagedProxyEndpoint(identity: "expired", generation: 1, loopbackHost: "127.0.0.1",
                                             port: 18080, state: .ready)
        var replacement = old
        replacement.identity = "replacement"
        replacement.generation = 2
        replacement.port = 18081
        func install(_ endpoint: AccessManagedProxyEndpoint, for key: AccessHostStoreKey) -> Bool {
            registry.setEndpoint(endpoint, scopeID: key.scopeID, host: key.host, isPrivate: key.isPrivate)
        }
        func bind(_ tab: String, to key: AccessHostStoreKey, bound: Bool = false) -> WKWebsiteDataStore? {
            registry.storeForTab(tabID: tab, scopeID: key.scopeID, isPrivate: key.isPrivate,
                targetHost: key.host, boundHost: bound ? key.host : nil, intent: .on)
        }
        XCTAssertTrue(install(old, for: ordinary))
        XCTAssertTrue(install(old, for: privateKey))
        XCTAssertTrue(install(replacement, for: unrelated))
        let ordinaryStore = try XCTUnwrap(bind("open-tab", to: ordinary))
        let privateStore = try XCTUnwrap(bind("closing-window", to: privateKey))
        let otherStore = try XCTUnwrap(bind("other-tab", to: unrelated))
        let acknowledgeDetached = try XCTUnwrap(registry.retainRetiringDocument(
            scopeID: ordinary.scopeID, host: ordinary.host, isPrivate: ordinary.isPrivate))
        var releases = 0
        let bound = registry.retireListener(identity: old.identity) { releases += 1 }
        XCTAssertEqual(bound[ordinary], ["open-tab"])
        XCTAssertEqual(bound[privateKey], ["closing-window"])
        XCTAssertNil(bind("new-tab", to: ordinary, bound: true))
        XCTAssertFalse(install(replacement, for: privateKey))
        XCTAssertEqual(ordinaryStore.proxyConfigurations.count, 1)
        XCTAssertEqual(privateStore.proxyConfigurations.count, 1)
        XCTAssertEqual(releases, 0)
        // A removed tab's close path acknowledges via the normal unbind callback.
        registry.unbind("closing-window")
        XCTAssertEqual(releases, 0)
        acknowledgeDetached()
        registry.acknowledgeRetiredTab("open-tab", key: ordinary, identity: replacement.identity)
        XCTAssertEqual(releases, 0)
        registry.acknowledgeRetiredTab("open-tab", key: ordinary, identity: old.identity)
        XCTAssertEqual(releases, 1)
        XCTAssertTrue(ordinaryStore.proxyConfigurations.isEmpty)
        XCTAssertTrue(privateStore.proxyConfigurations.isEmpty)
        XCTAssertEqual(otherStore.proxyConfigurations.count, 1)
        XCTAssertTrue(install(replacement, for: ordinary))
        XCTAssertNotNil(bind("new-generation", to: ordinary))
    }

    func testNavigationToAnotherHostDoesNotCarryThePreviousStore() throws {
        let decision = AccessHostRoutingPolicy.decide(AccessHostRoutingRequest(
            intent: .on,
            endpoint: .failed,
            targetHost: try host("other.com"),
            boundHost: try host("example.com")
        ))
        XCTAssertEqual(decision, .originalStore)
    }

    func testInUseStoreIsNotIdleEvicted() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let records = [
            try record(host: "example.com", tabs: ["tab-1"], idleSince: now.addingTimeInterval(-3_600))
        ]
        XCTAssertTrue(AccessHostStoreEvictionPolicy.evictions(records: records, now: now).isEmpty)
    }

    func testDisablingProxyForcesRevocation() throws {
        let result = AccessHostStoreEvictionPolicy.evictions(
            records: [try record(host: "example.com", tabs: ["tab-1"], enabled: false)],
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(result.map(\.kind), [.forced])
    }

    func testEndingPrivateSessionRevokesOnlyThatScope() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let records = [
            try record(host: "example.com", scope: "session-a", isPrivate: true, tabs: ["p1"]),
            try record(host: "example.com", tabs: ["o1"])
        ]
        let result = AccessHostStoreEvictionPolicy.evictions(
            records: records,
            now: now,
            endingPrivateScopeID: "session-a"
        )
        XCTAssertEqual(result.map(\.key.scopeID), ["session-a"])
        XCTAssertEqual(result.map(\.kind), [.forced])
    }

    func testIdleBoundaryAtOneMinute() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let almost = try record(host: "almost.example", idleSince: now.addingTimeInterval(-60 + 1))
        let due = try record(host: "due.example", idleSince: now.addingTimeInterval(-60))
        let result = AccessHostStoreEvictionPolicy.evictions(records: [almost, due], now: now)
        XCTAssertEqual(result.map { $0.key.host.rawValue }, ["due.example"])
        XCTAssertEqual(result.map(\.kind), [.idle])
    }

    func testNinthIdleStoreIsEvictedOldestFirst() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var records: [AccessHostStoreRecord] = []
        for index in 0..<9 {
            records.append(try record(
                host: "h\(index).example",
                idleSince: now.addingTimeInterval(TimeInterval(-index))
            ))
        }
        let result = AccessHostStoreEvictionPolicy.evictions(records: records, now: now)
        XCTAssertEqual(result.map { $0.key.host.rawValue }, ["h8.example"])
    }

    func testRetryAllowsOneGetAndRejectsPostAndASecondAttempt() throws {
        let host = try self.host("example.com")
        var ticket = AccessNavigationRetryTicket(
            tabID: "tab",
            scopeID: "ordinary",
            navigationID: "nav-1",
            host: host,
            url: URL(string: "https://example.com/a")!,
            method: "GET",
            hasReplayableBody: false,
            switchGeneration: 3
        )
        XCTAssertEqual(
            AccessNavigationRetryPolicy.evaluate(
                ticket: ticket,
                currentTabID: "tab",
                currentNavigationID: "nav-1",
                currentSwitchGeneration: 3,
                endpointReady: true
            ),
            .consumeAndRetry
        )
        ticket = AccessNavigationRetryPolicy.consume(ticket)
        XCTAssertEqual(
            AccessNavigationRetryPolicy.evaluate(
                ticket: ticket,
                currentTabID: "tab",
                currentNavigationID: "nav-1",
                currentSwitchGeneration: 3,
                endpointReady: true
            ),
            .alreadyConsumed
        )

        let post = AccessNavigationRetryTicket(
            tabID: "tab",
            scopeID: "ordinary",
            navigationID: "nav-1",
            host: host,
            url: URL(string: "https://example.com/a")!,
            method: "POST",
            hasReplayableBody: true,
            switchGeneration: 3
        )
        XCTAssertEqual(
            AccessNavigationRetryPolicy.evaluate(
                ticket: post,
                currentTabID: "tab",
                currentNavigationID: "nav-1",
                currentSwitchGeneration: 3,
                endpointReady: true
            ),
            .ineligible
        )
    }

    func testSameHostNewNavigationCancelsTheOldRetry() throws {
        let ticket = AccessNavigationRetryTicket(
            tabID: "tab",
            scopeID: "ordinary",
            navigationID: "nav-old",
            host: try host("example.com"),
            url: URL(string: "https://example.com/old")!,
            method: "HEAD",
            hasReplayableBody: false,
            switchGeneration: 1
        )
        XCTAssertEqual(
            AccessNavigationRetryPolicy.evaluate(
                ticket: ticket,
                currentTabID: "tab",
                currentNavigationID: "nav-new",
                currentSwitchGeneration: 1,
                endpointReady: true
            ),
            .ineligible
        )
    }

    func testStaleEndpointGenerationCannotRetry() throws {
        let ticket = AccessNavigationRetryTicket(
            tabID: "tab",
            scopeID: "ordinary",
            navigationID: "nav",
            host: try host("example.com"),
            url: URL(string: "https://example.com/")!,
            method: "GET",
            hasReplayableBody: false,
            switchGeneration: 1
        )
        XCTAssertEqual(
            AccessNavigationRetryPolicy.evaluate(
                ticket: ticket,
                currentTabID: "tab",
                currentNavigationID: "nav",
                currentSwitchGeneration: 2,
                endpointReady: true
            ),
            .ineligible
        )
    }

    @MainActor
    func testReadyHostStoreIsSharedAndOtherHostsStayUncreated() throws {
        let registry = AccessHostDataStoreRegistry()
        let host = try self.host("example.com")
        registry.setEndpoint(readyEndpoint(generation: 1), scopeID: "ordinary", host: host, isPrivate: false)
        let first = registry.storeForTab(
            tabID: "a", scopeID: "ordinary", isPrivate: false,
            targetHost: host, boundHost: nil, intent: .on
        )
        let second = registry.storeForTab(
            tabID: "b", scopeID: "ordinary", isPrivate: false,
            targetHost: host, boundHost: host, intent: .on
        )
        let other = registry.storeForTab(
            tabID: "c", scopeID: "ordinary", isPrivate: false,
            targetHost: try self.host("www.example.com"), boundHost: nil, intent: .on
        )
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
        XCTAssertNil(other)
        XCTAssertEqual(first?.proxyConfigurations.count, 1)
        XCTAssertFalse(first?.proxyConfigurations.first?.allowFailover ?? true)
    }

    @MainActor
    func testInadmissibleReadyEndpointsCannotCreateOrReuseAHostStore() throws {
        let host = try self.host("example.com")
        var forbiddenSOCKS = readyEndpoint(generation: 2, port: 1080)
        forbiddenSOCKS.transport = .socks5
        var nonLoopback = readyEndpoint(generation: 2)
        nonLoopback.loopbackHost = "192.0.2.1"
        for rejected in [forbiddenSOCKS, nonLoopback, readyEndpoint(generation: 2, port: 0)] {
            for hasExistingStore in [false, true] {
                let registry = AccessHostDataStoreRegistry()
                func attach(boundHost: AccessSiteHost?) -> WKWebsiteDataStore? {
                    registry.storeForTab(tabID: "tab", scopeID: "ordinary", isPrivate: false,
                                        targetHost: host, boundHost: boundHost, intent: .on)
                }
                let previous = readyEndpoint(generation: 1)
                var oldStore: WKWebsiteDataStore?
                if hasExistingStore {
                    XCTAssertTrue(registry.setEndpoint(previous, scopeID: "ordinary", host: host, isPrivate: false))
                    oldStore = try XCTUnwrap(attach(boundHost: nil))
                }
                XCTAssertFalse(registry.setEndpoint(rejected, scopeID: "ordinary", host: host, isPrivate: false))
                XCTAssertEqual(registry.endpoint(scopeID: "ordinary", host: host, isPrivate: false)?.state, .failed)
                XCTAssertNil(attach(boundHost: hasExistingStore ? host : nil))
                XCTAssertFalse(registry.setEndpoint(previous, scopeID: "ordinary", host: host, isPrivate: false))
                if let oldStore {
                    XCTAssertEqual(oldStore.proxyConfigurations.count, 1)
                    XCTAssertFalse(oldStore.proxyConfigurations.first?.allowFailover ?? true)
                } else {
                    XCTAssertNil(registry.store(scopeID: "ordinary", host: host, isPrivate: false))
                }
                XCTAssertTrue(registry.setEndpoint(readyEndpoint(generation: 3, port: 1080),
                                                   scopeID: "ordinary", host: host, isPrivate: false))
                let recovered = try XCTUnwrap(attach(boundHost: hasExistingStore ? host : nil))
                XCTAssertEqual(recovered.proxyConfigurations.count, 1)
                XCTAssertFalse(recovered.proxyConfigurations.first?.allowFailover ?? true)
            }
        }
    }

    @MainActor
    func testRejectedReplacementKeepsTheAppliedListenerUntilBothDocumentsRetire() throws {
        let registry = AccessHostDataStoreRegistry()
        let host = try self.host("example.com")
        let key = AccessHostStoreKey(scopeID: "ordinary", host: host, isPrivate: false)
        let old = readyEndpoint(generation: 1)
        var rejected = readyEndpoint(generation: 2, port: 1080)
        rejected.transport = .socks5
        XCTAssertTrue(registry.setEndpoint(old, scopeID: key.scopeID, host: host, isPrivate: false))
        func bind(_ id: String) -> WKWebsiteDataStore? {
            registry.storeForTab(tabID: id, scopeID: key.scopeID, isPrivate: false,
                targetHost: host, boundHost: nil, intent: .on)
        }
        let store = try XCTUnwrap(bind("bound"))
        XCTAssertTrue(bind("detached") === store)
        let detached = try XCTUnwrap(registry.detachTab("detached", from: store))
        XCTAssertFalse(registry.setEndpoint(rejected, scopeID: key.scopeID, host: host, isPrivate: false))
        XCTAssertEqual(registry.endpoint(scopeID: key.scopeID, host: host, isPrivate: false)?.identity, rejected.identity)
        var finished = 0
        XCTAssertEqual(registry.retireListener(identity: old.identity) { finished += 1 }, [key: ["bound"]])
        XCTAssertEqual(finished, 0)
        XCTAssertEqual(store.proxyConfigurations.count, 1)
        XCTAssertNil(bind("new"))
        XCTAssertFalse(registry.setEndpoint(readyEndpoint(generation: 3), scopeID: key.scopeID, host: host, isPrivate: false))
        registry.acknowledgeRetiredTab("bound", key: key, identity: rejected.identity)
        detached()
        XCTAssertEqual(finished, 0)
        registry.acknowledgeRetiredTab("bound", key: key, identity: old.identity)
        XCTAssertEqual(finished, 1)
        XCTAssertTrue(store.proxyConfigurations.isEmpty)
    }

    @MainActor
    func testFailedEndpointKeepsTheDedicatedStore() throws {
        let registry = AccessHostDataStoreRegistry()
        let host = try self.host("example.com")
        registry.setEndpoint(readyEndpoint(generation: 1), scopeID: "ordinary", host: host, isPrivate: false)
        let created = registry.storeForTab(
            tabID: "a", scopeID: "ordinary", isPrivate: false,
            targetHost: host, boundHost: nil, intent: .on
        )
        registry.setEndpoint(readyEndpoint(generation: 2, state: .failed), scopeID: "ordinary", host: host, isPrivate: false)
        let kept = registry.storeForTab(
            tabID: "a", scopeID: "ordinary", isPrivate: false,
            targetHost: host, boundHost: host, intent: .on
        )
        XCTAssertTrue(created === kept)
        XCTAssertFalse(kept?.proxyConfigurations.isEmpty ?? true)
    }

    @MainActor
    func testOldEndpointGenerationDoesNotReplaceTheCurrentEntry() throws {
        let registry = AccessHostDataStoreRegistry()
        let host = try self.host("example.com")
        registry.setEndpoint(readyEndpoint(generation: 2), scopeID: "ordinary", host: host, isPrivate: false)
        registry.setEndpoint(readyEndpoint(generation: 1, port: 9), scopeID: "ordinary", host: host, isPrivate: false)
        XCTAssertEqual(registry.endpoint(scopeID: "ordinary", host: host, isPrivate: false)?.generation, 2)
        XCTAssertEqual(registry.endpoint(scopeID: "ordinary", host: host, isPrivate: false)?.port, 18081)
    }

    private func readyEndpoint(
        generation: UInt64,
        port: UInt16 = 18081,
        state: AccessProxyEndpointState = .ready
    ) -> AccessManagedProxyEndpoint {
        AccessManagedProxyEndpoint(
            identity: "entry-\(generation)",
            generation: generation,
            loopbackHost: "127.0.0.1",
            port: port,
            state: state
        )
    }

    func testCertificateAndPolicyFailuresDoNotEnterTheRetryQueue() {
        XCTAssertFalse(AccessNavigationRetryPolicy.admitsNetworkFailure(
            isMainFrame: true,
            isCancellation: false,
            isCertificateError: true,
            isPolicyBlock: false
        ))
        XCTAssertFalse(AccessNavigationRetryPolicy.admitsNetworkFailure(
            isMainFrame: true,
            isCancellation: false,
            isCertificateError: false,
            isPolicyBlock: true
        ))
        XCTAssertTrue(AccessNavigationRetryPolicy.admitsNetworkFailure(
            isMainFrame: true,
            isCancellation: false,
            isCertificateError: false,
            isPolicyBlock: false
        ))
    }
}
