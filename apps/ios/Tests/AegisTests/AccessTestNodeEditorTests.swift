#if DEBUG
@testable import AccessKit
#else
import AccessKit
#endif
import CoreImage
import WebKit
import UIKit
import CryptoKit
import Network
import Security
import Synchronization
import Darwin
import XCTest
@testable import Aegis

@MainActor
final class AccessTestNodeEditorTests: XCTestCase {
    private let link = "vless://550e8400-e29b-41d4-a716-446655440000@198.51.100.10:443"
        + "?type=tcp&security=reality&flow=xtls-rprx-vision&sni=www.example.com"
        + "&pbk=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&sid=abcd1234#synthetic-node"

    private let webSocketLink = "vless://550e8400-e29b-41d4-a716-446655440000@198.51.100.20:8443"
        + "?security=tls&type=ws&host=ws.example.com&fp=chrome&sni=cert.example.com&path=%2Finside&encryption=none&alpn=#synthetic-ws"

    func testTestNodeImportPreservesWebSocketWireValuesAndLegacyReality() throws {
        let address = "xn--bcher-kva.example"
        let uri = try XCTUnwrap(URLComponents(string: webSocketLink.replacingOccurrences(of: "198.51.100.20", with: address)))
        var nested = uri
        let path = "/upgrade?origin=https://assets.example/"
        nested.queryItems = uri.queryItems?.map { $0.name == "path" ? URLQueryItem(name: "path", value: path) : $0 }
        let share = try XCTUnwrap(nested.string)
        XCTAssertTrue(share.contains("https://assets.example/"))
        guard case .vlessWebSocketTLS(let parameters) = try AccessInternalTestNode.parseSingleShareURI(share)
        else { return XCTFail("Expected a typed WebSocket profile") }
        XCTAssertEqual(parameters.address, address)
        XCTAssertEqual(parameters.path, path)

        let legacy = link.replacingOccurrences(of: "sid=abcd1234", with: "sid=abcd1234&spx=/café")
        let expected = try AccessLocalV2RayConfigLoader.parseSingleShareURI(legacy)
        XCTAssertEqual(expected.spiderX, "/café")
        XCTAssertEqual(try AccessInternalTestNode.parseSingleShareURI(legacy), .realityVision(expected))

        for scoped in ["[fe80::1%25lo0]", "[fe80::1%lo0]", "fe80::1%lo0"] {
            XCTAssertThrowsError(try AccessVLESSWebSocketTLSParameters(address: scoped, port: 443, userID: parameters.userID,
                serverName: parameters.serverName, requestHost: parameters.requestHost, path: "/", fingerprint: "", alpn: ""))
        }
        XCTAssertThrowsError(try AccessVLESSWebSocketTLSParameters(address: address, port: 443, userID: parameters.userID,
            serverName: parameters.serverName, requestHost: "[fe80::1%lo0]:443", path: "/", fingerprint: "", alpn: ""))
        XCTAssertThrowsError(try AccessInternalTestNode.parseSingleShareURI(share + webSocketLink))
    }

    func testWebSocketValidatesRequestTargetBytesAndBothAddressFields() throws {
        let source = webSocketLink.replacingOccurrences(of: "198.51.100.20", with: "r%6Fute.example.")
            .replacingOccurrences(of: "path=%2Finside", with: "path=%2Fupgrade%3Ftag%3D%25E9")
        guard case .vlessWebSocketTLS(let node) = try AccessInternalTestNode.parseSingleShareURI(source)
        else { return XCTFail("Expected a WebSocket profile") }
        XCTAssertEqual(node.address, "route.example.")
        XCTAssertEqual(node.path, "/upgrade?tag=%E9")

        let callback = webSocketLink.replacingOccurrences(of: "198.51.100.20", with: "b%C3%BCcher.example")
            .replacingOccurrences(of: "host=ws.example.com", with: "host=ws.example.com.%3A8443")
            .replacingOccurrences(of: "path=%2Finside", with: "path=%2Fupgrade%3Fnext%3D%2568ttps://assets.example/")
        guard case .vlessWebSocketTLS(let callbackNode) = try AccessInternalTestNode.parseSingleShareURI(callback)
        else { return XCTFail("Expected a WebSocket profile") }
        XCTAssertEqual(callbackNode.address, "xn--bcher-kva.example")
        XCTAssertEqual(callbackNode.requestHost, "ws.example.com.:8443")
        XCTAssertEqual(callbackNode.path, "/upgrade?next=%68ttps://assets.example/")

        let withSeparator = callback.replacingOccurrences(
            of: "assets.example/", with: "assets.example/search%253Fq%253D%253A%252F%252F")
        guard case .vlessWebSocketTLS(let separatorNode) = try AccessInternalTestNode.parseSingleShareURI(withSeparator)
        else { return XCTFail("Expected a WebSocket profile") }
        XCTAssertEqual(separatorNode.path, "/upgrade?next=%68ttps://assets.example/search%3Fq%3D%3A%2F%2F")

        let withPathLast = String(webSocketLink.prefix(while: { $0 != "#" }))
            .replacingOccurrences(of: "&path=%2Finside", with: "") + "&path=/upgrade"
        for scheme in ["vless", "ss", "trojan", "vmess"] {
            XCTAssertThrowsError(try AccessInternalTestNode.parseSingleShareURI(withPathLast + scheme + "://example.invalid"))
        }
        let forbiddenHost = source.replacingOccurrences(of: "host=ws.example.com", with: "host=169.254.8.8%25en0")
        XCTAssertThrowsError(try AccessInternalTestNode.parseSingleShareURI(forbiddenHost))
        let earlyData = source.replacingOccurrences(of: "tag%3D%25E9", with: "tag%3D%25E9%26e%2564%3D1")
        XCTAssertThrowsError(try AccessInternalTestNode.parseSingleShareURI(earlyData))
    }

    func testUnsupportedSavedWebSocketAddressCannotRunAndCanBeRemovedOrReplaced() throws {
        let node = try AccessInternalTestNode.parseSingleShareURI(webSocketLink)
        let original = AccessTestNodeRecord(node)
        let data = try JSONEncoder().encode(original)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        fields["address"] = "fe80::1%lo0"
        let invalid = try JSONSerialization.data(withJSONObject: fields)
        let storage = Storage()
        storage.encodedValue = invalid
        let repository = AccessTestNodeRepository(channel: .dev, storage: storage)
        let editor = AccessTestNodeEditor(isPrivate: false, repository: repository)
        XCTAssertThrowsError(try repository.savedNode(isPrivate: false))
        XCTAssertEqual(try repository.revision(isPrivate: false), original.revision)
        XCTAssertThrowsError(try repository.remove(expectedRevision: UUID(), isPrivate: false))
        editor.openProfile()
        XCTAssertTrue(editor.hasSavedNode)
        editor.removeSavedNode()
        XCTAssertNil(storage.encodedValue)
        XCTAssertFalse(editor.hasSavedNode)

        storage.encodedValue = invalid
        editor.openProfile()
        editor.preview(webSocketLink)
        XCTAssertTrue(editor.canApply)
        editor.apply()
        XCTAssertEqual(try repository.savedNode(isPrivate: false).node, node)
        XCTAssertNotEqual(try repository.revision(isPrivate: false), original.revision)
    }

