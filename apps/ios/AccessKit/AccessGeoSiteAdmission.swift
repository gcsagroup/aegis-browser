import AegisPolicyKit
import CryptoKit
import Foundation

/// Content admission requires metadata obtained through the fixed official
/// HTTPS transport. HTTP status, redirects and server trust belong to transport.
public enum AccessGeoSiteAdmission {
    private static let api = "https://api.github.com/repos/XTLS/Xray-rules-dat/releases"
    private static let web = "https://github.com/XTLS/Xray-rules-dat/releases"
    public static let metadataURL = URL(string: api + "/latest")!
    public static let maximumMetadataBytes = 256 * 1024
    public static let maximumChecksumBytes = 4 * 1024
    public static let maximumDatabaseBytes = 16 * 1024 * 1024
    public static let formatVersion = 1

    public enum Failure: Error, Equatable {
        case invalidMetadata
        case invalidTime
        case rollback
        case equivocation
        case invalidAsset
        case malformedDatabase
        case suffixListUnavailable
    }

    public struct Asset: Codable, Equatable, Sendable {
        public let id: Int64
        public let byteCount: Int
        public let sha256: String
    }

    public struct Receipt: Codable, Equatable, Sendable {
        public let tag: String
        public let releaseID: Int64
        public let publishedAt: String
        public let database: Asset
        public let checksum: Asset

        public var databaseURL: URL { Self.assetURL(tag: tag, name: "geosite.dat") }
        public var checksumURL: URL { Self.assetURL(tag: tag, name: "geosite.dat.sha256sum") }

        private static func assetURL(tag: String, name: String) -> URL {
            URL(string: AccessGeoSiteAdmission.web + "/download")!
                .appendingPathComponent(tag).appendingPathComponent(name)
        }

        public func validateSuccessor(of highWater: Self?) throws {
            guard let highWater else { return }
            if tag < highWater.tag { throw Failure.rollback }
            if tag == highWater.tag, self != highWater { throw Failure.equivocation }
        }

        public func validityDeadline() throws -> Date {
            guard releaseID > 0, database.id > 0, checksum.id > 0, database.id != checksum.id,
                  (1...AccessGeoSiteAdmission.maximumDatabaseBytes).contains(database.byteCount),
                  (1...AccessGeoSiteAdmission.maximumChecksumBytes).contains(checksum.byteCount),
                  AccessGeoSiteAdmission.isSHA256(database.sha256), AccessGeoSiteAdmission.isSHA256(checksum.sha256)
            else { throw Failure.invalidAsset }
            guard let tagTime = AccessGeoSiteAdmission.tagTime(tag),
                  let publication = AccessGeoSiteAdmission.publicationTime(publishedAt),
                  publication >= tagTime, publication.timeIntervalSince(tagTime) <= 86_400 else { throw Failure.invalidTime }
            return publication.addingTimeInterval(7 * 86_400)
        }

        public func expiry(at now: Date) throws -> Date {
            let expiry = try validityDeadline()
            guard now < expiry, expiry.timeIntervalSince(now) <= 7 * 86_400 + 300 else { throw Failure.invalidTime }
            return expiry
        }
    }

    public struct Candidate: Sendable {
        public let receipt: Receipt
        public let catalogue: AccessGeoSiteCatalogue
        public let categoryCount: Int
        public let expiresAt: Date
        public let suffixListSHA256: String
    }

    private struct ReleaseJSON: Decodable {
        let id: Int64
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let published_at: String
        let url: String
        let html_url: String
        let assets_url: String?
        let assets: [AssetJSON]
    }

    private struct AssetJSON: Decodable {
        let name: String
        let id: Int64
        let size: Int
        let state: String
        let digest: String?
        let url: String
        let browser_download_url: String

        func validated(tag: String, limit: Int) throws -> Asset {
            guard id > 0, size > 0, size <= limit, state == "uploaded",
                  url == AccessGeoSiteAdmission.api + "/assets/\(id)",
                  browser_download_url == AccessGeoSiteAdmission.web + "/download/\(tag)/\(name)",
                  let digest, digest.hasPrefix("sha256:") else { throw Failure.invalidAsset }
            let sha256 = String(digest.dropFirst(7))
            guard AccessGeoSiteAdmission.isSHA256(sha256) else { throw Failure.invalidAsset }
            return Asset(id: id, byteCount: size, sha256: sha256)
        }
    }

