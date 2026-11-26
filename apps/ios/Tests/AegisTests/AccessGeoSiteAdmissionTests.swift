import AccessKit
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Aegis

final class AccessGeoSiteAdmissionTests: XCTestCase {
    typealias Vector = AccessGeoSiteTestVector

    func testOfficialSelectedWireProjectionMatchesSignedGroups() throws {
        let database = Vector.selectedProjection
        XCTAssertEqual(database.count, 424)
        XCTAssertEqual(Vector.sha(database), "6704ff3c753be85d7b438e3d70b72e3097dc44bd99c764a4af3cddf6f59704e1")
        let result = try Vector.admit(database)
        XCTAssertEqual(result.categoryCount, 3)
        XCTAssertEqual(result.catalogue.groups, AccessGeoSiteCatalogue.bundled.groups)
        XCTAssertEqual(result.receipt.database.sha256, Vector.sha(database))
        XCTAssertEqual(result.suffixListSHA256, "ba7d836c0ea57a8bcf9f1fcb868066a7554bed029b441ecc6204ad8494a32612")
    }

    func testTypedRulesUseDNSLabelBoundariesAndCanFollowUnselectedWireRecords() throws {
        let attribute = Vector.field(1, Data("cn".utf8)) + Vector.scalar(2, 1)
        let unselected = Vector.group("CATEGORY-AI-!CN", rules: [
            Vector.rule(1, "regexp", attribute: attribute),
            Vector.rule(0, "keyword")
        ])
        let rules = [Vector.rule(3, "exact.example.net"), Vector.rule(2, "xn--bcher-kva.de")]
        let result = try Vector.admit(unselected + Vector.group("DEBIAN", rules: rules, nameLast: true))
        XCTAssertEqual(result.categoryCount, 2)
        let group = try XCTUnwrap(result.catalogue.groups[.debian])
        XCTAssertEqual(group.rules.map(\.kind), [.domain, .full])
        XCTAssertEqual(group.typedSHA256, Vector.sha(Data("domain:xn--bcher-kva.de\nfull:exact.example.net\n".utf8)))
        let route = AccessWebsiteRoutePolicy(catalogue: result.catalogue)
        XCTAssertTrue(route.matches(URL(string: "https://www.bücher.de./")!))
        XCTAssertTrue(route.matches(URL(string: "https://exact.example.net/")!))
        XCTAssertFalse(route.matches(URL(string: "https://child.exact.example.net/")!))
        XCTAssertFalse(route.matches(URL(string: "https://notxn--bcher-kva.de/")!))
    }

    func testPinnedPSLRecognizesPrivateTenantsWildcardAndException() throws {
        let positives: [(Int, String)] = [
            (2, "tenant.github.io"), (2, "www.ck"), (2, "sub.test.ck"), (3, "amazonaws.com"),
            (2, "city.kawasaki.jp")
        ]
        for (type, host) in positives {
            let result = try Vector.admit(Vector.group("DOUBAN", rules: [Vector.rule(type, host)]))
            XCTAssertEqual(result.catalogue.groups[.douban]?.rules.first?.host, host)
        }
        let invalid: [(Int, String)] = [
            (2, "com"), (3, "co.uk"), (2, "github.io"), (3, "tenant.ck"), (2, "amazonaws.com"),
            (2, "kawasaki.jp"), (3, "x.invalid-tld"), (2, "127.0.0.1"), (3, "office.home.arpa"),
            (2, "Example.com"), (2, "example.com."), (2, "a..example.com"), (2, "a%40example.com"),
            (2, "bücher.de"), (2, "xn--.de"), (2, "xn--a.de")
        ]
        for (type, host) in invalid {
            XCTAssertThrowsError(try Vector.admit(Vector.group("DOUBAN", rules: [
                Vector.rule(2, "douban.com"), Vector.rule(type, host)
            ])), host) { XCTAssertEqual($0 as? AccessGeoSiteAdmission.Failure, .malformedDatabase) }
        }
    }

    func testEmptyAndMissingMenuGroupsAreExplicitInACompleteNewerDatabase() throws {
        let initial = try Vector.admit(Vector.selectedProjection)
        let updated = try Vector.admit(Vector.group("DOUBAN", rules: []) + Vector.group("DEBIAN", rules: [
            Vector.rule(2, "debian.org")
        ]), newer: true, highWater: initial.receipt)
        XCTAssertEqual(updated.categoryCount, 2)
        XCTAssertEqual(Set(updated.catalogue.groups.keys), [.debian])
        XCTAssertGreaterThan(updated.receipt.tag, initial.receipt.tag)
    }

    func testRejectsInvalidCompleteDatabasesAfterBothHashesMatch() throws {
        let valid = Vector.group("DOUBAN", rules: [Vector.rule(2, "douban.com")])
        let malformed: [Data] = [
            Data(), valid.dropLast(), valid + Data([0]),
            valid + Data(repeating: 0xff, count: 11),
            valid + Data([0x0a, 0xff, 0xff, 0xff, 0xff, 0x7f]),
            valid + Data([0x0b, 0x0b, 0x0c, 0x0c]),
            valid + valid,
            valid + Vector.group("douban", rules: []),
            valid + Vector.group("UNSELECTED", rules: [Data([0x12, 0x05, 0x20])]),
            Vector.group("DOUBAN", rules: [Vector.rule(1, "douban.com")]),
            Vector.group("DOUBAN", rules: [Vector.rule(99, "douban.com")]),
            Vector.group("DOUBAN", rules: [Vector.rule(2, "douban.com", attribute: Data())]),
            Vector.group("DOUBAN", rules: [Vector.rule(2, "douban.com"), Vector.rule(2, "douban.com")]),
            Vector.group("DOUBAN", rules: [Vector.rule(2, "douban.com") + Vector.scalar(1, 2)]),
            Vector.group("DOUBAN", rules: (0..<129).map { Vector.rule(2, "site\($0).example.com") }),
            (0...4096).reduce(into: Data()) { $0 += Vector.group("UNSELECTED-\($1)", rules: []) }
        ]
        for (index, database) in malformed.enumerated() {
            XCTAssertThrowsError(try Vector.admit(database), "invalid database \(index)") {
                XCTAssertEqual($0 as? AccessGeoSiteAdmission.Failure, database.isEmpty ? .invalidAsset : .malformedDatabase)
            }
        }
    }

