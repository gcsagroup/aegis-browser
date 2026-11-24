import XCTest
@testable import AccessKit

final class AccessLocalV2RayConfigTests: XCTestCase {
    /// Documentation-only URI (TEST-NET + public demo UUID). Not a live node.
    private let sampleShareURI =
        "vless://550e8400-e29b-41d4-a716-446655440000@198.51.100.10:443"
        + "?flow=xtls-rprx-vision&security=reality&encryption=none&type=tcp"
        + "&sni=www.example.com&fp=chrome"
        + "&pbk=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&sid=abcd1234"
        + "&headerType=none#demo-reality-vision"

    func testManualShareRequiresExplicitVisionFlowWhileLegacyReadersKeepTheirDefault() throws {
        let expected = try AccessLocalV2RayConfigLoader.parseSingleShareURI(sampleShareURI)
        for flow in ["", "flow=&"] {
            let legacy = sampleShareURI.replacingOccurrences(of: "flow=xtls-rprx-vision&", with: flow)
            XCTAssertThrowsError(try AccessLocalV2RayConfigLoader.parseSingleShareURI(legacy))
            XCTAssertEqual(try AccessLocalV2RayConfigLoader.parseShareURI(legacy), expected)
            XCTAssertEqual(try AccessLocalV2RayConfigLoader.parse(text: legacy), expected)
        }
        XCTAssertThrowsError(try AccessLocalV2RayConfigLoader.parseSingleShareURI(
            sampleShareURI.replacingOccurrences(of: "xtls-rprx-vision", with: "xtls-rprx-origin")))
    }

    func testManualShareRejectsUnusableRealityKeyAndShortIDWithLegacyCompatibility() throws {
        let key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        for invalid in ["short", String(repeating: "A", count: 42), key + "%3D",
                        "+" + key.dropFirst()] {
            let link = sampleShareURI.replacingOccurrences(of: key, with: invalid)
            XCTAssertThrowsError(try AccessLocalV2RayConfigLoader.parseSingleShareURI(link))
            XCTAssertNoThrow(try AccessLocalV2RayConfigLoader.parseShareURI(link))
        }
        let odd = sampleShareURI.replacingOccurrences(of: "abcd1234", with: "abc")
        XCTAssertThrowsError(try AccessLocalV2RayConfigLoader.parseSingleShareURI(odd))
        XCTAssertEqual(try AccessLocalV2RayConfigLoader.parseShareURI(odd).shortID, "abc")
        let empty = sampleShareURI.replacingOccurrences(of: "abcd1234", with: "")
        XCTAssertEqual(try AccessLocalV2RayConfigLoader.parseSingleShareURI(empty).shortID, "")
        let urlSafe = sampleShareURI.replacingOccurrences(of: key, with: "-_" + key.dropFirst(2))
        XCTAssertNoThrow(try AccessLocalV2RayConfigLoader.parseSingleShareURI(urlSafe))
    }

    func testOptionsParserRequiresTheEntireInputToBeOneShareLink() throws {
        let expected = try AccessLocalV2RayConfigLoader.parseShareURI(sampleShareURI)
        XCTAssertEqual(try AccessLocalV2RayConfigLoader.parseSingleShareURI("  " + sampleShareURI + "\n"), expected)
        XCTAssertEqual(try AccessLocalV2RayConfigLoader.parseSingleShareURI(
            sampleShareURI.replacingOccurrences(of: "#", with: "&pcks=#")), expected)
        for invalid in [
            sampleShareURI.replacingOccurrences(of: "#", with: "&pcks=unsupported#"),
            sampleShareURI + "\n" + sampleShareURI,
            sampleShareURI + sampleShareURI,
            sampleShareURI + " extra",
            sampleShareURI.replacingOccurrences(of: "#", with: "&unknownOption=enabled#"),
            sampleShareURI.replacingOccurrences(of: "#", with: "&serverName=conflict.example#"),
            sampleShareURI.replacingOccurrences(of: "#", with: "&allowInsecure=1#"),
            sampleShareURI.replacingOccurrences(of: "&type=tcp", with: "&type=tcp&type=tcp"),
            sampleShareURI.replacingOccurrences(of: "headerType=none", with: "headerType=http"),
            sampleShareURI.replacingOccurrences(of: "type=tcp", with: "type=ws"),
            "https://example.com/subscription", "{\"address\":\"www.example.com\"}"
        ] {
            XCTAssertThrowsError(try AccessLocalV2RayConfigLoader.parseSingleShareURI(invalid))
        }
        // Legacy file/subscription consumers still receive their original selection contract.
        XCTAssertEqual(try AccessLocalV2RayConfigLoader.parse(text: sampleShareURI + "\n" + sampleShareURI), expected)
    }