    public static func metadata(_ bytes: Data, now: Date, highWater: Receipt? = nil) throws -> Receipt {
        guard bytes.count <= maximumMetadataBytes,
              let release = try? JSONDecoder().decode(ReleaseJSON.self, from: bytes),
              release.id > 0, !release.draft, !release.prerelease,
              release.url == api + "/\(release.id)",
              release.html_url == web + "/tag/\(release.tag_name)",
              release.assets_url.map({ $0 == api + "/\(release.id)/assets" }) != false,
              Set(release.assets.map(\.name)).count == release.assets.count,
              Set(release.assets.map(\.id)).count == release.assets.count,
              let raw = release.assets.first(where: { $0.name == "geosite.dat" }),
              let pair = release.assets.first(where: { $0.name == "geosite.dat.sha256sum" }) else {
            throw Failure.invalidMetadata
        }
        let receipt = Receipt(tag: release.tag_name, releaseID: release.id, publishedAt: release.published_at,
            database: try raw.validated(tag: release.tag_name, limit: maximumDatabaseBytes),
            checksum: try pair.validated(tag: release.tag_name, limit: maximumChecksumBytes))
        _ = try receipt.expiry(at: now)
        try receipt.validateSuccessor(of: highWater)
        return receipt
    }

    public static func admit(metadata: Data, database: Data, checksum: Data, now: Date,
                             highWater: Receipt? = nil) throws -> Candidate {
        try admit(receipt: self.metadata(metadata, now: now, highWater: highWater), database: database,
                  checksum: checksum, now: now, highWater: highWater)
    }

    public static func admit(receipt: Receipt, database: Data, checksum: Data, now: Date,
                             highWater: Receipt? = nil) throws -> Candidate {
        try Task.checkCancellation()
        let expiry = try receipt.expiry(at: now)
        try receipt.validateSuccessor(of: highWater)
        guard database.count == receipt.database.byteCount, checksum.count == receipt.checksum.byteCount,
              sha256(database) == receipt.database.sha256, sha256(checksum) == receipt.checksum.sha256,
              let pair = String(data: checksum, encoding: .ascii) else { throw Failure.invalidAsset }
        let digest = receipt.database.sha256
        let line = pair.hasSuffix("\r\n") ? String(pair.dropLast()) : (pair.hasSuffix("\n") ? String(pair.dropLast()) : pair)
        guard line == digest + "  geosite.dat" || line == digest + " *geosite.dat" else { throw Failure.invalidAsset }
        guard let suffixSHA = RegisteredDomain.verifiedGeoSiteSuffixListSHA256 else { throw Failure.suffixListUnavailable }

        let (groups, groupCount) = try database.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            try decodeDatabase(bytes)
        }
        return Candidate(receipt: receipt, catalogue: AccessGeoSiteCatalogue(tag: receipt.tag,
            publishedAt: receipt.publishedAt, rawSHA256: digest, groups: groups), categoryCount: groupCount,
            expiresAt: expiry, suffixListSHA256: suffixSHA)
    }

    /// Rebuilds one complete group with the same typed contract used by wire
    /// admission, including when a protected local snapshot is restored.
    public static func checkedGroup(_ rules: [AccessGeoSiteCatalogue.Rule]) throws -> AccessGeoSiteCatalogue.Group {
        guard RegisteredDomain.verifiedGeoSiteSuffixListSHA256 != nil else { throw Failure.suffixListUnavailable }
        guard !rules.isEmpty, rules.count <= 128, Set(rules.map(ruleKey)).count == rules.count,
              rules.allSatisfy({ RegisteredDomain.allowsGeoSiteHost($0.host, includingDescendants: $0.kind == .domain) })
        else { throw Failure.malformedDatabase }
        let sorted = rules.sorted { ruleKey($0) < ruleKey($1) }
        let typed = sorted.map { ruleKey($0) + "\n" }.joined()
        return AccessGeoSiteCatalogue.Group(typedSHA256: sha256(Data(typed.utf8)), rules: sorted)
    }

    private static func ruleKey(_ rule: AccessGeoSiteCatalogue.Rule) -> String {
        rule.kind.rawValue + ":" + rule.host
    }

    public static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func tagTime(_ tag: String) -> Date? {
        let digits = Array(tag.utf8)
        guard digits.count == 14 else { return nil }
        return utc(digits)
    }

    private static func publicationTime(_ stamp: String) -> Date? {
        let bytes = Array(stamp.utf8)
        guard (20...30).contains(bytes.count), bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
              bytes[13] == 58, bytes[16] == 58, bytes.last == 90 else { return nil }
        let digits = [0..<4, 5..<7, 8..<10, 11..<13, 14..<16, 17..<19].flatMap { bytes[$0] }
        guard let whole = utc(digits) else { return nil }
        if bytes.count == 20 { return whole }
        guard bytes.count >= 22, bytes[19] == 46 else { return nil }
        let fraction = bytes[20..<(bytes.count - 1)]
        guard fraction.allSatisfy({ (48...57).contains($0) }),
              let seconds = Double("0." + String(decoding: fraction, as: UTF8.self)) else { return nil }
        return whole.addingTimeInterval(seconds)
    }

    private static func utc(_ digits: [UInt8]) -> Date? {
        guard digits.allSatisfy({ (48...57).contains($0) }) else { return nil }
        func value(_ range: Range<Int>) -> Int {
            digits[range].reduce(0) { $0 * 10 + Int($1 - 48) }
        }
        let year = value(0..<4), month = value(4..<6), day = value(6..<8)
        let hour = value(8..<10), minute = value(10..<12), second = value(12..<14)
        guard year > 0, (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second < 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                            hour: hour, minute: minute, second: second)),
              calendar.component(.day, from: date) == day,
              calendar.component(.month, from: date) == month else { return nil }
        return date
    }
}