    func testReleaseIdentitySameTagReceiptLowerTagAndHigherRepublish() throws {
        XCTAssertEqual(AccessGeoSiteAdmission.metadataURL.absoluteString,
                       "https://api.github.com/repos/XTLS/Xray-rules-dat/releases/latest")
        let data = Vector.selectedProjection
        let first = try Vector.admit(data)
        let same = try Vector.admit(data, highWater: first.receipt)
        XCTAssertEqual(same.receipt, first.receipt)
        let newer = try Vector.admit(data, newer: true, highWater: first.receipt)
        XCTAssertEqual(newer.catalogue.groups, first.catalogue.groups)
        XCTAssertEqual(newer.receipt.database.sha256, first.receipt.database.sha256)
        XCTAssertThrowsError(try Vector.admit(data, highWater: newer.receipt)) {
            XCTAssertEqual($0 as? AccessGeoSiteAdmission.Failure, .rollback)
        }
        XCTAssertThrowsError(try Vector.admit(Vector.group("DOUBAN", rules: []), highWater: first.receipt)) {
            XCTAssertEqual($0 as? AccessGeoSiteAdmission.Failure, .equivocation)
        }
        let changed = try Vector.release(data) { $0["published_at"] = "2026-11-20T23:52:17Z" }
        XCTAssertThrowsError(try AccessGeoSiteAdmission.metadata(changed.metadata, now: Vector.now, highWater: first.receipt)) {
            XCTAssertEqual($0 as? AccessGeoSiteAdmission.Failure, .equivocation)
        }
    }

    func testRejectsWrongMetadataOriginIdentitySchemaAndTimes() throws {
        let data = Vector.selectedProjection
        let cases: [(String, Any)] = [
            ("url", "https://api.github.com/repos/other/Xray-rules-dat/releases/453302649"),
            ("html_url", "https://aegis.invalid/XTLS/Xray-rules-dat/releases/tag/20261120235103"),
            ("tag_name", "20261120305103"), ("tag_name", "20260230235103"), ("tag_name", "２０２６１１２０２３５１０３"),
            ("tag_name", "2026112023510"), ("draft", true), ("prerelease", true),
            ("published_at", "2026-11-20T23:50:00Z"), ("published_at", "2026-11-21T00:05:01Z"),
            ("published_at", "2026-11-20T15:52:15-08:00"), ("published_at", "2026-11-20T23:52:60Z")
        ]
        for (field, badValue) in cases {
            let input = try Vector.release(data) { $0[field] = badValue }
            XCTAssertThrowsError(try AccessGeoSiteAdmission.metadata(input.metadata, now: Vector.now), "\(field)=\(badValue)")
        }
        let valid = try Vector.release(data)
        XCTAssertThrowsError(try AccessGeoSiteAdmission.metadata(valid.metadata, now: Vector.now.addingTimeInterval(7 * 86_400))) {
            XCTAssertEqual($0 as? AccessGeoSiteAdmission.Failure, .invalidTime)
        }
    }

    func testVerifiesEachAssetAndChecksumPairAndEnforcesByteCaps() throws {
        let data = Vector.selectedProjection
        let vector = try Vector.release(data)
        func admits(_ metadata: Data, database: Data = Vector.selectedProjection, checksum: Data? = nil) throws {
            _ = try AccessGeoSiteAdmission.admit(metadata: metadata, database: database,
                                                checksum: checksum ?? vector.checksum, now: Vector.now)
        }
        XCTAssertNoThrow(try admits(vector.metadata))
        XCTAssertThrowsError(try admits(vector.metadata, database: data + Data([0])))
        XCTAssertThrowsError(try admits(vector.metadata, checksum: vector.checksum + Data([10])))
        for checksum in [Data("\(String(repeating: "0", count: 64))  geosite.dat\n".utf8),
                         Data("\(Vector.sha(data))  geosite.dat.gz\n".utf8),
                         vector.checksum + vector.checksum,
                         Data(repeating: 1, count: 4097)] {
            let input = try Vector.release(data, checksum: checksum)
            XCTAssertThrowsError(try admits(input.metadata, checksum: checksum))
        }
        for index in 0..<6 {
            let input = try Vector.release(data) { metadata in
                var assets = try XCTUnwrap(metadata["assets"] as? [[String: Any]], "Expected release asset dictionaries")
                switch index {
                case 0: assets.append(assets[0])
                case 1: assets[0]["digest"] = nil
                case 2: assets[0]["browser_download_url"] = "https://github.com/XTLS/Xray-rules-dat/releases/download/20261120235104/geosite.dat"
                case 3: assets[1]["name"] = "geosite.dat.gz.sha256sum"
                case 4: assets[0]["url"] = "https://api.github.com/repos/other/Xray-rules-dat/releases/assets/773779405"
                default: assets[0]["size"] = 16 * 1024 * 1024 + 1
                }
                metadata["assets"] = assets
            }
            XCTAssertThrowsError(try admits(input.metadata), "asset case \(index)")
        }
        XCTAssertThrowsError(try admits(Data(repeating: 32, count: 256 * 1024 + 1)))
        XCTAssertThrowsError(try admits(vector.metadata, database: Data(repeating: 1, count: 16 * 1024 * 1024 + 1)))
    }
}

