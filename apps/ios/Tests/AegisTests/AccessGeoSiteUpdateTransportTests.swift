import AccessKit
import BrowserKit
import Foundation
import os
import Security
import XCTest
@testable import Aegis

#if DEBUG && targetEnvironment(simulator)
/// Fixture URLs and trust live exclusively in XCTest. In particular, the CA
/// replaces the anchors for these sessions and does not replace hostname checks.
struct GeoSiteHTTPSFixture: Sendable {
    struct Contact: Codable, Equatable, Sendable {
        let role: String
        let path: String
        let ifNoneMatch: String?
        let cookieSupplied: Bool
        let authSupplied: Bool
        let refererSupplied: Bool
    }

    let metadata: URL
    let asset: URL
    let cdn: URL
    let ca: Data
    private let control: URL

    init() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AEGIS_GEOSITE_METADATA"] != nil else {
            throw XCTSkip("Run with the geosite-https native fixture")
        }
        func value(_ name: String) throws -> String {
            try XCTUnwrap(env["AEGIS_GEOSITE_" + name], "Run with the geosite-https native fixture")
        }
        metadata = try XCTUnwrap(URL(string: value("METADATA")))
        asset = try XCTUnwrap(URL(string: value("ASSET")))
        cdn = try XCTUnwrap(URL(string: value("CDN")))
        ca = try XCTUnwrap(Data(base64Encoded: value("CA")))
        control = try metadata.appendingPathComponent("_fixture").appendingPathComponent(value("CONTROL"))
    }

    final class Trust: NSObject, URLSessionDelegate {
        let ca: Data

        init(ca: Data) { self.ca = ca }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            Self.answer(challenge, ca: ca)
        }

        static func answer(_ challenge: URLAuthenticationChallenge, ca: Data)
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust,
                  let anchor = SecCertificateCreateWithData(nil, ca as CFData),
                  SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                  SecTrustEvaluateWithError(trust, nil) else { return (.cancelAuthenticationChallenge, nil) }
            return (.useCredential, URLCredential(trust: trust))
        }
    }

    func select(_ name: String, version: Int = 0, reset: Bool = false) async throws {
        var request = URLRequest(url: control)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["case": name, "version": version, "reset": reset])
        let session = URLSession(configuration: .ephemeral, delegate: Trust(ca: ca), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }

    func contacts() async throws -> [Contact] {
        let session = URLSession(configuration: .ephemeral, delegate: Trust(ca: ca), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: control)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode([Contact].self, from: data)
    }
}