private extension AccessGeoSiteAdmission {
    static func decodeDatabase(_ bytes: UnsafeRawBufferPointer) throws -> ([AccessGeoSiteCategory: AccessGeoSiteCatalogue.Group], Int) {
        var reader = WireReader(bytes, range: 0..<bytes.count)
        var available = 4_000_000
        var categories: Set<String> = []
        var selected: [AccessGeoSiteCategory: AccessGeoSiteCatalogue.Group] = [:]
        while let field = try reader.next(&available) {
            guard field.number == 1 else {
                try reader.skip(field)
                continue
            }
            let range = try reader.message(field)
            let name = try groupName(bytes, range: range, available: available)
            let folded = name.uppercased()
            guard categories.count < 4096, categories.insert(folded).inserted else { throw Failure.malformedDatabase }
            let category = AccessGeoSiteCategory(rawValue: folded)
            guard category == nil || name == folded else { throw Failure.malformedDatabase }
            let rules = try decodeGroup(bytes, range: range, selected: category != nil, available: &available)
            if let category, !rules.isEmpty {
                selected[category] = try checkedGroup(rules)
            }
        }
        guard !categories.isEmpty else { throw Failure.malformedDatabase }
        return (selected, categories.count)
    }

    static func groupName(_ bytes: UnsafeRawBufferPointer, range: Range<Int>, available: Int) throws -> String {
        // The name may follow entries. Peek past framed entries without storing
        // them, then charge each field once during the complete group scan.
        var reader = WireReader(bytes, range: range)
        var budget = available
        while let field = try reader.next(&budget) {
            if field.number == 1 {
                let name = try reader.message(field)
                guard (1...64).contains(name.count), bytes[name].allSatisfy({ (33...126).contains($0) })
                else { throw Failure.malformedDatabase }
                return String(decoding: bytes[name], as: UTF8.self)
            }
            try reader.skip(field)
        }
        throw Failure.malformedDatabase
    }

    static func decodeGroup(_ bytes: UnsafeRawBufferPointer, range: Range<Int>, selected: Bool,
                            available: inout Int) throws -> [AccessGeoSiteCatalogue.Rule] {
        var reader = WireReader(bytes, range: range)
        var hasName = false
        var rules: [AccessGeoSiteCatalogue.Rule] = []
        while let field = try reader.next(&available) {
            switch field.number {
            case 1:
                guard !hasName else { throw Failure.malformedDatabase }
                hasName = true
                _ = try reader.message(field)
            case 2:
                if selected, rules.count == 128 { throw Failure.malformedDatabase }
                let rule = try decodeRule(bytes, range: reader.message(field), selected: selected, available: &available)
                if let rule { rules.append(rule) }
            default:
                guard !selected else { throw Failure.malformedDatabase }
                try reader.skip(field)
            }
        }
        return rules
    }