    func testManualRealityFieldsFollowPinnedFingerprintAndSpiderPathRules() throws {
        func link(fp: String, encodedSpider: String) -> String {
            sampleShareURI.replacingOccurrences(of: "fp=chrome", with: "fp=\(fp)&spx=\(encodedSpider)")
        }
        for (fp, spider, field) in [("unsafe", "", "fingerprint"), ("HelloGolang", "", "fingerprint"),
                                    ("unknown-hello", "", "fingerprint"), ("chrome", "relative", "spiderX"),
                                    ("chrome", "%2Fbad%25ZZ", "spiderX"), ("chrome", "%2Fbad%00", "spiderX")] {
            let input = link(fp: fp, encodedSpider: spider)
            XCTAssertThrowsError(try AccessLocalV2RayConfigLoader.parseSingleShareURI(input)) {
                XCTAssertEqual($0 as? AccessRealityVisionOutboundConfigError, .fieldNotCanonical(field))
            }
            XCTAssertNoThrow(try AccessLocalV2RayConfigLoader.parseShareURI(input))
        }
        for (fp, encoded, decoded) in [("Chrome", "", ""), ("random", "%2F", "/"),
                                       ("helloios_14", "%2Fmanual%2520path%3Fq%3D1", "/manual%20path?q=1")] {
            let parameters = try AccessLocalV2RayConfigLoader.parseSingleShareURI(link(fp: fp, encodedSpider: encoded))
            XCTAssertEqual(parameters.fingerprint, fp)
            XCTAssertEqual(parameters.spiderX, decoded)
        }
    }