@MainActor
final class AccessGeoSiteUpdateTransportTests: XCTestCase {
    func testEligibleForegroundFetchesPairedOfficialAssetsAndPersistsReceipt() async throws {
        let fixture = try GeoSiteHTTPSFixture()
        try await fixture.select("base", reset: true)
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AccessGeoSiteStorage(directory: location, service: "geosite-test." + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: location)
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: storage.service] as CFDictionary)
        }
        let cache = AccessGeoSiteCache(storage: storage)
        await cache.restore(migrating: .init(mode: .smart, categories: [.debian, .douban, .meituan]))
        XCTAssertEqual(cache.status, .ready)
        let coordinator = AccessHostStoreCoordinator(channel: .dev, geoSiteCache: cache,
                                                     geoSiteTransport: fixture.transport())
        let first = UUID()
        let second = UUID()
        coordinator.setGeoSiteForeground(window: first, eligible: true)
        coordinator.setGeoSiteForeground(window: second, eligible: true)
        coordinator.setGeoSiteForeground(window: first, eligible: false)
        for _ in 0..<50 where cache.highWater == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        let contacts = try await fixture.contacts()
        XCTAssertEqual(contacts.filter { $0.role == "metadata" }.count, 1)
        XCTAssertEqual(contacts.filter { $0.role == "asset" }.count, 2)
        XCTAssertEqual(contacts.filter { $0.role == "cdn" }.count, 2)
        XCTAssertTrue(contacts.allSatisfy { !$0.cookieSupplied && !$0.authSupplied && !$0.refererSupplied })
        let receipt = try XCTUnwrap(cache.highWater)
        XCTAssertEqual(receipt.releaseID, 1000)
        XCTAssertGreaterThan(receipt.database.byteCount, 0)
        coordinator.setGeoSiteForeground(window: second, eligible: false)
        let reopened = AccessGeoSiteCache(storage: storage)
        await reopened.restore()
        XCTAssertEqual(reopened.highWater, receipt)
        XCTAssertEqual(reopened.selection, cache.selection)
        XCTAssertEqual(reopened.view.groups, cache.view.groups)
    }

    func testRejectsMalformedBodiesUntrustedTLSAndRedirects() async throws {
        let fixture = try GeoSiteHTTPSFixture()
        let badCases: [(String, AccessGeoSiteUpdateTransport.Failure)] = [
            ("partial", .status(206)), ("compressed", .encoding), ("wrong-length", .length),
            ("bad-body", .digest), ("over-limit", .length), ("metadata-redirect", .redirect),
            ("wrong-origin", .redirect), ("redirect-twice", .redirect), ("rate-limit", .status(429))
        ]
        let extended = ProcessInfo.processInfo.environment["AEGIS_GEOSITE_FIXTURE_EXTENDED"] == "1"
            ? [("compressed-valid", AccessGeoSiteUpdateTransport.Failure.encoding)] : []
        for (name, expected) in badCases + extended {
            try await fixture.select(name, reset: true)
            do {
                _ = try await fixture.transport().load(etag: nil, highWater: nil, now: Date())
                XCTFail("Unexpected admission: \(name)")
            } catch {
                let actual = error as? AccessGeoSiteUpdateTransport.Failure
                // CFNetwork can reject the truncated fixed-length stream before delivering the response.
                let truncatedBySystem = name == "wrong-length" && actual == .network(URLError.networkConnectionLost.rawValue)
                XCTAssertTrue(actual == expected || truncatedBySystem, "\(name): \(String(describing: actual))")
            }
            let contacts = try await fixture.contacts()
            XCTAssertFalse(contacts.isEmpty, name)
            XCTAssertTrue(contacts.allSatisfy { !$0.cookieSupplied && !$0.authSupplied && !$0.refererSupplied }, name)
            if name == "wrong-origin" || name == "redirect-twice" || name == "metadata-redirect" {
                XCTAssertFalse(contacts.contains { $0.path == "/meta" || $0.path == "/unexpected"
                    || ($0.role == "metadata" && $0.path.hasPrefix("/blobs/")) }, name)
            }
        }
        for name in ["bad-group", "bad-checksum"] {
            try await fixture.select(name, reset: true)
            do {
                _ = try await fixture.transport().load(etag: nil, highWater: nil, now: Date())
                XCTFail("Unexpected admission: \(name)")
            } catch {
                XCTAssertNotNil(error as? AccessGeoSiteAdmission.Failure, name)
            }
        }
        try await fixture.select("base", reset: true)
        do {
            _ = try await fixture.transport(trustFixture: false).load(etag: nil, highWater: nil, now: Date())
            XCTFail("System trust accepted a per-run untrusted certificate")
        } catch {
            let contacts = try await fixture.contacts()
            XCTAssertTrue(contacts.isEmpty)
        }
        do {
            _ = try await fixture.transport(mismatchedHostname: true).load(etag: nil, highWater: nil, now: Date())
            XCTFail("The test anchor must preserve hostname verification")
        } catch {
            let contacts = try await fixture.contacts()
            XCTAssertTrue(contacts.isEmpty)
        }
    }

    func testChunkedCompleteBodyAndWallTimeCeiling() async throws {
        let fixture = try GeoSiteHTTPSFixture()
        try await fixture.select("chunked", reset: true)
        let chunked = try await fixture.transport().load(etag: nil, highWater: nil, now: Date())
        guard case .candidate(let admitted, _) = chunked else { return XCTFail("Valid complete chunked response was not admitted") }
        XCTAssertEqual(admitted.catalogue.groups, AccessGeoSiteCatalogue.bundled.groups)
        try await fixture.select("slow", reset: true)
        do {
            _ = try await fixture.transport(budget: .seconds(1)).load(etag: nil, highWater: nil, now: Date())
            XCTFail("Accepted a response outside the refresh deadline")
        } catch {
            XCTAssertEqual(error as? AccessGeoSiteUpdateTransport.Failure, .deadline)
            let contacts = try await fixture.contacts()
            XCTAssertEqual(contacts.last?.path, "/blobs/geosite.dat")
        }
    }
}