    static func decodeRule(_ bytes: UnsafeRawBufferPointer, range: Range<Int>, selected: Bool,
                           available: inout Int) throws -> AccessGeoSiteCatalogue.Rule? {
        var reader = WireReader(bytes, range: range)
        var type: UInt64?
        var value: Range<Int>?
        while let field = try reader.next(&available) {
            switch field.number {
            case 1:
                guard type == nil else { throw Failure.malformedDatabase }
                type = try reader.scalar(field)
            case 2:
                guard value == nil else { throw Failure.malformedDatabase }
                value = try reader.message(field)
            case 3:
                guard !selected else { throw Failure.malformedDatabase }
                try skipAttribute(bytes, range: reader.message(field), available: &available)
            default:
                // Unselected entries may use semantics this client does not
                // implement. A selected rule must have only understood fields.
                guard !selected else { throw Failure.malformedDatabase }
                try reader.skip(field)
            }
        }
        guard selected else { return nil }
        guard let value, (1...253).contains(value.count),
              bytes[value].allSatisfy({ $0 < 128 }) else { throw Failure.malformedDatabase }
        let kind: AccessGeoSiteCatalogue.Rule.Kind
        switch type {
        case 2: kind = .domain
        case 3: kind = .full
        default: throw Failure.malformedDatabase
        }
        return .init(kind: kind, host: String(decoding: bytes[value], as: UTF8.self))
    }

    static func skipAttribute(_ bytes: UnsafeRawBufferPointer, range: Range<Int>, available: inout Int) throws {
        var reader = WireReader(bytes, range: range)
        var hasKey = false
        var hasTypedValue = false
        while let field = try reader.next(&available) {
            switch field.number {
            case 1:
                guard !hasKey else { throw Failure.malformedDatabase }
                hasKey = true
                _ = try reader.message(field)
            case 2, 3:
                guard !hasTypedValue else { throw Failure.malformedDatabase }
                hasTypedValue = true
                _ = try reader.scalar(field)
            default:
                try reader.skip(field)
            }
        }
    }

    /// The known schema descends at most three embedded messages. Other
    /// length-delimited fields skip as opaque bytes and wire groups are refused.
    struct WireReader {
        struct Field {
            let number: UInt64
            let wire: UInt64
        }

        let bytes: UnsafeRawBufferPointer
        let end: Int
        var position: Int

        init(_ bytes: UnsafeRawBufferPointer, range: Range<Int>) {
            self.bytes = bytes
            self.end = range.upperBound
            self.position = range.lowerBound
        }

        mutating func next(_ available: inout Int) throws -> Field? {
            guard position != end else { return nil }
            guard available > 0 else { throw Failure.malformedDatabase }
            available -= 1
            if available.isMultiple(of: 4096) { try Task.checkCancellation() }
            let key = try varint()
            let number = key >> 3
            let wire = key & 7
            guard (1...0x1fff_ffff).contains(number), wire == 0 || wire == 1 || wire == 2 || wire == 5
            else { throw Failure.malformedDatabase }
            return Field(number: number, wire: wire)
        }

        mutating func message(_ field: Field) throws -> Range<Int> {
            guard field.wire == 2 else { throw Failure.malformedDatabase }
            let length = try varint()
            guard length <= UInt64(end - position) else { throw Failure.malformedDatabase }
            return try take(Int(length))
        }

        mutating func scalar(_ field: Field) throws -> UInt64 {
            guard field.wire == 0 else { throw Failure.malformedDatabase }
            return try varint()
        }

        mutating func skip(_ field: Field) throws {
            switch field.wire {
            case 0: _ = try varint()
            case 1: _ = try take(8)
            case 2: _ = try message(field)
            default: _ = try take(4)
            }
        }

        private mutating func take(_ count: Int) throws -> Range<Int> {
            guard count <= end - position else { throw Failure.malformedDatabase }
            let start = position
            position += count
            return start..<position
        }

        private mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            for index in 0..<10 {
                guard position < end else { throw Failure.malformedDatabase }
                let byte = bytes[position]
                position += 1
                guard index < 9 || byte <= 1 else { throw Failure.malformedDatabase }
                result |= UInt64(byte & 0x7f) << (index * 7)
                if byte < 0x80 {
                    guard index == 0 || byte != 0 else { throw Failure.malformedDatabase }
                    return result
                }
            }
            throw Failure.malformedDatabase
        }
    }
}
