import Security
import XCTest
@testable import Aegis

@MainActor
final class AccessAccountRefreshTests: XCTestCase {
    private func store() -> AccessAccountKeychain {
        let store = AccessAccountKeychain(service: "test.access.refresh." + UUID().uuidString)
        addTeardownBlock { try store.save(nil) }
        return store
    }

    private func snapshot(_ account: String, plan: String = "p") -> AccessAccountEntitlement {
        AccessAccountEntitlement(entitlementAccountId: account, status: .active, planId: plan,
            periodId: "period", periodStart: 10, periodEnd: 100, expiresAt: 90,
            quotaBytes: "100", uploadedBytes: "2", downloadedBytes: "3", usedBytes: "5",
            remainingBytes: "95", measuredAt: nil, receivedAt: 15,
            snapshotAgeMs: nil, freshness: .unavailable)
    }

    func testQuotaRefreshCannotCancelQueuedProxySelection() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let origin = env["AEGIS_S1_FIXTURE_ORIGIN"], let token = env["AEGIS_S1_FIXTURE_C"] else {
            throw XCTSkip("Start the controlled account service for managed selection tests")
        }
        let client = try AccessAccountClient(origin: origin, allowSimulatorLoopback: true)
        let session = AccessAccountSession(client: client, keychain: store())
        defer { session.signOut() }
        await session.bind(accountID: "C", token: token)?.value
        let tab = UUID()
        let selection = session.selectProxy(for: tab, host: "site.example", privateMode: false)
        let refresh = session.refresh()
        let selected = await selection.value
        await refresh?.value
        XCTAssertTrue(selected, "Same-account quota reads must preserve the selected authorization")
        XCTAssertEqual(session.lastSnapshot?.entitlementAccountId, "C")
        XCTAssertTrue(session.hasSelectedProxy(for: tab, host: "site.example"))
        session.closeProxy(for: tab)
        XCTAssertFalse(session.hasSelectedProxy(for: tab, host: "site.example"))
    }

    func testSignOutAndRebindCannotReviveQueuedProxySelection() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let origin = env["AEGIS_S1_FIXTURE_ORIGIN"], let token = env["AEGIS_S1_FIXTURE_C"] else {
            throw XCTSkip("Start the controlled account service for managed selection tests")
        }
        let client = try AccessAccountClient(origin: origin, allowSimulatorLoopback: true)
        let session = AccessAccountSession(client: client, keychain: store())
        defer { session.signOut() }
        await session.bind(accountID: "C", token: token)?.value
        let tab = UUID()
        let selection = session.selectProxy(for: tab, host: "site.example", privateMode: false)
        session.signOut()
        let rebound = session.bind(accountID: "C", token: token)
        let selected = await selection.value
        await rebound?.value
        XCTAssertFalse(selected, "A cleared authorization must require a new explicit selection")
        let replacement = session.selectProxy(for: tab, host: "site.example", privateMode: false)
        let replaced = await replacement.value
        XCTAssertTrue(replaced)
    }

    func testSlowReadCoalescesAndCompletedReadCanRefreshAgain() async throws {
        let reads = RefreshReadGate()
        let client = try AccessAccountClient(origin: "https://account.example.test")
        let session = AccessAccountSession(client: client, keychain: store()) { _, credential in
            try await reads.fetch(credential.token)
        }
        let first = try XCTUnwrap(session.bind(accountID: "A", token: "one"))
        await reads.started(1)
        let second = try XCTUnwrap(session.refresh())
        let third = try XCTUnwrap(session.refresh())
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, third)
        XCTAssertFalse(first.isCancelled)
        XCTAssertTrue(session.isRefreshing)
        let count = await reads.count
        XCTAssertEqual(count, 1)
        await reads.respond(1, .success(snapshot("A")))
        await first.value
        await second.value
        await third.value
        XCTAssertFalse(session.isRefreshing)
        let next = try XCTUnwrap(session.refresh())
        await reads.started(2)
        await reads.respond(2, .success(snapshot("A", plan: "next")))
        await next.value
        XCTAssertEqual(session.state, .ready(snapshot("A", plan: "next")))
    }

    func testResponseTransitAndPostDeliveryTimeAgeTheDisplayedMeasurement() async throws {
        let reads = RefreshReadGate()
        var now: TimeInterval = 42
        let client = try AccessAccountClient(origin: "https://account.example.test")
        let session = AccessAccountSession(client: client, keychain: store(), uptime: { now }) { _, credential in
            try await reads.fetch(credential.token)
        }
        let measured = AccessAccountEntitlement(entitlementAccountId: "A", status: .active,
            planId: "p", periodId: "period", periodStart: 0, periodEnd: 100_000, expiresAt: 100_000,
            quotaBytes: "100", uploadedBytes: "2", downloadedBytes: "3", usedBytes: "5",
            remainingBytes: "95", measuredAt: 0, receivedAt: 10_000,
            snapshotAgeMs: 10_000, freshness: .delayed)
        let initial = try XCTUnwrap(session.bind(accountID: "A", token: "one"))
        await reads.started(1)
        now = 48 // Six seconds in transit cross the 15-second stale boundary.
        await reads.respond(1, .success(measured))
        await initial.value
        XCTAssertEqual(session.snapshotReceivedUptime, 48)
        XCTAssertEqual(session.snapshotFreshnessAnchorUptime, 42)
        XCTAssertEqual(session.lastSnapshot, measured, "Keep the server watermark unchanged")
        XCTAssertEqual(AccessAccountUsagePresentation.freshness(snapshot: measured,
            receivedUptime: session.snapshotFreshnessAnchorUptime, nowUptime: now,
            stale: session.snapshotIsStale), .unavailable)

        // A new successful read gets its own start. Receipt time alone cannot reset age.
        let next = try XCTUnwrap(session.refresh())
        await reads.started(2)
        now = 52
        await reads.respond(2, .success(measured))
        await next.value
        XCTAssertEqual(session.snapshotFreshnessAnchorUptime, 48)
        XCTAssertEqual(AccessAccountUsagePresentation.freshness(snapshot: measured,
            receivedUptime: session.snapshotFreshnessAnchorUptime, nowUptime: 53,
            stale: false), .delayed)
        XCTAssertEqual(AccessAccountUsagePresentation.freshness(snapshot: measured,
            receivedUptime: session.snapshotFreshnessAnchorUptime, nowUptime: 53.001,
            stale: false), .unavailable)
        session.signOut()
        XCTAssertNil(session.snapshotFreshnessAnchorUptime)
    }

    func testInvalidOrRegressingRequestTimingCannotProduceFreshness() async throws {
        for (start, end): (TimeInterval, TimeInterval) in [
            (-1, 5), (.nan, 5), (.infinity, 5), (5, 4), (5, .nan), (5, .infinity)
        ] {
            let reads = RefreshReadGate()
            var now = start
            let client = try AccessAccountClient(origin: "https://account.example.test")
            let session = AccessAccountSession(client: client, keychain: store(), uptime: { now }) { _, credential in
                try await reads.fetch(credential.token)
            }
            let measured = AccessAccountEntitlement(entitlementAccountId: "A", status: .active,
                planId: "p", periodId: "period", periodStart: 0, periodEnd: 100_000, expiresAt: 100_000,
                quotaBytes: "100", uploadedBytes: "2", downloadedBytes: "3", usedBytes: "5",
                remainingBytes: "95", measuredAt: 10_000, receivedAt: 10_000,
                snapshotAgeMs: 0, freshness: .current)
            let task = try XCTUnwrap(session.bind(accountID: "A", token: "one"))
            await reads.started(1)
            now = end
            await reads.respond(1, .success(measured))
            await task.value
            XCTAssertEqual(session.lastSnapshot, measured)
            XCTAssertNil(session.snapshotFreshnessAnchorUptime)
            XCTAssertEqual(AccessAccountUsagePresentation.freshness(snapshot: measured,
                receivedUptime: session.snapshotFreshnessAnchorUptime, nowUptime: 5,
                stale: false), .unavailable)
        }
    }

    func testSameIdentityRefreshRetainsStaleSnapshotAndReceiptUntilSuccess() async throws {
        let reads = RefreshReadGate()
        var now: TimeInterval = 42
        let client = try AccessAccountClient(origin: "https://account.example.test")
        let session = AccessAccountSession(client: client, keychain: store(), uptime: { now }) { _, credential in
            try await reads.fetch(credential.token)
        }
        let initial = try XCTUnwrap(session.bind(accountID: "A", token: "one"))
        await reads.started(1)
        await reads.respond(1, .success(snapshot("A")))
        await initial.value
        XCTAssertEqual(session.snapshotReceivedUptime, 42)
        XCTAssertFalse(session.snapshotIsStale)
        XCTAssertNil(session.lastSnapshot?.measuredAt)

        let failed = try XCTUnwrap(session.refresh())
        XCTAssertEqual(session.state, .loading)
        XCTAssertTrue(session.snapshotIsStale)
        XCTAssertEqual(session.lastSnapshot, snapshot("A"))
        await reads.started(2)
        await reads.respond(2, .failure(URLError(.timedOut)))
        await failed.value
        XCTAssertEqual(session.state, .unavailable)
        XCTAssertTrue(session.snapshotIsStale)
        XCTAssertEqual(session.snapshotReceivedUptime, 42)

        let foreign = try XCTUnwrap(session.refresh())
        await reads.started(3)
        await reads.respond(3, .success(snapshot("B")))
        await foreign.value
        XCTAssertEqual(session.state, .unavailable)
        XCTAssertEqual(session.lastSnapshot, snapshot("A"))
        XCTAssertTrue(session.snapshotIsStale)

        now = 99
        let recovered = try XCTUnwrap(session.refresh())
        await reads.started(4)
        await reads.respond(4, .success(snapshot("A", plan: "new")))
        await recovered.value
        XCTAssertEqual(session.lastSnapshot, snapshot("A", plan: "new"))
        XCTAssertEqual(session.snapshotReceivedUptime, 99)
        XCTAssertFalse(session.snapshotIsStale)
    }

    func testSwitchBackOldSuccessAndOldUnauthorizedCannotClearNewTask() async throws {
        let reads = RefreshReadGate()
        let keychain = store()
        let client = try AccessAccountClient(origin: "https://account.example.test")
        let session = AccessAccountSession(client: client, keychain: keychain) { _, credential in
            try await reads.fetch(credential.token)
        }
        let a = try XCTUnwrap(session.bind(accountID: "A", token: "one"))
        await reads.started(1)
        let b = try XCTUnwrap(session.bind(accountID: "B", token: "two"))
        await reads.started(2)
        let newA = try XCTUnwrap(session.bind(accountID: "A", token: "three"))
        await reads.started(3)
        await reads.respond(1, .success(snapshot("A", plan: "old")))
        await reads.respond(2, .failure(AccountQueryError.unauthorized))
        await a.value
        await b.value
        XCTAssertTrue(session.isRefreshing)
        XCTAssertEqual(session.refresh(), newA)
        XCTAssertNil(session.lastSnapshot)
        XCTAssertEqual(try keychain.read()?.token, "three")
        await reads.respond(3, .success(snapshot("A", plan: "new")))
        await newA.value
        XCTAssertEqual(session.lastSnapshot, snapshot("A", plan: "new"))
        let revoked = try XCTUnwrap(session.refresh())
        await reads.started(4)
        await reads.respond(4, .failure(AccountQueryError.unauthorized))
        await revoked.value
        XCTAssertEqual(session.state, .signedOut)
        XCTAssertNil(session.lastSnapshot)
        XCTAssertNil(session.snapshotReceivedUptime)
        XCTAssertNil(try keychain.read())
        XCTAssertFalse(session.isRefreshing)
    }

    func testSuspendAndSignOutInvalidateLateReadsAndClearReceipt() async throws {
        let reads = RefreshReadGate()
        let keychain = store()
        let client = try AccessAccountClient(origin: "https://account.example.test")
        let session = AccessAccountSession(client: client, keychain: keychain) { _, credential in
            try await reads.fetch(credential.token)
        }
        let initial = try XCTUnwrap(session.bind(accountID: "A", token: "one"))
        await reads.started(1)
        await reads.respond(1, .success(snapshot("A")))
        await initial.value
        let old = try XCTUnwrap(session.refresh())
        await reads.started(2)
        session.suspend()
        XCTAssertNil(session.lastSnapshot)
        XCTAssertNil(session.snapshotReceivedUptime)
        XCTAssertNotNil(try keychain.read())
        let resumed = try XCTUnwrap(session.refresh())
        await reads.started(3)
        await reads.respond(2, .success(snapshot("A", plan: "old")))
        await old.value
        XCTAssertTrue(session.isRefreshing)
        XCTAssertNil(session.lastSnapshot)
        session.signOut()
        await reads.respond(3, .success(snapshot("A")))
        await resumed.value
        XCTAssertEqual(session.state, .signedOut)
        XCTAssertFalse(session.isRefreshing)
        XCTAssertNil(session.lastSnapshot)
        XCTAssertNil(session.snapshotReceivedUptime)
        XCTAssertNil(try keychain.read())
    }

    func testExternalIdentityChangeDoesNotCoalesceOrRetainOldAccount() async throws {
        let reads = RefreshReadGate()
        let keychain = store()
        let client = try AccessAccountClient(origin: "https://account.example.test")
        let session = AccessAccountSession(client: client, keychain: keychain) { _, credential in
            try await reads.fetch(credential.token)
        }
        let initial = try XCTUnwrap(session.bind(accountID: "A", token: "one"))
        await reads.started(1)
        await reads.respond(1, .success(snapshot("A")))
        await initial.value
        let old = try XCTUnwrap(session.refresh())
        await reads.started(2)
        try keychain.save(.init(accountID: "B", token: "two", endpoint: client.endpoint.absoluteString))
        let current = try XCTUnwrap(session.refresh())
        await reads.started(3)
        XCTAssertNil(session.lastSnapshot)
        XCTAssertNil(session.snapshotReceivedUptime)
        await reads.respond(2, .failure(AccountQueryError.unauthorized))
        await old.value
        XCTAssertTrue(session.isRefreshing)
        XCTAssertEqual(try keychain.read()?.accountID, "B")
        await reads.respond(3, .success(snapshot("B")))
        await current.value
        XCTAssertEqual(session.lastSnapshot, snapshot("B"))

        let changedDuringRead = try XCTUnwrap(session.refresh())
        await reads.started(4)
        try keychain.save(nil)
        await reads.respond(4, .failure(URLError(.timedOut)))
        await changedDuringRead.value
        XCTAssertEqual(session.state, .unavailable)
        XCTAssertNil(session.lastSnapshot)
        XCTAssertNil(session.snapshotReceivedUptime)
        XCTAssertFalse(session.isRefreshing)
    }

    func testUnreadableKeychainClearsSnapshotAtRefreshAndAtReplyDelivery() async throws {
        for duringRead in [false, true] {
            let reads = RefreshReadGate()
            let keychain = store()
            let client = try AccessAccountClient(origin: "https://account.example.test")
            let session = AccessAccountSession(client: client, keychain: keychain) { _, credential in
                try await reads.fetch(credential.token)
            }
            let initial = try XCTUnwrap(session.bind(accountID: "A", token: "one"))
            await reads.started(1)
            await reads.respond(1, .success(snapshot("A")))
            await initial.value
            let pending = duringRead ? session.refresh() : nil
            if duringRead { await reads.started(2) }
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychain.service, kSecAttrAccount as String: "current",
                kSecAttrSynchronizable as String: false]
            let attributes = [kSecValueData as String: Data("not-json".utf8)]
            XCTAssertEqual(SecItemUpdate(query as CFDictionary, attributes as CFDictionary), errSecSuccess)
            XCTAssertThrowsError(try keychain.read())
            if duringRead {
                await reads.respond(2, .failure(URLError(.timedOut)))
                await pending?.value
            } else {
                XCTAssertNil(session.refresh())
            }
            XCTAssertEqual(session.state, .unavailable)
            XCTAssertNil(session.lastSnapshot)
            XCTAssertNil(session.snapshotReceivedUptime)
            XCTAssertFalse(session.isRefreshing)
        }
    }

    func testInvalidExternalCredentialClearsCachedSnapshotBeforeRequest() async throws {
        let reads = RefreshReadGate()
        let keychain = store()
        let client = try AccessAccountClient(origin: "https://account.example.test")
        let session = AccessAccountSession(client: client, keychain: keychain) { _, credential in
            try await reads.fetch(credential.token)
        }
        let initial = try XCTUnwrap(session.bind(accountID: "A", token: "one"))
        await reads.started(1)
        await reads.respond(1, .success(snapshot("A")))
        await initial.value
        try keychain.save(.init(accountID: "A", token: "one", endpoint: "https://different.example.test/v1/me/entitlement"))
        XCTAssertNil(session.refresh())
        XCTAssertEqual(session.state, .unavailable)
        XCTAssertNil(session.lastSnapshot)
        XCTAssertNil(session.snapshotReceivedUptime)
        XCTAssertFalse(session.isRefreshing)
    }
}

/// Ignores cancellation deliberately so tests exercise late-response generation guards.
private actor RefreshReadGate {
    typealias Reply = CheckedContinuation<AccessAccountEntitlement, any Error>
    private var replies: [Int: Reply] = [:]
    private var starts: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var count = 0

    func fetch(_ token: String) async throws -> AccessAccountEntitlement {
        count += 1
        let id = count
        return try await withCheckedThrowingContinuation { continuation in
            replies[id] = continuation
            starts.removeValue(forKey: id)?.resume()
        }
    }

    func started(_ id: Int) async {
        if replies[id] != nil { return }
        await withCheckedContinuation { starts[id] = $0 }
    }

    func respond(_ id: Int, _ result: Result<AccessAccountEntitlement, any Error>) {
        replies.removeValue(forKey: id)?.resume(with: result)
    }
}