    func testWebSocketProfileImportsOneShareAndPreservesVersionedRecords() throws {
        let store = Storage()
        let repository = AccessTestNodeRepository(channel: .dev, storage: store)
        let editor = AccessTestNodeEditor(isPrivate: false, repository: repository)
        editor.openProfile()
        editor.preview(link)
        editor.apply()
        let legacy = try repository.savedNode(isPrivate: false)
        let previous = Data("""
        {"version":1,"revision":"E1EA5ABF-608B-40E3-886A-9D92520F79A1","address":"198.51.100.10",
         "port":443,"userID":"550e8400-e29b-41d4-a716-446655440000","serverName":"www.example.com",
         "publicKey":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","shortID":"abcd1234","fingerprint":"chrome","spiderX":""}
        """.utf8)
        let restoredLegacy = try JSONDecoder().decode(AccessTestNodeRecord.self, from: previous)
        XCTAssertEqual(restoredLegacy.node, legacy.node)
        XCTAssertEqual(restoredLegacy.revision.uuidString, "E1EA5ABF-608B-40E3-886A-9D92520F79A1")

        editor.preview(webSocketLink)
        XCTAssertEqual(editor.draftProtocolName, "VLESS / WS / TLS")
        XCTAssertEqual(store.writes, 1)
        editor.apply()
        let record = try repository.savedNode(isPrivate: false)
        let restored = try JSONDecoder().decode(AccessTestNodeRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(record.node, restored.node)
        XCTAssertEqual(record.revision, restored.revision)
        XCTAssertNotEqual(legacy.revision, record.revision)
        guard case .vlessWebSocketTLS(let node) = record.node else { return XCTFail("Wrong outbound") }
        XCTAssertEqual(node.serverName, "cert.example.com")
        XCTAssertEqual(node.requestHost, "ws.example.com")
        XCTAssertEqual(node.path, "/inside")
        XCTAssertThrowsError(try AccessLocalV2RayConfigLoader.parseSingleShareURI(webSocketLink))
        let explicitPort = webSocketLink.replacingOccurrences(of: "host=ws.example.com", with: "host=ws.example.com%3A8443")
        guard case .vlessWebSocketTLS(let authority) = try AccessInternalTestNode.parseSingleShareURI(explicitPort)
        else { return XCTFail("Wrong outbound for HTTP authority") }
        XCTAssertEqual(authority.requestHost, "ws.example.com:8443")
        XCTAssertEqual(authority.serverName, "cert.example.com")
        let ipv6 = webSocketLink.replacingOccurrences(of: "198.51.100.20", with: "[2001:db8::2]")
        guard case .vlessWebSocketTLS(let literal) = try AccessInternalTestNode.parseSingleShareURI(ipv6)
        else { return XCTFail("Wrong outbound for IPv6") }
        XCTAssertEqual(literal.address, "2001:db8::2")
        let withQuery = webSocketLink.replacingOccurrences(of: "path=%2Finside", with: "path=%2Finside%3Fv%3D2")
        guard case .vlessWebSocketTLS(let queryPath) = try AccessInternalTestNode.parseSingleShareURI(withQuery)
        else { return XCTFail("Wrong outbound for a valid query") }
        XCTAssertEqual(queryPath.path, "/inside?v=2")

        for invalid in [webSocketLink.replacingOccurrences(of: "security=tls", with: "security=none"),
                        webSocketLink.replacingOccurrences(of: "&alpn=", with: "&allowInsecure=1"),
                        webSocketLink.replacingOccurrences(of: "&alpn=", with: "&security=tls"),
                        webSocketLink.replacingOccurrences(of: "path=%2Finside", with: "path=%2F%0D%0AX-Forged"),
                        webSocketLink.replacingOccurrences(of: "path=%2Finside", with: "path=%2Finvalid%25"),
                        webSocketLink.replacingOccurrences(of: "path=%2Finside", with: "path=%2F%3F%2565d%3D1"),
                        webSocketLink.replacingOccurrences(of: "path=%2Finside", with: "path=%2Finside%3Fv%3D%7B"),
                        webSocketLink.replacingOccurrences(of: "alpn=", with: "alpn=%FF"),
                        webSocketLink.replacingOccurrences(of: "@198.51.100.20", with: ":%FF@198.51.100.20"),
                        webSocketLink.replacingOccurrences(of: "8443?", with: "8443/%FF?"),
                        webSocketLink.replacingOccurrences(of: "198.51.100.20", with: "[route.example]"),
                        webSocketLink.replacingOccurrences(of: "host=ws.example.com", with: "host=ws.example.com%3A92233720368547758070"),
                        webSocketLink + "\n" + webSocketLink] {
            editor.preview(invalid)
            XCTAssertFalse(editor.canApply)
            XCTAssertEqual(editor.error, .invalidLink)
        }
        XCTAssertEqual(store.writes, 2)
    }

    func testWebSocketPageRetainsCertificateVerificationAndUsesOneOutbound() async throws {
        let storage = Storage()
        let repository = AccessTestNodeRepository(channel: .dev, storage: storage)
        let editor = AccessTestNodeEditor(isPrivate: false, repository: repository)
        editor.openProfile()
        editor.preview(webSocketLink)
        editor.apply()
        let core = PageCore()
        let page = AccessTestNodePage(isPrivate: false, repository: repository, testingCore: core, transport: .http)
        defer { page.close() }
        await page.open(URL(string: "https://controlled.example/page")!)
        XCTAssertEqual(page.selectedTransport, .http)
        let bytes = try XCTUnwrap(core.startedConfig.withLock { $0 })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual((json["inbounds"] as? [Any])?.count, 0)
        let outbounds = try XCTUnwrap(json["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds.count, 1)
        let stream = try XCTUnwrap(outbounds.first?["streamSettings"] as? [String: Any])
        XCTAssertEqual(stream["network"] as? String, "ws")
        XCTAssertEqual(stream["security"] as? String, "tls")
        let tls = try XCTUnwrap(stream["tlsSettings"] as? [String: Any])
        XCTAssertNil(tls["allowInsecure"])
        XCTAssertEqual(tls["useSystemCA"] as? Bool, true)
        XCTAssertEqual(tls["serverName"] as? String, "cert.example.com")
        let webSocket = try XCTUnwrap(stream["wsSettings"] as? [String: String])
        XCTAssertEqual(webSocket["host"], "ws.example.com")
        XCTAssertEqual(webSocket["path"], "/inside")
    }

    func testTransportAdmissionAndBindingTimeSelection() throws {
        XCTAssertEqual(try AccessTestNodeTransport.automatic.select(socksAdmitted: true), .socks5)
        XCTAssertEqual(try AccessTestNodeTransport.automatic.select(socksAdmitted: false), .http)
        XCTAssertEqual(try AccessTestNodeTransport.http.select(socksAdmitted: true), .http)
        XCTAssertThrowsError(try AccessTestNodeTransport.socks5.select(socksAdmitted: false))
        XCTAssertTrue(AccessInternalSOCKSAdmission.admitted(major: 26, minor: 6, patch: 1, build: "23G83", phone: true, simulator: false))
        for values in [(26, 6, 1, "23G84", true, false), (26, 6, 1, "23G83", false, false),
                       (26, 6, 1, "23G83", true, true), (27, 0, 0, "24A1", true, false)] {
            XCTAssertFalse(AccessInternalSOCKSAdmission.admitted(major: values.0, minor: values.1, patch: values.2,
                build: values.3, phone: values.4, simulator: values.5))
        }
    }

    func testNativeAdmissionRejectsMixedOrRestrictedIdentitiesEvenWithCapabilityEnabled() {
        let normal = "com.gcsa.aegis"
        let alpha = "com.gcsa.aegis.alpha.internal"
        func resolve(_ bundle: String?, _ channel: String?, _ profile: String?,
                     _ capability: String? = "YES", debug: Bool = true) -> AccessInternalOptions? {
            AccessInternalOptions.resolve(bundleID: bundle, channel: channel, releaseProfile: profile,
                                          capability: capability, debug: debug)
        }
        XCTAssertEqual(resolve(normal, "dev", "dev"), .dev)
        XCTAssertEqual(resolve(alpha, "alpha", "alpha", debug: false), .alpha)
        XCTAssertNil(resolve(normal, "dev", "dev", debug: false))
        XCTAssertNil(resolve(normal, "alpha", "alpha"))
        XCTAssertNil(resolve(alpha, "dev", "dev"))
        XCTAssertNil(resolve(alpha, "alpha", "dev"))
        XCTAssertNil(resolve(alpha, "alpha", "alpha", "NO"))
        XCTAssertNil(resolve(nil, "dev", "dev"))
        XCTAssertNil(resolve(alpha, nil, nil))
        for channel in ["beta", "release", "unknown"] {
            XCTAssertNil(resolve(alpha, channel, channel))
            XCTAssertNil(resolve(normal, channel, channel))
        }
    }

    func testTextAndScanShareWholeLinkValidationAndApplyIsExplicit() throws {
        let storage = Storage()
        let repository = AccessTestNodeRepository(channel: .dev, storage: storage)
        let editor = AccessTestNodeEditor(isPrivate: false, repository: repository)
        editor.openProfile()
        editor.preview(link + "\n" + link)
        XCTAssertEqual(editor.error, .invalidLink)
        XCTAssertFalse(editor.canApply)
        editor.apply()
        XCTAssertEqual(storage.writes, 0)

        editor.preview(link)
        XCTAssertTrue(editor.hasDraft)
        XCTAssertEqual(storage.writes, 0)
        editor.discard()
        XCTAssertFalse(editor.hasDraft)
        let scan = try XCTUnwrap(editor.beginScan())
        editor.finishScan(scan, result: .success(link + "\n" + link))
        XCTAssertEqual(editor.error, .invalidLink)
        XCTAssertFalse(editor.hasDraft)
        let singleScan = try XCTUnwrap(editor.beginScan())
        editor.finishScan(singleScan, result: .success(link))
        XCTAssertTrue(editor.hasDraft)
        XCTAssertFalse(editor.hasSavedNode)
        editor.apply()
        XCTAssertFalse(editor.hasDraft)
        XCTAssertTrue(editor.hasSavedNode)
        XCTAssertEqual(storage.writes, 1)
        XCTAssertNotNil(try repository.revision(isPrivate: false))
    }

#if DEBUG
    func testUITestLaunchUsesOnlyItsOwnInMemoryNodeRepository() throws {
        let persistent = Storage()
        let ordinary = AccessTestNodeRepository.launchRepository(arguments: [], channel: .dev) { persistent }
        let draft = try AccessLocalV2RayConfigLoader.parseSingleShareURI(link)
        let ordinaryRevision = try ordinary.apply(draft, expectedRevision: nil, isPrivate: false)
        var persistentOpens = 0
        func makeUITestRepository() -> AccessTestNodeRepository {
            AccessTestNodeRepository.launchRepository(arguments: ["--ui-testing"], channel: .dev) {
                persistentOpens += 1
                return persistent
            }
        }
        let test = makeUITestRepository()
        XCTAssertNil(try test.revision(isPrivate: false))
        let firstRevision = try test.apply(draft, expectedRevision: nil, isPrivate: false)
        XCTAssertEqual(try test.savedNode(isPrivate: false).revision, firstRevision)
        XCTAssertNil(try makeUITestRepository().revision(isPrivate: false), "An interrupted run leaves no saved node")
        try test.remove(expectedRevision: firstRevision, isPrivate: false)
        XCTAssertNil(try test.revision(isPrivate: false))
        XCTAssertEqual(persistentOpens, 0)
        XCTAssertEqual(try ordinary.savedNode(isPrivate: false).revision, ordinaryRevision)
        XCTAssertEqual(persistent.writes, 1)
        XCTAssertEqual(persistent.removals, 0)
    }
#endif

    func testCameraDenialCancellationAndProfileSwitchDoNotReplaceSavedNode() throws {
        let storage = Storage()
        let repository = AccessTestNodeRepository(channel: .dev, storage: storage)
        let editor = AccessTestNodeEditor(isPrivate: false, repository: repository)
        editor.openProfile()
        let denied = try XCTUnwrap(editor.beginScan())
        editor.finishScan(denied, result: .failure(.cameraDenied))
        XCTAssertEqual(editor.error, .cameraDenied)
        editor.preview(link)
        editor.apply()
        let old = try repository.revision(isPrivate: false)

        let cancelled = try XCTUnwrap(editor.beginScan())
        editor.finishScan(cancelled, result: nil)
        editor.finishScan(cancelled, result: .success(link))
        XCTAssertFalse(editor.hasDraft)

        let leftProfile = try XCTUnwrap(editor.beginScan())
        editor.closeProfile()
        editor.openProfile()
        let newScan = try XCTUnwrap(editor.beginScan())
        editor.finishScan(leftProfile, result: .success(link))
        XCTAssertEqual(editor.scan, newScan)
        XCTAssertFalse(editor.hasDraft)
        editor.apply()
        XCTAssertEqual(old, try repository.revision(isPrivate: false))
        XCTAssertEqual(storage.writes, 1)
    }

    func testValidScanSupersedesUnpreviewedTextAndStillRequiresExplicitApply() throws {
        let storage = Storage()
        let repository = AccessTestNodeRepository(channel: .dev, storage: storage)
        let editor = AccessTestNodeEditor(isPrivate: false, repository: repository)
        editor.openProfile()
        var pendingText = link
        let scanned = link.replacingOccurrences(of: "sid=abcd1234", with: "sid=ef")
        editor.finishScan(try XCTUnwrap(editor.beginScan()), result: .success(scanned), pendingText: &pendingText)
        XCTAssertTrue(pendingText.isEmpty, "The valid QR draft must not remain blocked by superseded text")
        XCTAssertTrue(editor.canApply)
        XCTAssertEqual(storage.writes, 0)
        editor.apply()
        XCTAssertEqual(storage.writes, 1)
        XCTAssertEqual(try repository.savedNode(isPrivate: false).parameters(),
                       try AccessLocalV2RayConfigLoader.parseSingleShareURI(scanned))
    }

    func testRejectedCancelledOrStaleScanPreservesPendingText() throws {
        let results: [Result<String, AccessTestNodeError>?] = [nil, .failure(.cameraDenied),
            .success("invalid"), .success(link + "\n" + link)]
        for result in results {
            let storage = Storage()
            let editor = AccessTestNodeEditor(isPrivate: false,
                repository: AccessTestNodeRepository(channel: .dev, storage: storage))
            editor.openProfile()
            var pendingText = link
            editor.finishScan(try XCTUnwrap(editor.beginScan()), result: result, pendingText: &pendingText)
            XCTAssertEqual(pendingText, link)
            XCTAssertFalse(editor.canApply)
            XCTAssertEqual(storage.writes, 0)
        }
        let editor = AccessTestNodeEditor(isPrivate: false,
            repository: AccessTestNodeRepository(channel: .dev, storage: Storage()))
        editor.openProfile()
        let oldScan = try XCTUnwrap(editor.beginScan())
        editor.closeProfile()
        editor.openProfile()
        let active = try XCTUnwrap(editor.beginScan())
        var pendingText = "new text in the current profile"
        editor.finishScan(oldScan, result: .success(link), pendingText: &pendingText)
        XCTAssertEqual(pendingText, "new text in the current profile")
        XCTAssertEqual(editor.scan, active)
        XCTAssertFalse(editor.hasDraft)
    }

    func testOfficialRealityShareWorksForTextAndScanAndRestoresNativeParameters() throws {
        let uri = link.replacingOccurrences(of: "sid=abcd1234",
            with: "sid=&spx=%2Fsynthetic-path&support-x25519mlkem768=true")
        for scanned in [false, true] {
            let storage = Storage()
            let repository = AccessTestNodeRepository(channel: .dev, storage: storage)
            let editor = AccessTestNodeEditor(isPrivate: false, repository: repository)
            editor.openProfile()
            if scanned {
                editor.finishScan(try XCTUnwrap(editor.beginScan()), result: .success(uri))
            } else { editor.preview(uri) }
            XCTAssertTrue(editor.canApply)
            XCTAssertEqual(storage.writes, 0)
            editor.apply()
            XCTAssertEqual(storage.writes, 1)
            let restored = try AccessTestNodeRepository(channel: .dev, storage: storage).savedNode(isPrivate: false).parameters()
            XCTAssertEqual(restored, try AccessLocalV2RayConfigLoader.parseSingleShareURI(uri))
            XCTAssertEqual(restored.shortID, "")
            XCTAssertEqual(restored.spiderX, "/synthetic-path")
        }
    }

    func testCampaignReorderingRequiresAnExactPermutationAndSafeIndependentIdentity() throws {
        let canonical = ["one.example", "two.example", "three.example"]
        let reordered = Data("three.example\none.example\ntwo.example\n".utf8)
        let digest = SHA256.hash(data: reordered).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try AccessDomainCampaignInput.order(reordered, canonical: canonical, digest: digest),
                       ["three.example", "one.example", "two.example"])
        for invalid in ["one.example\none.example\nthree.example\n", "one.example\ntwo.example\n",
                        "one.example\ntwo.example\noutside.example\n", "one.example\ntwo.example\nTHREE.example\n"] {
            let bytes = Data(invalid.utf8)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertThrowsError(try AccessDomainCampaignInput.order(bytes, canonical: canonical, digest: hash))
        }
        XCTAssertThrowsError(try AccessDomainCampaignInput.order(reordered, canonical: canonical, digest: "wrong"))
        XCTAssertTrue(AccessDomainCampaignInput.validID("popularity-20261121-test01-v1"))
        for invalid in ["", "../old", "a/b", "UPPER", String(repeating: "a", count: 65)] {
            XCTAssertFalse(AccessDomainCampaignInput.validID(invalid))
        }
    }

    func testRankedCampaignRequiresAnExplicitDispatchLimit() {
        let count = 5
        XCTAssertNil(AccessDomainCampaignInput.dispatchLimit(nil, hostCount: count, ranked: true))
        XCTAssertEqual(AccessDomainCampaignInput.dispatchLimit(nil, hostCount: count, ranked: false), count)
        XCTAssertEqual(AccessDomainCampaignInput.dispatchLimit("2", hostCount: count, ranked: true), 2)
        for value in ["", "0", "-1", "6", "all"] {
            XCTAssertNil(AccessDomainCampaignInput.dispatchLimit(value, hostCount: count, ranked: true))
        }
    }

    func testRankedResumeRequiresTheExactNonemptyCheckpointAndOrderedReservations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("checkpoint.jsonl")
        let hosts = ["first.invalid", "second.invalid", "third.invalid"]
        func read(_ sha: String?, order: String = "synthetic-order") throws -> AccessDomainCampaignInput.Checkpoint? {
            try AccessDomainCampaignInput.checkpoint(at: file, expectedSHA: sha, dataset: "synthetic-dataset",
                device: "synthetic-device", bundle: "example.invalid.test", runID: "synthetic-run",
                orderSHA: order, hosts: hosts)
        }
        func row(_ host: String) throws -> Data {
            var row = try JSONSerialization.data(withJSONObject: [
                "event": "reserved", "host": host, "dataset": "synthetic-dataset", "device": "synthetic-device",
                "bundle": "example.invalid.test", "campaignID": "synthetic-run", "orderSHA256": "synthetic-order"
            ], options: .sortedKeys)
            row.append(10)
            return row
        }
        let first = try row(hosts[0])
        let second = try row(hosts[1])
        let bytes = first + second
        let sha = AccessDomainCampaignInput.sha256(bytes)
        XCTAssertThrowsError(try read(sha))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try Data().write(to: file)
        XCTAssertThrowsError(try read(AccessDomainCampaignInput.sha256(Data())))
        try bytes.write(to: file)
        XCTAssertThrowsError(try read(nil))
        XCTAssertThrowsError(try read(AccessDomainCampaignInput.sha256(first)))
        XCTAssertThrowsError(try read(sha, order: "other-order"))
        XCTAssertEqual(try read(sha)?.reserved, Set(hosts.prefix(2)))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        for invalid in [second, first + first, Data(bytes.dropLast())] {
            try invalid.write(to: file)
            XCTAssertThrowsError(try read(AccessDomainCampaignInput.sha256(invalid)))
        }
    }

    func testRankedResumeDoesNotDispatchAnExhaustedOrStoppedCheckpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = directory.appendingPathComponent("control")
        let hosts = ["first.invalid", "second.invalid", "third.invalid"]
        let reserved: Set<String> = [hosts[0]]
        XCTAssertEqual(try AccessDomainCampaignInput.pendingHosts(hosts, limit: 2, reserved: reserved,
                                                                  ranked: true, control: control), [hosts[1]])
        XCTAssertTrue(try AccessDomainCampaignInput.pendingHosts(hosts, limit: 1, reserved: reserved,
                                                                  ranked: true, control: control).isEmpty)
        XCTAssertThrowsError(try AccessDomainCampaignInput.pendingHosts(hosts, limit: 1, reserved: Set(hosts.prefix(2)),
                                                                        ranked: true, control: control))
        try Data(" stop\n".utf8).write(to: control)
        XCTAssertTrue(try AccessDomainCampaignInput.pendingHosts(hosts, limit: 2, reserved: reserved,
                                                                  ranked: true, control: control).isEmpty)
    }