extension GeoSiteHTTPSFixture {
    func transport(budget: Duration = .seconds(30), trustFixture: Bool = true,
                   mismatchedHostname: Bool = false) -> AccessGeoSiteUpdateTransport {
        var origin = URLComponents(url: metadata, resolvingAgainstBaseURL: false)!
        if mismatchedHostname { origin.host = "127.0.0.1" }
        return AccessGeoSiteUpdateTransport(metadataURL: origin.url!.appendingPathComponent(AccessGeoSiteAdmission.metadataURL.path),
            assetURL: { URL(string: asset.absoluteString + $0.path)! }, cdnOrigin: cdn,
            canonicalMetadata: { data in
                var release = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                func canonical(_ record: [String: Any]) -> [String: Any] {
                    var copy = record
                    for key in ["url", "assets_url", "html_url", "browser_download_url"] {
                        guard let value = copy[key] as? String else { continue }
                        for (fixture, official) in [(metadata, "https://api.github.com"), (asset, "https://github.com")] {
                            let prefix = fixture.absoluteString + "/"
                            if value.hasPrefix(prefix) { copy[key] = official + "/" + value.dropFirst(prefix.count) }
                        }
                    }
                    return copy
                }
                release["assets"] = (release["assets"] as? [[String: Any]])?.map(canonical)
                return try JSONSerialization.data(withJSONObject: canonical(release))
            }, authenticate: { challenge in
                if trustFixture { return Trust.answer(challenge, ca: ca) }
                return (.performDefaultHandling, nil)
            }, budget: budget)
    }
}

@MainActor
final class AccessGeoSiteEligibilityTests: XCTestCase {
    func testWeak304KeepsOriginalExpiryAndSurvivesOfflineColdRestart() async throws {
        let fixture = try GeoSiteHTTPSFixture()
        try await fixture.select("base", reset: true)
        let install = GeoSiteTestInstall()
        defer { install.clean() }
        let cache = await install.restore()
        let coordinator = AccessHostStoreCoordinator(channel: .dev, geoSiteCache: cache,
                                                     geoSiteTransport: fixture.transport())
        let browser = GeoSiteTestInstall.window(coordinator)
        defer { browser.closeWindow() }
        browser.setWindowForeground(true)
        try await install.wait { cache.highWater?.releaseID == 1000 }
        let first = try XCTUnwrap(cache.highWater)
        let deadline = try first.validityDeadline()
        let etag = try XCTUnwrap(cache.refreshState.etag)
        XCTAssertTrue(etag.hasPrefix("W/"))
        let activeFile = cache.activeFileSHA256
        let firstAttempt = try XCTUnwrap(cache.refreshState.lastRequest)

        install.advance(86_401)
        coordinator.checkpointGeoSiteClock()
        try await install.wait {
            cache.refreshState.lastRequest != firstAttempt && cache.refreshState.failureCount == 0
                && (cache.refreshState.nextAttempt?.timeIntervalSince(install.now) ?? 0) > 86_300
        }
        let contacts = try await fixture.contacts()
        XCTAssertEqual(contacts.map(\.role), ["metadata", "asset", "cdn", "asset", "cdn", "metadata"])
        XCTAssertNil(contacts.first?.ifNoneMatch)
        XCTAssertEqual(contacts.last?.ifNoneMatch, etag)
        XCTAssertEqual(cache.highWater, first)
        XCTAssertEqual(cache.activeFileSHA256, activeFile)
        let context = try XCTUnwrap(cache.updateContext())
        let receipt = await cache.conditionalReceipt(using: context)
        XCTAssertEqual(receipt?.receipt, first)

        browser.closeWindow()
        let offline = await install.restore()
        XCTAssertEqual(offline.highWater, first)
        XCTAssertEqual(offline.activeFileSHA256, activeFile)
        XCTAssertEqual(offline.refreshState, cache.refreshState)
        guard case .available(_, let version) = offline.view.groups[.douban] else { return XCTFail("Cold restore lost verified active") }
        XCTAssertEqual(version?.expiry, deadline)
        XCTAssertEqual(offline.match(URL(string: "https://www.douban.com/")!), .managed)
        let after = try await fixture.contacts()
        XCTAssertEqual(after, contacts)
        attachWitness(after, name: "Weak 304 and offline restored receipt")
    }

