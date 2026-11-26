import Foundation
import XCTest
@testable import AccessKit

final class AccessOutboundNodeTests: XCTestCase {
    func testAdditionalTLSOutboundsProduceSingleVerifiedRouteAndKeepTheirStorageShape() async throws {
        let id = "aa000000-0000-4000-8000-000000000001"
        func vmess(_ network: String, cipher: String = "auto") throws -> String {
            let fields = ["v": "2", "aid": "0", "id": id, "add": "relay.invalid", "port": "443",
                          "tls": "tls", "net": network, "scy": cipher, "host": "relay.invalid", "path": "/test"]
            return "vmess://" + (try JSONEncoder().encode(fields)).base64EncodedString()
        }
        let trojan = "trojan://\(id)@relay.invalid:443?sni=relay.invalid&alpn=http%2F1.1"
        let hysteria = "hy2://\(id)@relay.invalid:443?peer=relay.invalid&insecure=0&upmbps=50&downmbps=100"
        let routes = [(trojan, "trojan", "tcp"), (try vmess("ws"), "vmess", "ws"),
                      (try vmess("httpupgrade"), "vmess", "httpupgrade"), (hysteria, "hysteria", "hysteria")]
        let core = try AccessGoEmbeddedCore()
        for (share, expectedProtocol, expectedNetwork) in routes {
            let node = try AccessOutboundNode.parseSingleShareURI(share)
            let restored = try JSONDecoder().decode(AccessOutboundNode.self, from: JSONEncoder().encode(node))
            XCTAssertTrue(node.isWireIdentical(to: restored))
            XCTAssertEqual(node.testSubscriptionIdentity, UUID(uuidString: id))

            let data = try AccessOutboundConfigRegistry.embeddedInstanceJSONData(for: node)
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var egress = try XCTUnwrap(document["outbounds"] as? [[String: Any]])
            XCTAssertEqual(egress.count, 1)
            XCTAssertEqual(egress[0]["protocol"] as? String, expectedProtocol)
            var stream = try XCTUnwrap(egress[0]["streamSettings"] as? [String: Any])
            XCTAssertEqual(stream["network"] as? String, expectedNetwork)
            var tls = try XCTUnwrap(stream["tlsSettings"] as? [String: Any])
            XCTAssertEqual(tls["useSystemCA"] as? Bool, true)

            try await core.start(configData: data)
            XCTAssertTrue(core.isRunning)
            let stopped = await core.stopAndConfirm()
            XCTAssertTrue(stopped)

            tls["allowInsecure"] = true
            stream["tlsSettings"] = tls
            egress[0]["streamSettings"] = stream
            document["outbounds"] = egress
            XCTAssertThrowsError(try AccessOutboundConfigRegistry.assertFailClosed(document, profile: node.profileKey))
        }
        for cipher in ["none", "zero"] {
            XCTAssertThrowsError(try AccessOutboundNode.parseSingleShareURI(vmess("ws", cipher: cipher)))
        }
        XCTAssertThrowsError(try AccessOutboundNode.parseSingleShareURI(hysteria.replacingOccurrences(of: "insecure=0", with: "insecure=1")))
        XCTAssertThrowsError(try AccessOutboundNode.parseSingleShareURI(trojan + "&sni=other.invalid"))
        let old = try AccessOutboundNode.parseSingleShareURI(trojan)
        let different = try AccessOutboundNode.parseSingleShareURI(trojan.replacingOccurrences(of: id, with: id.uppercased()))
        XCTAssertEqual(old.testSubscriptionIdentity, different.testSubscriptionIdentity)
        XCTAssertFalse(old.isWireIdentical(to: different))
    }

    func testSharedShareLinksPreserveLegacyConfigBytesAndAdmission() throws {
        for fixture in try fixtures() {
            let key = try XCTUnwrap(AccessOutboundProfileKey(profileName: fixture.profileKey))
            XCTAssertEqual(key.rawValue, fixture.profileKey)
            for alias in fixture.aliases {
                XCTAssertEqual(AccessOutboundProfileKey(profileName: alias), key)
            }
            let node = try AccessOutboundNode.parseSingleShareURI(fixture.share)
            XCTAssertEqual(node.profileKey, key)
            XCTAssertEqual(node.kind, .vless)
            XCTAssertEqual(try JSONDecoder().decode(AccessOutboundNode.self, from: JSONEncoder().encode(node)), node)
            XCTAssertEqual(try AccessOutboundConfigRegistry.embeddedInstanceJSONData(for: node),
                           try JSONSerialization.data(withJSONObject: fixture.embeddedConfig, options: [.sortedKeys]))

            let outbounds = try XCTUnwrap(fixture.embeddedConfig["outbounds"] as? [[String: Any]])
            XCTAssertEqual(outbounds.first?["tag"] as? String, fixture.legacyOutboundTag)
            for suffix in fixture.rejectedQuerySuffixes {
                let share = fixture.share.prefix(while: { $0 != "#" })
                XCTAssertThrowsError(try AccessOutboundNode.parseSingleShareURI(String(share) + suffix))
            }
        }
        XCTAssertNil(AccessOutboundProfileKey(profileName: "vless.raw.none"))
        XCTAssertEqual(AccessOutboundProfile.realityVision.rawValue, "reality_vision")
        for wsProfile in ["ws_tls_compat", "vless_ws_tls", "vless.ws.tls"] {
            XCTAssertThrowsError(try AccessOutboundProfile.parse(rawValue: wsProfile))
        }
    }