    func testProductPathInEachAppChannelWithAStaleResource() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let dev = "/dev-config-from-environment"
        let environment = [AccessLocalV2RayConfig.environmentVariable: dev]
        for channel in ["alpha", "beta", "release", "stable", "dev", "unexpected", ""] {
            let dir = root.appendingPathComponent(UUID().uuidString + ".bundle")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let node = dir.appendingPathComponent("AegisPrivateTestNode.vless")
            try Data(sampleShareURI.utf8).write(to: node)
            var info = ["CFBundleIdentifier": "test." + UUID().uuidString]
            if !channel.isEmpty { info["AegisAccessReleaseChannel"] = channel }
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: dir.appendingPathComponent("Info.plist"))
            let bundle = try XCTUnwrap(Bundle(url: dir))
            let path = AccessLocalV2RayConfigLoader.productPath(bundle: bundle, environment: environment)
            switch channel {
            case "alpha", "beta":
                let config = try AccessLocalV2RayConfigLoader.load(path: XCTUnwrap(path))
                XCTAssertEqual(config.parameters.address, "198.51.100.10")
            case "dev":
                XCTAssertEqual(path, dev)
                let bundled = AccessLocalV2RayConfigLoader.productPath(bundle: bundle, environment: [:])
                let config = try AccessLocalV2RayConfigLoader.load(path: XCTUnwrap(bundled))
                XCTAssertEqual(config.parameters.address, "198.51.100.10")
            default:
                XCTAssertNil(path, channel)
            }
        }
    }

    func testParsesShareURI() throws {
        let parameters = try AccessLocalV2RayConfigLoader.parseShareURI(sampleShareURI)
        XCTAssertEqual(parameters.address, "198.51.100.10")
        XCTAssertEqual(parameters.port, 443)
        XCTAssertEqual(parameters.userID, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(parameters.serverName, "www.example.com")
        XCTAssertEqual(parameters.publicKey, "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        XCTAssertEqual(parameters.shortID, "abcd1234")
        XCTAssertEqual(parameters.fingerprint, "chrome")
    }

    func testExplicitEmptyShortIDAndSpiderPath() throws {
        let uri = sampleShareURI.replacingOccurrences(of: "sid=abcd1234", with: "sid=&spx=%2Fexample")
        let parameters = try AccessLocalV2RayConfigLoader.parseShareURI(uri)
        XCTAssertEqual(parameters.shortID, "")
        XCTAssertEqual(parameters.spiderX, "/example")
        XCTAssertThrowsError(try AccessLocalV2RayConfigLoader.parseShareURI(uri.replacingOccurrences(of: "&sid=", with: "")))
    }

    func testOfficialRealityShareHintPreservesNativeParameters() throws {
        let uri = sampleShareURI.replacingOccurrences(of: "sid=abcd1234",
            with: "sid=&spx=%2Fsynthetic-path&support-x25519mlkem768=true")
        let parameters = try AccessLocalV2RayConfigLoader.parseSingleShareURI(uri)
        XCTAssertEqual(parameters.shortID, "")
        XCTAssertEqual(parameters.spiderX, "/synthetic-path")
        let config = try AccessRealityVisionOutboundConfigBuilder.build(parameters: parameters)
        let outbounds = try XCTUnwrap(config.jsonObject["outbounds"] as? [[String: Any]])
        let stream = try XCTUnwrap(outbounds.first?["streamSettings"] as? [String: Any])
        let reality = try XCTUnwrap(stream["realitySettings"] as? [String: Any])
        XCTAssertEqual(reality["shortId"] as? String, "")
        XCTAssertEqual(reality["spiderX"] as? String, "/synthetic-path")
        XCTAssertNil(reality["support-x25519mlkem768"])
        for value in ["false", "", "1", "TRUE"] {
            XCTAssertThrowsError(try AccessLocalV2RayConfigLoader.parseSingleShareURI(
                uri.replacingOccurrences(of: "support-x25519mlkem768=true",
                                         with: "support-x25519mlkem768=" + value)))
        }
        XCTAssertThrowsError(try AccessLocalV2RayConfigLoader.parseSingleShareURI(
            uri.replacingOccurrences(of: "#", with: "&support-x25519mlkem768=true#")))
        XCTAssertThrowsError(try AccessLocalV2RayConfigLoader.parseSingleShareURI(uri + "\n" + uri))
    }

    func testParsesShareURIWithEmptyEncryptionQuery() throws {
        let uri =
            "vless://550e8400-e29b-41d4-a716-446655440000@198.51.100.10:443"
            + "?flow=xtls-rprx-vision&security=reality&encryption=&type=tcp"
            + "&sni=www.example.com&fp=chrome"
            + "&pbk=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&sid=abcd1234"
        let parameters = try AccessLocalV2RayConfigLoader.parseShareURI(uri)
        XCTAssertEqual(parameters.address, "198.51.100.10")
        XCTAssertEqual(parameters.shortID, "abcd1234")
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
            "pbk": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
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
            "publicKey": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
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

    func testLoadsConfigFromProvidedEnvironmentPath() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(sampleShareURI.utf8).write(to: url)
        let imported = try AccessLocalV2RayConfigLoader.loadFromEnvironment(
            environment: [AccessLocalV2RayConfig.environmentVariable: url.path]
        )
        let config = try AccessRealityVisionOutboundConfigBuilder.build(parameters: imported.parameters)
        XCTAssertEqual(config.profile, .realityVision)
        XCTAssertFalse(imported.parameters.address.isEmpty)
        XCTAssertGreaterThan(imported.parameters.port, 0)
    }
}
