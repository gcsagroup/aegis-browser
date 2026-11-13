import CryptoKit
import Foundation
import Synchronization
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