    func testCampaignStopControlRejectsUnreadableOrInvalidContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = directory.appendingPathComponent("control")
        let hosts = ["first.invalid"]
        func pending() throws -> [String] {
            try AccessDomainCampaignInput.pendingHosts(hosts, limit: 1, reserved: [], ranked: true, control: control)
        }
        XCTAssertEqual(try pending(), hosts)
        try Data("stop\n".utf8).write(to: control)
        XCTAssertTrue(try pending().isEmpty)
        for bytes in [Data([0xff]), Data(), Data("unexpected".utf8)] {
            try bytes.write(to: control)
            XCTAssertThrowsError(try pending()) { error in
                XCTAssertEqual((error as? CocoaError)?.code, .fileReadCorruptFile)
            }
        }
        try FileManager.default.removeItem(at: control)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false)
        XCTAssertThrowsError(try pending())
        XCTAssertThrowsError(try AccessDomainCampaignInput.stopRequested(at: control))
    }

    func testCampaignSourceMustMatchThePreparedAppAndEmbeddedCore() throws {
        let source = String(repeating: "a", count: 40)
        let other = String(repeating: "b", count: 40)
        let bridge = String(repeating: "c", count: 64)
        func manifest(_ revision: String, kind: String = "ios-embedded-core-build", compiled: String? = nil) throws -> Data {
            var fields: [String: Any] = ["schemaVersion": 1, "kind": kind, "sourceCommit": revision, "bridgeSha256": bridge]
            fields["compiledBridgeSha256"] = compiled
            return try JSONSerialization.data(withJSONObject: fields)
        }
        let core = try manifest(source, compiled: bridge)
        XCTAssertEqual(AccessDomainCampaignInput.sourceSHA(source, prepared: source, tests: source, coreManifest: core), source)
        for request in [nil, "unknown", "abcd", source.uppercased(), other] {
            XCTAssertNil(AccessDomainCampaignInput.sourceSHA(request, prepared: source, tests: source, coreManifest: core))
        }
        XCTAssertNil(AccessDomainCampaignInput.sourceSHA(source, prepared: nil, tests: source, coreManifest: core))
        XCTAssertNil(AccessDomainCampaignInput.sourceSHA(source, prepared: other, tests: source, coreManifest: core))
        XCTAssertNil(AccessDomainCampaignInput.sourceSHA(source, prepared: source, tests: other, coreManifest: core))
        XCTAssertNil(AccessDomainCampaignInput.sourceSHA(source, prepared: source, tests: nil, coreManifest: core))
        XCTAssertNil(AccessDomainCampaignInput.sourceSHA(source, prepared: source, tests: source, coreManifest: nil))
        XCTAssertNil(AccessDomainCampaignInput.sourceSHA(source, prepared: source, tests: source, coreManifest: try manifest(other, compiled: bridge)))
        XCTAssertNil(AccessDomainCampaignInput.sourceSHA(source, prepared: source, tests: source, coreManifest: try manifest(source, kind: "other", compiled: bridge)))
        XCTAssertNil(AccessDomainCampaignInput.sourceSHA(source, prepared: source, tests: source, coreManifest: try manifest(source)))
        XCTAssertNil(AccessDomainCampaignInput.sourceSHA(source, prepared: source, tests: source, coreManifest: try manifest(source, compiled: String(repeating: "d", count: 64))))
    }

    func testMalformedManualRealityInputCannotApplyOverSavedNode() throws {
        let storage = Storage()
        let repository = AccessTestNodeRepository(channel: .alpha, storage: storage)
        let editor = AccessTestNodeEditor(isPrivate: false, repository: repository)
        editor.openProfile()
        editor.preview(link)
        editor.apply()
        let saved = try repository.savedNode(isPrivate: false)
        for invalid in [
            link.replacingOccurrences(of: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", with: "invalid"),
            link.replacingOccurrences(of: "sid=abcd1234", with: "sid=abc"),
            link.replacingOccurrences(of: "#", with: "&fp=unsafe#"),
            link.replacingOccurrences(of: "#", with: "&fp=not-a-native-fingerprint#"),
            link.replacingOccurrences(of: "#", with: "&spx=relative#"),
            link.replacingOccurrences(of: "#", with: "&spx=%2Fbad%25ZZ#"),
            link.replacingOccurrences(of: "#", with: "&spx=%2Fpath%3F%2563%3D1000000000#")
        ] {
            editor.preview(invalid)
            XCTAssertFalse(editor.canApply)
            editor.apply()
            XCTAssertEqual(try repository.savedNode(isPrivate: false).revision, saved.revision)
            XCTAssertEqual(storage.writes, 1)
        }
    }

    func testPreviouslySavedMalformedRealityPathCannotActivateAndCanBeReplaced() throws {
        let storage = Storage()
        let malformed = link.replacingOccurrences(of: "#", with: "&spx=%2Fbad%25ZZ#")
        let parameters = try AccessLocalV2RayConfigLoader.parseShareURI(malformed)
        let saved = AccessTestNodeRecord(parameters)
        storage.value = saved
        let repository = AccessTestNodeRepository(channel: .alpha, storage: storage)
        var revocations = 0
        _ = repository.observeRevocation { revocations += 1 }
        XCTAssertThrowsError(try repository.savedNode(isPrivate: false).parameters())
        XCTAssertThrowsError(try repository.apply(parameters, expectedRevision: saved.revision, isPrivate: false))
        XCTAssertEqual(try repository.revision(isPrivate: false), saved.revision)
        XCTAssertEqual(storage.writes, 0)
        XCTAssertEqual(revocations, 0)

        let editor = AccessTestNodeEditor(isPrivate: false, repository: repository)
        editor.openProfile()
        XCTAssertTrue(editor.hasSavedNode)
        editor.preview(link)
        editor.apply()
        XCTAssertEqual(try repository.savedNode(isPrivate: false).parameters().spiderX, "")
        XCTAssertEqual(storage.writes, 1)
        XCTAssertEqual(revocations, 1)
    }

    func testTwoWindowsCompareSavedRevisionAndFailedStoragePreservesDraft() {
        let storage = Storage()
        let repository = AccessTestNodeRepository(channel: .alpha, storage: storage)
        let first = AccessTestNodeEditor(isPrivate: false, repository: repository)
        let second = AccessTestNodeEditor(isPrivate: false, repository: repository)
        for editor in [first, second] {
            editor.openProfile()
            editor.preview(link)
        }
        storage.failWrite = true
        first.apply()
        XCTAssertTrue(first.hasDraft)
        XCTAssertEqual(first.error, .storageUnavailable)
        XCTAssertFalse(first.hasSavedNode)
        storage.failWrite = false
        first.apply()
        second.apply()
        XCTAssertEqual(storage.writes, 1)
        XCTAssertTrue(second.hasDraft)
        XCTAssertEqual(second.error, .conflict)
        second.discard()
        XCTAssertTrue(second.hasSavedNode)
        XCTAssertFalse(second.canApply)
    }

    func testDirectCommandsAndRestoreNeverTouchRestrictedOrPrivateStorage() async throws {
        let storage = Storage()
        let params = try AccessLocalV2RayConfigLoader.parseSingleShareURI(link)
        storage.value = AccessTestNodeRecord(params)
        for (channel, isPrivate): (AccessInternalOptions?, Bool) in [(nil, false), (.dev, true), (.alpha, true)] {
            let repository = AccessTestNodeRepository(channel: channel, storage: storage)
            XCTAssertFalse(repository.allowsEditing(isPrivate: isPrivate))
            XCTAssertThrowsError(try repository.revision(isPrivate: isPrivate))
            XCTAssertThrowsError(try repository.savedNode(isPrivate: isPrivate))
            XCTAssertThrowsError(try repository.apply(params, expectedRevision: nil, isPrivate: isPrivate))
            XCTAssertThrowsError(try repository.remove(expectedRevision: UUID(), isPrivate: isPrivate))
            let editor = AccessTestNodeEditor(isPrivate: isPrivate, repository: repository)
            editor.openProfile()
            XCTAssertNil(editor.beginScan())
            editor.preview(link)
            editor.apply()
            XCTAssertFalse(editor.hasDraft)
            XCTAssertFalse(editor.hasSavedNode)
            XCTAssertFalse(editor.showsEmptyProfile, "Denied storage is not an empty ordinary profile")
            let core = PageCore(beforeStart: { XCTFail("A denied restore must not start its core") })
            let page = AccessTestNodePage(isPrivate: isPrivate, repository: repository, testingCore: core)
            await page.open(URL(string: "https://example.invalid/private-restore")!)
            XCTAssertNil(page.initialBinding)
            XCTAssertNil(page.webView)
            XCTAssertFalse(core.isRunning)
        }
        XCTAssertEqual(storage.reads, 0)
        XCTAssertEqual(storage.writes, 0)
        XCTAssertEqual(storage.removals, 0)
    }

    func testKeychainStoresNormalizedRecordAndSeparatesChannels() throws {
        let service = "test.access-node." + UUID().uuidString
        let storage = AccessTestNodeKeychain(service: service)
        defer {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service] as CFDictionary)
        }
        let first = AccessTestNodeRepository(channel: .dev, storage: storage)
        let params = try AccessLocalV2RayConfigLoader.parseSingleShareURI(link)
        let revision = try first.apply(params, expectedRevision: nil, isPrivate: false)
        let reopened = AccessTestNodeRepository(channel: .dev, storage: storage)
        XCTAssertEqual(try reopened.revision(isPrivate: false), revision)
        XCTAssertNil(try AccessTestNodeRepository(channel: .alpha, storage: storage).revision(isPrivate: false))

        let record = try XCTUnwrap(storage.read(channel: .dev))
        let serialized = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        XCTAssertFalse(serialized.contains("synthetic-node"))
        XCTAssertFalse(serialized.contains("vless://"))
        XCTAssertThrowsError(try reopened.remove(expectedRevision: UUID(), isPrivate: false))
        XCTAssertEqual(try reopened.revision(isPrivate: false), revision)
        try reopened.remove(expectedRevision: revision, isPrivate: false)
        XCTAssertNil(try reopened.revision(isPrivate: false))
    }

    func testDecodedSyntheticQRCodeMatchesTextAndRejectsMultiplePayloads() throws {
        let generator = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        generator.setValue(Data(link.utf8), forKey: "inputMessage")
        let image = try XCTUnwrap(generator.outputImage).transformed(by: CGAffineTransform(scaleX: 5, y: 5))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: context,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let payloads = detector.features(in: image).map { ($0 as? CIQRCodeFeature)?.messageString }
        let decoded = try AccessTestNodeQRCode.payload(from: payloads).get()
        XCTAssertEqual(try AccessLocalV2RayConfigLoader.parseSingleShareURI(decoded),
                       try AccessLocalV2RayConfigLoader.parseSingleShareURI(link))
        let storage = Storage()
        let editor = AccessTestNodeEditor(isPrivate: false,
            repository: AccessTestNodeRepository(channel: .dev, storage: storage))
        editor.openProfile()
        let scan = try XCTUnwrap(editor.beginScan())
        editor.finishScan(scan, result: AccessTestNodeQRCode.payload(from: payloads))
        XCTAssertTrue(editor.canApply)
        XCTAssertEqual(storage.writes, 0)
        editor.apply()
        XCTAssertEqual(storage.writes, 1)
        XCTAssertThrowsError(try AccessTestNodeQRCode.payload(from: [link, link]).get())
        XCTAssertThrowsError(try AccessTestNodeQRCode.payload(from: []).get())
        XCTAssertThrowsError(try AccessTestNodeQRCode.payload(from: [nil]).get())
    }

    func testNewScanInvalidatesOldDraftAndCorruptRestoreCannotApply() throws {
        let storage = Storage()
        let editor = AccessTestNodeEditor(isPrivate: false,
            repository: AccessTestNodeRepository(channel: .dev, storage: storage))
        editor.openProfile()
        editor.preview(link)
        XCTAssertTrue(editor.canApply)
        let scan = try XCTUnwrap(editor.beginScan())
        editor.finishScan(scan, result: AccessTestNodeQRCode.payload(from: [nil]))
        XCTAssertFalse(editor.canApply)
        editor.apply()
        XCTAssertEqual(storage.writes, 0)

        let record = AccessTestNodeRecord(try AccessLocalV2RayConfigLoader.parseSingleShareURI(link))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        for version: Int? in [nil, 0, 2] {
            json["version"] = version
            XCTAssertThrowsError(try JSONDecoder().decode(AccessTestNodeRecord.self,
                from: JSONSerialization.data(withJSONObject: json)))
        }
    }

    func testPageBindsOneHTTPStoreFromExplicitSavedProfileAndRefusesRestrictedRestore() async throws {
        let storage = Storage()
        let repository = AccessTestNodeRepository(channel: .dev, storage: storage)
        _ = try repository.apply(AccessLocalV2RayConfigLoader.parseSingleShareURI(link),
                                 expectedRevision: nil, isPrivate: false)
        let core = PageCore()
        let page = AccessTestNodePage(isPrivate: false, repository: repository, testingCore: core)
        await page.open(URL(string: "https://example.invalid/single")!)
        XCTAssertTrue(core.isRunning)
        XCTAssertNotNil(page.endpoint)
        XCTAssertEqual(page.webView?.configuration.websiteDataStore.proxyConfigurations.count, 1)
        XCTAssertEqual(page.webView?.configuration.websiteDataStore.proxyConfigurations.first?.allowFailover, false)
        let original = page.webView
        await page.open(URL(string: "https://second.invalid/")!)
        XCTAssertTrue(original === page.webView)
        _ = try repository.apply(AccessLocalV2RayConfigLoader.parseSingleShareURI(link),
                                 expectedRevision: repository.revision(isPrivate: false), isPrivate: false)
        XCTAssertEqual(page.status, "连接暂不可用", "Apply revokes old pages before returning")

        let deniedCore = PageCore()
        let denied = AccessTestNodePage(isPrivate: false, repository: AccessTestNodeRepository(channel: nil, storage: storage),
                                       testingCore: deniedCore)
        await denied.open(URL(string: "https://example.invalid/")!)
        XCTAssertFalse(deniedCore.isRunning)
        XCTAssertNil(denied.webView)
        XCTAssertNil(denied.endpoint)
    }

    func testExplicitSOCKSRequiresAdmissionAndPublishesItsActualTransport() async throws {
        let repository = AccessTestNodeRepository(channel: .dev, storage: Storage())
        _ = try repository.apply(AccessLocalV2RayConfigLoader.parseSingleShareURI(link), expectedRevision: nil, isPrivate: false)
        let rejectedCore = PageCore()
        let rejected = AccessTestNodePage(isPrivate: false, repository: repository, testingCore: rejectedCore,
                                         transport: .socks5, socksAdmitted: false)
        await rejected.open(URL(string: "https://example.invalid/")!)
        XCTAssertFalse(rejectedCore.isRunning)
        XCTAssertNil(rejected.webView)
        let admitted = AccessTestNodePage(isPrivate: false, repository: repository, testingCore: PageCore(),
                                         transport: .socks5, socksAdmitted: true)
        await admitted.open(URL(string: "https://example.invalid/")!)
        XCTAssertEqual(admitted.endpoint?.transport, .socks5)
        XCTAssertNotEqual(admitted.endpoint?.port, 0)
        XCTAssertNotEqual(admitted.endpoint?.port, 1080)
        XCTAssertEqual(admitted.webView?.configuration.websiteDataStore.proxyConfigurations.count, 1)
        XCTAssertEqual(admitted.webView?.configuration.websiteDataStore.proxyConfigurations.first?.allowFailover, false)
        admitted.close()
    }

    func testPageExposesBothWebKitPolicySelectors() {
        let page = AccessTestNodePage(isPrivate: false)
        XCTAssertTrue(page.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")))
        XCTAssertTrue(page.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationResponse:decisionHandler:")))
    }

    func testPreparationTimeoutSurvivesLateCancellationAndFailure() async throws {
        try await assertPreparationFailure(timerDelayed: false, error: CancellationError(), expectTimeout: true)
        try await assertPreparationFailure(timerDelayed: false, error: URLError(.cannotConnectToHost), expectTimeout: true)
    }

    func testExpiredPreparationIsTimedOutBeforeTheDelayedTimerRuns() async throws {
        try await assertPreparationFailure(timerDelayed: true, error: URLError(.cannotConnectToHost), expectTimeout: true)
    }

    func testPreparationFailureBeforeDeadlineIsPreserved() async throws {
        try await assertPreparationFailure(timerDelayed: true, error: URLError(.cannotConnectToHost), expectTimeout: false)
    }

    func testCredentialRestorationConsumesTheAbsolutePreparationDeadline() async throws {
        let storage = Storage()
        let repository = AccessTestNodeRepository(channel: .dev, storage: storage)
        _ = try repository.apply(AccessLocalV2RayConfigLoader.parseSingleShareURI(link),
                                 expectedRevision: nil, isPrivate: false)
        let initialReads = storage.reads
        storage.beforeRead = { Thread.sleep(forTimeInterval: 0.1) }
        let core = PageCore(beforeStart: { XCTFail("An expired credential restore must never start the core") })
        let page = AccessTestNodePage(isPrivate: false, repository: repository, testingCore: core,
                                      preparationTimeout: .milliseconds(40))
        await page.open(URL(string: "https://example.invalid/restore")!)
        XCTAssertEqual(storage.reads, initialReads + 1)
        XCTAssertEqual(page.failureDomain, NSURLErrorDomain)
        XCTAssertEqual(page.failureCode, NSURLErrorTimedOut)
        XCTAssertNil(page.initialBinding)
        XCTAssertNil(page.webView)
        XCTAssertFalse(core.isRunning)
    }

    private func assertPreparationFailure(timerDelayed: Bool, error: any Error, expectTimeout: Bool) async throws {
        let repository = AccessTestNodeRepository(channel: .dev, storage: Storage())
        _ = try repository.apply(AccessLocalV2RayConfigLoader.parseSingleShareURI(link), expectedRevision: nil, isPrivate: false)
        let started = expectation(description: "core started preparing")
        let release = XCTestExpectation(description: "allow core start to fail")
        let timerEntered = expectation(description: "preparation timer received its deadline")
        var actualDeadline: ContinuousClock.Instant?
        let core = PageCore(beforeStart: {
            started.fulfill()
            let result = await XCTWaiter.fulfillment(of: [release], timeout: 3)
            XCTAssertEqual(result, .completed)
            throw error
        })
        let page = AccessTestNodePage(isPrivate: false, repository: repository, testingCore: core,
                                      preparationTimeout: expectTimeout ? .milliseconds(100) : .seconds(15),
                                      waitForPreparationDeadline: { deadline in
            actualDeadline = deadline
            timerEntered.fulfill()
            if timerDelayed { try await Task.sleep(for: .seconds(10)) }
            else { try await ContinuousClock().sleep(until: deadline) }
        })
        let completed = expectation(description: "open returned")
        let opening = Task {
            await page.open(URL(string: "https://example.invalid/prepare")!)
            completed.fulfill()
        }
        defer { opening.cancel(); page.close() }
        await fulfillment(of: [started, timerEntered], timeout: 2)
        if expectTimeout {
            let deadline = try XCTUnwrap(actualDeadline)
            if timerDelayed {
                try await ContinuousClock().sleep(until: deadline)
                XCTAssertNil(page.failureCode, "The timer has not recorded its timeout")
            } else {
                await fulfillment(of: [completed], timeout: 1)
                XCTAssertEqual(page.failureDomain, NSURLErrorDomain)
                XCTAssertEqual(page.failureCode, NSURLErrorTimedOut)
            }
        }
        release.fulfill()
        if timerDelayed { await fulfillment(of: [completed], timeout: 2) }
        if expectTimeout {
            XCTAssertEqual(page.failureDomain, NSURLErrorDomain)
            XCTAssertEqual(page.failureCode, NSURLErrorTimedOut)
        } else {
            let failure = AccessSiteSessionError.prepareFailed("") as NSError
            XCTAssertEqual(page.failureDomain, failure.domain)
            XCTAssertEqual(page.failureCode, failure.code)
        }
        XCTAssertNil(page.initialBinding)
        XCTAssertNil(page.webView)
        XCTAssertFalse(core.isRunning)
    }

    func testPreparationDeadlineReturnsBeforeLateSuccessfulStartAndDisposesIt() async throws {
        let repository = AccessTestNodeRepository(channel: .dev, storage: Storage())
        _ = try repository.apply(AccessLocalV2RayConfigLoader.parseSingleShareURI(link),
                                 expectedRevision: nil, isPrivate: false)
        let started = expectation(description: "native startup blocked")
        let release = XCTestExpectation(description: "release native startup")
        let stopped = expectation(description: "late core stopped by the publisher")
        let core = PageCore(beforeStart: {
            started.fulfill()
            _ = await XCTWaiter.fulfillment(of: [release], timeout: 4)
        }, afterStop: { stopped.fulfill() })
        let page = AccessTestNodePage(isPrivate: false, repository: repository, testingCore: core,
                                      preparationTimeout: .milliseconds(300))
        let returned = expectation(description: "open returned before native startup was released")
        let opening = Task {
            await page.open(URL(string: "https://example.invalid/prepare")!)
            returned.fulfill()
        }
        defer { opening.cancel(); page.close() }
        await fulfillment(of: [started, returned], timeout: 2, enforceOrder: true)
        XCTAssertEqual(page.failureDomain, NSURLErrorDomain)
        XCTAssertEqual(page.failureCode, NSURLErrorTimedOut)
        XCTAssertNil(page.initialBinding)
        release.fulfill()
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertFalse(core.isRunning)
        XCTAssertNil(page.webView)
        XCTAssertNil(page.initialBinding)
        XCTAssertEqual(page.failureCode, NSURLErrorTimedOut)
    }

    func testSupersededNavigationFailuresCannotCloseTheReplacement() throws {
        let page = AccessTestNodePage(isPrivate: false)
        let view = WKWebView()
        let first = try XCTUnwrap(view.loadHTMLString("<p>first</p>", baseURL: URL(string: "https://aegis.invalid/first")))
        let replacement = try XCTUnwrap(view.loadHTMLString("<p>replacement</p>", baseURL: URL(string: "https://aegis.invalid/replacement")))
        page.webView(view, didStartProvisionalNavigation: first)
        page.webView(view, didStartProvisionalNavigation: replacement)
        for error in [URLError(.cancelled), URLError(.cannotConnectToHost)] {
            page.webView(view, didFailProvisionalNavigation: first, withError: error)
            XCTAssertEqual(page.status, "正在加载")
        }
        page.webView(view, didFinish: replacement)
        page.webView(view, didFail: first, withError: URLError(.serverCertificateUntrusted))
        XCTAssertEqual(page.status, "已连接")
        page.webView(view, didFail: replacement, withError: URLError(.cannotConnectToHost))
        XCTAssertEqual(page.status, "连接暂不可用")
    }

    func testPolicyInterruptionAttributionRemainsUnknownWithoutAnObservedDecision() throws {
        let page = AccessTestNodePage(isPrivate: false)
        XCTAssertEqual(page.navigationPolicyObservation, "no-local-rejection-observed")
        let view = WKWebView()
        let navigation = try XCTUnwrap(view.loadHTMLString("<p>policy</p>", baseURL: URL(string: "https://aegis.invalid/policy")))
        page.webView(view, didStartProvisionalNavigation: navigation)
        page.webView(view, didFailProvisionalNavigation: navigation,
                     withError: NSError(domain: "WebKitErrorDomain", code: 102))
        XCTAssertNil(page.localPolicyRejection)
        XCTAssertEqual(page.navigationPolicyObservation, "policy-interruption-unattributed")
        XCTAssertEqual(page.status, "连接暂不可用")
    }

    func testClosingPendingPageCommitsInertDocumentAndReleasesEndpoint() async throws {
        let repository = AccessTestNodeRepository(channel: .dev, storage: Storage())
        _ = try repository.apply(AccessLocalV2RayConfigLoader.parseSingleShareURI(link),
                                 expectedRevision: nil, isPrivate: false)
        let page = AccessTestNodePage(isPrivate: false, repository: repository, testingCore: PageCore())
        await page.open(URL(string: "https://example.invalid/pending")!)
        let view = try XCTUnwrap(page.webView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.addSubview(view)
        view.frame = window.bounds
        window.makeKeyAndVisible()
        defer { view.removeFromSuperview(); window.isHidden = true }
        XCTAssertNotNil(page.endpoint)
        let closeStarted = ContinuousClock.now
        page.close()
        let request = try XCTUnwrap(page.retirementRequestedAt)
        XCTAssertGreaterThanOrEqual(request, closeStarted)
        let deadline = Date().addingTimeInterval(10)
        while page.endpoint != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(page.endpoint, "A proxy-bound pending document must retire before its port is released")
        let commit = try XCTUnwrap(page.retirementCommittedAt)
        XCTAssertGreaterThanOrEqual(commit, request)
        let replacement = try XCTUnwrap(page.retirementNavigation)
        page.webView(view, didCommit: replacement)
        XCTAssertEqual(page.retirementCommittedAt, commit, "The first matching commit is immutable")
        XCTAssertNotNil(page.initialBinding, "Retirement must retain its immutable receipt identity")
        XCTAssertEqual(view.url?.host, "aegis.invalid")
        XCTAssertTrue(view.url?.path.hasPrefix("/retired/") == true)
    }

    func testContentProcessTerminationRequiresInertCommitInsteadOfReplayingTarget() async throws {
        let repository = AccessTestNodeRepository(channel: .dev, storage: Storage())
        _ = try repository.apply(AccessLocalV2RayConfigLoader.parseSingleShareURI(link), expectedRevision: nil, isPrivate: false)
        let core = PageCore()
        let page = AccessTestNodePage(isPrivate: false, repository: repository, testingCore: core)
        await page.open(URL(string: "https://example.invalid/pending")!)
        let view = try XCTUnwrap(page.webView)
        let binding = page.initialBinding
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.addSubview(view); view.frame = window.bounds; window.makeKeyAndVisible()
        defer { view.removeFromSuperview(); window.isHidden = true }
        page.webViewWebContentProcessDidTerminate(WKWebView())
        XCTAssertNotNil(page.endpoint, "Another view cannot revoke this binding")
        XCTAssertNil(page.retirementRequestedAt)
        page.webViewWebContentProcessDidTerminate(view)
        let request = try XCTUnwrap(page.retirementRequestedAt)
        XCTAssertEqual(page.failureDomain, WKError.errorDomain)
        XCTAssertEqual(page.failureCode, WKError.Code.webContentProcessTerminated.rawValue)
        XCTAssertNotNil(page.endpoint, "Process notification alone cannot release the port")
        let deadline = Date().addingTimeInterval(10)
        while page.endpoint != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(page.endpoint)
        XCTAssertEqual(page.initialBinding, binding)
        XCTAssertTrue(view.url?.path.hasPrefix("/retired/") == true)
        XCTAssertTrue(page.retirementEvents.contains("replacement-committed"))
#if DEBUG
        let commit = try XCTUnwrap(page.retirementCommittedAt)
        var checkpoints: [AccessTestNodeDeviceTests.RetirementCheckpoint] = []
        let retired = try await AccessTestNodeDeviceTests.observeRetirement(page) { checkpoints.append($0) }
        XCTAssertTrue(retired)
        XCTAssertEqual(page.retirementRequestedAt, request)
        let elapsed = request.duration(to: commit).components
        XCTAssertEqual(checkpoints.first?.commitSeconds, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(checkpoints.first?.commitSeconds), 0)
#endif
    }

    func testInterruptedRetirementRequiresFreshLocalCommitAndKeepsTheBinding() async throws {
        let repository = AccessTestNodeRepository(channel: .dev, storage: Storage())
        _ = try repository.apply(AccessLocalV2RayConfigLoader.parseSingleShareURI(link), expectedRevision: nil, isPrivate: false)
        let page = AccessTestNodePage(isPrivate: false, repository: repository, testingCore: PageCore())
        await page.open(URL(string: "https://example.invalid/pending")!)
        let view = try XCTUnwrap(page.webView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.addSubview(view); view.frame = window.bounds; window.makeKeyAndVisible()
        defer { view.removeFromSuperview(); window.isHidden = true }
        page.close()
        let interrupted = try XCTUnwrap(page.retirementNavigation)
        view.stopLoading()
        // Inject a cancellation for the exact replacement, then deliver its stale
        // commit before another actor turn. Neither callback is a retirement ack.
        page.webView(view, didFailProvisionalNavigation: interrupted, withError: URLError(.cancelled))
        page.webView(view, didCommit: interrupted)
        XCTAssertNotNil(page.endpoint, "An interrupted replacement cannot release the binding")
        XCTAssertNil(page.retirementCommittedAt)
        let deadline = Date().addingTimeInterval(10)
        while page.endpoint != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(page.endpoint, "Only a fresh local replacement commit may release the binding")
        XCTAssertTrue(page.retirementEvents.contains("replacement-retry-scheduled"))
        XCTAssertTrue(view.url?.path.hasPrefix("/retired/") == true)
    }

    func testCompetingLocalNavigationCannotStrandTheRetirementReplacement() async throws {
        let repository = AccessTestNodeRepository(channel: .dev, storage: Storage())
        _ = try repository.apply(AccessLocalV2RayConfigLoader.parseSingleShareURI(link), expectedRevision: nil, isPrivate: false)
        let page = AccessTestNodePage(isPrivate: false, repository: repository, testingCore: PageCore())
        await page.open(URL(string: "https://example.invalid/pending")!)
        let view = try XCTUnwrap(page.webView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.addSubview(view); view.frame = window.bounds; window.makeKeyAndVisible()
        defer { view.removeFromSuperview(); window.isHidden = true }
        page.close()
        // A real second WebKit action overtakes the pending inert load. This is
        // local about:blank, never a second request to the original target.
        _ = view.load(URLRequest(url: URL(string: "about:blank")!))
        XCTAssertNotNil(page.endpoint)
        let deadline = Date().addingTimeInterval(10)
        while page.endpoint != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(page.endpoint)
        XCTAssertTrue(page.retirementEvents.contains("denied-about-main"))
        XCTAssertEqual(page.retirementEvents.filter { $0 == "replacement-retry-scheduled" }.count, 1)
        XCTAssertTrue(page.retirementEvents.contains("replacement-committed"))
        XCTAssertTrue(view.url?.path.hasPrefix("/retired/") == true)
    }

    private final class PageCore: AccessEmbeddedCoreControlling, @unchecked Sendable {
        let running = Mutex(false)
        private let beforeStart: (@MainActor () async throws -> Void)?
        private let afterStop: (@MainActor () -> Void)?
        let startedConfig = Mutex<Data?>(nil)
        init(beforeStart: (@MainActor () async throws -> Void)? = nil, afterStop: (@MainActor () -> Void)? = nil) {
            self.beforeStart = beforeStart
            self.afterStop = afterStop
        }
        var isRunning: Bool { running.withLock { $0 } }
        func start(configData: Data) async throws {
            if let beforeStart { try await beforeStart() }
            startedConfig.withLock { $0 = configData }
            running.withLock { $0 = true }
        }
        func stop() async {
            running.withLock { $0 = false }
            if let afterStop { await afterStop() }
        }
        func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
            throw URLError(.cannotConnectToHost)
        }
    }

    private final class Storage: AccessTestNodeStoring {
        var value: AccessTestNodeRecord?
        var encodedValue: Data?
        var reads = 0
        var writes = 0
        var removals = 0
        var failWrite = false
        var beforeRead: (() -> Void)?

        func read(channel: AccessInternalOptions) throws -> AccessTestNodeRecord? {
            reads += 1
            beforeRead?()
            if let encodedValue { return try JSONDecoder().decode(AccessTestNodeRecord.self, from: encodedValue) }
            return value
        }

        func revision(channel: AccessInternalOptions) throws -> UUID? {
            if let encodedValue { return try AccessTestNodeRecord.storedRevision(in: encodedValue) }
            return try read(channel: channel)?.revision
        }

        func write(_ record: AccessTestNodeRecord, channel: AccessInternalOptions) throws {
            if failWrite { throw AccessTestNodeError.storageUnavailable }
            writes += 1
            encodedValue = nil
            value = record
        }

        func remove(channel: AccessInternalOptions) throws {
            removals += 1
            encodedValue = nil
            value = nil
        }
    }
}

enum AccessDomainCampaignInput {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        }
    }

    static func order(_ data: Data, canonical: [String], digest: String) throws -> [String] {
        guard sha256(data) == digest, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let hosts = text.split(separator: "\n").map(String.init)
        guard hosts.count == canonical.count, Set(hosts).count == hosts.count,
              Set(hosts) == Set(canonical) else { throw CocoaError(.fileReadCorruptFile) }
        return hosts
    }

    static func dispatchLimit(_ value: String?, hostCount: Int, ranked: Bool) -> Int? {
        guard hostCount > 0 else { return nil }
        guard let value else { return ranked ? nil : hostCount }
        guard let count = Int(value), (1...hostCount).contains(count) else { return nil }
        return count
    }

    static func sourceSHA(_ requested: String?, prepared: String?, tests: String?, coreManifest: Data?) -> String? {
        guard let requested, requested.utf8.count == 40,
              requested.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              requested == prepared, requested == tests, let coreManifest,
              let manifest = (try? JSONSerialization.jsonObject(with: coreManifest)) as? [String: Any],
              manifest["schemaVersion"] as? Int == 1,
              manifest["kind"] as? String == "ios-embedded-core-build",
              let bridge = manifest["compiledBridgeSha256"] as? String, bridge.utf8.count == 64,
              bridge.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              manifest["bridgeSha256"] as? String == bridge,
              manifest["sourceCommit"] as? String == requested else { return nil }
        return requested
    }

    static func installedSourceSHA(_ requested: String?) -> String? {
        let coreManifest = Bundle(for: AccessEmbeddedCoreAdapter.self)
            .url(forResource: "embedded-core-build", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
        let key = "AegisPreparedSourceCommit"
        return sourceSHA(requested, prepared: Bundle.main.object(forInfoDictionaryKey: key) as? String,
                         tests: Bundle(for: AccessTestNodeEditorTests.self).object(forInfoDictionaryKey: key) as? String,
                         coreManifest: coreManifest)
    }

    static func pendingHosts(_ hosts: [String], limit: Int, reserved: Set<String>, ranked: Bool,
                             control: URL) throws -> [String] {
        guard !ranked || reserved.count <= limit else { throw CocoaError(.fileReadCorruptFile) }
        guard try !stopRequested(at: control) else { return [] }
        return hosts.prefix(limit).filter { !reserved.contains($0) }
    }

    static func stopRequested(at control: URL) throws -> Bool {
        let bytes: Data
        do { bytes = try Data(contentsOf: control) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
        guard let command = String(data: bytes, encoding: .utf8),
              command.trimmingCharacters(in: .whitespacesAndNewlines) == "stop" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return true
    }

    struct Checkpoint {
        let bytes: Data
        let reserved: Set<String>
    }

    static func checkpoint(at file: URL, expectedSHA: String?, dataset: String, device: String, bundle: String,
                           runID: String?, orderSHA: String?, hosts: [String]) throws -> Checkpoint? {
        let bytes: Data
        do { bytes = try Data(contentsOf: file) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile && runID == nil && expectedSHA == nil {
            return nil
        }
        if runID != nil || expectedSHA != nil {
            guard !bytes.isEmpty, sha256(bytes) == expectedSHA else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        guard let text = String(data: bytes, encoding: .utf8), bytes.isEmpty || bytes.last == 10 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let validHosts = Set(hosts)
        var reserved = Set<String>()
        for line in text.split(separator: "\n") {
            guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["dataset"] as? String == dataset, record["device"] as? String == device,
                  record["bundle"] as? String == bundle, record["campaignID"] as? String == runID,
                  record["orderSHA256"] as? String == orderSHA else { throw CocoaError(.fileReadCorruptFile) }
            if record["event"] as? String == "reserved" {
                guard let host = record["host"] as? String, validHosts.contains(host),
                      runID == nil || (reserved.count < hosts.count && host == hosts[reserved.count]),
                      reserved.insert(host).inserted else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
        if runID != nil && reserved.isEmpty { throw CocoaError(.fileReadCorruptFile) }
        return Checkpoint(bytes: bytes, reserved: reserved)
    }
}

#if DEBUG
private enum AccessProbeReceiptKind: String, CaseIterable {
    case controlledPath = "ios208-controlled-path"
    case socksAdmission = "ios208-socks-admission"

    func write(_ receipt: [String: Any], attempt: UUID, in documents: URL) throws -> URL {
        guard JSONSerialization.isValidJSONObject(receipt) else { throw CocoaError(.propertyListWriteInvalid) }
        let bytes = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
        let directory = documents.appendingPathComponent("\(rawValue)-\(attempt.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("receipt.json")
        try bytes.write(to: file, options: .atomic)
        return file
    }

    @MainActor
    func writeAndAttach(_ receipt: [String: Any], attempt: UUID, to test: XCTestCase) {
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            let file = try write(receipt, attempt: attempt, in: documents)
            let attachment = XCTAttachment(contentsOfFile: file)
            attachment.name = "\(rawValue)-\(attempt.uuidString)"
            attachment.lifetime = .keepAlways
            test.add(attachment)
        } catch {
            let failure = error as NSError
            XCTFail("\(rawValue) receipt \(attempt.uuidString) failed: \(failure.domain) \(failure.code)")
        }
    }
}

@MainActor
final class AccessTestNodeDeviceTests: XCTestCase {
    func testPhysicalDomainCampaign() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("This campaign requires its designated physical device")
#else
        let env = ProcessInfo.processInfo.environment
        let device = "ios-device-2d62695fc7"
        guard env["AEGIS_TEST_CAMPAIGN_DEVICE"] == device,
              env.keys.contains("AEGIS_TEST_AUTHORIZED_NODE"),
              let input = Bundle.main.url(forResource: "domains", withExtension: "txt") else {
            throw XCTSkip("Explicit physical campaign inputs are required")
        }
        var system = utsname()
        uname(&system)
        let model = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        guard model == "iPhone14,3" else { XCTFail("Wrong physical device model"); return }
        guard let bundleID = Bundle.main.bundleIdentifier,
              let sourceSHA = AccessDomainCampaignInput.installedSourceSHA(env["AEGIS_TEST_SOURCE_SHA"]) else {
            XCTFail("Campaign source identity does not match the installed app, tests and embedded core"); return
        }
        let data = try Data(contentsOf: input)
        let digest = AccessDomainCampaignInput.sha256(data)
        guard digest == "84a004adf2537fde3befb724fe77512cf3a4acb1df8ec350cd898a6cf8428374" else {
            XCTFail("Campaign input digest differs"); return
        }
        var hosts = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        guard hosts.count == 4372, Set(hosts).count == hosts.count else { XCTFail("Campaign input is incomplete"); return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let runID = env["AEGIS_TEST_CAMPAIGN_RUN_ID"]
        let orderDigest = env["AEGIS_TEST_CAMPAIGN_ORDER_SHA256"]
        if let runID {
            guard AccessDomainCampaignInput.validID(runID), let orderDigest else {
                XCTFail("Independent campaign identity or order digest missing"); return
            }
            let ordered = try Data(contentsOf: documents.appendingPathComponent("ios208-" + runID + ".domains.txt"))
            hosts = try AccessDomainCampaignInput.order(ordered, canonical: hosts, digest: orderDigest)
        } else if orderDigest != nil { XCTFail("Order requires an independent campaign identity"); return }
        guard let limit = AccessDomainCampaignInput.dispatchLimit(
            env["AEGIS_TEST_CAMPAIGN_LIMIT"], hostCount: hosts.count, ranked: runID != nil
        ) else { XCTFail("Invalid or missing campaign phase limit"); return }
        let file = documents.appendingPathComponent(runID.map { "ios208-" + $0 + "-dispatch.jsonl" }
            ?? "ios208-domain-dispatch.jsonl")
        let checkpoint = try AccessDomainCampaignInput.checkpoint(at: file,
            expectedSHA: env["AEGIS_TEST_CAMPAIGN_LEDGER_SHA256"], dataset: digest, device: device,
            bundle: bundleID, runID: runID, orderSHA: orderDigest, hosts: hosts)
        var reserved = checkpoint?.reserved ?? []
        let control = file.deletingLastPathComponent().appendingPathComponent("ios208-campaign-control")
        let pending = try AccessDomainCampaignInput.pendingHosts(hosts, limit: limit, reserved: reserved,
                                                                ranked: runID != nil, control: control)
        guard !pending.isEmpty else { return }
        let node = try XCTUnwrap(env["AEGIS_TEST_AUTHORIZED_NODE"])
        let repository = AccessTestNodeRepository.shared
        guard repository.allowsEditing(isPrivate: false) else { XCTFail("Native admission denied"); return }
        let parameters = try AccessLocalV2RayConfigLoader.parseSingleShareURI(node)
        // Ranked execution always resumes a supplied checkpoint. The legacy
        // unranked entry may still initialize its own file.
        guard try !AccessDomainCampaignInput.stopRequested(at: control) else { return }
        if checkpoint == nil { try Data().write(to: file, options: .withoutOverwriting) }
        let output = try FileHandle(forUpdating: file)
        defer { try? output.close() }
        guard try (output.readToEnd() ?? Data()) == (checkpoint?.bytes ?? Data()) else {
            XCTFail("Dispatch ledger changed before opening the campaign"); return
        }
        try output.seekToEnd()
        guard try !AccessDomainCampaignInput.stopRequested(at: control) else { return }
        if (try? repository.savedNode(isPrivate: false).parameters()) != parameters {
            _ = try repository.apply(parameters, expectedRevision: repository.revision(isPrivate: false), isPrivate: false)
        }
        func append(_ item: [String: Any]) throws {
            var record = item
            record["dataset"] = digest
            record["device"] = device
            record["bundle"] = bundleID
            record["sourceSHA"] = sourceSHA
            record["campaignID"] = runID
            record["orderSHA256"] = orderDigest
            record["nodeInputSHA256"] = SHA256.hash(data: Data(node.utf8)).map { String(format: "%02x", $0) }.joined()
            record["os"] = ProcessInfo.processInfo.operatingSystemVersionString
            record["time"] = Date().timeIntervalSince1970
            var bytes = try JSONSerialization.data(withJSONObject: record, options: .sortedKeys)
            bytes.append(10)
            try output.write(contentsOf: bytes)
            try output.synchronize()
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let pathState = Mutex((label: "unknown", reachable: false, reported: false))
        let monitor = NWPathMonitor()
        let network: String = await withCheckedContinuation { continuation in
            monitor.pathUpdateHandler = { path in
                let label = path.usesInterfaceType(.wifi) ? "wifi" :
                    path.usesInterfaceType(.cellular) ? "cellular" :
                    path.usesInterfaceType(.wiredEthernet) ? "wired" : "other"
                let first = pathState.withLock { state in
                    let first = !state.reported
                    state = (label, path.status == .satisfied, true)
                    return first
                }
                if first { continuation.resume(returning: label) }
            }
            monitor.start(queue: DispatchQueue(label: "ios208-campaign-network"))
        }
        defer { monitor.cancel() }
        guard try !AccessDomainCampaignInput.stopRequested(at: control) else { return }
        try append(["event":"network", "interface":network])
        var preparationFailures = AccessCampaignPreparationFailureStreak()
        var consecutiveNetworkFailures = 0
        for host in pending {
            if try AccessDomainCampaignInput.stopRequested(at: control) {
                try append(["event":"checkpoint", "reservedCount":reserved.count])
                return
            }
            let network = pathState.withLock { ($0.label, $0.reachable) }
            guard network.1 else {
                try append(["event":"checkpoint", "reason":"network-unavailable", "reservedCount":reserved.count])
                return
            }
            let attempt = UUID().uuidString
            try append(["event":"reserved", "host":host, "attempt":attempt, "network":network.0])
            reserved.insert(host)
            guard let url = URL(string: "https://" + host + "/") else { XCTFail("Invalid fixed hostname"); return }
            let page = AccessTestNodePage(isPrivate: false, singleNavigation: true)
            await page.open(url)
            if let view = page.webView { view.frame = window.bounds; window.addSubview(view) }
            let deadline = Date().addingTimeInterval(20)
            while page.status == "正在加载", Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            let timedOut = page.status == "正在加载"
            let documentDigest = !timedOut && page.status == "已连接"
                ? await Self.documentPrefixDigest(page.webView) : ""
            try append(["event":"result", "host":host, "attempt":attempt,
                        "state":timedOut ? "timeout" : page.status,
                        "errorDomain":page.failureDomain ?? "", "errorCode":page.failureCode ?? 0,
                        "httpStatus":page.httpStatus ?? 0, "documentPrefixSHA256":documentDigest,
                        "initialHTTPStatus":page.initialHTTPStatus ?? 0,
                        "initialResponseObserved":page.initialHTTPStatus != nil,
                        "serverRedirectCount":page.serverRedirectCount,
                        "navigationPolicy":page.navigationPolicyObservation,
                        "localPolicyRejection":page.localPolicyRejection ?? "",
                        "endpoint":page.initialBinding?.identity ?? "", "generation":page.initialBinding?.generation ?? 0,
                        "port":page.initialBinding?.port ?? 0,
                        "phase":page.initialBinding == nil ? "preparation" : "navigation",
                        "actualProtocol":page.initialBinding.map { $0.transport == .socks5 ? "socks5" : "http" } ?? "unbound",
                        "network":network.0])
            consecutiveNetworkFailures = timedOut || page.failureDomain == NSURLErrorDomain ? consecutiveNetworkFailures + 1 : 0
            let preparationLimitReached = preparationFailures.observe(navigationIssued: page.timeline.instant(.loadIssued) != nil)
            let retired = try await Self.observeRetirement(page) { checkpoint in
                var row: [String: Any] = ["event":checkpoint.supplement ? "retirement-supplement" : "retirement",
                    "host":host, "attempt":attempt, "retired":checkpoint.confirmed,
                    "observationSeconds":checkpoint.observationSeconds, "events":page.retirementEvents]
                row["commitSeconds"] = checkpoint.commitSeconds
                try append(row)
            }
            guard retired else { XCTFail("Old document retirement unconfirmed; campaign stopped"); return }
            page.webView?.removeFromSuperview()
            guard !preparationLimitReached else { XCTFail("Repeated preparation failures; campaign stopped"); return }
            if consecutiveNetworkFailures >= 10 {
                try append(["event":"checkpoint", "reason":"consecutive-network-failures", "reservedCount":reserved.count])
                return
            }
        }
        try append(["event":"checkpoint", "reason":"phase-complete", "phaseLimit":limit, "reservedCount":reserved.count])
#endif

    }

    /// The initial observation and eventual acknowledgement are separate facts.
    /// Keep the old view mounted and its port owned until the exact inert commit.
    /// Never retry the target or release anything to make a deadline appear green.
    fileprivate static func observeRetirement(
        _ page: AccessTestNodePage,
        afterClose: () async throws -> Void = {},
        checkpoint: (RetirementCheckpoint) throws -> Void
    ) async throws -> Bool {
        page.close()
        let started = try XCTUnwrap(page.retirementRequestedAt)
        try await afterClose()
        return try await observeRetirement(started: started, hasBoundDocument: page.initialBinding != nil,
            committedAt: { page.retirementCommittedAt }, checkpoint: checkpoint)
    }

    fileprivate struct RetirementCheckpoint {
        let supplement: Bool
        let confirmed: Bool
        let observationSeconds: TimeInterval
        let commitSeconds: TimeInterval?
    }

    fileprivate static func observeRetirement(
        started: ContinuousClock.Instant, hasBoundDocument: Bool,
        committedAt: () -> ContinuousClock.Instant?,
        now: () -> ContinuousClock.Instant = { .now },
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(50)) },
        checkpoint: (RetirementCheckpoint) throws -> Void
    ) async throws -> Bool {
        func seconds(_ instant: ContinuousClock.Instant) -> TimeInterval {
            let elapsed = started.duration(to: instant).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
        for (index, budget) in [Duration.seconds(5), .seconds(10)].enumerated() {
            let cutoff = started.advanced(by: budget)
            while hasBoundDocument, committedAt() == nil, now() < cutoff { try await pause() }
            let commit = committedAt().flatMap { $0 >= started ? $0 : nil }
            let confirmed = !hasBoundDocument || commit.map { $0 <= cutoff } == true
            try checkpoint(RetirementCheckpoint(supplement: index > 0, confirmed: confirmed,
                observationSeconds: seconds(now()), commitSeconds: commit.map(seconds)))
            if confirmed { return true }
        }
        return false
    }

    /// Observation must not hold up the next checkpoint when WebContent stops responding.
    private static func documentPrefixDigest(_ view: WKWebView?) async -> String {
        guard let view else { return "" }
        return await withCheckedContinuation { continuation in
            let result = DocumentDigestResult(continuation)
            view.evaluateJavaScript("document.documentElement.outerHTML.slice(0, 65536)") { value, _ in
                let text = value as? String
                Task { @MainActor in result.finish(text) }
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                result.finish(nil)
            }
        }
    }

    private final class DocumentDigestResult {
        var continuation: CheckedContinuation<String, Never>?
        init(_ continuation: CheckedContinuation<String, Never>) { self.continuation = continuation }
        func finish(_ text: String?) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: text.map { SHA256.hash(data: Data($0.utf8))
                .map { String(format: "%02x", $0) }.joined() } ?? "")
        }
    }

    /// Explicit operator-supplied inputs only. Never uses any member of the domain campaign as a probe.
    func testAuthorizedAppPath() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment.keys.contains("AEGIS_TEST_AUTHORIZED_NODE"),
              let rawURL = environment["AEGIS_TEST_CONTROLLED_URL"], let url = URL(string: rawURL) else {
            throw XCTSkip("Explicit authorized node and independent controlled URL are required")
        }
        let attempt = UUID()
        var receipt: [String: Any] = [
            "attempt": attempt.uuidString,
            "destination": Self.controlledPathDestination(),
            "nonce": URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "nonce" })?.value ?? "",
            "state": "probe-incomplete"
        ]
        defer { AccessProbeReceiptKind.controlledPath.writeAndAttach(receipt, attempt: attempt, to: self) }
        guard let sourceSHA = AccessDomainCampaignInput.installedSourceSHA(environment["AEGIS_TEST_SOURCE_SHA"]) else {
            receipt["state"] = "invalid-source-identity"
            XCTFail("Controlled path requires matching installed app, test and embedded core source identity")
            return
        }
        receipt["sourceSHA"] = sourceSHA
        guard let destination = Self.controlledDestination(url) else {
            receipt["state"] = "invalid-controlled-destination"
            XCTFail("An HTTPS controlled URL with a valid port is required")
            return
        }
        receipt["requestedUpstreamPort"] = destination.port
        guard let preference = Self.requestedTransport(environment["AEGIS_TEST_LOCAL_TRANSPORT"]) else {
            receipt["state"] = "invalid-requested-transport"
            XCTFail("Invalid explicit controlled-probe transport")
            return
        }
        receipt["requestedTransport"] = preference.rawValue
        let capabilityOverride: Bool? = environment["AEGIS_TEST_FORCE_SOCKS_UNADMITTED"] == "1" ? false : nil
        let expectedTransport = try preference.select(socksAdmitted: capabilityOverride ?? AccessInternalSOCKSAdmission.current)
        let repository = AccessTestNodeRepository.shared
        guard repository.allowsEditing(isPrivate: false) else {
            XCTFail("Native internal channel admission rejected this package")
            return
        }
        let editor = AccessTestNodeEditor(isPrivate: false, repository: repository)
        editor.openProfile()
        editor.preview(try XCTUnwrap(environment["AEGIS_TEST_AUTHORIZED_NODE"]))
        guard editor.canApply else { XCTFail("Authorized node did not produce a valid native draft"); return }
        editor.apply()
        guard editor.error == nil, editor.hasSavedNode else { XCTFail("Native Apply did not save the authorized node"); return }
        let core = try ObservedCore(mainHost: destination.host)
        let singleNavigation = environment["AEGIS_TEST_SINGLE_NAVIGATION"] == "1"
        let expectPolicyBlock = environment["AEGIS_TEST_EXPECT_POLICY_BLOCK"] == "1"
        let page = AccessTestNodePage(isPrivate: false, repository: repository, testingCore: core,
                                     singleNavigation: singleNavigation,
                                     transport: preference, socksAdmitted: capabilityOverride)
        defer { receipt["dnsObservation"] = core.observation }
        defer { page.close() }
        await page.open(url)
        receipt.merge(Self.bindingReceiptFields(selected: page.selectedTransport, binding: page.initialBinding)) { _, new in new }
        receipt["state"] = page.status
        receipt["failureDomain"] = page.failureDomain
        receipt["failureCode"] = page.failureCode
        guard let binding = page.initialBinding, binding.transport == expectedTransport,
              page.selectedTransport == expectedTransport else {
            XCTFail("The controlled path did not bind the selected transport")
            return
        }
        guard let webView = page.webView else { XCTFail("Authorized publisher did not bind a DataStore"); return }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.addSubview(webView)
        webView.frame = window.bounds
        window.makeKeyAndVisible()
        defer { page.close(); window.isHidden = true }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let expectedPath = environment["AEGIS_TEST_EXPECT_FINAL_PATH"]
        while (page.status == "正在加载" || expectedPath.map { webView.url?.path != $0 } == true), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        if singleNavigation { try await Task.sleep(for: .seconds(1)) }
        receipt["singleNavigation"] = singleNavigation
        receipt["state"] = page.status
        receipt["failureDomain"] = page.failureDomain ?? ""
        receipt["failureCode"] = page.failureCode
        receipt["navigationPolicy"] = page.navigationPolicyObservation
        receipt["localPolicyRejection"] = page.localPolicyRejection ?? ""
        receipt["initialHTTPStatus"] = page.initialHTTPStatus ?? 0
        receipt["initialResponseObserved"] = page.initialHTTPStatus != nil
        receipt["serverRedirectCount"] = page.serverRedirectCount
        var callbackInconclusive = false
        if expectPolicyBlock {
            let expectedPolicy = environment["AEGIS_TEST_EXPECT_POLICY_REASON"] ?? "additional-top-level-navigation"
            XCTAssertEqual(page.localPolicyRejection, expectedPolicy)
            XCTAssertEqual(page.navigationPolicyObservation, expectedPolicy)
            if expectedPolicy == "additional-top-level-navigation" {
                XCTAssertEqual(page.failureDomain, "AdditionalTopLevelNavigation")
            }
            XCTAssertEqual(page.status, "连接暂不可用")
        } else {
            XCTAssertEqual(page.status, "已连接", "Controlled page did not finish through its bound profile")
            XCTAssertNotNil(page.endpoint)
            let expectedStatus = Int(environment["AEGIS_TEST_EXPECT_HTTP_STATUS"] ?? "200") ?? 200
            XCTAssertEqual(page.httpStatus, expectedStatus)
            if let expectedPath { XCTAssertEqual(webView.url?.path, expectedPath) }
            let nonce = try XCTUnwrap(receipt["nonce"] as? String)
            XCTAssertFalse(nonce.isEmpty)
            let observation = await AccessPhysicalSOCKSAdmissionTests.observeNonce(
                until: min(deadline, ContinuousClock.now.advanced(by: .seconds(2)))
            ) { finish in
                webView.callAsyncJavaScript("return document.documentElement.textContent.includes(nonce);",
                    arguments: ["nonce": nonce], in: nil, in: .page, completionHandler: { result in
                    finish((try? result.get()) as? Bool)
                })
            }
            receipt["nonceObservation"] = observation.rawValue
            receipt["documentContainsNonce"] = observation == .matched
            callbackInconclusive = observation == .timedOut
            XCTAssertEqual(observation, .matched)
        }
        receipt["httpStatus"] = page.httpStatus
        XCTAssertNotEqual(binding.port, 0)
        if binding.transport == .socks5 { XCTAssertNotEqual(binding.port, 1080) }
        XCTAssertEqual(webView.configuration.websiteDataStore.proxyConfigurations.count, 1)
        XCTAssertEqual(webView.configuration.websiteDataStore.proxyConfigurations.first?.allowFailover, false)
        let normalCloseProbe = environment["AEGIS_TEST_NORMAL_CLOSE_PROBE"] == "1" && !callbackInconclusive
        var closeSession: URLSession?
        var oldFlow: LocalProxyPeer?
        defer { closeSession?.invalidateAndCancel(); oldFlow?.cancel() }
        if normalCloseProbe {
            XCTAssertEqual(environment["AEGIS_TEST_BUSY_CONTENT_BEFORE_CLOSE"], "1")
            let config = URLSessionConfiguration.ephemeral
            config.proxyConfigurations = webView.configuration.websiteDataStore.proxyConfigurations
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.waitsForConnectivity = false
            config.timeoutIntervalForRequest = 3
            let session = URLSession(configuration: config)
            closeSession = session
            let (data, response) = try await session.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(receipt["nonce"] as? String ?? "missing"))
            let peer = LocalProxyPeer(port: try XCTUnwrap(page.initialBinding?.port))
            oldFlow = peer
            let outcome = await peer.connect(host: destination.host, upstreamPort: destination.port, transport: binding.transport)
            receipt["oldProxyCONNECTOutcome"] = outcome.rawValue
            guard outcome == .admitted else { XCTFail("Old probe did not establish CONNECT: \(outcome.rawValue)"); return }
            receipt["normalCloseProbe"] = true
        }
        if let target = environment["AEGIS_TEST_REVOKED_URL"], !normalCloseProbe, !callbackInconclusive {
            await core.stop()
            receipt["coreStopped"] = !core.isRunning
            let observation = await Self.observeRevokedFetch(
                until: ContinuousClock.now.advanced(by: .seconds(3)),
                retirementCommittedAt: { page.retirementCommittedAt }
            ) { finish in
                webView.callAsyncJavaScript(
                    "return await fetch(target, {cache: 'no-store'}).then(() => 'received').catch(() => 'blocked');",
                    arguments: ["target": target], in: nil, in: .page, completionHandler: { result in
                    switch result {
                    case .success(let value): finish(value as? String ?? "unknown")
                    case .failure: finish(nil)
                    }
                })
            }
            receipt["revokedFetch"] = observation.rawValue
            switch observation {
            case .documentRetired, .blocked:
                break
            case .timedOut, .evaluationFailed, .unknown:
                callbackInconclusive = true
                XCTFail("Revoked fetch is inconclusive: \(observation.rawValue)")
            case .received:
                XCTFail("Stopped protection must not fall back to direct networking")
            }
        }
        if callbackInconclusive { receipt["state"] = "probe-inconclusive" }
        let busyStarted = XCTestExpectation(description: "controlled WebContent busy loop started")
        let busy = RetirementSignal { busyStarted.fulfill() }
        let probeBusyContent = environment["AEGIS_TEST_BUSY_CONTENT_BEFORE_CLOSE"] == "1" && !callbackInconclusive
        if probeBusyContent {
            webView.configuration.userContentController.add(busy, name: "aegisRetirementSignal")
            let pendingNavigation = environment["AEGIS_TEST_RETIREMENT_RACE"] == "1"
                ? "window.location.replace('about:blank');" : ""
            webView.evaluateJavaScript("window.webkit.messageHandlers.aegisRetirementSignal.postMessage('started'); const until = performance.now()+8000; while(performance.now()<until){}; " + pendingNavigation + " window.webkit.messageHandlers.aegisRetirementSignal.postMessage('ended');", completionHandler: nil)
            receipt["retirementPendingNavigationProbe"] = !pendingNavigation.isEmpty
            await fulfillment(of: [busyStarted], timeout: 2)
        }
        defer { if probeBusyContent { webView.configuration.userContentController.removeScriptMessageHandler(forName: "aegisRetirementSignal") } }
        if normalCloseProbe {
            receipt["coreRunningBeforeProductClose"] = core.isRunning
            XCTAssertTrue(core.isRunning)
        }
        var observations: [[String: Any]] = []
        let retired = try await Self.observeRetirement(page, afterClose: {
            if normalCloseProbe {
                let port = try XCTUnwrap(page.initialBinding?.port)
                receipt["endpointHeldDuringCloseFence"] = page.endpoint != nil
                receipt["portHeldDuringCloseFence"] = Self.portIsOwned(port)
                XCTAssertNotNil(page.endpoint)
                XCTAssertTrue(Self.portIsOwned(port))
                let oldClosed = await oldFlow?.waitForClose() == true
                receipt["oldAcceptedFlowClosed"] = oldClosed
                XCTAssertTrue(oldClosed)
                let newcomer = LocalProxyPeer(port: port)
                defer { newcomer.cancel() }
                let outcome = await newcomer.connect(host: destination.host, upstreamPort: destination.port, transport: binding.transport)
                receipt["newProxyCONNECTOutcome"] = outcome.rawValue
                switch outcome {
                case .refused, .peerClosed:
                    receipt["newProxyCONNECTAdmitted"] = false
                case .admitted:
                    receipt["newProxyCONNECTAdmitted"] = true
                    XCTFail("The retiring listener admitted a new CONNECT")
                case .timedOut, .cancelled, .inconclusive:
                    XCTFail("The new CONNECT probe is inconclusive: \(outcome.rawValue)")
                }
                if let target = environment["AEGIS_TEST_REVOKED_URL"], let targetURL = URL(string: target), let session = closeSession {
                    var received = false
                    do { _ = try await session.data(from: targetURL); received = true } catch { }
                    receipt["normalCloseMarkedRequestReceived"] = received
                    XCTAssertFalse(received)
                } else { XCTFail("Normal-close probe requires its independent negative marker") }
                receipt["coreRunningDuringCloseFence"] = core.isRunning
            }
            if environment["AEGIS_TEST_RETIREMENT_INTERFERENCE"] == "1", !callbackInconclusive {
                XCTAssertTrue(normalCloseProbe)
                receipt["retirementInterferenceProbe"] = true
                _ = webView.load(URLRequest(url: URL(string: "about:blank")!))
            }
        }) { checkpoint in
            var observation: [String: Any] = ["supplement":checkpoint.supplement, "confirmed":checkpoint.confirmed,
                "observationSeconds":checkpoint.observationSeconds, "events":page.retirementEvents]
            observation["commitSeconds"] = checkpoint.commitSeconds
            if normalCloseProbe, !checkpoint.confirmed, page.retirementCommittedAt == nil,
               let port = page.initialBinding?.port {
                observation["portStillOwned"] = Self.portIsOwned(port)
                observation["sameEndpointStillHeld"] = page.endpoint == page.initialBinding
                XCTAssertTrue(Self.portIsOwned(port))
                XCTAssertEqual(page.endpoint, page.initialBinding)
            }
            observations.append(observation)
        }
        receipt["retirementObservations"] = observations
        receipt["retirementWithinFirst5Seconds"] = observations.first?["confirmed"]
        receipt["retirementObservationSeconds"] = observations.last?["observationSeconds"]
        receipt["retirementEvents"] = page.retirementEvents
        if environment["AEGIS_TEST_RETIREMENT_INTERFERENCE"] == "1", !callbackInconclusive {
            XCTAssertTrue(page.retirementEvents.contains("denied-about-main"))
            XCTAssertEqual(page.retirementEvents.filter { $0 == "replacement-retry-scheduled" }.count, 1)
        }
        receipt["busyContentProbe"] = probeBusyContent
        if normalCloseProbe {
            receipt["coreStoppedByProductClose"] = !core.isRunning
            XCTAssertFalse(core.isRunning)
        }
        XCTAssertTrue(retired, "The real proxy-bound document must commit its inert replacement")
        receipt["retired"] = retired
        XCTAssertNotNil(page.initialBinding)
    }

    fileprivate static func controlledDestination(_ url: URL) -> (host: String, port: UInt16)? {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              let port = UInt16(exactly: url.port ?? 443), port != 0 else { return nil }
        return (host, port)
    }

    fileprivate enum RevokedFetchObservation: String {
        case blocked, received, unknown
        case documentRetired = "document-retired"
        case evaluationFailed = "evaluation-failed"
        case timedOut = "timed-out"
    }

    fileprivate static func observeRevokedFetch(
        until deadline: ContinuousClock.Instant,
        retirementCommittedAt: @escaping @MainActor () -> ContinuousClock.Instant?,
        evaluate: (@escaping @MainActor (String?) -> Void) -> Void
    ) async -> RevokedFetchObservation {
        await AccessPhysicalSOCKSAdmissionTests.observeWebContent(until: deadline, timeout: .timedOut) { finish in
            evaluate { value in
                switch value {
                case "blocked": finish(.blocked)
                case "received": finish(.received)
                case nil:
                    finish(retirementCommittedAt() == nil ? .evaluationFailed : .documentRetired)
                default: finish(.unknown)
                }
            }
        }
    }

    fileprivate static func controlledPathDestination() -> [String: String] {
        var result = [
            "model": UIDevice.current.model,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "bundle": Bundle.main.bundleIdentifier ?? "unknown"
        ]
        var system = utsname()
        if uname(&system) == 0 {
            result["machine"] = withUnsafeBytes(of: &system.machine) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
#if targetEnvironment(simulator)
        result["kind"] = "simulator"
        let environment = ProcessInfo.processInfo.environment
        result["simulatorModelIdentifier"] = environment["SIMULATOR_MODEL_IDENTIFIER"]
        result["simulatorUDID"] = environment["SIMULATOR_UDID"].flatMap { UUID(uuidString: $0)?.uuidString }
#else
        result["kind"] = "physical-device"
#endif
        return result
    }

    fileprivate static func bindingReceiptFields(selected: AccessInboundTransport?, binding: AccessManagedProxyEndpoint?) -> [String: Any] {
        var fields: [String: Any] = [:]
        fields["selectedTransport"] = selected.map { String(describing: $0) }
        if let binding {
            fields["protocol"] = String(describing: binding.transport)
            fields["port"] = binding.port
            fields["endpoint"] = binding.identity
            fields["generation"] = binding.generation
        }
        return fields
    }

    fileprivate static func requestedTransport(_ value: String?) -> AccessTestNodeTransport? {
        guard let value else { return .http }
        return AccessTestNodeTransport(rawValue: value)
    }

    fileprivate static func portIsOwned(_ port: UInt16) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result != 0 && errno == EADDRINUSE
    }

    /// App-native connection probes supplement the real WebKit page; they do not
    /// replace its publisher/DataStore or navigate any corpus member.
    fileprivate final class LocalProxyPeer: @unchecked Sendable {
        enum ConnectOutcome: String, Sendable {
            case admitted, refused, peerClosed, timedOut, cancelled, inconclusive
        }
        private enum PeerError: Error { case closed }

        let connection: NWConnection
        private let locallyCancelled = Mutex(false)
        init(port: UInt16) {
            connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            connection.start(queue: DispatchQueue(label: "ios208-owned-proxy-probe"))
        }
        func cancel() {
            locallyCancelled.withLock { $0 = true }
            connection.cancel()
        }
        func send(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { c.resume(throwing: error) } else { c.resume() }
                })
            }
        }
        func receive(_ count: Int) async throws -> Data {
            try await withCheckedThrowingContinuation { c in
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, complete, error in
                    if let error { c.resume(throwing: error) }
                    else if let data, data.count == count { c.resume(returning: data) }
                    else if complete { c.resume(throwing: PeerError.closed) }
                    else { c.resume(throwing: URLError(.badServerResponse)) }
                }
            }
        }
        func connect(host: String, upstreamPort: UInt16, transport: AccessInboundTransport) async -> ConnectOutcome {
            if locallyCancelled.withLock({ $0 }) || Task.isCancelled { return .cancelled }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            let timeout = Task {
                try? await ContinuousClock().sleep(until: deadline)
                if !Task.isCancelled { connection.cancel() }
            }
            defer { timeout.cancel() }
            let outcome: ConnectOutcome = await withTaskCancellationHandler {
                do { return try await handshake(host: host, upstreamPort: upstreamPort, transport: transport) }
                catch PeerError.closed { return .peerClosed }
                catch let error as NWError {
                    switch error {
                    case .posix(.ECONNREFUSED): return .refused
                    case .posix(.ECONNRESET): return .peerClosed
                    default: return .inconclusive
                    }
                } catch { return .inconclusive }
            } onCancel: {
                cancel()
            }
            if locallyCancelled.withLock({ $0 }) || Task.isCancelled { return .cancelled }
            if ContinuousClock.now >= deadline { return .timedOut }
            return outcome
        }

        static func socksRequest(host: String, upstreamPort: UInt16) -> Data? {
            guard !host.isEmpty, host.utf8.count < 256 else { return nil }
            var request = Data([5, 1, 0, 3, UInt8(host.utf8.count)])
            request.append(contentsOf: host.utf8)
            request.append(contentsOf: [UInt8(upstreamPort >> 8), UInt8(upstreamPort & 255)])
            return request
        }

        static func httpRequest(host: String, upstreamPort: UInt16) -> Data {
            let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            let authority = "\(address):\(upstreamPort)"
            return Data("CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n\r\n".utf8)
        }

        private func handshake(host: String, upstreamPort: UInt16, transport: AccessInboundTransport) async throws -> ConnectOutcome {
            if transport == .socks5 {
                try await send(Data([5, 1, 0]))
                let method = try await receive(2)
                if method == Data([5, 255]) { return .refused }
                guard method == Data([5, 0]), let request = Self.socksRequest(host: host, upstreamPort: upstreamPort)
                else { return .inconclusive }
                try await send(request)
                let prefix = try await receive(4)
                guard prefix[0] == 5, prefix[2] == 0 else { return .inconclusive }
                switch prefix[3] {
                case 1: _ = try await receive(6)
                case 3:
                    let count = try await receive(1)[0]
                    guard count > 0 else { return .inconclusive }
                    _ = try await receive(Int(count) + 2)
                case 4: _ = try await receive(18)
                default: return .inconclusive
                }
                if prefix[1] == 0 { return .admitted }
                return (1...8).contains(prefix[1]) ? .refused : .inconclusive
            } else {
                try await send(Self.httpRequest(host: host, upstreamPort: upstreamPort))
                var header = Data()
                let end = [UInt8(13), 10, 13, 10]
                while header.count < 4096, !header.suffix(4).elementsEqual(end) {
                    header.append(try await receive(1))
                }
                guard header.suffix(4).elementsEqual(end),
                      let firstLine = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n").first else {
                    return .inconclusive
                }
                let fields = firstLine.split(separator: " ", maxSplits: 2)
                guard fields.count >= 2, fields[0] == "HTTP/1.1", fields[1].utf8.count == 3,
                      let status = Int(fields[1]) else { return .inconclusive }
                if status == 200 { return .admitted }
                return (300...599).contains(status) ? .refused : .inconclusive
            }
        }
        func waitForClose() async -> Bool {
            let timedOut = Mutex(false)
            let timeout = Task {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { timedOut.withLock { $0 = true }; connection.cancel() }
            }
            defer { timeout.cancel() }
            return await withCheckedContinuation { c in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, complete, error in
                    c.resume(returning: !timedOut.withLock { $0 } && (complete || error != nil) && (data?.isEmpty ?? true))
                }
            }
        }
    }

    private final class RetirementSignal: NSObject, WKScriptMessageHandler {
        let started: () -> Void
        init(started: @escaping () -> Void) { self.started = started }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.body as? String == "started" { started() }
        }
    }

    /// Observes arguments delivered by the real WebKit inbound to the real core.
    /// Does not resolve names, alter configuration or persist target names.
    private final class ObservedCore: AccessEmbeddedCoreControlling, @unchecked Sendable {
        let base: AccessGoEmbeddedCore
        let mainHost: String
        let state = Mutex((domains: 0, ips: 0, mainName: false, dnsOverride: false))
        init(mainHost: String) throws {
            self.mainHost = mainHost
            base = try AccessGoEmbeddedCore(isolated: true)
        }
        var isRunning: Bool { base.isRunning }
        func start(configData: Data) async throws {
            let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any]
            state.withLock { $0.dnsOverride = config?["dns"] != nil }
            try await base.start(configData: configData)
        }
        func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
            state.withLock {
                if IPv4Address(host) != nil || IPv6Address(host) != nil { $0.ips += 1 }
                else { $0.domains += 1 }
                if host == mainHost { $0.mainName = true }
            }
            return try await base.dial(host: host, port: port)
        }
        func stop() async { await base.stop() }
        var observation: [String: Any] {
            state.withLock { ["domainTargets": $0.domains, "ipTargets": $0.ips,
                             "controlledMainNameForwarded": $0.mainName, "clientDNSOverride": $0.dnsOverride] }
        }
    }
}
#endif

