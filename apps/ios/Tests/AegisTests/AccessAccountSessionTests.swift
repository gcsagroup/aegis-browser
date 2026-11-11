import XCTest
@testable import Aegis

@MainActor
final class AccessAccountSessionTests: XCTestCase {
    private func isolatedStore() -> AccessAccountKeychain {
        let keychain = AccessAccountKeychain(service: "test.access.account." + UUID().uuidString)
        addTeardownBlock { try keychain.save(nil) }
        return keychain
    }

    func testEndpointAllowsOnlyAServiceOriginAndExplicitLoopback() throws {
        for origin in ["http://example.org", "https://a@b", "https://example.org/?x", "https://example.org/#x",
                       "https://example.org/v1", "http://localhost", "http://127.0.0.1/"] {
            XCTAssertThrowsError(try AccessAccountClient(origin: origin))
        }
        XCTAssertEqual(try AccessAccountClient(origin: "https://account.example.test/").endpoint.absoluteString,
                       "https://account.example.test/v1/me/entitlement")
    }

    func testStatusFreshnessAndIntegerWireContract() throws {
        let complete: [String: Any] = ["entitlementAccountId": "A", "status": "active",
            "planId": "p", "periodId": "1", "periodStart": 0, "periodEnd": 30000, "expiresAt": 28000,
            "quotaBytes": "9007199254740997", "uploadedBytes": "4", "downloadedBytes": "5",
            "usedBytes": "9", "remainingBytes": "9007199254740988", "receivedAt": 20000,
            "measuredAt": 10000, "snapshotAgeMs": 10000, "freshness": "delayed"]
        func decode(_ fields: [String: Any]) throws -> AccessAccountEntitlement {
            let data = try JSONSerialization.data(withJSONObject: fields)
            let result = try JSONDecoder().decode(AccessAccountEntitlement.self, from: data)
            try result.validate(for: "A")
            return result
        }
        XCTAssertEqual(try decode(complete).freshness, .delayed)
        XCTAssertEqual(try decode(complete.merging(["status": "expired"]) { _, x in x }).status, .expired)
        XCTAssertEqual(try decode(["entitlementAccountId": "A", "status": "not_subscribed"]).status, .notSubscribed)
        for (key, bad): (String, Any) in [("quotaBytes", 9007199254740997 as UInt64), ("usedBytes", "09"),
                                         ("remainingBytes", "0"), ("freshness", "current"), ("status", "exhausted")] {
            XCTAssertThrowsError(try decode(complete.merging([key: bad]) { _, x in x }), key)
        }
    }

    func testPendingSwitchBackAndRevocationCannotPublishAnEarlierIdentity() async throws {
        let service = try AccessAccountClient(origin: "https://account.example.test")
        let store = isolatedStore()
        let pending = DelayedAccountReads()
        let session = AccessAccountSession(client: service, keychain: store) { _, credential in
            try await pending.fetch(credential.token)
        }
        let first = try XCTUnwrap(session.bind(accountID: "A", token: "one"))
        await pending.started("one")
        let second = try XCTUnwrap(session.bind(accountID: "B", token: "two"))
        await pending.started("two")
        let third = try XCTUnwrap(session.bind(accountID: "A", token: "three"))
        await pending.started("three")
        await pending.respond("three", with: account("A", plan: "new-plan"))
        await third.value
        await pending.respond("one", with: account("A", plan: "old-plan"))
        await pending.fail("two", error: AccountQueryError.unauthorized)
        await first.value
        await second.value
        XCTAssertEqual(session.state, .ready(account("A", plan: "new-plan")))
        XCTAssertEqual(try store.read()?.token, "three")

        let task = session.refresh()
        await pending.started("three")
        await pending.fail("three", error: AccountQueryError.unauthorized)
        await task?.value
        XCTAssertEqual(session.state, .signedOut)
        XCTAssertNil(try store.read())
    }

