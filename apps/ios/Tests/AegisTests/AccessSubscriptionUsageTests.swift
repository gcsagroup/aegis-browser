import AccessKit
import CryptoKit
import Foundation
import Synchronization
import SwiftUI
import UIKit
import XCTest
@testable import Aegis

private let subscriptionFixtureNode = Data("vless://fixture@example.invalid:443".utf8)
private func subscriptionConfiguration(url: String = "https://example.invalid/sub/fixture?format=info") -> AccessSubscriptionConfiguration {
    AccessSubscriptionConfiguration(subscriptionInfoURL: URL(string: url)!, allowedTestClient: "fixture",
        expectedQuotaBytes: 10_000_000_000, trafficReset: "daily",
        nodeSHA256: SHA256.hash(data: subscriptionFixtureNode).map { String(format: "%02x", $0) }.joined())
}
private func subscriptionUsage(upload: UInt64 = 10, download: UInt64 = 20) -> AccessSubscriptionUsage {
    .init(sId: "fixture", emails: ["fixture"], uploadByte: upload, downloadByte: download,
          totalByte: 10_000_000_000, expire: 0, enabled: true)
}

@MainActor
final class AccessSubscriptionUsageTests: XCTestCase {
    func testSharedUsagePageRendersCountersAndKeepsPrivateSessionIsolated() async throws {
        let preferences = AegisLanguagePreferenceStore.runtime
        let previousChoice = preferences.choice
        preferences.setFamily(.simplifiedChinese)
        defer { preferences.setChoice(previousChoice) }
        let session = AccessSubscriptionUsageSession(isSelected: true, configuration: subscriptionConfiguration(),
            fetch: { _ in subscriptionUsage(upload: 750_000_000, download: 2_250_000_000) })
        session.setActive(true)
        await session.refresh()?.value
        XCTAssertEqual(session.snapshot?.usedBytes, 3_000_000_000)
        let account = AccessAccountSession.product()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        defer { window.isHidden = true; previous?.makeKeyAndVisible(); session.setActive(false) }
        for dark in [false, true] {
            let view = NavigationStack { AccessUsagePage(isPrivate: false) }
                .environmentObject(account).environmentObject(session)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
                .preferredColorScheme(dark ? .dark : .light)
                .tint(Color(red: 0.09, green: 0.47, blue: 0.37))
            let host = UIHostingController(rootView: view)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = dark ? "共享测试用量-深色-固定数据" : "共享测试用量-浅色-固定数据"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let privateSession = AccessSubscriptionUsageSession(isSelected: true, configuration: subscriptionConfiguration(),
            fetch: { _ in throw AccessSubscriptionQueryError.invalid })
        var refreshRequests = 0
        privateSession.usageRefresh = AccessAccountUsageRefreshCoordinator(refresh: {
            refreshRequests += 1
            return nil
        })
        privateSession.setActive(true)
        // The app-wide schedule polls once on activation even with no visible owner.
        let activationRequests = refreshRequests
        XCTAssertEqual(activationRequests, 1)
        let privateHost = UIHostingController(rootView: NavigationStack { AccessUsagePage(isPrivate: true) }
            .environmentObject(account).environmentObject(privateSession)
            .environment(\.scenePhase, .active))
        window.rootViewController = privateHost
        privateHost.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(privateSession.snapshot)
        XCTAssertEqual(refreshRequests, activationRequests,
                       "Opening the private page must not add a visible ordinary-usage observer")
        privateSession.setActive(false)
    }

    func testBetaSelectsBundledNodeQuotaWhileReleaseRejectsIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for channel in ["alpha", "beta", "release", "prod", ""] {
            let directory = root.appendingPathComponent(UUID().uuidString + ".bundle")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try subscriptionFixtureNode.write(to: directory.appendingPathComponent("AegisPrivateTestNode.vless"))
            let config = subscriptionConfiguration()
            let descriptor: [String: Any] = ["subscriptionInfoURL": config.subscriptionInfoURL.absoluteString,
                "allowedTestClient": config.allowedTestClient, "expectedQuotaBytes": config.expectedQuotaBytes,
                "trafficReset": config.trafficReset, "nodeSHA256": config.nodeSHA256]
            try JSONSerialization.data(withJSONObject: descriptor).write(to: directory.appendingPathComponent("AegisPrivateTestSubscription.json"))
            let info = ["CFBundleIdentifier": "fixture." + UUID().uuidString, "AegisAccessReleaseChannel": channel]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: directory.appendingPathComponent("Info.plist"))
            let session = AccessSubscriptionUsageSession.product(bundle: try XCTUnwrap(Bundle(url: directory)))
            XCTAssertEqual(session.isSelected, ["alpha", "beta"].contains(channel))
        }
    }

    func testIdentityExactCountersResetAndMalformedResponses() throws {
        let configuration = subscriptionConfiguration()
        try configuration.validate(node: subscriptionFixtureNode)
        let initial = subscriptionUsage(upload: 2_000_000_000, download: 7_000_000_000)
        try initial.validate(for: configuration)
        XCTAssertEqual(initial.usedBytes, 9_000_000_000)
        XCTAssertEqual(initial.remainingBytes, 1_000_000_000)
        let reset = subscriptionUsage(upload: 0, download: 0)
        try reset.validate(for: configuration)
        XCTAssertEqual(reset.remainingBytes, 10_000_000_000, "server reset is a new snapshot, never a negative delta")
        let over = subscriptionUsage(upload: 9_000_000_000, download: 2_000_000_000)
        try over.validate(for: configuration)
        XCTAssertEqual(over.remainingBytes, 0)
        XCTAssertThrowsError(try subscriptionUsage(upload: .max, download: 1).validate(for: configuration))
        for variant in 0..<5 {
            let value = AccessSubscriptionUsage(sId: variant == 0 ? "other" : "fixture",
                emails: variant == 1 ? ["fixture", "other"] : ["fixture"], uploadByte: 0, downloadByte: 0,
                totalByte: variant == 2 ? 0 : variant == 3 ? 1 : 10_000_000_000,
                expire: variant == 4 ? .max : 0, enabled: true)
            XCTAssertThrowsError(try value.validate(for: configuration))
        }
        for raw in ["{}", "{\"uploadByte\":-1}", "{\"uploadByte\":18446744073709551616}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(AccessSubscriptionUsage.self, from: Data(raw.utf8)))
        }
    }

    func testDedicatedFiniteQuotaBindingAndRevocation() throws {
        let reference = subscriptionConfiguration()
        let configuration = AccessSubscriptionConfiguration(subscriptionInfoURL: reference.subscriptionInfoURL,
            allowedTestClient: "fixture", expectedQuotaBytes: 10_000_000, trafficReset: "never",
            nodeSHA256: reference.nodeSHA256)
        try configuration.validate(node: subscriptionFixtureNode)
        for (upload, enabled, expiry, permitted) in [(UInt64(0), true, UInt64(0), true),
                (10_000_000, true, 0, false), (0, false, 0, false), (0, true, 1, false)] {
            let usage = AccessSubscriptionUsage(sId: "fixture", emails: ["fixture"], uploadByte: upload,
                downloadByte: 0, totalByte: 10_000_000, expire: expiry, enabled: enabled)
            try usage.validate(for: configuration)
            XCTAssertEqual(usage.permitsConnection, permitted)
        }
        XCTAssertThrowsError(try subscriptionUsage().validate(for: configuration),
                             "A shared-account quota must not be accepted for the dedicated account")
        for (quota, reset) in [(UInt64(0), "never"), (UInt64.max, "never"), (10_000_000, "unknown")] {
            let invalid = AccessSubscriptionConfiguration(subscriptionInfoURL: reference.subscriptionInfoURL,
                allowedTestClient: "fixture", expectedQuotaBytes: quota, trafficReset: reset,
                nodeSHA256: reference.nodeSHA256)
            XCTAssertThrowsError(try invalid.validateEndpoint())
        }
    }

    func testEndpointAndEmbeddedNodeBinding() throws {
        XCTAssertThrowsError(try subscriptionConfiguration().validate(node: Data("different node".utf8)))
        for url in ["http://example.invalid/sub/fixture?format=info", "https://user:pass@example.invalid/sub/fixture?format=info",
                    "https://example.invalid/sub/fixture", "https://example.invalid/sub/fixture?format=info&token=x",
                    "https://example.invalid/sub/fixture?format=info#fragment"] {
            XCTAssertThrowsError(try subscriptionConfiguration(url: url).validate(node: subscriptionFixtureNode))
        }
    }

    func testBackgroundCancellationSingleFlightAndLateResponseIsolation() async throws {
        let gate = SubscriptionFetchGate()
        let session = AccessSubscriptionUsageSession(isSelected: true, configuration: subscriptionConfiguration()) { _ in
            await gate.read()
        }
        session.setActive(true)
        for _ in 0..<10 { session.refresh() }
        await waitUntil { await gate.count == 1 }
        let firstCount = await gate.count
        XCTAssertEqual(firstCount, 1)
        session.setActive(false)
        session.setActive(true)
        await waitUntil { await gate.count == 2 }
        await gate.finish(subscriptionUsage(upload: 111))
        await Task.yield()
        XCTAssertNil(session.snapshot, "cancelled old request cannot populate current state")
        await gate.finish(subscriptionUsage(upload: 222))
        await waitUntil { await MainActor.run { session.snapshot != nil } }
        XCTAssertEqual(session.snapshot?.uploadByte, 222)
        XCTAssertFalse(session.isRefreshing)
        session.setActive(false)
    }

    func testHTTPSInfoRequestAndHTTPFailureDoNotBecomeZeroQuota() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubscriptionProtocol.self]
        SubscriptionProtocol.state.withLock { $0 = .init(status: 200, bytes: Data("{\"sId\":\"fixture\",\"emails\":[\"fixture\"],\"uploadByte\":123,\"downloadByte\":456,\"totalByte\":10000000000,\"expire\":0,\"enabled\":true,\"subUrl\":\"private-ignored\"}".utf8)) }
        let result = try await AccessSubscriptionClient.read(subscriptionConfiguration(), sessionConfiguration: configuration)
        XCTAssertEqual(result.usedBytes, 579)
        let request = SubscriptionProtocol.state.withLock { $0.request }
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        for status in [301, 401, 404, 503] {
            SubscriptionProtocol.state.withLock { $0.status = status }
            do {
                _ = try await AccessSubscriptionClient.read(subscriptionConfiguration(), sessionConfiguration: configuration)
                XCTFail("HTTP failure must not become a quota snapshot")
            } catch { }
        }
        SubscriptionProtocol.state.withLock { $0.status = 200; $0.bytes = Data(repeating: 32, count: 65_537) }
        do {
            _ = try await AccessSubscriptionClient.read(subscriptionConfiguration(), sessionConfiguration: configuration)
            XCTFail("oversized body accepted")
        } catch { }
    }

    func testAccountNodesParsePlainAndBase64AndRejectAnotherIdentity() throws {
        let id = "550e8400-e29b-41d4-a716-446655440000"
        let node = "vless://\(id)@node.invalid:443?security=reality&type=tcp&flow=xtls-rprx-vision&sni=www.example.com&pbk=fixture-key&sid=abcd"
        let document = Data("socks://ignored.invalid:1080\n\(node)\n\(node)".utf8)
        let plain = try AccessSubscriptionClient.parseNodes(document, userID: id)
        XCTAssertEqual(plain.count, 1)
        XCTAssertEqual(plain.first?.address, "node.invalid")
        let encoded = Data((document.base64EncodedString() + "\n").utf8)
        XCTAssertEqual(try AccessSubscriptionClient.parseNodes(encoded, userID: id), plain)
        for data in [Data(), Data("socks://ignored.invalid:1080".utf8), Data(node.replacingOccurrences(of: "security=reality", with: "security=tls").utf8),
                     Data(repeating: 32, count: 65_537), Data(Array(repeating: node, count: 129).joined(separator: "\n").utf8)] {
            XCTAssertThrowsError(try AccessSubscriptionClient.parseNodes(data, userID: id))
        }
        XCTAssertThrowsError(try AccessSubscriptionClient.parseNodes(document, userID: UUID().uuidString))
    }

    func testAccountNodesUsePinnedSubscriptionURLAndNeverResponseLinks() async throws {
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [SubscriptionProtocol.self]
        let id = "550e8400-e29b-41d4-a716-446655440000"
        let node = "vless://\(id)@node.invalid:443?security=reality&sni=www.example.com&pbk=fixture-key&sid="
        SubscriptionProtocol.state.withLock { $0 = .init(status: 200, bytes: Data(node.utf8)) }
        let nodes = try await AccessSubscriptionClient.nodes(subscriptionConfiguration(), userID: id, sessionConfiguration: settings)
        XCTAssertEqual(nodes.count, 1)
        let request = SubscriptionProtocol.state.withLock { $0.request }
        XCTAssertEqual(request?.url?.absoluteString, "https://example.invalid/sub/fixture")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept"), "text/plain")
        for status in [301, 401, 503] {
            SubscriptionProtocol.state.withLock { $0.status = status }
            do {
                _ = try await AccessSubscriptionClient.nodes(subscriptionConfiguration(), userID: id, sessionConfiguration: settings)
                XCTFail("Failed account subscription must not supply nodes")
            } catch { }
        }
    }

    func testAccountResolvesCurrentNodesAndClearsThemAfterFailureOrExhaustion() async throws {
        let fixture = SubscriptionAccountFixture()
        let id = "550e8400-e29b-41d4-a716-446655440000"
        let session = AccessSubscriptionUsageSession(isSelected: true, configuration: subscriptionConfiguration(),
            managesConnections: true, nodeUserID: id,
            fetchNodes: { _, _ in try await fixture.nodes() }, fetch: { _ in try await fixture.usage() })
        session.setActive(true)
        let node = try await session.connectionParameters()
        XCTAssertEqual(node.userID, id)
        XCTAssertEqual(session.availableConnectionCount, 1)
        XCTAssertTrue(session.permitsExistingConnection)
        await fixture.setMode(4)
        await session.refresh()?.value
        XCTAssertEqual(session.availableConnectionCount, 1)
        XCTAssertFalse(session.permitsExistingConnection, "A removed node must not keep its old connection authorized")
        await fixture.setMode(1)
        await session.refresh()?.value
        XCTAssertEqual(session.snapshot?.usedBytes, 30, "Node outage must retain real account counters")
        XCTAssertTrue(session.connectionsUnavailable)
        XCTAssertEqual(session.availableConnectionCount, 0)
        do { _ = try await session.connectionParameters(); XCTFail("Stale node reused") } catch { }
        await fixture.setMode(2)
        await session.refresh()?.value
        XCTAssertEqual(session.snapshot?.remainingBytes, 0)
        XCTAssertFalse(session.permitsExistingConnection)
        do { _ = try await session.connectionParameters(); XCTFail("Exhausted account connected") } catch { }
        await fixture.setMode(3)
        await session.refresh()?.value
        XCTAssertTrue(session.unavailable)
        XCTAssertEqual(session.snapshot?.remainingBytes, 0, "Outage preserves the last known reading")
        XCTAssertEqual(session.availableConnectionCount, 0)
        session.setActive(false)
        do { _ = try await session.connectionParameters(); XCTFail("Inactive session connected") } catch { }
    }

    func testTransientInactivityKeepsRetainedEndpointReadyOnResume() async throws {
        let fixture = SubscriptionAccountFixture()
        let session = AccessSubscriptionUsageSession(isSelected: true, configuration: subscriptionConfiguration(),
            managesConnections: true, nodeUserID: "550e8400-e29b-41d4-a716-446655440000",
            fetchNodes: { _, _ in try await fixture.nodes() }, fetch: { _ in try await fixture.usage() })
        session.setActive(true)
        _ = try await session.connectionParameters()
        let publisher = AccessProxyEntryPublisher(provision: { generation, _ in
            .init(endpoint: .init(identity: "inactivity-test", generation: generation, loopbackHost: "127.0.0.1", port: 18080, state: .ready),
                listenerReady: true, runtimeHealthy: true, bridgeInstalled: true)
        }, healthCheck: { session.permitsExistingConnection })
        let operation = UUID()
        let ready = try await publisher.prepare(.init(operationID: operation, deadline: .seconds(5)))
        let key = AccessHostStoreKey(scopeID: "regular", host: try AccessSiteHost("site.invalid"), isPrivate: false)
        XCTAssertTrue(publisher.retain(ready.endpoint, for: key))
        publisher.cancel(operationID: operation)
        session.setActive(false)
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertTrue(session.permitsExistingConnection)
        XCTAssertEqual(publisher.currentEndpoint, ready.endpoint)
        session.setActive(true)
        await session.refresh()?.value
        XCTAssertTrue(session.permitsExistingConnection)
        XCTAssertEqual(publisher.currentEndpoint, ready.endpoint)
        publisher.release(for: key)
        session.setActive(false)
    }

    func testCancelledAuthorizationCannotReuseOldNodesAfterReactivation() async throws {
        let reads = SubscriptionFetchGate()
        let fixture = SubscriptionAccountFixture()
        let session = AccessSubscriptionUsageSession(isSelected: true, configuration: subscriptionConfiguration(),
            managesConnections: true, nodeUserID: "550e8400-e29b-41d4-a716-446655440000",
            fetchNodes: { _, _ in try await fixture.nodes() }, fetch: { _ in await reads.read() })
        session.setActive(true)
        let initial = session.refresh()
        await waitUntil { await reads.count == 1 }
        await reads.finish(subscriptionUsage())
        await initial?.value
        XCTAssertEqual(session.availableConnectionCount, 1)
        let authorization = Task { try await session.connectionParameters() }
        await waitUntil { await reads.count == 2 }
        session.setActive(false)
        session.setActive(true)
        let current = session.refresh()
        await waitUntil { await reads.count == 3 }
        // The cancelled old request delivers while the replacement is still pending.
        await reads.finish(subscriptionUsage(upload: 111))
        do { _ = try await authorization.value; XCTFail("Cancelled query reused a prior valid node list") } catch { }
        XCTAssertEqual(session.snapshot?.uploadByte, 10)
        await reads.finish(subscriptionUsage(upload: 222))
        await current?.value
        XCTAssertEqual(session.snapshot?.uploadByte, 222)
        session.setActive(false)
    }

    func testDisabledAndExpiredSubscriptionsCannotAuthorizeConnection() {
        for value in [AccessSubscriptionUsage(sId: "fixture", emails: ["fixture"], uploadByte: 0, downloadByte: 0,
                        totalByte: 10_000_000_000, expire: 0, enabled: false),
                      AccessSubscriptionUsage(sId: "fixture", emails: ["fixture"], uploadByte: 0, downloadByte: 0,
                        totalByte: 10_000_000_000, expire: 1, enabled: true)] {
            XCTAssertFalse(value.permitsConnection)
        }
    }

    /// Opt-in, bounded read-only subscription query plus a small real-core HTTP request.
    /// Shared counters are observed; an increase alone cannot attribute traffic to this device.
    func testAuthorizedSharedAccountFetchesNodesAndDrivesRealCore() async throws {
        guard ProcessInfo.processInfo.environment["AEGIS_TEST_ACCOUNT_LIVE"] == "1" else {
            throw XCTSkip("Requires the explicitly selected private shared test account")
        }
        let preferences = AegisLanguagePreferenceStore.runtime
        let previousChoice = preferences.choice
        preferences.setFamily(.simplifiedChinese)
        defer { preferences.setChoice(previousChoice) }
        let session = AccessSubscriptionUsageSession.product()
        XCTAssertTrue(session.managesConnections)
        session.setActive(true)
        defer { session.setActive(false) }
        let expectedState = ProcessInfo.processInfo.environment["AEGIS_TEST_ACCOUNT_STATUS"] ?? "allowed"
        XCTAssertTrue(["allowed", "disabled", "expired", "exhausted"].contains(expectedState))
        if expectedState != "allowed" {
            await session.refresh()?.value
            let usage = try XCTUnwrap(session.snapshot)
            switch expectedState {
            case "disabled": XCTAssertFalse(usage.enabled)
            case "expired":
                XCTAssertGreaterThan(usage.expire, 0)
                XCTAssertLessThanOrEqual(TimeInterval(usage.expire), Date.now.timeIntervalSince1970)
            case "exhausted": XCTAssertEqual(usage.remainingBytes, 0)
            default: XCTFail("Unknown live acceptance state")
            }
            XCTAssertFalse(session.permitsExistingConnection)
            do {
                _ = try await session.connectionParameters()
                XCTFail("The current server status must prevent a new connection")
            } catch { /* The actual subscription must deny this connection. */ }
            return
        }
        let core = try AccessGoEmbeddedCore()
        let publisher = AccessEmbeddedProxyEntryFactory.makeProductPublisher(verifiedCore: core, parameters: {
            try await session.connectionParameters()
        }, connectionAllowed: { session.permitsExistingConnection })
        let operation = UUID()
        do {
            let result = try await publisher.prepare(.init(operationID: operation, deadline: .seconds(45)))
            XCTAssertTrue(publisher.validateReady(result))
            XCTAssertGreaterThan(session.availableConnectionCount, 0)
            let usage = try XCTUnwrap(session.snapshot)
            let descriptorURL = try XCTUnwrap(Bundle.main.url(forResource: "AegisPrivateTestSubscription", withExtension: "json"))
            let descriptor = try JSONDecoder().decode(AccessSubscriptionConfiguration.self, from: Data(contentsOf: descriptorURL))
            XCTAssertEqual(usage.totalByte, descriptor.expectedQuotaBytes)
            XCTAssertEqual(usage.emails, [descriptor.allowedTestClient])
            XCTAssertEqual(usage.usedBytes, usage.uploadByte + usage.downloadByte)
            let watchdog = Task {
                try await Task.sleep(for: .seconds(25))
                await core.stop()
            }
            defer { watchdog.cancel() }
            let stream = try await core.dial(host: "example.com", port: 80)
            defer { stream.close() }
            try await stream.write(Data("HEAD / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n".utf8))
            let response = try await stream.read(maxBytes: 4096)
            XCTAssertTrue(response?.starts(with: Data("HTTP/1.".utf8)) == true)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let previous = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            defer { window.isHidden = true; previous?.makeKeyAndVisible() }
            let view = NavigationStack { AccessUsagePage(isPrivate: false) }
                .environmentObject(AccessAccountSession.product()).environmentObject(session)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
            let host = UIHostingController(rootView: view)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "共享测试账号-实时订阅与额度"
            attachment.lifetime = .keepAlways
            add(attachment)
            publisher.cancel(operationID: operation)
            await core.stop()
        } catch {
            publisher.cancel(operationID: operation)
            await core.stop()
            XCTFail("Shared test account connection or quota read failed; private details withheld")
        }
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
        for _ in 0..<100 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition did not settle")
    }
}