    func testEnabledLoggingConfigMatchesFixtureWithLogSinkAndGeneration() throws {
        let path = "/private/var/mobile/aegis-diagnostics/fifo"
        for fixture in try fixtures() {
            let node = try AccessOutboundNode.parseSingleShareURI(fixture.share)
            for level in [AccessLogLevel.debug, .info, .warning, .error] {
                var expected = fixture.embeddedConfig
                expected["log"] = ["loglevel": level.rawValue, "access": path, "error": path]
                expected["aegisLogCaptureGeneration"] = 7
                let expectedData = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
                XCTAssertEqual(try AccessOutboundConfigRegistry.embeddedInstanceJSONData(
                    for: node, logLevel: level, errorLogPath: path, logCaptureGeneration: 7), expectedData,
                    "\(fixture.profileKey) \(level.rawValue)")
                // Account-selected REALITY nodes assemble the same document on their own path.
                if case .realityVision(let parameters) = node {
                    let config = try AccessRealityVisionOutboundConfigBuilder.build(parameters: parameters)
                    XCTAssertEqual(try config.embeddedInstanceJSONData(
                        logLevel: level, errorLogPath: path, includeAccessLog: true, logCaptureGeneration: 7),
                        expectedData, "account path \(level.rawValue)")
                    XCTAssertEqual(try config.embeddedInstanceJSONData(),
                                   try AccessOutboundConfigRegistry.embeddedInstanceJSONData(for: node))
                }
            }
        }
    }

