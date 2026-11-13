import XCTest
@testable import AccessKit

final class AccessRealityVisionOutboundConfigTests: XCTestCase {
    private func makeParameters(
        address: String = "198.51.100.10",
        port: UInt16 = 443,
        userID: String = "550e8400-e29b-41d4-a716-446655440000",
        serverName: String = "www.example.com",
        publicKey: String = "abcdefghijklmnopqrstuvwxyzABCDEFG",
        shortID: String = "abcd1234"
    ) throws -> AccessRealityVisionParameters {
        try AccessRealityVisionParameters(
            address: address,
            port: port,
            userID: userID,
            serverName: serverName,
            publicKey: publicKey,
            shortID: shortID
        )
    }

    func testBuildsRealityVisionOutboundMatrix() throws {
        let parameters = try makeParameters()
        let config = try AccessRealityVisionOutboundConfigBuilder.build(parameters: parameters)
        XCTAssertEqual(config.profile, .realityVision)

        let root = config.jsonObject
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds.count, 1)
        let outbound = try XCTUnwrap(outbounds.first)
        XCTAssertEqual(outbound["protocol"] as? String, "vless")
        XCTAssertEqual(outbound["tag"] as? String, "reality_vision")

        let settings = try XCTUnwrap(outbound["settings"] as? [String: Any])
        let vnext = try XCTUnwrap(settings["vnext"] as? [[String: Any]])
        let server = try XCTUnwrap(vnext.first)
        XCTAssertEqual(server["address"] as? String, "198.51.100.10")
        XCTAssertEqual(server["port"] as? Int, 443)
        let users = try XCTUnwrap(server["users"] as? [[String: Any]])
        let user = try XCTUnwrap(users.first)
        XCTAssertEqual(user["id"] as? String, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(user["encryption"] as? String, "none")
        XCTAssertEqual(user["flow"] as? String, "xtls-rprx-vision")

        let stream = try XCTUnwrap(outbound["streamSettings"] as? [String: Any])
        XCTAssertEqual(stream["network"] as? String, "tcp")
        XCTAssertEqual(stream["security"] as? String, "reality")
        XCTAssertNil(stream["wsSettings"])
        XCTAssertNil(stream["allowInsecure"])
        let reality = try XCTUnwrap(stream["realitySettings"] as? [String: Any])
        XCTAssertEqual(reality["serverName"] as? String, "www.example.com")
        XCTAssertEqual(reality["publicKey"] as? String, "abcdefghijklmnopqrstuvwxyzABCDEFG")
        XCTAssertEqual(reality["shortId"] as? String, "abcd1234")
        XCTAssertEqual(reality["fingerprint"] as? String, "chrome")
        XCTAssertNil(reality["allowInsecure"])

        let text = try config.jsonUTF8String()
        XCTAssertFalse(text.contains("allowInsecure"))
        XCTAssertFalse(text.contains("ws_tls_compat"))
        XCTAssertFalse(text.contains("wsSettings"))
        XCTAssertTrue(text.contains("xtls-rprx-vision"))
    }

    func testRejectsWsTlsCompatProfileString() throws {
        let parameters = try makeParameters()
        XCTAssertThrowsError(
            try AccessRealityVisionOutboundConfigBuilder.build(
                profileRawValue: "ws_tls_compat",
                parameters: parameters
            )
        ) { error in
            XCTAssertEqual(error as? AccessContractError, .wsTlsCompatNotAdmitted)
        }
    }

    func testRejectsMalformedParameters() throws {
        XCTAssertThrowsError(try makeParameters(address: "")) { error in
            XCTAssertEqual(
                error as? AccessRealityVisionOutboundConfigError,
                .emptyField("address")
            )
        }
        XCTAssertThrowsError(try makeParameters(port: 0)) { error in
            XCTAssertEqual(
                error as? AccessRealityVisionOutboundConfigError,
                .invalidPort(0)
            )
        }
        XCTAssertThrowsError(try makeParameters(userID: "not-a-uuid")) { error in
            XCTAssertEqual(
                error as? AccessRealityVisionOutboundConfigError,
                .invalidUserID
            )
        }
        XCTAssertThrowsError(try makeParameters(shortID: "zzzz")) { error in
            XCTAssertEqual(
                error as? AccessRealityVisionOutboundConfigError,
                .fieldNotCanonical("shortID")
            )
        }
    }

    func testAssertFailClosedCatchesAllowInsecureAndWs() throws {
        XCTAssertThrowsError(
            try AccessRealityVisionOutboundConfigBuilder.assertFailClosed([
                "allowInsecure": true,
            ])
        ) { error in
            XCTAssertEqual(
                error as? AccessRealityVisionOutboundConfigError,
                .allowInsecureRejected
            )
        }
        XCTAssertThrowsError(
            try AccessRealityVisionOutboundConfigBuilder.assertFailClosed([
                "streamSettings": ["wsSettings": ["path": "/"]],
            ])
        ) { error in
            XCTAssertEqual(
                error as? AccessRealityVisionOutboundConfigError,
                .unsupportedNetwork("ws")
            )
        }
    }
}