/// Select this suite explicitly with the geosite-official-data native fixture.
final class AccessGeoSiteFullFrozenAdmissionTests: XCTestCase {
    @MainActor
    func testFullFrozenOfficialDatabase() async throws {
        let (metadata, database, checksum) = try await AccessGeoSiteTestVector.frozenOfficialAssets()
        let candidate = try AccessGeoSiteAdmission.admit(metadata: metadata, database: database, checksum: checksum,
                                                         now: AccessGeoSiteTestVector.now)
        XCTAssertEqual(candidate.categoryCount, 1572)
        XCTAssertEqual(candidate.receipt.releaseID, 453302649)
        XCTAssertEqual(candidate.receipt.tag, AccessGeoSiteCatalogue.bundled.tag)
        XCTAssertEqual(candidate.receipt.database.sha256, AccessGeoSiteCatalogue.bundled.rawSHA256)
        XCTAssertEqual(candidate.receipt.checksum.sha256, "9d153aa5f78ff022a85726e42522ea00776e87b30e4c2519c8e04dbd795893e6")
        XCTAssertEqual(candidate.catalogue.groups, AccessGeoSiteCatalogue.bundled.groups)
        let combined = try AccessGeoSiteAdmission.admit(metadata: metadata, database: database, checksum: checksum,
            now: AccessGeoSiteTestVector.now, includeOverseas: true)
        XCTAssertEqual(combined.catalogue, candidate.catalogue)
        XCTAssertEqual(combined.categoryCount, candidate.categoryCount)
        XCTAssertNil(candidate.overseas)
        let overseas = try XCTUnwrap(combined.overseas)
        XCTAssertEqual(overseas.counts.source, 4_417)
        XCTAssertEqual(overseas.counts.admitted, 4_368)
        XCTAssertEqual(overseas.counts.rejected, 36)
        XCTAssertEqual(overseas.counts.unsupported, 13)
        XCTAssertEqual(overseas.counts.exclusions, 32)
        XCTAssertEqual(overseas.hosts.values.reduce(0) { $0 + $1.count }, 34)
        XCTAssertEqual(overseas.hosts, [
            .video: ["www.youtube.com", "www.netflix.com", "vimeo.com", "www.twitch.tv", "m.youtube.com", "m.twitch.tv"],
            .ai: ["chatgpt.com", "claude.ai", "gemini.google.com", "www.perplexity.ai"],
            .web: ["www.google.com", "duckduckgo.com", "search.yahoo.com"],
            .social: ["x.com", "www.instagram.com", "t.me", "discord.com", "telegram.org"],
            .news: ["www.bbc.com", "www.nytimes.com", "www.reuters.com", "www.dw.com"],
            .development: ["github.com", "gist.github.com", "raw.githubusercontent.com", "hub.docker.com"],
            .reference: ["zh.wikipedia.org", "scholar.google.com", "archive.org"],
            .cloud: ["drive.google.com", "docs.google.com", "www.dropbox.com", "onedrive.live.com", "accounts.google.com"],
        ])
        // iPhone WebKit lands on these hosts after the first hop of a listed entry.
        // Category mode must keep them on the overseas route, and only in their own category.
        for (entry, landing, category, other) in [
            ("www.youtube.com", "m.youtube.com", AccessOverseasCategory.video, AccessOverseasCategory.ai),
            ("www.twitch.tv", "m.twitch.tv", .video, .social),
            ("drive.google.com", "accounts.google.com", .cloud, .web),
            ("docs.google.com", "accounts.google.com", .cloud, .ai),
            ("t.me", "telegram.org", .social, .video),
        ] {
            let entryURL = try XCTUnwrap(URL(string: "https://\(entry)/"))
            let landingURL = try XCTUnwrap(URL(string: "https://\(landing)/"))
            XCTAssertTrue(overseas.matches(entryURL, scope: .categories([category])), entry)
            XCTAssertTrue(overseas.matches(landingURL, scope: .categories([category])), landing)
            XCTAssertFalse(overseas.matches(landingURL, scope: .categories([other])), landing)
            XCTAssertFalse(overseas.matches(try XCTUnwrap(URL(string: "https://child.\(landing)/")),
                                            scope: .categories([category])), landing)
        }
        try await checkOverseasColdCache(combined, name: "official DAT", positive: "ampproject.org",
                                         exception: "www.ampproject.org")
    }

    @MainActor
    func testOverseasColdCacheAtSourceRecordLimits() async throws {
        typealias Vector = AccessGeoSiteTestVector
        let positives = [Vector.rule(2, "example.com")]
            + (1..<8_192).map { Vector.rule(3, "positive-\($0).example.net") }
        let exclusions = (0..<512).map { Vector.rule(2, "exception-\($0).example.com") }
        let data = Vector.group("GFWLIST-CN", rules: positives)
            + Vector.group("GFWLIST-CN-EXCLUDE", rules: exclusions)
        let candidate = try Vector.admit(data, newer: true, includeOverseas: true)
        XCTAssertEqual(candidate.overseas?.counts.admitted, 8_192)
        XCTAssertEqual(candidate.overseas?.counts.exclusions, 512)
        try await checkOverseasColdCache(candidate, name: "source rule limits", positive: "example.com",
                                         exception: "exception-0.example.com")
    }

    @MainActor
    private func checkOverseasColdCache(_ candidate: AccessGeoSiteAdmission.Candidate, name: String,
                                        positive positiveHost: String, exception exceptionHost: String) async throws {
        let fixture = AccessGeoSiteCacheTests.Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .smart, categories: []))
        try cache.requestOverseasPreview()
        try await cache.apply(candidate, using: XCTUnwrap(cache.updateContext()))
        let choice = AccessOverseasSelection(enabled: true, mode: .all)
        try await cache.confirmOverseas(cache.overseasConfirmation(for: choice)) { true }
        let cold = fixture.cache()
        let clock = ContinuousClock()
        let started = clock.now
        await cold.restore()
        let load = started.duration(to: clock.now)
        let active = cold.runtimeView().overseas
        XCTAssertEqual(active.selection, choice)
        let positive = try XCTUnwrap(URL(string: "https://\(positiveHost)/"))
        let exception = try XCTUnwrap(URL(string: "https://\(exceptionHost)/"))
        XCTAssertEqual(active.match(positive), .managed)
        XCTAssertEqual(active.match(exception), .original)
        let files = try FileManager.default.contentsOfDirectory(at: fixture.storage.directory, includingPropertiesForKeys: [.fileSizeKey])
        let sizes = try files.filter { $0.lastPathComponent.hasPrefix("overseas-") && $0.pathExtension == "json" }
            .map { try XCTUnwrap($0.resourceValues(forKeys: [.fileSizeKey]).fileSize) }
        XCTAssertEqual(sizes.count, 2)
        XCTAssertTrue(sizes.allSatisfy { (AccessGeoSiteStorage.blobLimit + 1...AccessGeoSiteStorage.overseasBlobLimit).contains($0) })
        var samples: [Duration] = []
        var matches = 0
        for _ in 0..<1_000 {
            let start = clock.now
            if active.match(positive) == .managed { matches += 1 }
            _ = active.match(exception)
            samples.append(start.duration(to: clock.now))
        }
        XCTAssertEqual(matches, 1_000)
        var usage = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
        print("Overseas \(name): blob sizes \(sizes.sorted()) bytes, offline cold restore \(load), hot hit+exception pair p95 \(samples.sorted()[949]), app test process peak RSS \(usage.ru_maxrss) bytes")
        fixture.clock.advance(by: 8 * 86_400)
        XCTAssertEqual(cold.runtimeView().overseas.match(positive), .indeterminate)
        XCTAssertEqual(cold.runtimeView().overseas.match(exception), .original)
    }
}

