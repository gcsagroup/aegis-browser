import AccessKit
import Foundation
import Synchronization
import SwiftUI
import UIKit
import XCTest
@testable import Aegis

@MainActor
final class AccessThreeXUIWebEntryTests: XCTestCase {
    private let userID = "550e8400-e29b-41d4-a716-446655440000"

    func testAlphaListIsChannelBoundAndSelectionDoesNotExposeCredentials() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try JSONEncoder().encode([alphaWSNode(address: "first.example"), alphaWSNode(address: "second.example")])
        let nodes = alphaCatalogue(data: data, defaults: defaults)
        XCTAssertTrue(nodes.isConfigured)
        XCTAssertEqual(nodes.entries.map(\.protocolName), ["VLESS / WS / TLS", "VLESS / WS / TLS"])
        XCTAssertEqual(nodes.entries.map(\.displayName), ["1 · VLESS / WS / TLS", "2 · VLESS / WS / TLS"])
        XCTAssertFalse(nodes.entries.contains { $0.displayName.contains("example") || $0.displayName.contains(userID) })
        XCTAssertEqual(nodes.selectedIndex, 0)
        nodes.select(1)
        XCTAssertEqual(nodes.selectedIndex, 1)
        XCTAssertEqual(alphaCatalogue(data: data, defaults: defaults).selectedIndex, 1)
        let changed = try JSONEncoder().encode([alphaWSNode(address: "different.example")])
        XCTAssertEqual(alphaCatalogue(data: changed, defaults: defaults).selectedIndex, 0)
        for channel in ["dev", "beta", "release"] {
            let other = AccessAlphaNodeCatalogue(channel: channel, profile: channel, bundleID: "com.gcsa.aegis",
                                                 data: data, defaults: defaults)
            XCTAssertFalse(other.isConfigured)
            XCTAssertTrue(other.entries.isEmpty)
        }
        let wrongProfile = AccessAlphaNodeCatalogue(channel: "alpha", profile: "beta", bundleID: "com.gcsa.aegis",
                                                   data: data, defaults: defaults)
        XCTAssertTrue(wrongProfile.entries.isEmpty)
        let invalid = alphaCatalogue(data: Data("not json".utf8), defaults: defaults)
        XCTAssertTrue(invalid.isConfigured)
        XCTAssertTrue(invalid.entries.isEmpty)
        XCTAssertNil(invalid.selectedIndex)
    }

    func testAlphaCatalogueRejectsDuplicateParsedRoutes() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = alphaWSNode(address: "first.example")
        let equivalent = original.replacingOccurrences(of: "path=%2Finside", with: "path=/inside")
        let data = try JSONEncoder().encode([original + "#one", equivalent + "#two"])
        let nodes = alphaCatalogue(data: data, defaults: defaults)
        XCTAssertTrue(nodes.isConfigured)
        XCTAssertTrue(nodes.entries.isEmpty)
        XCTAssertNil(nodes.selectedIndex)
    }

    func testAlphaSelectionRoutesProductOnlyAfterQuotaAndRevokesOnChange() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try JSONEncoder().encode([alphaWSNode(address: "first.example"), alphaWSNode(address: "second.example")])
        let nodes = alphaCatalogue(data: data, defaults: defaults)
        let fixture = ThreeXUIEntryFixture(userID: userID)
        let usage = AccessSubscriptionUsageSession(isSelected: true, configuration: configuration(), managesConnections: true,
            nodeUserID: userID, fetchAlphaNodes: { config, id in try await fixture.alphaNodes(config, id: id) },
            alphaRoutes: nodes.routes, fetch: { config in try await fixture.usage(config) })
        usage.setActive(true)
        defer { usage.setActive(false) }
        let core = EntryRecordingCore()
        var retired: [String] = []
        let publisher = publisher(for: usage, core: core, alphaNodes: nodes,
                                  retireDocuments: { identity, finish in retired.append(identity); finish() })
        let operation = UUID()
        defer { publisher.cancel(operationID: operation) }
        let ready = try await publisher.prepare(.init(operationID: operation, deadline: .seconds(5)))
        XCTAssertTrue(publisher.validateReady(ready))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(core.startedConfiguration)) as? [String: Any])
        let outbound = try XCTUnwrap((document["outbounds"] as? [[String: Any]])?.first)
        let settings = try XCTUnwrap(outbound["settings"] as? [String: Any])
        let server = try XCTUnwrap((settings["vnext"] as? [[String: Any]])?.first)
        XCTAssertEqual(server["address"] as? String, "first.example")
        XCTAssertEqual(usage.snapshot?.usedBytes, 30)
        XCTAssertEqual(usage.availableConnectionCount, 2)
        XCTAssertFalse(usage.connectionsUnavailable)
        nodes.select(1)
        XCTAssertEqual(retired, [ready.endpoint.identity])
        XCTAssertFalse(publisher.validateReady(ready), "Switching nodes must revoke the old listener")
    }

    func testAlphaNodeCannotBypassMissingQuotaOrDifferentSubscriptionIdentity() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try JSONEncoder().encode([alphaWSNode(address: "first.example")])
        let nodes = alphaCatalogue(data: data, defaults: defaults)
        for mode in [ThreeXUIEntryFixture.Mode.unavailable, .exhausted, .foreignNode, .unlistedRoute] {
            let fixture = ThreeXUIEntryFixture(userID: userID, mode: mode)
            let usage = AccessSubscriptionUsageSession(isSelected: true, configuration: configuration(), managesConnections: true,
                nodeUserID: userID, fetchAlphaNodes: { config, id in try await fixture.alphaNodes(config, id: id) },
                alphaRoutes: nodes.routes, fetch: { config in try await fixture.usage(config) })
            usage.setActive(true)
            let core = EntryRecordingCore()
            let publisher = publisher(for: usage, core: core, alphaNodes: nodes)
            do { _ = try await publisher.prepare(.init(operationID: UUID(), deadline: .seconds(5))); XCTFail("Quota rejection must not start Alpha nodes") }
            catch { }
            XCTAssertNil(core.startedConfiguration)
            usage.setActive(false)
        }
        let otherIdentity = try JSONEncoder().encode([alphaWSNode(address: "first.example")
            .replacingOccurrences(of: userID, with: "550e8400-e29b-41d4-a716-446655440001")])
        let differentNodes = alphaCatalogue(data: otherIdentity, defaults: defaults)
        let fixture = ThreeXUIEntryFixture(userID: userID)
        let usage = AccessSubscriptionUsageSession(isSelected: true, configuration: configuration(), managesConnections: true,
            nodeUserID: userID, fetchAlphaNodes: { config, id in try await fixture.alphaNodes(config, id: id) },
            alphaRoutes: differentNodes.routes, fetch: { config in try await fixture.usage(config) })
        usage.setActive(true)
        defer { usage.setActive(false) }
        let core = EntryRecordingCore()
        let publisher = publisher(for: usage, core: core, alphaNodes: differentNodes)
        do { _ = try await publisher.prepare(.init(operationID: UUID(), deadline: .seconds(5))); XCTFail("Foreign Alpha node authorized") }
        catch { }
        XCTAssertNil(core.startedConfiguration)
    }

    func testAlphaConnectionCountOnlyIncludesBundledRoutesTheSubscriptionPublishes() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try JSONEncoder().encode([alphaWSNode(address: "first.example"), alphaWSNode(address: "absent.example")])
        let nodes = alphaCatalogue(data: data, defaults: defaults)
        for (mode, expected) in [(ThreeXUIEntryFixture.Mode.allowed, 1), (.unlistedRoute, 0)] {
            let fixture = ThreeXUIEntryFixture(userID: userID, mode: mode)
            let usage = AccessSubscriptionUsageSession(isSelected: true, configuration: configuration(), managesConnections: true,
                nodeUserID: userID, fetchAlphaNodes: { config, id in try await fixture.alphaNodes(config, id: id) },
                alphaRoutes: nodes.routes, fetch: { config in try await fixture.usage(config) })
            usage.setActive(true)
            await usage.refresh()?.value
            XCTAssertEqual(usage.availableConnectionCount, expected, "\(mode)")
            XCTAssertEqual(usage.connectionsUnavailable, expected == 0, "\(mode)")
            XCTAssertEqual(usage.availableAlphaRouteIDs, expected == 0 ? [] : [0], "\(mode)")
            usage.setActive(false)
        }
    }

    func testExpiredAllowanceCannotShowOrSaveAnEnabledAlphaRoute() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try JSONEncoder().encode([alphaWSNode(address: "first.example"), alphaWSNode(address: "second.example")])
        let nodes = alphaCatalogue(data: data, defaults: defaults)
        let fixture = ThreeXUIEntryFixture(userID: userID)
        await fixture.setExpire(UInt64(Date.now.timeIntervalSince1970) + 2)
        let usage = AccessSubscriptionUsageSession(isSelected: true, configuration: configuration(), managesConnections: true,
            nodeUserID: userID, fetchAlphaNodes: { config, id in try await fixture.alphaNodes(config, id: id) },
            alphaRoutes: nodes.routes, fetch: { config in try await fixture.usage(config) })
        usage.setActive(true)
        defer { usage.setActive(false) }
        await usage.refresh()?.value
        XCTAssertTrue(usage.isAlphaRouteSelectable(1))
        let deadline = Date.now.addingTimeInterval(6)
        while usage.isAlphaRouteSelectable(1), Date.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(usage.snapshot?.permitsConnection ?? true)
        XCTAssertFalse(usage.isAlphaRouteSelectable(0))
        XCTAssertFalse(usage.isAlphaRouteSelectable(1))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(usage.availableAlphaRouteIDs, [], "Known expiry must refresh the published route list")
        XCTAssertEqual(usage.availableConnectionCount, 0)
        XCTAssertFalse(usage.permitsExistingConnection)
        let core = EntryRecordingCore()
        let publisher = publisher(for: usage, core: core, alphaNodes: nodes)
        do { _ = try await publisher.prepare(.init(operationID: UUID(), deadline: .seconds(5))); XCTFail("Expired allowance started an Alpha route") }
        catch { }
        XCTAssertNil(core.startedConfiguration)
    }

    private func alphaWSNode(address: String) -> String {
        "vless://\(userID)@\(address):443?security=tls&type=ws&host=ws.example.com&sni=cert.example.com&path=%2Finside&encryption=none"
    }

    private func alphaCatalogue(data: Data, defaults: UserDefaults) -> AccessAlphaNodeCatalogue {
        AccessAlphaNodeCatalogue(channel: "alpha", profile: "alpha", bundleID: "com.gcsa.aegis", data: data, defaults: defaults)
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "test.alpha.nodes." + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testUnselectedOrReadOnlyUsageCannotBuildAnUnmeteredWebEntry() async throws {
        for (selected, manages) in [(false, false), (false, true), (true, false)] {
            let usage = AccessSubscriptionUsageSession(isSelected: selected, configuration: configuration(), managesConnections: manages)
            let core = EntryRecordingCore()
            let publisher = publisher(for: usage, core: core)
            XCTAssertTrue(publisher is AccessFailClosedProxyEntryPublisher)
            do { _ = try await publisher.prepare(.init(operationID: UUID(), deadline: .seconds(5))); XCTFail("Unconfigured entry became ready") }
            catch { }
            XCTAssertFalse(core.isRunning)
            XCTAssertNil(core.startedConfiguration)
        }
    }

    func testProductEntryLoadsNodeAndVisibleCountersFromTheSameSubscription() async throws {
        let client = ThreeXUIEntryFixture(userID: userID)
        let usage = AccessSubscriptionUsageSession(isSelected: true, configuration: configuration(), managesConnections: true,
            nodeUserID: userID, fetchNodes: { config, id in try await client.nodes(config, id: id) },
            fetch: { config in try await client.usage(config) })
        usage.setActive(true)
        defer { usage.setActive(false) }
        let core = EntryRecordingCore()
        let publisher = publisher(for: usage, core: core)
        let operation = UUID()
        defer { publisher.cancel(operationID: operation) }
        let ready = try await publisher.prepare(.init(operationID: operation, deadline: .seconds(5)))
        XCTAssertTrue(publisher.validateReady(ready))
        XCTAssertTrue(usage.permitsExistingConnection)
        XCTAssertEqual(usage.snapshot?.usedBytes, 30)
        XCTAssertEqual(usage.snapshot?.remainingBytes, 9_999_970)
        let config = try XCTUnwrap(core.startedConfiguration)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: config) as? [String: Any])
        let outbound = try XCTUnwrap((document["outbounds"] as? [[String: Any]])?.first)
        let settings = try XCTUnwrap(outbound["settings"] as? [String: Any])
        let server = try XCTUnwrap((settings["vnext"] as? [[String: Any]])?.first)
        let user = try XCTUnwrap((server["users"] as? [[String: Any]])?.first)
        XCTAssertEqual(user["id"] as? String, userID)
        XCTAssertEqual(server["address"] as? String, "fixture-node.invalid")
        let sources = await client.observedSources
        XCTAssertFalse(sources.isEmpty)
        XCTAssertEqual(Set(sources), [configuration().subscriptionInfoURL.absoluteString])
    }

    func testQuotaFailureExhaustionAndForeignNodesCannotStartAStaticFallback() async throws {
        for mode in [ThreeXUIEntryFixture.Mode.unavailable, .exhausted, .foreignNode] {
            let fixture = ThreeXUIEntryFixture(userID: userID, mode: mode)
            let usage = AccessSubscriptionUsageSession(isSelected: true, configuration: configuration(), managesConnections: true,
                nodeUserID: userID, fetchNodes: { config, id in try await fixture.nodes(config, id: id) },
                fetch: { config in try await fixture.usage(config) })
            usage.setActive(true)
            let core = EntryRecordingCore()
            let publisher = publisher(for: usage, core: core)
            let operation = UUID()
            do { _ = try await publisher.prepare(.init(operationID: operation, deadline: .seconds(5))); XCTFail("Rejected 3X-UI state authorized a webpage") }
            catch { }
            XCTAssertFalse(core.isRunning)
            XCTAssertNil(core.startedConfiguration)
            XCTAssertNil(publisher.currentEndpoint)
            publisher.cancel(operationID: operation)
            usage.setActive(false)
        }
    }

    func testReadyProductEntryIsRejectedAfterSubscriptionExhaustion() async throws {
        let fixture = ThreeXUIEntryFixture(userID: userID)
        let usage = AccessSubscriptionUsageSession(isSelected: true, configuration: configuration(), managesConnections: true,
            nodeUserID: userID, fetchNodes: { config, id in try await fixture.nodes(config, id: id) },
            fetch: { config in try await fixture.usage(config) })
        usage.setActive(true)
        defer { usage.setActive(false) }
        let core = EntryRecordingCore()
        let publisher = publisher(for: usage, core: core)
        let operation = UUID()
        defer { publisher.cancel(operationID: operation) }
        let ready = try await publisher.prepare(.init(operationID: operation, deadline: .seconds(5)))
        XCTAssertTrue(publisher.validateReady(ready))
        XCTAssertTrue(core.isRunning)

        await fixture.setMode(.exhausted)
        await usage.refresh()?.value
        XCTAssertEqual(usage.snapshot?.remainingBytes, 0)
        XCTAssertFalse(usage.permitsExistingConnection)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while publisher.validateReady(ready), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(publisher.validateReady(ready), "An exhausted subscription must revoke the existing ready entry")
    }

    func testUnconfiguredUsagePageRendersWithoutAnAccountBackendEnvironment() async throws {
        let usage = AccessSubscriptionUsageSession(isSelected: false, configuration: nil)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        // Deliberately do not supply AccessAccountSession: a fallback to the
        // future account UI would require that environment and fail rendering.
        let host = UIHostingController(rootView: NavigationStack { AccessUsagePage(isPrivate: false) }
            .environmentObject(usage).environment(\.locale, Locale(identifier: "zh-Hans")))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(usage.snapshot)
        XCTAssertFalse(usage.isRefreshing)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "3X-UI未配置-无账户后端回退"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func publisher(for usage: AccessSubscriptionUsageSession, core: EntryRecordingCore,
                           alphaNodes: AccessAlphaNodeCatalogue? = nil,
                           retireDocuments: @escaping @MainActor (String, @escaping @MainActor () -> Void) -> Void = { _, finish in finish() }
    ) -> any AccessProxyEntryPublishing {
        let lock = Data(#"{"status":"verified_build","xrayCore":{"commit":"676eaf66f8f05d4d558ee7a74b4736623d3feeb9","tag":"v26.11.9"},"artifacts":{"iosArm64Sha256":"aa","iosArm64SimulatorSha256":"bb"}}"#.utf8)
        return AccessThreeXUIWebEntry.makePublisher(for: usage, alphaNodes: alphaNodes, lockData: lock, verifiedCore: core,
                                               retireDocuments: retireDocuments)
    }

    private func configuration() -> AccessSubscriptionConfiguration {
        .init(subscriptionInfoURL: URL(string: "https://subscription.example.invalid/sub/fixture?format=info")!,
              allowedTestClient: "fixture", expectedQuotaBytes: 10_000_000, trafficReset: "never", nodeSHA256: String(repeating: "0", count: 64))
    }
}

private actor ThreeXUIEntryFixture {
    enum Mode { case allowed, unavailable, exhausted, foreignNode, unlistedRoute }
    let userID: String
    private var mode: Mode
    private var expire: UInt64 = 0
    private(set) var observedSources: [String] = []
    init(userID: String, mode: Mode = .allowed) { self.userID = userID; self.mode = mode }
    func setMode(_ mode: Mode) { self.mode = mode }
    func setExpire(_ value: UInt64) { expire = value }
    func usage(_ configuration: AccessSubscriptionConfiguration) throws -> AccessSubscriptionUsage {
        observedSources.append(configuration.subscriptionInfoURL.absoluteString)
        if mode == .unavailable { throw AccessSubscriptionQueryError.unavailable }
        return .init(sId: "fixture", emails: ["fixture"], uploadByte: mode == .exhausted ? 10_000_000 : 10,
                     downloadByte: mode == .exhausted ? 0 : 20, totalByte: 10_000_000, expire: expire, enabled: true)
    }
    func nodes(_ configuration: AccessSubscriptionConfiguration, id: String) throws -> [AccessRealityVisionParameters] {
        observedSources.append(configuration.subscriptionInfoURL.absoluteString)
        guard id == userID else { throw AccessSubscriptionQueryError.invalid }
        return [try .init(address: "fixture-node.invalid", port: 443,
            userID: mode == .foreignNode ? "550e8400-e29b-41d4-a716-446655440001" : userID,
            serverName: "www.example.com", publicKey: "fixture-key", shortID: "")]
    }
    func alphaNodes(_ configuration: AccessSubscriptionConfiguration, id: String) throws -> [AccessInternalTestNode] {
        observedSources.append(configuration.subscriptionInfoURL.absoluteString)
        let identity = mode == .foreignNode ? "550e8400-e29b-41d4-a716-446655440001" : userID
        let addresses = mode == .unlistedRoute ? ["unlisted.example"] : ["first.example", "second.example"]
        let shares = addresses.map {
            "vless://\(identity)@\($0):443?security=tls&type=ws&host=ws.example.com&sni=cert.example.com&path=%2Finside&encryption=none"
        }.joined(separator: "\n")
        return try AccessSubscriptionClient.parseAlphaNodes(Data(shares.utf8).base64EncodedData(), userID: id)
    }
}

private final class EntryRecordingCore: AccessEmbeddedCoreControlling, Sendable {
    private struct State { var running = false; var configuration: Data? }
    private let state = Mutex(State())
    var isRunning: Bool { state.withLock { $0.running } }
    var startedConfiguration: Data? { state.withLock { $0.configuration } }
    func start(configData: Data) async throws { state.withLock { $0.configuration = configData; $0.running = true } }
    func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream { AccessMemoryRealityStream() }
    func stop() async { state.withLock { $0.running = false } }
}