    func testTransientErrorsBackOffAndOnlyCompleteNewerRemovalPersists() async throws {
        let fixture = try GeoSiteHTTPSFixture()
        try await fixture.select("base", reset: true)
        let install = GeoSiteTestInstall()
        defer { install.clean() }
        let cache = await install.restore()
        let coordinator = AccessHostStoreCoordinator(channel: .dev, geoSiteCache: cache,
                                                     geoSiteTransport: fixture.transport())
        let browser = GeoSiteTestInstall.window(coordinator)
        defer { browser.closeWindow() }
        browser.setWindowForeground(true)
        try await install.wait { cache.highWater?.releaseID == 1000 }
        install.advance(86_401)
        let target = URL(string: "https://www.douban.com/")!
        for (index, delay) in [60.0, 300, 1_800, 21_600, 21_600].enumerated() {
            try await fixture.select(index == 0 ? "missing-metadata" : "rate-limit", version: 1)
            let previousRequest = cache.refreshState.lastRequest
            coordinator.checkpointGeoSiteClock()
            try await install.wait {
                cache.refreshState.lastRequest != previousRequest && cache.refreshState.failureCount == min(index + 1, 4)
                    && abs((cache.refreshState.nextAttempt?.timeIntervalSince(install.now) ?? 0) - delay) < 3
            }
            XCTAssertEqual(cache.match(target), .managed)
            XCTAssertEqual(cache.highWater?.releaseID, 1000)
            let cold = await install.restore()
            XCTAssertEqual(cold.refreshState, cache.refreshState)
            // Brief foreground oscillation must not bypass the recorded retry.
            let last = cache.refreshState.lastRequest
            browser.setWindowForeground(false)
            browser.setWindowForeground(true)
            XCTAssertEqual(cache.refreshState.lastRequest, last)
            install.advance(delay + 1)
        }
        try await fixture.select("removed", version: 2)
        coordinator.checkpointGeoSiteClock()
        try await install.wait { cache.highWater?.releaseID == 1002 }
        XCTAssertEqual(cache.match(target), .original)
        XCTAssertTrue(cache.selection?.categories.contains(.douban) == true)
        XCTAssertEqual(cache.refreshState.failureCount, 0)
        browser.closeWindow()
        install.advance(8 * 86_400)
        let offline = await install.restore()
        XCTAssertEqual(offline.view.groups[.douban], .withdrawn(cache.highWater!.tag))
        XCTAssertTrue(offline.selection?.categories.contains(.douban) == true)
        let contacts = try await fixture.contacts()
        XCTAssertEqual(contacts.filter { $0.role == "metadata" }.count, 7)
        XCTAssertEqual(contacts.filter { $0.role == "cdn" }.count, 4)
        attachWitness(contacts, name: "Transient errors, capped backoff and official removal")
    }

    func testConflicting304AndMissingOrExpiredActiveRequireUnconditionalRecovery() async throws {
        let fixture = try GeoSiteHTTPSFixture()
        try await fixture.select("base", reset: true)
        let install = GeoSiteTestInstall()
        defer { install.clean() }
        let cache = await install.restore()
        let coordinator = AccessHostStoreCoordinator(channel: .dev, geoSiteCache: cache,
                                                     geoSiteTransport: fixture.transport())
        let browser = GeoSiteTestInstall.window(coordinator)
        defer { browser.closeWindow() }
        browser.setWindowForeground(true)
        try await install.wait { cache.highWater?.releaseID == 1000 }
        let initial = try XCTUnwrap(cache.highWater)
        let etag = try XCTUnwrap(cache.refreshState.etag)
        try await fixture.select("etag-conflict")
        install.advance(86_401)
        coordinator.checkpointGeoSiteClock()
        try await install.wait { cache.refreshState.failureCount == 1 }
        var contacts = try await fixture.contacts()
        XCTAssertEqual(contacts.last?.ifNoneMatch, etag)
        XCTAssertNil(cache.refreshState.etag)
        XCTAssertEqual(cache.highWater, initial)

        try await fixture.select("base")
        install.advance(61)
        coordinator.checkpointGeoSiteClock()
        try await install.wait { cache.refreshState.etag == etag }
        contacts = try await fixture.contacts()
        XCTAssertEqual(contacts.filter { $0.role == "metadata" }.last?.ifNoneMatch, nil)
        XCTAssertEqual(cache.highWater, initial)
        let active = try XCTUnwrap(cache.activeFileSHA256)
        try FileManager.default.removeItem(at: install.storage.blobURL(.active, active))
        try await fixture.select("stale-304")
        install.advance(86_401)
        coordinator.checkpointGeoSiteClock()
        try await install.wait { cache.refreshState.failureCount == 1 }
        contacts = try await fixture.contacts()
        XCTAssertEqual(contacts.last?.role, "metadata")
        XCTAssertNil(contacts.last?.ifNoneMatch)

        try await fixture.select("base")
        install.advance(61)
        coordinator.checkpointGeoSiteClock()
        try await install.wait { cache.refreshState.etag == etag }
        install.advance(7 * 86_400)
        try await fixture.select("stale-304")
        coordinator.checkpointGeoSiteClock()
        try await install.wait { cache.refreshState.failureCount == 1 }
        contacts = try await fixture.contacts()
        XCTAssertEqual(contacts.last?.role, "metadata")
        XCTAssertNil(contacts.last?.ifNoneMatch)
        XCTAssertEqual(cache.highWater, initial)
        XCTAssertEqual(cache.match(URL(string: "https://debian.org/")!), .indeterminate)
        attachWitness(contacts, name: "304 conflict, missing file, repair and expiry")
    }