final class AccessOverseasAdmissionTests: XCTestCase {
    private typealias Vector = AccessGeoSiteTestVector

    func testMixedIntersectionSealsAndRecoversBothSourceExceptionSets() throws {
        let choice = AccessOverseasSelection(enabled: true, mode: .all)
        let shared = [Vector.rule(2, "example.com")]
        let prior = try AccessOverseasCacheSnapshot(overseasCandidate(shared + [Vector.rule(2, "example.org")],
            excluding: (0..<512).map { Vector.rule(2, "old-\($0).example.com") })).approving(choice)
        let offered = try AccessOverseasCacheSnapshot(overseasCandidate(shared + [Vector.rule(2, "example.net")],
            excluding: (0..<512).map { Vector.rule(3, "new-\($0).example.com") }, newer: true))
        let intersection = try XCTUnwrap(offered.narrowed(to: choice, retaining: prior))

        let recovered = try roundTrip(intersection, approved: choice)
        XCTAssertEqual(recovered.exclusions.count, 1_024)
        XCTAssertTrue(recovered.matches(try url("safe.example.com")))
        XCTAssertTrue(recovered.matches(try url("child.new-511.example.com")))
        for host in ["child.old-511.example.com", "new-511.example.com", "example.org", "example.net"] {
            XCTAssertFalse(recovered.matches(try url(host)), host)
        }
    }

    func testChainedIntersectionKeepsProvableCoverageWhenExceptionsOverflow() throws {
        let rules = [Vector.rule(2, "example.com"), Vector.rule(2, "safe.example.com"),
                     Vector.rule(2, "example.org"), Vector.rule(3, "keep.example.com")]
        func policy(_ prefix: String) throws -> AccessOverseasCatalogue.Policy {
            let exclusions = (0..<512).map { Vector.rule(2, "\(prefix)-\($0).example.com") }
            let candidate = try overseasCandidate(rules, excluding: exclusions)
            return try XCTUnwrap(candidate.overseas).policy(for: .all)
        }
        let first = try policy("a")
        let second = try policy("b")
        let third = try policy("c")
        let prior = try XCTUnwrap(first.intersection(with: second))
        let intersection = try XCTUnwrap(third.intersection(with: prior))

        XCTAssertEqual(intersection, prior.intersection(with: third))
        for host in ["example.com", "keep.example.com", "child.safe.example.com", "child.example.org"] {
            XCTAssertTrue(intersection.matches(try url(host)), host)
        }
        for host in ["a-511.example.com", "b-511.example.com", "c-511.example.com", "child.keep.example.com"] {
            XCTAssertFalse(intersection.matches(try url(host)), host)
        }
    }

    func testMixedIntersectionKeepsProvableCoverageWhenSnapshotBytesOverflow() throws {
        let choice = AccessOverseasSelection(enabled: true, mode: .all)
        let label = String(repeating: "a", count: 63)
        let longPrefix = [label, label, label, String(repeating: "b", count: 44)].joined(separator: ".")
        func hosts(under domain: String) -> [Data] {
            (1_000...9_189).map { Vector.rule(3, "\(longPrefix).\($0).\(domain)") }
        }
        let shared = [Vector.rule(3, "keep.example.org")]
        let prior = try AccessOverseasCacheSnapshot(overseasCandidate(
            [Vector.rule(2, "example.com")] + shared + hosts(under: "example.net"))).approving(choice)
        let offered = try AccessOverseasCacheSnapshot(overseasCandidate(
            [Vector.rule(2, "example.net")] + shared + hosts(under: "example.com"), newer: true))
        let intersection = try XCTUnwrap(offered.narrowed(to: choice, retaining: prior))

        let recovered = try roundTrip(intersection, approved: choice)
        XCTAssertGreaterThan(recovered.rules.count, 8_192)
        XCTAssertLessThan(recovered.rules.count, 16_381)
        XCTAssertTrue(recovered.matches(try url("keep.example.org")))
        XCTAssertFalse(recovered.matches(try url("unlisted.example.net")))
    }

    private func overseasCandidate(_ rules: [Data], excluding exclusions: [Data] = [], newer: Bool = false) throws
        -> AccessGeoSiteAdmission.Candidate {
        let database = Vector.group("GFWLIST-CN", rules: rules) + Vector.group("GFWLIST-CN-EXCLUDE", rules: exclusions)
        return try Vector.admit(database, newer: newer, includeOverseas: true)
    }

