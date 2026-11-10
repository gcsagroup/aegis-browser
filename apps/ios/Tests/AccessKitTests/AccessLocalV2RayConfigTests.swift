import XCTest
@testable import AccessKit

final class AccessLocalV2RayConfigTests: XCTestCase {
    /// Documentation-only URI (TEST-NET + public demo UUID). Not a live node.
    private let sampleShareURI =
        "vless://550e8400-e29b-41d4-a716-446655440000@198.51.100.10:443"
        + "?flow=xtls-rprx-vision&security=reality&encryption=none&type=tcp"
        + "&sni=www.example.com&fp=chrome"
        + "&pbk=abcdefghijklmnopqrstuvwxyzABCDEFG&sid=abcd1234"
        + "&headerType=none#demo-reality-vision"

    func testParsesShareURI() throws {
        let parameters = try AccessLocalV2RayConfigLoader.parseShareURI(sampleShareURI)
        XCTAssertEqual(parameters.address, "198.51.100.10")
        XCTAssertEqual(parameters.port, 443)
        XCTAssertEqual(parameters.userID, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(parameters.serverName, "www.example.com")
        XCTAssertEqual(parameters.publicKey, "abcdefghijklmnopqrstuvwxyzABCDEFG")
        XCTAssertEqual(parameters.shortID, "abcd1234")
        XCTAssertEqual(parameters.fingerprint, "chrome")
    }

    func testParsesShareURIFromFileBytes() throws {
        let data = Data(sampleShareURI.utf8)
        let parameters = try AccessLocalV2RayConfigLoader.parse(data: data)
        XCTAssertEqual(parameters.address, "198.51.100.10")
        XCTAssertEqual(parameters.port, 443)
    }

    func testParsesFlatParametersObject() throws {
        let root: [String: Any] = [
            "address": "203.0.113.5",
            "port": "8443",
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "sni": "cdn.example.net",
            "pbk": "abcdefghijklmnopqrstuvwxyzABCDEFG",
            "sid": "deadbeef",
            "fp": "chrome",
            "flow": "xtls-rprx-vision",
            "security": "reality",
            "type": "tcp",
        ]
        let data = try JSONSerialization.data(withJSONObject: root)
        let parameters = try AccessLocalV2RayConfigLoader.parse(data: data)
        XCTAssertEqual(parameters.address, "203.0.113.5")
        XCTAssertEqual(parameters.port, 8443)
        XCTAssertEqual(parameters.serverName, "cdn.example.net")
        XCTAssertEqual(parameters.shortID, "deadbeef")
    }

    func testRejectsWsTlsShareURI() {
        // Documentation-shaped WS+TLS share — must stay fail-closed for Access.
        let ws =
            "vless://550e8400-e29b-41d4-a716-446655440000@cdn.example.net:8443"
            + "?flow=&security=tls&type=ws&sni=cdn.example.net&fp=chrome"
            + "&path=%2Fdemo%2F&host="
        XCTAssertThrowsError(try AccessLocalV2RayConfigLoader.parseShareURI(ws)) { error in
            XCTAssertEqual(
                error as? AccessLocalV2RayConfigError,
                .unsupportedSecurity("tls")
            )
        }
    }

    func testRejectsAllowInsecureFlatJSON() throws {
        let insecure: [String: Any] = [
            "address": "198.51.100.10",
            "port": 443,
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "serverName": "www.example.com",
            "publicKey": "abcdefghijklmnopqrstuvwxyzABCDEFG",
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
            .appendingPathComponent("aegis-local-vless-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(sampleShareURI.utf8).write(to: url)

        let imported = try AccessLocalV2RayConfigLoader.load(path: url.path)
        let config = try AccessRealityVisionOutboundConfigBuilder.build(parameters: imported.parameters)
        XCTAssertEqual(config.profile, .realityVision)
        let target = try imported.probeTarget()
        XCTAssertEqual(target.host, "198.51.100.10")
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
        if AccessLocalV2RayConfigLoader.configuredPath() == nil {
            throw XCTSkip(
                "Set \(AccessLocalV2RayConfig.environmentVariable) to a local vless:// file for live import"
            )
        }
        let imported = try AccessLocalV2RayConfigLoader.loadFromEnvironment()
        let config = try AccessRealityVisionOutboundConfigBuilder.build(parameters: imported.parameters)
        XCTAssertEqual(config.profile, .realityVision)
        XCTAssertFalse(imported.parameters.address.isEmpty)
        XCTAssertGreaterThan(imported.parameters.port, 0)
    }
}
