import Foundation
import XCTest
@testable import Aegis

/// Dedicated local HTTPS fixture gate. Its CA is installed only on the task Simulator.
/// It is not a physical-device or live-panel acceptance result.
final class ThreeXUISubscriptionRedirectFixtureTests: XCTestCase {
    func testInfoAndNodeRequestsDoNotFollowAnActualHTTPSRedirect() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let origin = environment["AEGIS_3XUI_REDIRECT_ORIGIN"],
              let destination = environment["AEGIS_3XUI_REDIRECT_DESTINATION"] else {
            throw XCTSkip("Run with the dedicated local HTTPS redirect fixture")
        }
        let configuration = AccessSubscriptionConfiguration(
            subscriptionInfoURL: try XCTUnwrap(URL(string: origin + "/sub/fixture?format=info")),
            allowedTestClient: "fixture", expectedQuotaBytes: 10_000_000, trafficReset: "never",
            nodeSHA256: String(repeating: "0", count: 64))
        do { _ = try await AccessSubscriptionClient.read(configuration); XCTFail("Redirected quota response accepted") } catch { }
        do {
            _ = try await AccessSubscriptionClient.nodes(configuration, userID: "550e8400-e29b-41d4-a716-446655440000")
            XCTFail("Redirected node list accepted")
        } catch { }
        // Prove the origin received both requests: TLS or transport failure must
        // not count as successful redirect rejection.
        let (requests, originReply) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: origin + "/_fixture/requests")))
        XCTAssertEqual((originReply as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: requests),
                       ["/sub/fixture?format=info", "/sub/fixture"])
        let (data, reply) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: destination + "/visits")))
        XCTAssertEqual((reply as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "0", "A redirect destination was contacted before final-URL validation")
    }
}