    private func roundTrip(_ snapshot: AccessOverseasCacheSnapshot, approved: AccessOverseasSelection) throws
        -> AccessOverseasCatalogue.Policy {
        let owner = UUID()
        let storage = AccessGeoSiteStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(owner.uuidString),
                                          service: "aegis.geosite.test." + owner.uuidString)
        defer { try? FileManager.default.removeItem(at: storage.directory) }
        let reference = try snapshot.seal(owner: owner, storage: storage)
        XCTAssertLessThan(reference.length, 4 * 1024 * 1024)
        let recovered = try AccessOverseasCacheSnapshot.recover(reference, owner: owner, approved: approved,
                                                              storage: storage, now: Vector.now)
        XCTAssertEqual(recovered.policy, snapshot.policy)
        return recovered.policy
    }

    private func url(_ host: String) throws -> URL {
        try XCTUnwrap(URL(string: "https://\(host)/"))
    }

    func testExactCategoryDeltaOnlyReportsNewlyReachableHosts() throws {
        let mother = Vector.group("GFWLIST-CN", rules: [Vector.rule(2, "google.com"), Vector.rule(3, "chatgpt.com")])
        let topic = Vector.group("GOOGLE-GEMINI", rules: [Vector.rule(3, "gemini.google.com")])
        let oldExceptions = Vector.group("GFWLIST-CN-EXCLUDE", rules: (1...33).map { Vector.rule(2, "x-\($0).example.com") })
        let prior = try XCTUnwrap(Vector.admit(mother + oldExceptions + topic, includeOverseas: true).overseas)
        let newTopic = Vector.group("OPENAI", rules: [Vector.rule(3, "chatgpt.com")])
        let newExceptions = Vector.group("GFWLIST-CN-EXCLUDE", rules: [])
        let offered = try XCTUnwrap(Vector.admit(mother + newExceptions + topic + newTopic, includeOverseas: true).overseas)
        let previous = try prior.policy(for: .categories([.ai]))
        let delta = try offered.policy(for: .categories([.ai])).expansion(over: previous)
        XCTAssertEqual(delta.rules.map(\.value), ["chatgpt.com"])
        XCTAssertEqual(delta.removedExclusions.count, 0)
    }

    func testAllModeDoesNotChargeNarrowerExceptionsThatStillCoverEveryPositiveHost() throws {
        let exact = (1...33).map { "x.s\($0).example.net" }
        let oldRules = [Vector.rule(2, "example.com")] + exact.map { Vector.rule(3, $0) }
        let oldExceptions = (1...33).map { Vector.rule(2, "s\($0).example.net") }
        let newExceptions = exact.map { Vector.rule(3, $0) }
        func policy(_ rules: [Data], exclusions: [Data]) throws -> AccessOverseasCatalogue.Policy {
            let data = Vector.group("GFWLIST-CN", rules: rules) + Vector.group("GFWLIST-CN-EXCLUDE", rules: exclusions)
            return try XCTUnwrap(Vector.admit(data, includeOverseas: true).overseas).policy(for: .all)
        }
        let old = try policy(oldRules, exclusions: oldExceptions)
        let offered = try policy(oldRules + [Vector.rule(3, "reachable.example.org")], exclusions: newExceptions)
        let delta = offered.expansion(over: old)
        XCTAssertEqual(delta.rules.map(\.value), ["reachable.example.org"])
        XCTAssertTrue(delta.removedExclusions.isEmpty)
        let root = "root.example.org"
        let withRoot = oldRules + [Vector.rule(3, root)]
        let excluded = try policy(withRoot, exclusions: oldExceptions + [Vector.rule(2, root)])
        let admitted = try policy(withRoot, exclusions: newExceptions)
        XCTAssertEqual(admitted.expansion(over: excluded).removedExclusions.map(\.value), [root])

        let keep = Vector.rule(3, "keep.example.org")
        let rootExclusion = Vector.rule(2, "example.com")
        let oldKeywords = (1...33).map { Vector.rule(0, "blocked-\($0)") }
        let raw = [Vector.rule(2, "example.com"), keep]
        let finiteOld = try policy(raw, exclusions: [rootExclusion] + oldKeywords)
        let finiteNew = try policy(raw + [Vector.rule(3, "new.example.org")], exclusions: [rootExclusion])
        XCTAssertEqual(finiteNew.expansion(over: finiteOld).rules.map(\.value), ["new.example.org"])
        XCTAssertTrue(finiteNew.expansion(over: finiteOld).removedExclusions.isEmpty)

        let suffix = Vector.rule(2, "example.com")
        let suffixOld = try policy([suffix], exclusions: oldKeywords)
        let suffixNew = try policy([suffix, Vector.rule(2, "example.net")], exclusions: [Vector.rule(0, ".example.com")])
        let apex = try XCTUnwrap(suffixNew.intersection(with: suffixOld))
        XCTAssertEqual(apex.rules.map(\.value), ["example.com"])
        XCTAssertEqual(apex.rules.map(\.kind), [.full])
        for previous in [suffixOld, apex] {
            let expansion = suffixNew.expansion(over: previous)
            XCTAssertEqual(expansion.rules.map(\.value), ["example.net"])
            XCTAssertTrue(expansion.removedExclusions.isEmpty)
        }

        let shared = (1...511).map { Vector.rule(2, "excluded-\($0).example.org") }
        let mixedOld = try policy(raw, exclusions: shared + [Vector.rule(2, "old.example.org")])
        let mixedNew = try policy([Vector.rule(2, "example.net"), keep],
                                  exclusions: shared + [Vector.rule(2, "new.example.org")])
        XCTAssertEqual(try XCTUnwrap(mixedNew.intersection(with: mixedOld)).rules.map(\.value), ["keep.example.org"])

        let retainedDomain = Vector.rule(2, "example.com")
        let domainOld = try policy([retainedDomain], exclusions: shared + [Vector.rule(2, "old.example.org")])
        let domainNew = try policy([retainedDomain, Vector.rule(2, "example.net")],
                                   exclusions: shared + [Vector.rule(2, "new.example.org")])
        let intersection = try XCTUnwrap(domainNew.intersection(with: domainOld))
        XCTAssertEqual(intersection.rules.map(\.value), ["example.com"])
        XCTAssertTrue(intersection.exclusions.isEmpty)

        let blockedExact = (1...17).map { Vector.rule(3, "formerly-blocked-\($0).example.org") }
        let beforeRemoval = try policy([retainedDomain] + blockedExact, exclusions: blockedExact)
        let afterRemoval = try policy([retainedDomain] + blockedExact, exclusions: [])
        let retained = try XCTUnwrap(afterRemoval.intersection(with: beforeRemoval))
        let newlyReachable = afterRemoval.expansion(over: retained)
        XCTAssertEqual(newlyReachable.rules.count, 17)
        XCTAssertTrue(newlyReachable.removedExclusions.isEmpty)

        let redundant = (1...510).map { Vector.rule(3, "child-\($0).blocked.example.com") }
        let deniedDomain = Vector.rule(2, "blocked.example.com")
        let domainAccounts = [deniedDomain] + redundant
        let unionOld = try policy([retainedDomain], exclusions: domainAccounts + [Vector.rule(3, "old.blocked.example.com")])
        let unionNew = try policy([retainedDomain, Vector.rule(2, "example.net")],
                                  exclusions: domainAccounts + [Vector.rule(3, "new.blocked.example.com")])
        let compressed = try XCTUnwrap(unionNew.intersection(with: unionOld))
        XCTAssertEqual(compressed.exclusions.map(\.value), ["blocked.example.com"])

        let redundantHosts = (1...32).map { Vector.rule(3, "new-\($0).example.com") }
        let baseline = try policy([Vector.rule(2, "example.org")], exclusions: [])
        let expanded = try policy([Vector.rule(2, "example.org"), retainedDomain] + redundantHosts, exclusions: [])
        XCTAssertEqual(expanded.expansion(over: baseline).rules.map(\.value), ["example.com"])

        let permittedChild = Vector.rule(2, "sub.example.com")
        let previousExclusions = (1...33).map { Vector.rule(2, "blocked-\($0).sub.example.com") }
        let childPolicy = try policy([permittedChild], exclusions: previousExclusions)
        let parentPolicy = try policy([retainedDomain], exclusions: [])
        let narrower = try XCTUnwrap(parentPolicy.intersection(with: childPolicy))
        let lift = parentPolicy.expansion(over: narrower)
        XCTAssertEqual(lift.rules.map(\.value), ["example.com"])
        XCTAssertEqual(lift.removedExclusions.count, 33)

        let blockChildren = Vector.rule(0, ".example.com")
        let unrelatedKeywords = (1...33).map { Vector.rule(0, "k\($0)") }
        let apexBefore = try policy([retainedDomain], exclusions: [blockChildren] + unrelatedKeywords)
        let apexAfter = try policy([retainedDomain, Vector.rule(3, "example.net")], exclusions: [blockChildren])
        let apexDelta = apexAfter.expansion(over: try XCTUnwrap(apexAfter.intersection(with: apexBefore)))
        XCTAssertEqual(apexDelta.rules.map(\.value), ["example.net"])
        XCTAssertTrue(apexDelta.removedExclusions.isEmpty)

        let combinedHosts = (1...33).map { "x\($0).example.com" }
        let suffixExclusions = try policy([retainedDomain], exclusions: combinedHosts.map { Vector.rule(2, $0) })
        let equivalent = try policy([retainedDomain, Vector.rule(3, "new.example.net")],
            exclusions: combinedHosts.map { Vector.rule(3, $0) } + [Vector.rule(0, ".x")])
        let combinedDelta = equivalent.expansion(over: suffixExclusions)
        XCTAssertEqual(combinedDelta.rules.map(\.value), ["new.example.net"])
        XCTAssertTrue(combinedDelta.removedExclusions.isEmpty)

        let olderHosts = (1...4_200).map { Vector.rule(3, "old-\($0).example.com") }
        let newerHosts = (1...4_200).map { Vector.rule(3, "new-\($0).example.com") }
        let earlier = try policy([retainedDomain] + olderHosts, exclusions: [])
        let later = try policy([retainedDomain, Vector.rule(2, "example.net")] + newerHosts, exclusions: [])
        XCTAssertEqual(try XCTUnwrap(later.intersection(with: earlier)).rules.map(\.value), ["example.com"])
    }

    func testCuratedRulesUseOnlyApprovedHTTPSHostsAndApplyBothExclusionTypes() throws {
        let positive = Vector.group("GFWLIST-CN", rules: [
            Vector.rule(2, "google.com"), Vector.rule(2, "fast.com"),
            Vector.rule(2, "ampproject.org"), Vector.rule(2, "tokenplus.app"),
            Vector.rule(2, "github.io"), Vector.rule(1, "(.*)blogspot\\.(.*)")
        ])
        let exceptions = Vector.group("GFWLIST-CN-EXCLUDE", rules: [
            Vector.rule(2, "www.ampproject.org"), Vector.rule(0, ".tokenplus.app")
        ])
        let topics = Vector.group("GOOGLE-GEMINI", rules: [Vector.rule(3, "gemini.google.com")])
            + Vector.group("GOOGLE", rules: [Vector.rule(2, "google.com")])
            + Vector.group("NETFLIX", rules: [Vector.rule(2, "fast.com")])
        let candidate = try Vector.admit(positive + exceptions + topics, includeOverseas: true)
        let catalogue = try XCTUnwrap(candidate.overseas)

        func matches(_ url: String, _ scope: AccessOverseasCatalogue.Scope = .all) throws -> Bool {
            catalogue.matches(try XCTUnwrap(URL(string: url)), scope: scope)
        }
        XCTAssertEqual(catalogue.counts.admitted, 4)
        XCTAssertEqual(catalogue.counts.rejected, 1)
        XCTAssertEqual(catalogue.counts.unsupported, 1)
        XCTAssertTrue(try matches("https://fast.com"))
        XCTAssertFalse(try matches("https://fast.com", .categories([.video])))
        XCTAssertTrue(try matches("https://gemini.google.com:443/", .categories([.ai])))
        XCTAssertFalse(try matches("https://gemini.google.com", .categories([.web])))
        XCTAssertFalse(try matches("https://child.gemini.google.com", .categories([.ai])))
        XCTAssertFalse(try matches("https://gemini.google.com:8443"))
        XCTAssertFalse(try matches("http://gemini.google.com"))
        XCTAssertFalse(try matches("https://user@google.com"))
        XCTAssertFalse(try matches("https://evilgoogle.com"))
        XCTAssertTrue(try matches("https://ampproject.org"))
        XCTAssertFalse(try matches("https://www.ampproject.org"))
        XCTAssertFalse(try matches("https://abc.tokenplus.app"))
        XCTAssertFalse(try matches("https://arbitrary.github.io"))
    }

    func testMissingUnknownExceptionsRejectOverseasAdmission() throws {
        let positive = Vector.group("GFWLIST-CN", rules: [Vector.rule(2, "google.com")])
        let invalid = [
            Data(),
            Vector.group("GFWLIST-CN-EXCLUDE", rules: [Vector.rule(1, "^google")])
        ]
        for negative in invalid {
            XCTAssertThrowsError(try Vector.admit(positive + negative, includeOverseas: true))
        }
        XCTAssertNil(try Vector.admit(positive).overseas)
    }

    func testPositiveAndExclusionRecordCountBoundaries() throws {
        let positives = (0..<8_193).map { Vector.rule(3, "positive-\($0).example.com") }
        let exclusions = (0..<513).map { Vector.rule(2, "exception-\($0).example.com") }
        func admit(positiveCount: Int, exclusionCount: Int) throws -> AccessOverseasCatalogue {
            let database = Vector.group("GFWLIST-CN", rules: Array(positives.prefix(positiveCount)))
                + Vector.group("GFWLIST-CN-EXCLUDE", rules: Array(exclusions.prefix(exclusionCount)))
            let candidate = try Vector.admit(database, includeOverseas: true)
            return try XCTUnwrap(candidate.overseas)
        }
        let valid = try admit(positiveCount: 8_192, exclusionCount: 512)
        XCTAssertEqual(valid.counts.admitted, 8_192)
        XCTAssertEqual(valid.counts.exclusions, 512)
        XCTAssertThrowsError(try admit(positiveCount: 8_193, exclusionCount: 512))
        XCTAssertThrowsError(try admit(positiveCount: 8_192, exclusionCount: 513))
    }

    func testSourceGroupMustHaveCanonicalNameAndKnownGroupSemantics() throws {
        let positive = Vector.group("GFWLIST-CN", rules: [Vector.rule(2, "google.com")])
        let exclusions = Vector.group("GFWLIST-CN-EXCLUDE", rules: [])
        let rule = Vector.rule(3, "gemini.google.com")
        let wrongName = Vector.group("google-gemini", rules: [rule])
        let unknownField = Vector.field(1, Vector.field(1, Data("GOOGLE-GEMINI".utf8))
            + Vector.field(2, rule) + Vector.scalar(3, 1))
        for topic in [wrongName, unknownField] {
            XCTAssertThrowsError(try Vector.admit(positive + exclusions + topic, includeOverseas: true))
        }
    }

    func testOversizedPositiveHostnameIsRejectedWithoutIndexingItsAncestors() throws {
        let name = String(repeating: "label.", count: 4_096) + "example.com"
        let positive = Vector.group("GFWLIST-CN", rules: [Vector.rule(2, name), Vector.rule(2, "google.com")])
        let exclusions = Vector.group("GFWLIST-CN-EXCLUDE", rules: [])
        let catalogue = try XCTUnwrap(Vector.admit(positive + exclusions, includeOverseas: true).overseas)
        XCTAssertEqual(catalogue.counts.admitted, 1)
        XCTAssertEqual(catalogue.counts.rejected, 1)
    }

    func testLongUnsupportedPositivePatternHasItsOwnDisposition() throws {
        let pattern = "^" + String(repeating: "ab", count: 200) + "$"
        let positive = Vector.group("GFWLIST-CN", rules: [
            Vector.rule(2, "google.com"), Vector.rule(1, pattern), Vector.rule(2, "github.io")
        ])
        let exclusions = Vector.group("GFWLIST-CN-EXCLUDE", rules: [])
        let catalogue = try XCTUnwrap(Vector.admit(positive + exclusions, includeOverseas: true).overseas)
        XCTAssertEqual(catalogue.counts.admitted, 1)
        XCTAssertEqual(catalogue.unusedRules.map(\.value), [pattern, "github.io"])
        XCTAssertEqual(catalogue.unusedRules.map(\.kind), [.regexp, .domain])
        XCTAssertEqual(catalogue.unusedRules.map(\.reason), [.unsupportedRegexp, .hostRejected])
    }

    func testSingleLabelExclusionNarrowsAValidDescendantRule() throws {
        let positive = Vector.group("GFWLIST-CN", rules: [
            Vector.rule(2, "pki.goog"), Vector.rule(2, "google.com")
        ])
        let exclusions = Vector.group("GFWLIST-CN-EXCLUDE", rules: [Vector.rule(2, "goog")])
        let catalogue = try XCTUnwrap(Vector.admit(positive + exclusions, includeOverseas: true).overseas)
        XCTAssertEqual(catalogue.counts.admitted, 2)
        XCTAssertFalse(catalogue.matches(try XCTUnwrap(URL(string: "https://c.pki.goog")), scope: .all))
        XCTAssertTrue(catalogue.matches(try XCTUnwrap(URL(string: "https://www.google.com")), scope: .all))
    }

    func testTopicEvidenceCanAppearAfterPositiveInventoryLimit() throws {
        let positive = Vector.group("GFWLIST-CN", rules: [Vector.rule(2, "google.com")])
        let exclusions = Vector.group("GFWLIST-CN-EXCLUDE", rules: [])
        let records = (0..<8_192).map { Vector.rule(2, "other-\($0).example.com") }
            + [Vector.rule(3, "www.google.com")]
        let topic = Vector.group("GOOGLE", rules: records)
        let catalogue = try XCTUnwrap(Vector.admit(positive + exclusions + topic, includeOverseas: true).overseas)
        XCTAssertEqual(catalogue.hosts[.web], ["www.google.com"])
    }

    func testExclusionsRequireCanonicalIDNALabels() throws {
        let positive = Vector.group("GFWLIST-CN", rules: [Vector.rule(2, "xn--bcher-kva.de")])
        for (type, host) in [(2, "xn--a.de"), (3, "xn--a.de"), (2, "xn--a.xn--bcher-kva.de"),
                             (2, "1.xn--mgbh0fb.de"), (3, "1.xn--mgbh0fb.de")] {
            let malformed = Vector.group("GFWLIST-CN-EXCLUDE", rules: [Vector.rule(type, host)])
            XCTAssertThrowsError(try Vector.admit(positive + malformed, includeOverseas: true))
        }
        let exclusions = Vector.group("GFWLIST-CN-EXCLUDE", rules: [Vector.rule(2, "xn--bcher-kva.de")])
        let catalogue = try XCTUnwrap(Vector.admit(positive + exclusions, includeOverseas: true).overseas)
        XCTAssertFalse(catalogue.matches(try XCTUnwrap(URL(string: "https://www.bücher.de/")), scope: .all))
    }
}