#if DEBUG
/// Explicit physical protocol admission, independent of the domain campaign.
@MainActor
final class AccessPhysicalSOCKSAdmissionTests: XCTestCase {
    private static var quarantined: [(WKWebView, AccessSOCKS5InboundListener, UIWindow)] = []

    func testControlledSOCKSWebKitAdmission() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("SOCKS OS admission requires the designated physical device")
#else
        let env = ProcessInfo.processInfo.environment
        guard env["AEGIS_TEST_SOCKS_PROBE"] == "1",
              env["AEGIS_TEST_CAMPAIGN_DEVICE"] == "ios-device-2d62695fc7",
              let raw = env["AEGIS_TEST_CONTROLLED_URL"], let url = URL(string: raw),
              let destination = AccessTestNodeDeviceTests.controlledDestination(url),
              let nonce = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "nonce" })?.value, !nonce.isEmpty else {
            throw XCTSkip("Explicit physical SOCKS admission inputs required")
        }
        var system = utsname()
        uname(&system)
        let model = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        guard model == "iPhone14,3" else { XCTFail("Wrong physical device model"); return }
        let attempt = UUID()
        var result: [String: Any] = ["attempt": attempt.uuidString, "device": "ios-device-2d62695fc7",
            "model": model, "destination": AccessTestNodeDeviceTests.controlledPathDestination(),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "bundle": Bundle.main.bundleIdentifier ?? "unknown", "nonce": nonce, "status": "probe-incomplete",
            "requestedUpstreamPort": destination.port]
        defer { AccessProbeReceiptKind.socksAdmission.writeAndAttach(result, attempt: attempt, to: self) }
        guard let sourceSHA = AccessDomainCampaignInput.installedSourceSHA(env["AEGIS_TEST_SOURCE_SHA"]) else {
            result["status"] = "invalid-source-identity"
            XCTFail("SOCKS admission requires matching installed app, test and embedded core source identity")
            return
        }
        result["sourceSHA"] = sourceSHA

        let repository = AccessTestNodeRepository.shared
        guard repository.allowsEditing(isPrivate: false) else { XCTFail("Internal admission required"); return }
        let parameters = try repository.savedNode(isPrivate: false).parameters()
        let outbound = try AccessRealityVisionOutboundConfigBuilder.build(parameters: parameters)
        let core = try AccessGoEmbeddedCore(isolated: true)
        // The native listener owns the fixed DEV port independently of Xray.
        // That lets retirement fence both directions before releasing the socket.
        let registration = AccessRegistration(
            id: try AccessRegistrationID("socks-admission-\(attempt.uuidString)"),
            owner: try AccessOwner(channel: 1, profile: "ordinary", partition: "socks-admission"),
            transport: .socks5, endpoint: try AccessEndpoint(host: "127.0.0.1", port: 10806),
            credentialSlot: try AccessCredentialSlot(id: "socks-admission"),
            lease: try AccessLease(generation: 1, expiresAt: Date().addingTimeInterval(3600)))
        let listener = try AccessSOCKS5InboundListener(registration: registration, tunnels: FixtureTunnel(core: core))
        let diagnostics = AccessDiagnosticLog.shared
        var logLease: AccessDiagnosticLog.Lease?
        defer { if let logLease { diagnostics.stop(lease: logLease) } }
        do {
            logLease = try await AccessEmbeddedProxyEntrySession.startCoreWithDiagnostics(
                core: core, outbound: outbound, diagnostics: diagnostics, level: .none,
                disableCaptureWhenQuiet: false)
            try await listener.start()
        } catch {
            result["errorDomain"] = (error as NSError).domain
            result["errorCode"] = (error as NSError).code
            try? listener.stop()
            await core.stop()
            XCTFail("SOCKS fixture could not start; no OS conclusion")
            return
        }
        result["protocol"] = "socks5"
        result["port"] = listener.boundPort
        do {
            try await Self.nativeSOCKSConnect(host: destination.host, port: destination.port)
            result["nativeConnect"] = true
        } catch {
            result["nativeConnect"] = false
            result["errorDomain"] = (error as NSError).domain
            result["errorCode"] = (error as NSError).code
            try? listener.stop()
            await core.stop()
            XCTFail("Native SOCKS fixture did not admit CONNECT; no OS conclusion")
            return
        }
        let store = WKWebsiteDataStore.nonPersistent()
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: 10806))
        proxy.allowFailover = false
        store.proxyConfigurations = [proxy]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        let observer = SOCKSProbeNavigation()
        view.navigationDelegate = observer
        let window = UIWindow(frame: view.frame)
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.addSubview(view)
        window.makeKeyAndVisible()
        let navigationDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        view.load(URLRequest(url: url))
        do {
            while !observer.finished, observer.failure == nil, ContinuousClock.now < navigationDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            observer.failure = error as NSError
            XCTFail("SOCKS fixture navigation observation was interrupted")
        }
        let nonceObservation: NonceObservation
        if observer.finished {
            let deadline = min(navigationDeadline, ContinuousClock.now.advanced(by: .seconds(2)))
            nonceObservation = await Self.observeNonce(until: deadline) { finish in
                view.callAsyncJavaScript("return document.documentElement.textContent.includes(nonce)",
                                         arguments: ["nonce": nonce], in: nil, in: .defaultClient, completionHandler: { result in
                    finish((try? result.get()) as? Bool)
                })
            }
        } else {
            nonceObservation = .unavailable
        }
        result["proxyCount"] = store.proxyConfigurations.count
        result["allowFailover"] = proxy.allowFailover
        result["httpStatus"] = observer.httpStatus ?? 0
        result["nonceObservation"] = nonceObservation.rawValue
        result["documentContainsNonce"] = nonceObservation == .matched
        result["status"] = observer.finished && observer.httpStatus == 200 && nonceObservation == .matched
            ? "webkit-response-verified" : "webkit-not-admitted"
        if let failure = observer.failure {
            result["errorDomain"] = failure.domain
            result["errorCode"] = failure.code
        }
        let stopStarted = ContinuousClock.now
        let stopDeadline = stopStarted.advanced(by: .seconds(10))
        listener.suspend()
        let portHeld = AccessTestNodeDeviceTests.portIsOwned(registration.endpoint.port)
        result["portHeldAtRetirement"] = portHeld
        XCTAssertTrue(portHeld)
        view.stopLoading()
        view.configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        observer.retirement = view.loadHTMLString("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'\">",
                                                  baseURL: URL(string: "https://aegis.invalid/socks-retired"))
        let newcomer = AccessTestNodeDeviceTests.LocalProxyPeer(port: registration.endpoint.port)
        let outcome = await newcomer.connect(host: destination.host, upstreamPort: destination.port, transport: .socks5)
        newcomer.cancel()
        result["newProxyCONNECTOutcome"] = outcome.rawValue
        XCTAssertTrue(outcome == .refused || outcome == .peerClosed, "The fenced fixture must refuse a new CONNECT")
        await core.stop()
        do {
            while observer.retiredAt == nil, ContinuousClock.now < stopDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            XCTFail("SOCKS fixture retirement observation was interrupted")
        }
        let retirement = Self.retirementOutcome(from: stopStarted, through: stopDeadline, commit: observer.retiredAt)
        result["retired"] = retirement.confirmed
        result["retirementCommitSeconds"] = retirement.seconds
        if retirement.seconds != nil {
            view.removeFromSuperview()
            window.isHidden = true
            try listener.stop()
            XCTAssertTrue(retirement.confirmed, "The exact SOCKS retirement commit missed its deadline")
        } else {
            Self.quarantined.append((view, listener, window))
            XCTFail("SOCKS fixture document retirement unconfirmed; fenced listener retained until process exit")
        }
        if nonceObservation == .timedOut { XCTFail("SOCKS fixture nonce observation timed out") }
