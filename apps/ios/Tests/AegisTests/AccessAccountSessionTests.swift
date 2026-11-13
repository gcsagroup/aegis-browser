import XCTest
@testable import BrowserKit
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

    func testManagedLeaseRejectsWrongAccountPeriodContextModeAndExpiry() throws {
        let context = UUID().uuidString.lowercased(), now = Date(timeIntervalSince1970: 1)
        let fixture: [String: Any] = ["accountId": "A", "periodId": "p", "contextId": context, "mode": "regular",
            "credentialId": "node-id", "username": "node-id", "password": "synthetic", "host": "node.invalid",
            "port": 443, "expiresAt": 2000]
        func validate(_ replacements: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: fixture.merging(replacements) { _, new in new })
            let value = try JSONDecoder().decode(AccessNodeLease.self, from: data)
            try value.validate(account: "A", period: "p", context: context, mode: .regular, now: now)
        }
        try validate([:])
        for invalid: [String: Any] in [["accountId": "B"], ["periodId": "other"], ["contextId": UUID().uuidString],
                                      ["mode": "private"], ["expiresAt": 1000], ["username": "other"],
                                      ["host": "user@node.invalid"], ["port": 0], ["credentialId": "../x", "username": "../x"]] {
            XCTAssertThrowsError(try validate(invalid))
        }
    }

    func testRenewalRejectsChangedBindingAndLateOrNonExtendingReplies() throws {
        let lease = AccessNodeLease(accountId: "a", periodId: "p", credentialId: "id", contextId: "ctx", host: "node.invalid",
                                    username: "id", password: "synthetic", mode: .private, port: 443, expiresAt: 5000)
        let fields: [String: Any] = ["accountId": "a", "periodId": "p", "credentialId": "id",
                                     "contextId": "ctx", "mode": "private", "expiresAt": 8000]
        func renew(_ changes: [String: Any], now: TimeInterval = 4) throws -> AccessNodeLease {
            try lease.renewed(with: JSONSerialization.data(withJSONObject: fields.merging(changes) { _, new in new }),
                              now: Date(timeIntervalSince1970: now))
        }
        let renewed = try renew([:])
        XCTAssertEqual(renewed.expiresAt, 8000)
        XCTAssertEqual(renewed.password, lease.password)
        for changes: [String: Any] in [["accountId": "b"], ["periodId": "q"], ["credentialId": "other"],
                                        ["contextId": "other"], ["mode": "regular"], ["expiresAt": 5000]] {
            XCTAssertThrowsError(try renew(changes))
        }
        XCTAssertThrowsError(try renew([:], now: 5))
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

#if DEBUG && targetEnvironment(simulator)
    func testProtectedCaptureSurvivesNormalizationAndEditedOrigin() async throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil),
                                     workspaceStore: WorkspaceStore(persistenceURL: nil))
        let tab = try XCTUnwrap(browser.activeTab)
        let target = try XCTUnwrap(URL(string: "https://example.invalid/file?utm_source=example"))
        let account = AccessAccountSession(client: nil, keychain: isolatedStore())
        let downloads = DownloadManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                        background: false)
        defer { try? FileManager.default.removeItem(at: downloads.directory) }
        try await waitUntil { downloads.isReady }
        tab.prepareForRestore(url: target)
        tab.selectedAccessHost = "example.invalid"
        tab.onDownload?(target)
        let captured = try XCTUnwrap(browser.pendingAccessDownload)
        let clean = try DownloadManager.validatedURL(target.absoluteString)
        XCTAssertNotEqual(clean, target)
        let edited = try XCTUnwrap(URL(string: "https://other.invalid/replacement"))
        for destination in [clean, edited] {
            do {
                _ = try await account.startDownload(.init(urls: [destination]), captured: captured,
                                                    browser: browser, downloads: downloads)
                XCTFail("A protected sheet started an ordinary transfer")
            } catch { }
        }
        XCTAssertTrue(downloads.items.isEmpty)
    }

    func testRootDotCapturesProtectedDownload() throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil),
                                     workspaceStore: WorkspaceStore(persistenceURL: nil))
        let tab = try XCTUnwrap(browser.activeTab)
        let page = try XCTUnwrap(URL(string: "https://example.invalid./"))
        let download = try XCTUnwrap(URL(string: "https://EXAMPLE.INVALID./file"))
        tab.prepareForRestore(url: page)
        _ = AccessSiteProxySessionStore().setProxyEnabled(true, for: tab,
            account: AccessAccountSession(client: nil, keychain: isolatedStore()))
        tab.onDownload?(download)
        XCTAssertEqual(browser.pendingAccessDownload?.tab, tab.id)
    }

    func testSheetCaptureIsNotReplacedByAnotherTabOrReusedAfterReselection() throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil),
                                     workspaceStore: WorkspaceStore(persistenceURL: nil))
        let first = try XCTUnwrap(browser.activeTab)
        let url = try XCTUnwrap(URL(string: "https://example.invalid/file"))
        first.prepareForRestore(url: url)
        first.selectedAccessHost = "example.invalid"
        first.onDownload?(url)
        let captured = try XCTUnwrap(browser.pendingAccessDownload)
        XCTAssertTrue(browser.ownsAccessDownload(captured))
        let second = browser.newTab()
        second.prepareForRestore(url: url)
        second.onDownload?(url)
        XCTAssertNil(browser.pendingAccessDownload)
        XCTAssertFalse(browser.ownsAccessDownload(captured))
        browser.activate(first.id)
        first.prepareForRestore(url: url)
        first.onDownload?(url)
        let nextRequest = try XCTUnwrap(browser.pendingAccessDownload)
        XCTAssertTrue(browser.ownsAccessDownload(nextRequest))
        XCTAssertFalse(browser.ownsAccessDownload(captured))
        first.selectedAccessHost = nil
        first.selectedAccessHost = "example.invalid"
        XCTAssertFalse(browser.ownsAccessDownload(nextRequest))
    }

    private func resetIssuanceGate(_ origin: String) async throws -> URL {
        let gate = try XCTUnwrap(URL(string: origin + "/gate"))
        var reset = URLRequest(url: gate.appendingPathComponent("reset")); reset.httpMethod = "POST"
        let (_, resetReply) = try await URLSession.shared.data(for: reset)
        XCTAssertEqual((resetReply as? HTTPURLResponse)?.statusCode, 200)
        return gate
    }

    private func waitForHeldIssuance(_ gate: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while true {
            let (data, _) = try await URLSession.shared.data(from: gate)
            let state = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if state?["firstWaiting"] as? Bool == true { break }
            guard ContinuousClock.now < deadline else { throw AccountQueryError.invalid }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    func testReplacedSheetRefusesTransferAfterAsyncIssuance() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let origin = env["AEGIS_S3_RACE_ORIGIN"] else { throw XCTSkip("Start the local gated issuer") }
        let target = try XCTUnwrap(env["AEGIS_S3_HTTPS_URL"].flatMap(URL.init(string:)))
        let host = try XCTUnwrap(target.host)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil),
                                     workspaceStore: WorkspaceStore(persistenceURL: nil))
        let tab = try XCTUnwrap(browser.activeTab)
        let account = AccessAccountSession(client: try AccessAccountClient(origin: origin, allowSimulatorLoopback: true),
                                           keychain: isolatedStore())
        let downloads = DownloadManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                        background: false)
        defer { account.signOut(); try? FileManager.default.removeItem(at: downloads.directory) }
        try await waitUntil { downloads.isReady }
        await account.bind(accountID: try XCTUnwrap(env["AEGIS_S3_ID"]), token: try XCTUnwrap(env["AEGIS_S3_TOKEN"]))?.value
        let gate = try await resetIssuanceGate(origin)
        tab.prepareForRestore(url: target)
        let pending = try XCTUnwrap(AccessSiteProxySessionStore().setProxyEnabled(true, for: tab, account: account))
        tab.onDownload?(target)
        let captured = try XCTUnwrap(browser.pendingAccessDownload)
        let started = expectation(description: "Protected download enters async acquisition")
        let consumer = Task {
            started.fulfill()
            return try await account.startDownload(.init(urls: [target]), captured: captured, browser: browser, downloads: downloads)
        }
        await fulfillment(of: [started], timeout: 5)
        try await waitForHeldIssuance(gate)
        let other = browser.newTab()
        other.prepareForRestore(url: target)
        other.onDownload?(target)
        // An unrelated new tab replaces the pending sheet event while the old
        // selected tab remains authorized. Return to it before the POST completes.
        browser.activate(tab.id)
        tab.prepareForRestore(url: target)
        let releaseGate = await account.selectProxy(for: other.id, host: host, privateMode: false).value
        XCTAssertTrue(releaseGate)
        let prepared = await pending.value
        XCTAssertTrue(prepared)
        do { _ = try await consumer.value; XCTFail("A stale sheet started a transfer") } catch { }
        XCTAssertTrue(downloads.items.isEmpty)
    }

    func testDelayedIssuanceCannotRevokeReplacement() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let origin = env["AEGIS_S3_RACE_ORIGIN"] else { throw XCTSkip("Start the local gated issuer") }
        let target = try XCTUnwrap(env["AEGIS_S3_HTTPS_URL"].flatMap(URL.init(string:)))
        let host = try XCTUnwrap(target.host), tab = UUID()
        let account = AccessAccountSession(client: try AccessAccountClient(origin: origin, allowSimulatorLoopback: true),
                                           keychain: isolatedStore())
        let downloads = DownloadManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                        background: false)
        defer { account.signOut(); try? FileManager.default.removeItem(at: downloads.directory) }
        try await waitUntil { downloads.isReady }
        let gate = try await resetIssuanceGate(origin)
        await account.bind(accountID: try XCTUnwrap(env["AEGIS_S3_ID"]), token: try XCTUnwrap(env["AEGIS_S3_TOKEN"]))?.value
        let first = account.selectProxy(for: tab, host: host, privateMode: false)
        try await waitForHeldIssuance(gate)
        await account.refresh()?.value
        let replacement = try await account.downloadSession(for: tab, privateMode: false, target: target, downloadDelegate: downloads)
        let staleAccepted = await first.value
        XCTAssertFalse(staleAccepted)
        let download = try downloads.start(.init(urls: [target]), accessSession: replacement)
        try await waitUntil { downloads.items.contains { $0.id == download && [.completed, .failed].contains($0.state) } }
        XCTAssertEqual(downloads.items.first?.sha256, env["AEGIS_S3_EXPECTED_SHA256"])
    }

    func testManagedRegularAndExplicitPrivateDownloadAndLiveLogout() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let origin = env["AEGIS_S3_ORIGIN"] else { throw XCTSkip("Start the managed TLS CONNECT/Xray fixture") }
        let target = try XCTUnwrap(env["AEGIS_S3_HTTPS_URL"].flatMap(URL.init(string:)))
        let id = try XCTUnwrap(env["AEGIS_S3_ID"])
        let token = try XCTUnwrap(env["AEGIS_S3_TOKEN"])
        let client = try AccessAccountClient(origin: origin, allowSimulatorLoopback: true)
        let account = AccessAccountSession(client: client, keychain: isolatedStore())
        await account.bind(accountID: id, token: token)?.value
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloads = DownloadManager(directory: dir, background: false)
        try await waitUntil { downloads.isReady }
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil),
                                     workspaceStore: WorkspaceStore(persistenceURL: nil))
        let site = AccessSiteProxySessionStore()
        let regularTab = try XCTUnwrap(browser.activeTab)
        let regular = regularTab.id
        regularTab.prepareForRestore(url: target)
        let regularPrepared = await site.setProxyEnabled(true, for: regularTab, account: account)?.value
        XCTAssertEqual(regularPrepared, true)
        browser.switchProfile(to: .privateMode)
        let otr = try XCTUnwrap(browser.activeTab), privateTab = otr.id
        otr.prepareForRestore(url: target)
        let unauthorized = await site.setProxyEnabled(true, for: otr, account: account)?.value
        XCTAssertEqual(unauthorized, false)
        do {
            _ = try await account.downloadSession(for: privateTab, privateMode: true, target: target, downloadDelegate: downloads)
            XCTFail("OTR borrowed regular authorization")
        } catch AccountQueryError.unauthorized { }
        let authorized = await site.setProxyEnabled(true, for: otr, account: account, privateAccount: id, privateToken: token)?.value
        XCTAssertEqual(authorized, true)
        for tab in [regularTab, otr] {
            browser.switchProfile(to: tab.profile)
            browser.activate(tab.id)
            var source = try XCTUnwrap(URLComponents(url: target, resolvingAgainstBaseURL: false))
            source.host = try XCTUnwrap(target.host) + "."
            source.queryItems = [URLQueryItem(name: "utm_source", value: "native")]
            let raw = try XCTUnwrap(source.url)
            tab.prepareForRestore(url: raw)
            tab.onDownload?(raw)
            let captured = try XCTUnwrap(browser.pendingAccessDownload)
            // Ordinary Start sanitizes the URL first. A same-origin manual edit is also
            // allowed, but both paths must use this sheet's original paid transport.
            let destination = tab.profile.isPrivate ? target : try DownloadManager.validatedURL(raw.absoluteString)
            let download = try await account.startDownload(.init(urls: [destination]), captured: captured,
                                                           browser: browser, downloads: downloads)
            try await waitUntil { downloads.items.contains { $0.id == download && [.completed, .failed].contains($0.state) } }
            let item = try XCTUnwrap(downloads.items.first { $0.id == download })
            XCTAssertEqual(item.state, .completed, item.message ?? "")
            XCTAssertEqual(item.sha256, env["AEGIS_S3_EXPECTED_SHA256"])
        }
        let slow = try XCTUnwrap(env["AEGIS_S3_SLOW_URL"].flatMap(URL.init(string:)))
        let route = try await account.downloadSession(for: regular, privateMode: false, target: slow, downloadDelegate: downloads)
        let live = try downloads.start(.init(urls: [slow]), accessSession: route)
        try await waitUntil { downloads.items.contains { $0.id == live && $0.state == .running && $0.received > 0 } }
        let alternate = try XCTUnwrap(env["AEGIS_S3_B_ID"]), alternateToken = try XCTUnwrap(env["AEGIS_S3_B_TOKEN"])
        await account.bind(accountID: alternate, token: alternateToken)?.value
        XCTAssertThrowsError(try downloads.start(.init(urls: [slow]), accessSession: route))
        try await waitUntil { downloads.items.contains { $0.id == live && [.failed, .cancelled].contains($0.state) } }
        let secondRoute = try await account.downloadSession(for: regular, privateMode: false, target: slow, downloadDelegate: downloads)
        let secondLive = try downloads.start(.init(urls: [slow]), accessSession: secondRoute)
        try await waitUntil { downloads.items.contains { $0.id == secondLive && $0.state == .running && $0.received > 0 } }
        account.signOut()
        XCTAssertThrowsError(try downloads.start(.init(urls: [slow]), accessSession: secondRoute))
        try await waitUntil { downloads.items.contains { $0.id == secondLive && [.failed, .cancelled].contains($0.state) } }
        do {
            _ = try await account.downloadSession(for: privateTab, privateMode: true, target: target, downloadDelegate: downloads)
            XCTFail("Private bearer survived sign-out")
        } catch AccountQueryError.unauthorized { }
    }

    func testQueuedProtectedDownloadsKeepOnlyTheirLiveAuthorization() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let seconds = env["AEGIS_S3_LEASE_TTL_SECONDS"], let ttl = Int(seconds) else {
            throw XCTSkip("Start the short-lease managed node fixture")
        }
        let origin = try XCTUnwrap(env["AEGIS_S3_ORIGIN"])
        let slow = try XCTUnwrap(env["AEGIS_S3_SLOW_URL"].flatMap(URL.init(string:)))
        let fast = try XCTUnwrap(env["AEGIS_S3_HTTPS_URL"].flatMap(URL.init(string:)))
        let account = AccessAccountSession(client: try AccessAccountClient(origin: origin, allowSimulatorLoopback: true),
                                           keychain: isolatedStore())
        await account.bind(accountID: try XCTUnwrap(env["AEGIS_S3_ID"]), token: try XCTUnwrap(env["AEGIS_S3_TOKEN"]))?.value
        defer { account.signOut() }
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), workspaceStore: WorkspaceStore(persistenceURL: nil))
        let downloads = DownloadManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                        background: false, maximumConcurrentDownloads: 1)
        defer { try? FileManager.default.removeItem(at: downloads.directory) }
        try await waitUntil { downloads.isReady }
        let site = AccessSiteProxySessionStore()
        func authorize(_ tab: BrowserTab) async {
            tab.prepareForRestore(url: fast)
            let selected = await site.setProxyEnabled(true, for: tab, account: account)?.value
            XCTAssertEqual(selected, true)
        }
        func start(_ tab: BrowserTab, _ url: URL) async throws -> UUID {
            tab.prepareForRestore(url: url)
            tab.onDownload?(url)
            let captured = try XCTUnwrap(browser.pendingAccessDownload)
            return try await account.startDownload(.init(urls: [url]), captured: captured, browser: browser, downloads: downloads)
        }
        let first = try XCTUnwrap(browser.activeTab)
        await authorize(first)
        let blocker = try await start(first, slow)
        try await waitUntil { downloads.items.contains { $0.id == blocker && $0.received > 0 } }

        let second = browser.newTab()
        await authorize(second)
        let cancelled = try await start(second, fast)
        let waiting = try await start(second, fast)
        downloads.cancel(cancelled)
        let closedTab = browser.newTab()
        await authorize(closedTab)
        let closed = try await start(closedTab, fast)
        site.setProxyEnabled(false, for: closedTab, account: account)

        try await Task.sleep(for: .seconds(ttl + 2))
        XCTAssertEqual(downloads.items.first { $0.id == waiting }?.state, .queued)
        downloads.cancel(blocker)
        try await waitUntil { downloads.items.contains { $0.id == waiting && [.completed, .failed].contains($0.state) } }
        try await waitUntil { downloads.items.contains { $0.id == closed && $0.state == .failed } }
        XCTAssertEqual(downloads.items.first { $0.id == waiting }?.sha256, env["AEGIS_S3_EXPECTED_SHA256"])
        XCTAssertEqual(downloads.items.first { $0.id == cancelled }?.state, .cancelled)
        XCTAssertEqual(downloads.items.first { $0.id == closed }?.received, 0)
    }

    func testSlowProtectedDownloadExtendsOnlyItsActiveLease() async throws {
        try await exerciseSlowDownload(allowRenewal: true)
    }

    func testDeniedRenewalStopsSlowProtectedDownloadAtOriginalDeadline() async throws {
        try await exerciseSlowDownload(allowRenewal: false)
    }

    private func exerciseSlowDownload(allowRenewal: Bool) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let seconds = env["AEGIS_S3_LEASE_TTL_SECONDS"], let ttl = Int(seconds) else {
            throw XCTSkip("Start the short-lease managed node fixture")
        }
        let origin = try XCTUnwrap(env[allowRenewal ? "AEGIS_S3_ORIGIN" : "AEGIS_S3_RENEW_DENIED_ORIGIN"])
        let slow = try XCTUnwrap(env["AEGIS_S3_SLOW_URL"].flatMap(URL.init(string:)))
        let sha = try XCTUnwrap(env["AEGIS_S3_SLOW_SHA256"])
        let account = AccessAccountSession(client: try AccessAccountClient(origin: origin, allowSimulatorLoopback: true),
                                           keychain: isolatedStore())
        await account.bind(accountID: try XCTUnwrap(env["AEGIS_S3_ID"]), token: try XCTUnwrap(env["AEGIS_S3_TOKEN"]))?.value
        defer { account.signOut() }
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), workspaceStore: WorkspaceStore(persistenceURL: nil))
        let tab = try XCTUnwrap(browser.activeTab)
        tab.prepareForRestore(url: slow)
        let downloads = DownloadManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                        background: false)
        defer { try? FileManager.default.removeItem(at: downloads.directory) }
        try await waitUntil { downloads.isReady }
        let started = ContinuousClock.now
        let selected = await AccessSiteProxySessionStore().setProxyEnabled(true, for: tab, account: account)?.value
        XCTAssertEqual(selected, true)
        tab.onDownload?(slow)
        let captured = try XCTUnwrap(browser.pendingAccessDownload)
        let id = try await account.startDownload(.init(urls: [slow], sha256: sha), captured: captured, browser: browser, downloads: downloads)
        try await waitUntil(timeout: .seconds(55)) {
            downloads.items.contains { $0.id == id && [.completed, .failed, .cancelled].contains($0.state) }
        }
        let item = try XCTUnwrap(downloads.items.first { $0.id == id })
        let elapsed = started.duration(to: .now)
        if allowRenewal {
            XCTAssertEqual(item.state, .completed)
            XCTAssertEqual(item.sha256, sha)
            XCTAssertGreaterThan(elapsed, .seconds(ttl * 2))
        } else {
            XCTAssertTrue([.failed, .cancelled].contains(item.state))
            XCTAssertGreaterThan(item.received, 0)
            XCTAssertNil(item.sha256)
            XCTAssertGreaterThanOrEqual(elapsed, .seconds(ttl - 1))
            XCTAssertLessThan(elapsed, .seconds(ttl + 4))
        }
    }

    func testClosingWindowRevokesLivePaidDownloadWhileDisposingWebKitTab() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let origin = env["AEGIS_S3_ORIGIN"] else { throw XCTSkip("Start the managed TLS CONNECT/Xray fixture") }
        let slow = try XCTUnwrap(env["AEGIS_S3_SLOW_URL"].flatMap(URL.init(string:)))
        let account = AccessAccountSession(client: try AccessAccountClient(origin: origin, allowSimulatorLoopback: true),
                                           keychain: isolatedStore())
        await account.bind(accountID: try XCTUnwrap(env["AEGIS_S3_ID"]), token: try XCTUnwrap(env["AEGIS_S3_TOKEN"]))?.value
        defer { account.signOut() }
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), workspaceStore: WorkspaceStore(persistenceURL: nil))
        let tab = try XCTUnwrap(browser.activeTab)
        tab.prepareForRestore(url: slow)
        let prepared = await AccessSiteProxySessionStore().setProxyEnabled(true, for: tab, account: account)?.value
        XCTAssertEqual(prepared, true)
        let downloads = DownloadManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                        background: false)
        defer { try? FileManager.default.removeItem(at: downloads.directory) }
        try await waitUntil { downloads.isReady }
        let route = try await account.downloadSession(for: tab.id, privateMode: false, target: slow, downloadDelegate: downloads)
        let transfer = try downloads.start(.init(urls: [slow]), accessSession: route)
        try await waitUntil { downloads.items.contains { $0.id == transfer && $0.received > 0 } }
        browser.closeWindow()
        XCTAssertTrue(tab.isDisposed)
        XCTAssertFalse(account.hasSelectedProxy(for: tab.id, host: try XCTUnwrap(slow.host)))
        XCTAssertThrowsError(try downloads.start(.init(urls: [slow]), accessSession: route))
        try await waitUntil { downloads.items.contains { $0.id == transfer && [.failed, .cancelled].contains($0.state) } }
    }

    private func waitUntil(timeout: Duration = .seconds(24), _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "ManagedTransferDeadline", code: 1) }
            try await Task.sleep(for: .milliseconds(40))
        }
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