enum AccessGeoSiteTestVector {
    static let now = Date(timeIntervalSince1970: 1_795_219_200)

    static func frozenOfficialAssets() async throws -> (metadata: Data, database: Data, checksum: Data) {
#if !targetEnvironment(simulator)
        if let metadataURL = Bundle(for: AccessGeoSiteAdmissionTests.self).url(
            forResource: "metadata", withExtension: "json", subdirectory: "Fixtures/PhysicalGeoSite"
        ) {
            let directory = metadataURL.deletingLastPathComponent()
            let database = try Data(contentsOf: directory.appendingPathComponent("geosite.dat"))
            XCTAssertEqual(database.count, 7_750_066)
            XCTAssertEqual(sha(database), AccessGeoSiteCatalogue.bundled.rawSHA256)
            return (try Data(contentsOf: metadataURL), database,
                    try Data(contentsOf: directory.appendingPathComponent("geosite.dat.sha256sum")))
        }
#endif
        guard let value = ProcessInfo.processInfo.environment["AEGIS_GEOSITE_VECTOR"] else {
            throw XCTSkip("Run this test with the geosite-official-data fixture")
        }
        let base = try XCTUnwrap(URL(string: value).flatMap { url in
            url.scheme == "http" && url.host == "127.0.0.1" ? url : nil
        }, "Expected the local frozen GeoSite fixture")
        func fetch(_ name: String) async throws -> Data {
            let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent(name))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            return data
        }
        let metadata = try await fetch("metadata.json")
        let database = try await fetch("geosite.dat")
        let checksum = try await fetch("geosite.dat.sha256sum")
        XCTAssertEqual(database.count, 7_750_066)
        XCTAssertEqual(sha(database), AccessGeoSiteCatalogue.bundled.rawSHA256)
        return (metadata, database, checksum)
    }

    // Complete projected records from XTLS standard geosite.dat 20261120235103.
    // The full frozen source is tested separately through the native fixture.
    static let selectedProjection = Data(base64Encoded:
        "CigKBkRFQklBThIOCAISCmRlYmlhbi5vcmcSDggCEgpkb3RkZWIub3JnCjkKBkRPVUJBThIOCAISCmRvdWJhbi5jb20SDQgCEglkb3ViYW4uZm0SEAgCEgxkb3ViYW5pby5jb20KwAIKB01FSVRVQU4SCggCEgYxMDAubWUSDggCEgo1MXBpbmcuY29tEhIIAhIOYmFvYmFvYWljaGkuY24SDggCEgpkZGNvcnAubmV0Eg8IAhILZGRmcmVzaC5uZXQSDggCEgpkZGltZy5tb2JpEhAIAhIMZGRtYWljYWkubmV0Eg0IAhIJZGRtYy5tb2JpEg8IAhILZGR1c2VyLm1vYmkSDQgCEglkZHhxLm1vYmkSEAgCEgxkaWFucGluZy5jb20SDggCEgpkcGZpbGUuY29tEhAIAhIMaW1haWNhaS5tb2JpEg4IAhIKbWFveWFuLmNvbRIPCAISC21laXR1YW4uY29tEg8IAhILbWVpdHVhbi5uZXQSDQgCEgltdHl1bi5jb20SDQgCEgluZWl4aW4uY24SDwgCEgtzYW5rdWFpLmNvbQ==")!

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func varint(_ value: Int) -> Data {
        var remaining = value
        var bytes = Data()
        while remaining >= 128 {
            bytes.append(UInt8(remaining & 127) | 128)
            remaining >>= 7
        }
        bytes.append(UInt8(remaining))
        return bytes
    }

    static func field(_ id: Int, _ data: Data) -> Data { varint(id * 8 + 2) + varint(data.count) + data }
    static func scalar(_ id: Int, _ value: Int) -> Data { varint(id * 8) + varint(value) }

    static func rule(_ type: Int, _ host: String, attribute: Data? = nil) -> Data {
        var data = (type == 0 ? Data() : scalar(1, type)) + field(2, Data(host.utf8))
        if let attribute { data += field(3, attribute) }
        return data
    }

    static func group(_ name: String, rules: [Data], nameLast: Bool = false) -> Data {
        let key = field(1, Data(name.utf8))
        let values = rules.reduce(into: Data()) { $0 += field(2, $1) }
        return field(1, nameLast ? values + key : key + values)
    }

    static func release(_ database: Data, newer: Bool = false, checksum: Data? = nil,
                        mutate: (inout [String: Any]) throws -> Void = { _ in }) throws -> (metadata: Data, checksum: Data) {
        let tag = newer ? "20261120235104" : "20261120235103"
        let id = newer ? 453302650 : 453302649
        let pair = checksum ?? Data("\(sha(database))  geosite.dat\n".utf8)
        let api = "https://api.github.com/repos/XTLS/Xray-rules-dat/releases"
        let web = "https://github.com/XTLS/Xray-rules-dat/releases"
        func asset(_ name: String, id: Int, body: Data) -> [String: Any] {
            ["name": name, "id": id, "size": body.count, "digest": "sha256:" + sha(body), "state": "uploaded",
             "url": "\(api)/assets/\(id)", "browser_download_url": "\(web)/download/\(tag)/\(name)"]
        }
        var json: [String: Any] = [
            "id": id, "tag_name": tag, "draft": false, "prerelease": false,
            "published_at": newer ? "2026-11-20T23:52:16Z" : "2026-11-20T23:52:15Z",
            "url": "\(api)/\(id)", "html_url": "\(web)/tag/\(tag)",
            "assets": [asset("geosite.dat", id: 773779405, body: database), asset("geosite.dat.sha256sum", id: 773779518, body: pair)]
        ]
        try mutate(&json)
        return (try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), pair)
    }

    static func admit(_ database: Data, newer: Bool = false,
                      highWater: AccessGeoSiteAdmission.Receipt? = nil,
                      includeOverseas: Bool = false) throws -> AccessGeoSiteAdmission.Candidate {
        let input = try release(database, newer: newer)
        return try AccessGeoSiteAdmission.admit(metadata: input.metadata, database: database, checksum: input.checksum,
                                                now: now, highWater: highWater, includeOverseas: includeOverseas)
    }
}