    func testLastNormalWindowCancelsAndManualEmptyPrivateAndNonDEVStaySilent() async throws {
        let fixture = try GeoSiteHTTPSFixture()
        try await fixture.select("slow", reset: true)
        let install = GeoSiteTestInstall()
        defer { install.clean() }
        let cache = await install.restore(migrating: .init(mode: .manual, categories: [.debian]))
        let coordinator = AccessHostStoreCoordinator(channel: .dev, geoSiteCache: cache,
                                                     geoSiteTransport: fixture.transport())
        let first = GeoSiteTestInstall.window(coordinator)
        let second = GeoSiteTestInstall.window(coordinator)
        defer { first.closeWindow(); second.closeWindow() }
        first.setWindowForeground(true)
        second.setWindowForeground(true)
        let tab = try XCTUnwrap(first.activeTab)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertNil(cache.refreshState.lastRequest)
        try cache.setSelection(.init(mode: .smart, categories: []))
        try await Task.sleep(for: .milliseconds(180))
        let initialContacts = try await fixture.contacts()
        XCTAssertTrue(initialContacts.isEmpty)

        let selection = try XCTUnwrap(coordinator.websiteCategories(for: tab))
        coordinator.setWebsiteCategory(.debian, selected: true, from: selection, for: tab)
        for _ in 0..<60 {
            if try await fixture.contacts().contains(where: { $0.role == "cdn" && $0.path == "/blobs/geosite.dat" }) { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        let before = try await fixture.contacts()
        XCTAssertEqual(before.filter { $0.role == "metadata" }.count, 1)
        XCTAssertTrue(before.contains { $0.role == "cdn" && $0.path == "/blobs/geosite.dat" })
        first.closeWindow()
        second.switchProfile(to: .privateMode)
        try await Task.sleep(for: .milliseconds(3_250))
        XCTAssertNil(cache.highWater)
        XCTAssertNotNil(cache.refreshState.lastRequest)
        let last = cache.refreshState.lastRequest
        install.advance(2 * 86_400)
        coordinator.checkpointGeoSiteClock()
        let privateTab = try XCTUnwrap(second.activeTab)
        XCTAssertNil(coordinator.websiteCategories(for: privateTab))
        XCTAssertNil(coordinator.websiteCategoryProposal(.debian, for: second))

        for channel: AccessReleaseChannel in [.release, .unknown] {
            let ineligible = AccessHostStoreCoordinator(channel: channel, geoSiteCache: cache, geoSiteTransport: fixture.transport())
            let window = GeoSiteTestInstall.window(ineligible)
            window.setWindowForeground(true)
            ineligible.checkpointGeoSiteClock()
            let guest = try XCTUnwrap(window.activeTab)
            XCTAssertNil(ineligible.websiteCategories(for: guest))
            window.closeWindow()
        }
        try await Task.sleep(for: .milliseconds(300))
        let after = try await fixture.contacts()
        XCTAssertEqual(after, before)
        XCTAssertEqual(cache.refreshState.lastRequest, last)
        attachWitness(after, name: "Single in-flight request, cancelled before publication")
    }

    private func attachWitness(_ contacts: [GeoSiteHTTPSFixture.Contact], name: String) {
        attachGeoSiteWitness((try? String(decoding: JSONEncoder().encode(contacts), as: UTF8.self)) ?? "", name: name)
    }
}

@MainActor
final class AccessGeoSiteFrozenTransportTests: XCTestCase {
    func testFrozenOfficialPairedAssetsThroughNativeHTTPS() async throws {
        let fixture = try GeoSiteHTTPSFixture()
        guard ProcessInfo.processInfo.environment["AEGIS_GEOSITE_FROZEN"] != "0" else {
            throw XCTSkip("Run with the fixture and complete frozen official assets")
        }
        try await fixture.select("frozen-official", reset: true)
        let result = try await fixture.transport().load(etag: nil, highWater: nil, now: AccessGeoSiteTestVector.now)
        guard case .candidate(let candidate, _) = result else { return XCTFail("Expected complete official 200 assets") }
        XCTAssertEqual(candidate.receipt.tag, "20261120235103")
        XCTAssertEqual(candidate.receipt.database.byteCount, 7_750_066)
        XCTAssertEqual(candidate.receipt.database.sha256, AccessGeoSiteCatalogue.bundled.rawSHA256)
        XCTAssertEqual(candidate.catalogue.groups, AccessGeoSiteCatalogue.bundled.groups)
        XCTAssertEqual(candidate.categoryCount, 1_572)
        let contacts = try await fixture.contacts()
        XCTAssertEqual(contacts.map(\.role), ["metadata", "asset", "cdn", "asset", "cdn"])
        attachGeoSiteWitness(geoSiteReceipt(candidate), name: "Frozen official native HTTPS and admission")
    }
}

@MainActor
final class AccessGeoSiteLiveTransportTests: XCTestCase {
    func testCanonicalLatestAndPairedAssetsUsingSystemTrust() async throws {
        guard ProcessInfo.processInfo.environment["AEGIS_GEOSITE_LIVE"] == "1" else {
            throw XCTSkip("Opt in with the geosite-live native runner")
        }
        let transport = AccessGeoSiteUpdateTransport()
        let result = try await transport.load(etag: nil, highWater: nil, now: Date())
        guard case .candidate(let latest, let validator) = result else { return XCTFail("Expected latest metadata and both complete assets") }
        XCTAssertGreaterThan(latest.categoryCount, 0)
        let etag = try XCTUnwrap(validator, "GitHub latest supplied no usable validator")
        let next = try await transport.load(etag: etag, highWater: latest.receipt, now: Date())
        let second: String
        switch next {
        case .notModified(let responseTag):
            if let responseTag { XCTAssertEqual(responseTag, etag) }
            second = "next_metadata_status=304"
        case .candidate(let publishedDuringRun, _):
            XCTAssertGreaterThan(publishedDuringRun.receipt.tag, latest.receipt.tag)
            second = "next_metadata_status=200\n" + geoSiteReceipt(publishedDuringRun)
        }
        attachGeoSiteWitness(geoSiteReceipt(latest) + "\n" + second, name: "Canonical GitHub native HTTPS and admission")
    }
}

private func geoSiteReceipt(_ candidate: AccessGeoSiteAdmission.Candidate) -> String {
    let receipt = candidate.receipt
    return """
    metadata_status=200 database_status=200 checksum_status=200
    tag=\(receipt.tag) release_id=\(receipt.releaseID) groups=\(candidate.categoryCount)
    database_id=\(receipt.database.id) bytes=\(receipt.database.byteCount) sha256=\(receipt.database.sha256)
    checksum_id=\(receipt.checksum.id) bytes=\(receipt.checksum.byteCount) sha256=\(receipt.checksum.sha256)
    """
}

private extension XCTestCase {
    func attachGeoSiteWitness(_ value: String, name: String) {
        let witness = XCTAttachment(string: value)
        witness.name = name
        witness.lifetime = .keepAlways
        add(witness)
    }
}

@MainActor
private struct GeoSiteTestInstall {
    let storage = AccessGeoSiteStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                       service: "geosite-native." + UUID().uuidString)
    private let offset = OSAllocatedUnfairLock(initialState: 0.0)

    var now: Date { Date().addingTimeInterval(offset.withLock { $0 }) }
    func advance(_ seconds: TimeInterval) { offset.withLock { $0 += seconds } }

    func restore(migrating: AccessGeoSiteCache.Selection = .init(mode: .smart, categories: [.debian, .douban, .meituan]))
        async -> AccessGeoSiteCache {
        let offset = self.offset
        let cache = AccessGeoSiteCache(storage: storage,
            time: .init(wall: { Date().addingTimeInterval(offset.withLock { $0 }) }))
        await cache.restore(migrating: migrating)
        return cache
    }

    func clean() {
        try? FileManager.default.removeItem(at: storage.directory)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: storage.service] as CFDictionary)
    }

    static func window(_ coordinator: AccessHostStoreCoordinator) -> BrowserSession {
        BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
    }

    func wait(file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("GeoSite state did not settle", file: file, line: line)
        throw CocoaError(.featureUnsupported)
    }
}