private actor SubscriptionFetchGate {
    var count = 0
    private var pending: [CheckedContinuation<AccessSubscriptionUsage, Never>] = []
    func read() async -> AccessSubscriptionUsage {
        count += 1
        return await withCheckedContinuation { pending.append($0) }
    }
    func finish(_ value: AccessSubscriptionUsage) { pending.removeFirst().resume(returning: value) }
}

private final class SubscriptionProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable { var status: Int; var bytes: Data; var request: URLRequest? }
    static let state = Mutex(State(status: 200, bytes: Data()))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.state.withLock { state in state.request = request; return state }
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private actor SubscriptionAccountFixture {
    private var mode = 0
    func setMode(_ value: Int) { mode = value }
    func usage() throws -> AccessSubscriptionUsage {
        if mode == 3 { throw AccessSubscriptionQueryError.unavailable }
        return subscriptionUsage(upload: mode == 2 ? 10_000_000_000 : 10, download: mode == 2 ? 0 : 20)
    }
    func nodes() throws -> [AccessRealityVisionParameters] {
        if mode == 1 { throw AccessSubscriptionQueryError.unavailable }
        return [try AccessRealityVisionParameters(address: mode == 4 ? "replacement.invalid" : "node.invalid", port: 443,
            userID: "550e8400-e29b-41d4-a716-446655440000", serverName: "www.example.com", publicKey: "fixture-key", shortID: "")]
    }
}