#endif
    }

    fileprivate enum NonceObservation: String {
        case matched, missing, unavailable, timedOut
    }

    fileprivate static func observeNonce(
        until deadline: ContinuousClock.Instant,
        evaluate: (@escaping @MainActor (Bool?) -> Void) -> Void
    ) async -> NonceObservation {
        await observeWebContent(until: deadline, timeout: .timedOut) { finish in
            evaluate { matched in
                finish(matched.map { $0 ? .matched : .missing } ?? .unavailable)
            }
        }
    }

    fileprivate static func observeWebContent<Value: Sendable>(
        until deadline: ContinuousClock.Instant, timeout: Value,
        evaluate: (@escaping @MainActor (Value) -> Void) -> Void
    ) async -> Value {
        guard ContinuousClock.now < deadline, !Task.isCancelled else { return timeout }
        return await withCheckedContinuation { continuation in
            let result = WebContentResult(continuation)
            result.timeout = Task {
                try? await ContinuousClock().sleep(until: deadline)
                guard !Task.isCancelled else { return }
                result.finish(timeout)
            }
            evaluate { value in
                result.finish(ContinuousClock.now < deadline ? value : timeout)
            }
        }
    }

    @MainActor
    private final class WebContentResult<Value: Sendable> {
        var timeout: Task<Void, Never>?
        private var continuation: CheckedContinuation<Value, Never>?

        init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }

        func finish(_ outcome: Value) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel()
            timeout = nil
            continuation.resume(returning: outcome)
        }
    }

    fileprivate static func retirementOutcome(
        from started: ContinuousClock.Instant, through deadline: ContinuousClock.Instant,
        commit: ContinuousClock.Instant?
    ) -> (confirmed: Bool, seconds: TimeInterval?) {
        guard let commit, commit >= started else { return (false, nil) }
        let elapsed = started.duration(to: commit).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return (commit <= deadline, seconds)
    }

    private final class FixtureTunnel: AccessHTTPTunnelOpening {
        let core: AccessGoEmbeddedCore
        init(core: AccessGoEmbeddedCore) { self.core = core }
        func open(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
            try await core.dial(host: host, port: port)
        }
    }

    private static func nativeSOCKSConnect(host: String, port: UInt16) async throws {
        let connection = NWConnection(host: "127.0.0.1", port: 10806, using: .tcp)
        connection.start(queue: DispatchQueue(label: "ios208-socks-admission"))
        let deadline = Task { try? await Task.sleep(for: .seconds(15)); connection.cancel() }
        defer { deadline.cancel(); connection.cancel() }
        func send(_ bytes: Data) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }
        func receive(_ count: Int) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, data.count == count { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: URLError(.badServerResponse)) }
                }
            }
        }
        try await send(Data([5, 1, 0]))
        guard try await receive(2) == Data([5, 0]),
              let request = AccessTestNodeDeviceTests.LocalProxyPeer.socksRequest(host: host, upstreamPort: port)
        else { throw URLError(.badServerResponse) }
        try await send(request)
        let reply = try await receive(10)
        guard reply[0] == 5, reply[1] == 0 else { throw URLError(.cannotConnectToHost) }
    }

    private final class SOCKSProbeNavigation: NSObject, WKNavigationDelegate {
        var finished = false
        var failure: NSError?
        var httpStatus: Int?
        var retirement: WKNavigation?
        private(set) var retiredAt: ContinuousClock.Instant?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if retiredAt == nil, let navigation, navigation === retirement { retiredAt = .now }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failure = error as NSError
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = error as NSError }
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            if response.isForMainFrame { httpStatus = (response.response as? HTTPURLResponse)?.statusCode }
            decisionHandler(.allow)
        }
    }
}
#endif