@MainActor
final class AccessGeoSiteSettingsFixtureTests: XCTestCase {
    func testPrepareVerifiedStagedScopeForSettings() async throws {
        let fixture = try GeoSiteHTTPSFixture()
        try await fixture.select("expand", version: 1, reset: true)
        let storage = try AccessGeoSiteStorage.consentUITest(keep: false)
        let cache = AccessGeoSiteCache(storage: storage)
        await cache.restore(migrating: .init(mode: .smart, categories: [.debian, .douban]))
        let coordinator = AccessHostStoreCoordinator(channel: .dev, geoSiteCache: cache, geoSiteTransport: fixture.transport())
        let browser = GeoSiteTestInstall.window(coordinator)
        defer { browser.closeWindow() }
        browser.setWindowForeground(true)
        try await GeoSiteTestInstall().wait { cache.highWater?.releaseID == 1001 }
        let proposal = try XCTUnwrap(coordinator.websiteCategoryProposal(.douban, for: browser))
        XCTAssertEqual(proposal.addedRules.map(\.host), ["expanded.example.com"])
        let receipt = try XCTUnwrap(cache.highWater)
        let reopened = AccessGeoSiteCache(storage: storage)
        await reopened.restore()
        XCTAssertEqual(reopened.highWater, receipt)
        XCTAssertEqual(reopened.view.staged[.douban]?.addedRules, proposal.addedRules)
    }
}

