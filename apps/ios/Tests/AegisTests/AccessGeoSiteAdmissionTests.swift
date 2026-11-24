import AccessKit
import CryptoKit
import Foundation
import XCTest

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
                var assets = metadata["assets"] as! [[String: Any]]
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
    func testFullFrozenOfficialDatabase() async throws {
        guard let value = ProcessInfo.processInfo.environment["AEGIS_GEOSITE_VECTOR"] else {
            throw XCTSkip("Run this suite with the geosite-official-data fixture")
        }
        let base = try XCTUnwrap(URL(string: value))
        XCTAssertEqual(base.host, "127.0.0.1")
        func fetch(_ name: String) async throws -> Data {
            let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent(name))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            return data
        }
        let metadata = try await fetch("metadata.json")
        let database = try await fetch("geosite.dat")
        let checksum = try await fetch("geosite.dat.sha256sum")
        XCTAssertEqual(database.count, 7_750_066)
        let candidate = try AccessGeoSiteAdmission.admit(metadata: metadata, database: database, checksum: checksum,
                                                         now: AccessGeoSiteTestVector.now)
        XCTAssertEqual(candidate.categoryCount, 1572)
        XCTAssertEqual(candidate.receipt.releaseID, 453302649)
        XCTAssertEqual(candidate.receipt.tag, AccessGeoSiteCatalogue.bundled.tag)
        XCTAssertEqual(candidate.receipt.database.sha256, AccessGeoSiteCatalogue.bundled.rawSHA256)
        XCTAssertEqual(candidate.receipt.checksum.sha256, "9d153aa5f78ff022a85726e42522ea00776e87b30e4c2519c8e04dbd795893e6")
        XCTAssertEqual(candidate.catalogue.groups, AccessGeoSiteCatalogue.bundled.groups)
    }
}

enum AccessGeoSiteTestVector {
    static let now = Date(timeIntervalSince1970: 1_795_219_200)
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
                        mutate: (inout [String: Any]) -> Void = { _ in }) throws -> (metadata: Data, checksum: Data) {
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
        mutate(&json)
        return (try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), pair)
    }

    static func admit(_ database: Data, newer: Bool = false,
                      highWater: AccessGeoSiteAdmission.Receipt? = nil) throws -> AccessGeoSiteAdmission.Candidate {
        let input = try release(database, newer: newer)
        return try AccessGeoSiteAdmission.admit(metadata: input.metadata, database: database, checksum: input.checksum,
                                                now: now, highWater: highWater)
    }
}