#if DEBUG
@MainActor
final class AccessTestNodeEvidenceTests: XCTestCase {
    private typealias Probe = AccessTestNodeDeviceTests

    func testPhysicalNonceObservationTimesOutWithoutAWebContentReply() async {
        var reply: (@MainActor (Bool?) -> Void)?
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        let outcome = await AccessPhysicalSOCKSAdmissionTests.observeNonce(until: deadline) { reply = $0 }
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertNotNil(reply)
        reply?(true)
        let responsive = await AccessPhysicalSOCKSAdmissionTests.observeNonce(
            until: ContinuousClock.now.advanced(by: .seconds(1))
        ) { $0(true) }
        XCTAssertEqual(responsive, .matched)
        let expired = await AccessPhysicalSOCKSAdmissionTests.observeNonce(until: deadline) { _ in
            XCTFail("An expired observation must never evaluate WebContent")
        }
        XCTAssertEqual(expired, .timedOut)
    }

    func testControlledRevokedFetchTreatsASilentOrLateReplyAsInconclusive() async {
        var late: (@MainActor (String?) -> Void)?
        let timedOut = await Probe.observeRevokedFetch(until: ContinuousClock.now.advanced(by: .milliseconds(100)),
                                                       retirementCommittedAt: { nil }) {
            late = $0
        }
        XCTAssertEqual(timedOut, .timedOut)
        XCTAssertNotNil(late)
        late?("blocked")
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        let blocked = await Probe.observeRevokedFetch(until: deadline, retirementCommittedAt: { nil }) { $0("blocked"); $0("received") }
        XCTAssertEqual(blocked, .blocked)
        var committedAt: ContinuousClock.Instant?
        let failedBeforeCommit = await Probe.observeRevokedFetch(until: deadline, retirementCommittedAt: { committedAt }) {
            $0(nil)
            committedAt = .now
        }
        XCTAssertEqual(failedBeforeCommit, .evaluationFailed)
        let retired = await Probe.observeRevokedFetch(until: deadline, retirementCommittedAt: { committedAt }) { $0(nil) }
        XCTAssertEqual(retired, .documentRetired)
    }