    func testForeignAccountResponseAndUnavailableNeverExposePriorNumbers() async throws {
        let client = try AccessAccountClient(origin: "https://account.example.test")
        let pending = DelayedAccountReads()
        let session = AccessAccountSession(client: client, keychain: isolatedStore()) { _, credential in
            try await pending.fetch(credential.token)
        }
        let first = try XCTUnwrap(session.bind(accountID: "A", token: "one"))
        await pending.started("one")
        await pending.respond("one", with: account("A"))
        await first.value
        XCTAssertEqual(session.state, .ready(account("A")))
        let wrong = session.refresh()
        XCTAssertEqual(session.state, .loading)
        await pending.started("one")
        await pending.respond("one", with: account("B"))
        await wrong?.value
        XCTAssertEqual(session.state, .unavailable)
        let failed = session.refresh()
        await pending.started("one")
        await pending.fail("one", error: URLError(.timedOut))
        await failed?.value
        XCTAssertEqual(session.state, .unavailable)
        let late = session.refresh()
        await pending.started("one")
        session.signOut()
        await pending.respond("one", with: account("A"))
        await late?.value
        XCTAssertEqual(session.state, .signedOut)
    }

#if DEBUG && targetEnvironment(simulator)
    func testSimulatorProductEntryAgainstProvisionedAccountService() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let origin = env["AEGIS_S1_FIXTURE_ORIGIN"] else {
            throw XCTSkip("Start apps/ios/scripts/account-entitlement-fixture.py for the loopback service test")
        }
        let store = isolatedStore()
        let session = AccessAccountSession.product(environment: ["AEGIS_ACCOUNT_SIM_ORIGIN": origin,
            "AEGIS_ACCOUNT_SIM_ACTION": "bind", "AEGIS_ACCOUNT_SIM_ID": "A",
            "AEGIS_ACCOUNT_SIM_TOKEN": try XCTUnwrap(env["AEGIS_S1_FIXTURE_A"])], keychain: store)
        await session.refresh()?.value
        guard case let .ready(a) = session.state else { return XCTFail("A did not resolve through native product entry") }
        XCTAssertEqual(a.entitlementAccountId, "A")
        XCTAssertEqual(a.quotaBytes, "9007199254740997")
        XCTAssertEqual(a.usedBytes, "65636")
        XCTAssertEqual(a.freshness, .unavailable)
        XCTAssertNil(a.measuredAt)
        await session.bind(accountID: "B", token: try XCTUnwrap(env["AEGIS_S1_FIXTURE_B"]))?.value
        guard case let .ready(b) = session.state else { return XCTFail("B did not resolve") }
        XCTAssertEqual(b.status, .exhausted)
        XCTAssertEqual(b.remainingBytes, "0")
        await session.bind(accountID: "B", token: "unknown")?.value
        XCTAssertEqual(session.state, .signedOut)

        let redirection = try XCTUnwrap(env["AEGIS_S1_FIXTURE_REDIRECT"])
        let guarded = AccessAccountSession.product(environment: ["AEGIS_ACCOUNT_SIM_ORIGIN": redirection,
            "AEGIS_ACCOUNT_SIM_ACTION": "bind", "AEGIS_ACCOUNT_SIM_ID": "A", "AEGIS_ACCOUNT_SIM_TOKEN": "canary"], keychain: store)
        await guarded.refresh()?.value
        XCTAssertEqual(guarded.state, .unavailable)
        let (count, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: redirection + "/visits")))
        XCTAssertEqual(String(decoding: count, as: UTF8.self), "0")
    }
#endif

    private func account(_ id: String, plan: String = "p") -> AccessAccountEntitlement {
        AccessAccountEntitlement(entitlementAccountId: id, status: .active, planId: plan, periodId: "current",
            periodStart: 10, periodEnd: 100, expiresAt: 90, quotaBytes: "100", uploadedBytes: "2",
            downloadedBytes: "3", usedBytes: "5", remainingBytes: "95", measuredAt: nil, receivedAt: 15,
            snapshotAgeMs: nil, freshness: .unavailable)
    }


}

private actor DelayedAccountReads {
    typealias Callback = CheckedContinuation<AccessAccountEntitlement, any Error>
    var reads: [String: Callback] = [:]
    var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    func fetch(_ token: String) async throws -> AccessAccountEntitlement {
        try await withCheckedThrowingContinuation { continuation in
            reads[token] = continuation
            waiters.removeValue(forKey: token)?.resume()
        }
    }
    func started(_ token: String) async {
        if reads[token] == nil { await withCheckedContinuation { waiters[token] = $0 } }
    }
    func respond(_ token: String, with result: AccessAccountEntitlement) {
        reads.removeValue(forKey: token)?.resume(returning: result)
    }
    func fail(_ token: String, error: any Error) { reads.removeValue(forKey: token)?.resume(throwing: error) }
}