@MainActor
final class AccessGeoSiteSwitchingTests: XCTestCase {
    func testWindowForegroundEpochInvalidatesApprovalDuringDiskPublish() async throws {
        let blocked = OSAllocatedUnfairLock(initialState: false)
        let armed = OSAllocatedUnfairLock(initialState: false)
        let resume = DispatchSemaphore(value: 0)
        let storage = AccessGeoSiteStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                           service: "geosite-approval." + UUID().uuidString) { step in
            if step == .afterFileSync, armed.withLock({ $0 }) {
                blocked.withLock { $0 = true }
                guard resume.wait(timeout: .now() + 6) == .success else { throw CocoaError(.fileWriteUnknown) }
            }
        }
        defer {
            resume.signal()
            try? FileManager.default.removeItem(at: storage.directory)
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: storage.service] as CFDictionary)
        }
        let cache = AccessGeoSiteCache(storage: storage, time: .init(wall: { AccessGeoSiteTestVector.now }))
        await cache.restore(migrating: .init(mode: .smart, categories: [.douban]))
        typealias Vector = AccessGeoSiteTestVector
        let raw = Vector.group("DOUBAN", rules: [
            Vector.rule(2, "douban.com"), Vector.rule(2, "douban.fm"), Vector.rule(2, "doubanio.com"),
            Vector.rule(2, "expanded.example.com")
        ])
        let candidate = try Vector.admit(raw, newer: true)
        try await cache.apply(candidate, using: XCTUnwrap(cache.updateContext()))
        let coordinator = AccessHostStoreCoordinator(channel: .dev, geoSiteCache: cache)
        let window = GeoSiteTestInstall.window(coordinator)
        let other = GeoSiteTestInstall.window(coordinator)
        defer { window.closeWindow(); other.closeWindow() }
        window.setWindowForeground(true)
        other.setWindowForeground(true)
        let proposal = try XCTUnwrap(coordinator.websiteCategoryProposal(.douban, for: window))
        armed.withLock { $0 = true }
        let click = Task { await coordinator.confirmWebsiteCategory(proposal, for: window) }
        try await GeoSiteTestInstall().wait { blocked.withLock { $0 } }
        window.switchProfile(to: .privateMode)
        XCTAssertNil(coordinator.websiteCategoryProposal(.douban, for: window))
        window.switchProfile(to: .standard)
        resume.signal()
        let accepted = await click.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(cache.match(URL(string: "https://expanded.example.com/")!), .original)
        XCTAssertEqual(coordinator.websiteCategoryProposal(.douban, for: other), proposal)
    }
}
#endif
