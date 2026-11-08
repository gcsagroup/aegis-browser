import XCTest
@testable import AccessKit

final class AccessLocalV2RayConfigTests: XCTestCase {
    private let sampleUserID = "550e8400-e29b-41d4-a716-446655440000"
    private let samplePublicKey = "abcdefghijklmnopqrstuvwxyzABCDEFG"

    private func outboundJSON() throws -> Data {
        let root: [String: Any] = [
            "outbounds": [
                [
                    "protocol": "vless",
                    "settings": [
                        "vnext": [
                            [
                                "address": "198.51.100.10",
                                "port": 443,
                                "users": [
                                    [
                                        "id": sampleUserID,
                                        "encryption": "none",
                                        "flow": "xtls-rprx-vision",
                                    ],
                                ],
                            ],
                        ],
                    ],
                    "streamSettings": [
                        "network": "tcp",
                        "security": "reality",
                        "realitySettings": [
                            "serverName": "www.example.com",
                            "publicKey": samplePublicKey,
                            "shortId": "abcd1234",
                            "fingerprint": "chrome",
                        ],
                    ],
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: root)
    }

    func testParsesFullOutboundConfig() throws {
        let parameters = try AccessLocalV2RayConfigLoader.parse(data: try outboundJSON())
        XCTAssertEqual(parameters.address, "198.51.100.10")
        XCTAssertEqual(parameters.port, 443)
        XCTAssertEqual(parameters.userID, sampleUserID)
        XCTAssertEqual(parameters.serverName, "www.example.com")
        XCTAssertEqual(parameters.publicKey, samplePublicKey)
        XCTAssertEqual(parameters.shortID, "abcd1234")
        XCTAssertEqual(parameters.fingerprint, "chrome")
    }

    func testParsesFlatParametersObject() throws {
        let root: [String: Any] = [
            "address": "203.0.113.5",
            "port": "8443",
            "id": sampleUserID,
            "sni": "cdn.example.net",
            "pbk": samplePublicKey,
            "sid": "deadbeef",
            "fp": "chrome",
        ]
        let data = try JSONSerialization.data(withJSONObject: root)
        let parameters = try AccessLocalV2RayConfigLoader.parse(data: data)
        XCTAssertEqual(parameters.address, "203.0.113.5")
        XCTAssertEqual(parameters.port, 8443)
        XCTAssertEqual(parameters.serverName, "cdn.example.net")
        XCTAssertEqual(parameters.shortID, "deadbeef")
    }

    func testRejectsWsAndAllowInsecure() throws {
        let ws: [String: Any] = [
            "outbounds": [
                [
                    "protocol": "vless",
                    "settings": [
                        "vnext": [
                            [
                                "address": "198.51.100.10",
                                "port": 443,
                                "users": [["id": sampleUserID, "flow": "xtls-rprx-vision"]],
                            ],
                        ],
                    ],
                    "streamSettings": [
                        "network": "ws",
                        "security": "reality",
                        "wsSettings": ["path": "/"],
                        "realitySettings": [
                            "serverName": "www.example.com",
                            "publicKey": samplePublicKey,
                            "shortId": "abcd1234",
                        ],
                    ],
                ],
            ],
        ]
        XCTAssertThrowsError(
            try AccessLocalV2RayConfigLoader.parse(data: try JSONSerialization.data(withJSONObject: ws))
        ) { error in
            XCTAssertEqual(error as? AccessLocalV2RayConfigError, .unsupportedNetwork("ws"))
        }

        let insecure: [String: Any] = [
            "address": "198.51.100.10",
            "port": 443,
            "id": sampleUserID,
            "serverName": "www.example.com",
            "publicKey": samplePublicKey,
            "shortId": "abcd1234",
            "allowInsecure": true,
        ]
        XCTAssertThrowsError(
            try AccessLocalV2RayConfigLoader.parse(
                data: try JSONSerialization.data(withJSONObject: insecure)
            )
        ) { error in
            XCTAssertEqual(error as? AccessLocalV2RayConfigError, .allowInsecureRejected)
        }
    }

    func testLoadFromTempFileAndBuildOutbound() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aegis-local-v2ray-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try outboundJSON().write(to: url)

        let imported = try AccessLocalV2RayConfigLoader.load(path: url.path)
        XCTAssertEqual(imported.sourcePath, url.path)
        let config = try AccessRealityVisionOutboundConfigBuilder.build(parameters: imported.parameters)
        XCTAssertEqual(config.profile, .realityVision)
        let target = try imported.probeTarget()
        XCTAssertEqual(target.host, "198.51.100.10")
        XCTAssertEqual(target.port, 443)
        XCTAssertEqual(target.authorizationID, AccessLocalV2RayConfig.localAuthorizationID)
    }

    func testEnvironmentPathMissingIsPathNotSet() {
        XCTAssertThrowsError(
            try AccessLocalV2RayConfigLoader.loadFromEnvironment(environment: [:])
        ) { error in
            XCTAssertEqual(error as? AccessLocalV2RayConfigError, .pathNotSet)
        }
    }

    func testLiveSuiteSkipsWithoutLocalConfig() throws {
        // Keeps CI green: the live suite is opt-in via env path.
        if AccessLocalV2RayConfigLoader.configuredPath() == nil {
            throw XCTSkip(
                "Set \(AccessLocalV2RayConfig.environmentVariable) to a local V2Ray/Xray JSON to run live import"
            )
        }
        let imported = try AccessLocalV2RayConfigLoader.loadFromEnvironment()
        let config = try AccessRealityVisionOutboundConfigBuilder.build(parameters: imported.parameters)
        XCTAssertEqual(config.profile, .realityVision)
        // Never print secrets — only assert non-empty admitted fields via typed accessors.
        XCTAssertFalse(imported.parameters.address.isEmpty)
        XCTAssertGreaterThan(imported.parameters.port, 0)
    }
}