    func testControlledHTTPSPortIsEncodedInBothLocalProxyRequests() throws {
        let url = try XCTUnwrap(URL(string: "https://origin.invalid:8443/probe"))
        let destination = try XCTUnwrap(Probe.controlledDestination(url))
        XCTAssertEqual(destination.port, 8443)
        XCTAssertEqual(Probe.controlledDestination(try XCTUnwrap(URL(string: "https://origin.invalid")))?.port, 443)
        for invalid in ["https://origin.invalid:0", "https://origin.invalid:65536", "http://origin.invalid:8443"] {
            XCTAssertNil(Probe.controlledDestination(try XCTUnwrap(URL(string: invalid))))
        }
        let socks = try XCTUnwrap(Probe.LocalProxyPeer.socksRequest(host: destination.host, upstreamPort: destination.port))
        XCTAssertEqual(socks, Data([5, 1, 0, 3, 14] + Array("origin.invalid".utf8) + [0x20, 0xfb]))
        let http = Probe.LocalProxyPeer.httpRequest(host: destination.host, upstreamPort: destination.port)
        XCTAssertEqual(String(decoding: http, as: UTF8.self),
            "CONNECT origin.invalid:8443 HTTP/1.1\r\nHost: origin.invalid:8443\r\n\r\n")
    }

