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

    private func publisher(for usage: AccessSubscriptionUsageSession, core: EntryRecordingCore) -> any AccessProxyEntryPublishing {
        let lock = Data(#"{"status":"verified_build","xrayCore":{"commit":"676eaf66f8f05d4d558ee7a74b4736623d3feeb9","tag":"v26.11.9"},"artifacts":{"iosArm64Sha256":"aa","iosArm64SimulatorSha256":"bb"}}"#.utf8)
        return AccessThreeXUIWebEntry.makePublisher(for: usage, lockData: lock, verifiedCore: core,
                                               retireDocuments: { _, finish in finish() })
    }

    private func configuration() -> AccessSubscriptionConfiguration {
        .init(subscriptionInfoURL: URL(string: "https://subscription.example.invalid/sub/fixture?format=info")!,
              allowedTestClient: "fixture", expectedQuotaBytes: 10_000_000, trafficReset: "never", nodeSHA256: String(repeating: "0", count: 64))
    }
}

private actor ThreeXUIEntryFixture {
    enum Mode { case allowed, unavailable, exhausted, foreignNode }
    let userID: String
    private var mode: Mode
    private(set) var observedSources: [String] = []
    init(userID: String, mode: Mode = .allowed) { self.userID = userID; self.mode = mode }
    func setMode(_ mode: Mode) { self.mode = mode }
    func usage(_ configuration: AccessSubscriptionConfiguration) throws -> AccessSubscriptionUsage {
        observedSources.append(configuration.subscriptionInfoURL.absoluteString)
        if mode == .unavailable { throw AccessSubscriptionQueryError.unavailable }
        return .init(sId: "fixture", emails: ["fixture"], uploadByte: mode == .exhausted ? 10_000_000 : 10,
                     downloadByte: mode == .exhausted ? 0 : 20, totalByte: 10_000_000, expire: 0, enabled: true)
    }
    func nodes(_ configuration: AccessSubscriptionConfiguration, id: String) throws -> [AccessRealityVisionParameters] {
        observedSources.append(configuration.subscriptionInfoURL.absoluteString)
        guard id == userID else { throw AccessSubscriptionQueryError.invalid }
        return [try .init(address: "fixture-node.invalid", port: 443,
            userID: mode == .foreignNode ? "550e8400-e29b-41d4-a716-446655440001" : userID,
            serverName: "www.example.com", publicKey: "fixture-key", shortID: "")]
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