    func testOutboundNodeStorageLayoutIsStable() throws {
        let fixtures = try fixtures()
        let ws = try AccessOutboundNode.parseSingleShareURI(fixtures[1].share)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ws)) as? NSDictionary)
        let expected: NSDictionary = [
            "kind": "vless",
            "endpoint": ["address": "192.0.2.20", "port": 8443],
            "security": ["tls": ["serverName": "cert.example.com", "fingerprint": "chrome", "alpn": "http/1.1"]],
            "transport": ["ws": ["path": "/ws?token=%74est-value&opaque=%E9", "host": "ws.example.com"]],
            "credentials": ["vless": ["userID": "00000000-0000-4000-8000-000000000002", "encryption": "none"]],
        ]
        XCTAssertEqual(stored, expected)
        let storedWS = try JSONSerialization.data(withJSONObject: expected)
        XCTAssertEqual(try JSONDecoder().decode(AccessOutboundNode.self, from: storedWS), ws)

        let reality = try AccessOutboundNode.parseSingleShareURI(fixtures[0].share)
        guard case .realityVision(let parameters) = reality else { return XCTFail("Wrong outbound") }
        let expectedReality: NSDictionary = [
            "kind": "vless",
            "endpoint": ["address": "192.0.2.10", "port": 443],
            "security": ["reality": ["serverName": "cert.example.com", "fingerprint": "chrome",
                                     "publicKey": parameters.publicKey, "shortID": "01020304", "spiderX": "/test"]],
            "transport": ["raw": [:] as [String: String]],
            "credentials": ["vless": ["userID": "00000000-0000-4000-8000-000000000001", "encryption": "none",
                                      "flow": "xtls-rprx-vision"]],
        ]
        let storedReality = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reality)) as? NSDictionary
        XCTAssertEqual(storedReality, expectedReality)
        let expectedRealityBytes = try JSONSerialization.data(withJSONObject: expectedReality)
        XCTAssertEqual(try JSONDecoder().decode(AccessOutboundNode.self, from: expectedRealityBytes), reality)
    }

    func testStructuralWhitelistRejectsAddedFieldsAndWrongShapesForBothProfiles() throws {
        for fixture in try fixtures() {
            let key = try XCTUnwrap(AccessOutboundProfileKey(profileName: fixture.profileKey))
            let root = fixture.embeddedConfig
            let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
            let outbound = try XCTUnwrap(outbounds.first)
            let stream = try XCTUnwrap(outbound["streamSettings"] as? [String: Any])
            let settings = try XCTUnwrap(outbound["settings"] as? [String: Any])
            let vnext = try XCTUnwrap((settings["vnext"] as? [[String: Any]])?.first)
            let user = try XCTUnwrap((vnext["users"] as? [[String: Any]])?.first)
            let securityKey = key == .vlessRawReality ? "realitySettings" : "tlsSettings"
            let security = try XCTUnwrap(stream[securityKey] as? [String: Any])

            func replacing(_ object: [String: Any], _ key: String, _ value: Any) -> [String: Any] {
                object.merging([key: value]) { _, new in new }
            }
            func withStream(_ stream: [String: Any]) -> [String: Any] {
                replacing(root, "outbounds", [replacing(outbound, "streamSettings", stream)])
            }
            func withServer(_ server: [String: Any]) -> [String: Any] {
                replacing(root, "outbounds", [replacing(outbound, "settings", ["vnext": [server]])])
            }

            XCTAssertNoThrow(try AccessOutboundConfigRegistry.assertFailClosed(root, profile: key))
            let invalid: [[String: Any]] = [
                replacing(root, "extra", true),
                replacing(root, "routing", ["rules": []]),
                replacing(root, "inbounds", [["protocol": "socks"]]),
                replacing(root, "outbounds", [outbound, outbound]),
                replacing(root, "outbounds", [] as [Any]),
                replacing(root, "outbounds", [replacing(outbound, "mux", ["enabled": false])]),
                replacing(root, "outbounds", [replacing(outbound, "proxySettings", [:] as [String: Any])]),
                replacing(root, "outbounds", [replacing(outbound, "protocol", "freedom")]),
                withStream(replacing(stream, "fragment", [:] as [String: Any])),
                withStream(replacing(stream, "sockopt", ["dialerProxy": "another"])),
                withStream(replacing(stream, "network", 42)),
                withStream(replacing(stream, "security", "none")),
                withStream(replacing(stream, securityKey, replacing(security, "allowInsecure", false))),
                withStream(replacing(stream, securityKey, replacing(security, "disableSystemRoot", false))),
                withServer(replacing(vnext, "users", [user, user])),
                withServer(replacing(vnext, "users", [replacing(user, "futureField", "")])),
                withServer(replacing(vnext, "port", true)),
                withServer(replacing(vnext, "port", 443.5)),
                withServer(replacing(vnext, "port", 443.0)),
            ]
            for (index, object) in invalid.enumerated() {
                XCTAssertThrowsError(try AccessOutboundConfigRegistry.assertFailClosed(object, profile: key),
                                     "\(key.rawValue) mutation \(index)")
            }
            let invalidStream = replacing(replacing(stream, "security", "none"), "network", 42)
            XCTAssertThrowsError(try AccessOutboundConfigRegistry.assertFailClosed(
                withStream(invalidStream), profile: key)) { error in
                XCTAssertEqual(error as? AccessRealityVisionOutboundConfigError, .fieldNotCanonical("network"))
            }
            XCTAssertThrowsError(try AccessOutboundConfigRegistry.assertFailClosed(root,
                profile: key == .vlessRawReality ? .vlessWsTls : .vlessRawReality))
            if key == .vlessWsTls {
                XCTAssertThrowsError(try AccessOutboundConfigRegistry.assertFailClosed(
                    withStream(replacing(stream, securityKey, replacing(security, "useSystemCA", 1))), profile: key))
            } else {
                XCTAssertThrowsError(try AccessOutboundConfigRegistry.assertFailClosed(
                    withServer(replacing(vnext, "users", [replacing(user, "flow", "")])), profile: key))
            }
        }
    }

    func testDiagnosticSecretsIncludeBothPathRepresentationsAndSuppressOverflow() throws {
        let fixtures = try fixtures()
        let reality = try AccessOutboundNode.parseSingleShareURI(fixtures[0].share)
        let ws = try AccessOutboundNode.parseSingleShareURI(fixtures[1].share)
        XCTAssertTrue(try AccessOutboundConfigRegistry.diagnosticSecrets(for: reality).credentials.contains("01020304"))
        let secrets = try AccessOutboundConfigRegistry.diagnosticSecrets(for: ws)
        XCTAssertEqual(secrets.credentials, ["00000000-0000-4000-8000-000000000002"])
        XCTAssertEqual(secrets.queryValues, ["%74est-value", "test-value", "%E9"])

        let query = (0..<256).map { "q=\($0)" }.joined(separator: "&")
        let params = try AccessVLESSWebSocketTLSParameters(address: "192.0.2.20", port: 443,
            userID: "00000000-0000-4000-8000-000000000002", serverName: "cert.example.com",
            requestHost: "ws.example.com", path: "/ws?" + query, fingerprint: "", alpn: "")
        let overflow = try AccessOutboundConfigRegistry.diagnosticSecrets(for: .vlessWebSocketTLS(params))
        XCTAssertEqual(overflow.count, 257)
        let log = AccessDiagnosticLog(pollInterval: .seconds(60))
        let first = log.acquireShared(level: .info, secrets: [])
        let path = try XCTUnwrap(first.path)
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? writer.close() }
        let blocked = log.acquireShared(level: .info, secrets: overflow)
        XCTAssertNil(blocked.path)
        XCTAssertTrue(log.unavailable)
        try writer.write(contentsOf: Data("2026/11/11 00:00:00 from local accepted //example.invalid:443\n".utf8))
        XCTAssertTrue(log.stop(lease: blocked))
        XCTAssertTrue(log.stop(lease: first))
        XCTAssertEqual(log.snapshot(), "")
        let atLimit = AccessDiagnosticLog.RedactionSecrets(credentials: Array(overflow.credentials),
            queryValues: Array(overflow.queryValues.subtracting(["255"])))
        XCTAssertEqual(atLimit.count, 256)
        let recovered = log.acquireShared(level: .info, secrets: atLimit)
        defer { log.stop(lease: recovered) }
        XCTAssertNotNil(recovered.path)
    }

    func testQueryValuesAreRemovedFromURLsWithoutChangingTimestampsOrEndpoints() throws {
        let userID = "00000000-0000-4000-8000-000000000002"
        let requestTarget = "/ws?v=1&x=%31&k=a+b&id=abc&year=2026&token=fixture-query-value"
        let params = try AccessVLESSWebSocketTLSParameters(address: "192.0.2.20", port: 443,
            userID: userID, serverName: "cert.example.com", requestHost: "ws.example.com",
            path: requestTarget, fingerprint: "", alpn: "")
        let secrets = try AccessOutboundConfigRegistry.diagnosticSecrets(for: .vlessWebSocketTLS(params))
        XCTAssertEqual(secrets.credentials, [userID])
        XCTAssertEqual(secrets.queryValues, ["1", "%31", "a+b", "a b", "abc", "2026", "fixture-query-value"])

        let log = AccessDiagnosticLog(pollInterval: .seconds(60))
        defer { log.stop() }
        let lease = log.acquireShared(level: .info, secrets: secrets)
        let path = try XCTUnwrap(lease.path)
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? writer.close() }
        let events = [
            "2026/11/11 00:00:01 from local accepted https://abc.example.com:1443\(requestTarget)",
            "2026/11/11 00:00:02 [Error] transport/internet/websocket: upgrade error \(requestTarget)",
            "2026/11/11 00:00:03 from local accepted //\(userID).example.com:443",
        ]
        try writer.write(contentsOf: Data((events.joined(separator: "\n") + "\n").utf8))
        XCTAssertTrue(log.stop(lease: lease))
        XCTAssertEqual(log.snapshot(), [
            "2026/11/11 00:00:01 [Access] accepted abc.example.com:1443",
            "2026/11/11 00:00:02 [Error] details withheld",
            "2026/11/11 00:00:03 [Access] accepted [redacted]",
        ].joined(separator: "\n"))
    }

    private struct Fixture {
        let profileKey: String
        let aliases: [String]
        let legacyOutboundTag: String
        let share: String
        let rejectedQuerySuffixes: [String]
        let embeddedConfig: [String: Any]
    }

    private func fixtures() throws -> [Fixture] {
        let bundle = Bundle(for: Self.self)
        return try ["vless.raw.reality", "vless.ws.tls"].map { name in
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json", subdirectory: "share-links"))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            return Fixture(profileKey: try XCTUnwrap(root["profileKey"] as? String),
                           aliases: try XCTUnwrap(root["aliases"] as? [String]),
                           legacyOutboundTag: try XCTUnwrap(root["legacyOutboundTag"] as? String),
                           share: try XCTUnwrap(root["share"] as? String),
                           rejectedQuerySuffixes: try XCTUnwrap(root["rejectedQuerySuffixes"] as? [String]),
                           embeddedConfig: try XCTUnwrap(root["embeddedConfig"] as? [String: Any]))
        }
    }
}