    func testPhysicalRetirementDistinguishesLateCommitFromUnconfirmedAndOnTime() {
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .seconds(10))
        for (commit, confirmed, seconds) in [
            (nil, false, nil), (-1.0, false, nil), (9.0, true, 9.0), (10.0, true, 10.0), (10.001, false, 10.001)
        ] as [(Double?, Bool, Double?)] {
            let result = AccessPhysicalSOCKSAdmissionTests.retirementOutcome(from: started, through: deadline,
                commit: commit.map { started.advanced(by: .seconds($0)) })
            XCTAssertEqual(result.confirmed, confirmed)
            XCTAssertEqual(result.seconds, seconds)
        }
    }

    func testControlledPathRejectsAnInvalidExplicitTransport() {
        XCTAssertEqual(Probe.requestedTransport(nil), .http)
        XCTAssertEqual(Probe.requestedTransport("http"), .http)
        XCTAssertEqual(Probe.requestedTransport("socks5"), .socks5)
        XCTAssertEqual(Probe.requestedTransport("automatic"), .automatic)
        for invalid in ["", "https", "socks", "HTTP", " http"] {
            XCTAssertNil(Probe.requestedTransport(invalid))
        }
    }

    func testRetirementBudgetsUseCommitTimeEvenWhenObservationIsLate() async throws {
        let started = ContinuousClock.now
        for (commit, observed, expected) in [(-1.0, 11.0, [false, false]), (4.0, 6.0, [true]), (5.0, 6.0, [true]),
            (5.5, 6.0, [false, true]), (10.0, 11.0, [false, true]), (10.5, 11.0, [false, false])] {
            var checkpoints: [Probe.RetirementCheckpoint] = []
            let retired = try await Probe.observeRetirement(started: started, hasBoundDocument: true,
                committedAt: { started.advanced(by: .seconds(commit)) },
                now: { started.advanced(by: .seconds(observed)) },
                pause: { XCTFail("The commit was already observed") },
                checkpoint: { checkpoints.append($0) })
            XCTAssertEqual(checkpoints.map(\.confirmed), expected)
            XCTAssertEqual(checkpoints.map(\.supplement), expected.indices.map { $0 > 0 })
            XCTAssertEqual(checkpoints.map(\.commitSeconds), expected.map { _ in commit >= 0 ? commit : nil })
            XCTAssertEqual(checkpoints.map(\.observationSeconds), expected.map { _ in observed })
            XCTAssertEqual(retired, expected.last)
        }
        var checkpoints: [Probe.RetirementCheckpoint] = []
        var now = started
        let retired = try await Probe.observeRetirement(started: started, hasBoundDocument: true,
            committedAt: { nil }, now: { now }, pause: { now = now.advanced(by: .seconds(1)) },
            checkpoint: { checkpoints.append($0) })
        XCTAssertFalse(retired)
        XCTAssertEqual(checkpoints.map(\.observationSeconds), [5, 10])
        XCTAssertEqual(checkpoints.map(\.confirmed), [false, false])
    }

    func testControlledPathReceiptsKeepAttemptsAndReportSerializationAndWriteFailures() throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: documents) }
        let oldBytes = Data("historical receipt".utf8)
        let first = UUID(), second = UUID()
        for kind in AccessProbeReceiptKind.allCases {
            let previous = documents.appendingPathComponent("\(kind.rawValue).json")
            try oldBytes.write(to: previous)
            let firstPath = try kind.write(["attempt": first.uuidString], attempt: first, in: documents)
            let secondPath = try kind.write(["attempt": second.uuidString], attempt: second, in: documents)
            XCTAssertNotEqual(firstPath, secondPath)
            XCTAssertEqual(firstPath.deletingLastPathComponent().lastPathComponent, "\(kind.rawValue)-\(first.uuidString)")
            XCTAssertThrowsError(try kind.write(["attempt": "collision"], attempt: first, in: documents))
            XCTAssertThrowsError(try kind.write(["invalid": Date()], attempt: UUID(), in: documents))
            XCTAssertThrowsError(try kind.write([:], attempt: UUID(), in: previous))
            let firstReceipt = try JSONSerialization.jsonObject(with: Data(contentsOf: firstPath)) as? [String: String]
            let secondReceipt = try JSONSerialization.jsonObject(with: Data(contentsOf: secondPath)) as? [String: String]
            XCTAssertEqual(firstReceipt?["attempt"], first.uuidString)
            XCTAssertEqual(secondReceipt?["attempt"], second.uuidString)
            XCTAssertEqual(try Data(contentsOf: previous), oldBytes)
        }
    }

    func testControlledPathReceiptUsesTheBoundTransportAndLeavesFailedPreparationUnbound() {
        let endpoint = AccessManagedProxyEndpoint(identity: "fixture", generation: 1, loopbackHost: "127.0.0.1",
                                                  port: 18081, state: .ready, transport: .http)
        let bound = Probe.bindingReceiptFields(selected: .socks5, binding: endpoint)
        XCTAssertEqual(bound["selectedTransport"] as? String, "socks5")
        XCTAssertEqual(bound["protocol"] as? String, "http")
        XCTAssertEqual(bound["port"] as? UInt16, endpoint.port)
        let unbound = Probe.bindingReceiptFields(selected: .socks5, binding: nil)
        XCTAssertEqual(unbound["selectedTransport"] as? String, "socks5")
        for field in ["protocol", "port", "endpoint", "generation"] { XCTAssertNil(unbound[field]) }
    }

    func testControlledPathDestinationReportsTheRunningTarget() {
        let destination = Probe.controlledPathDestination()
#if targetEnvironment(simulator)
        XCTAssertEqual(destination["kind"], "simulator")
#else
        XCTAssertEqual(destination["kind"], "physical-device")
        XCTAssertNil(destination["simulatorUDID"])
#endif
        XCTAssertNotNil(destination["machine"])
        XCTAssertNotNil(destination["os"])
    }

    func testCONNECTProbeDistinguishesAdmissionRefusalAndLocalTimeout() async throws {
        for (reply, expected) in [("HTTP/1.1 200 Connection Established\r\n\r\n", Probe.LocalProxyPeer.ConnectOutcome.admitted),
                                  ("HTTP/1.1 503 Service Unavailable\r\n\r\n", .refused),
                                  (nil, .peerClosed),
                                  (nil, .timedOut)] {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            let connection = Mutex<NWConnection?>(nil)
            defer { listener.cancel(); connection.withLock { $0?.cancel() } }
            let ready = expectation(description: "loopback CONNECT fixture ready")
            let requested = expectation(description: "CONNECT sent to loopback fixture")
            let queue = DispatchQueue(label: "ios208-connect-outcome-fixture")
            listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
            listener.newConnectionHandler = { peer in
                connection.withLock { $0 = peer }
                peer.start(queue: queue)
                peer.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    if let data, !data.isEmpty { requested.fulfill() }
                    if let reply { peer.send(content: Data(reply.utf8), completion: .contentProcessed { _ in }) }
                    if expected == .peerClosed {
                        peer.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                  completion: .contentProcessed { _ in })
                    }
                }
            }
            listener.start(queue: queue)
            await fulfillment(of: [ready], timeout: 2)
            let port = try XCTUnwrap(listener.port?.rawValue)
            let probe = Probe.LocalProxyPeer(port: port)
            defer { probe.cancel() }
            let outcome = await probe.connect(host: "fixture.invalid", upstreamPort: 8443, transport: .http)
            await fulfillment(of: [requested], timeout: 2)
            XCTAssertEqual(outcome, expected)
            if expected == .timedOut {
                probe.cancel()
                let local = await probe.connect(host: "fixture.invalid", upstreamPort: 8443, transport: .http)
                XCTAssertEqual(local, .cancelled)
            }
        }
    }
}
#endif
