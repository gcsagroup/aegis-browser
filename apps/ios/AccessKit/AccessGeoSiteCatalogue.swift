/// A complete, admitted GeoSite category. The raw values are upstream IDs and
/// are also the stable values used for local selection.
public enum AccessGeoSiteCategory: String, CaseIterable, Codable, Sendable {
    case debian = "DEBIAN"
    case douban = "DOUBAN"
    case meituan = "MEITUAN"
}

public struct AccessGeoSiteCatalogue: Equatable, Sendable {
    public struct Rule: Equatable, Codable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case domain
            case full
        }

        public let kind: Kind
        public let host: String

        public func matches(_ candidate: String) -> Bool {
            candidate == host || (kind == .domain && candidate.hasSuffix("." + host))
        }
    }

    public struct Group: Equatable, Codable, Sendable {
        public let typedSHA256: String
        public let rules: [Rule]
    }

    public let tag: String
    public let publishedAt: String
    public let rawSHA256: String
    public let groups: [AccessGeoSiteCategory: Group]

    public init(tag: String, publishedAt: String, rawSHA256: String, groups: [AccessGeoSiteCategory: Group]) {
        self.tag = tag
        self.publishedAt = publishedAt
        self.rawSHA256 = rawSHA256
        self.groups = groups
    }

    // Standard geosite.dat from XTLS/Xray-rules-dat release 20261126014317
    // (458847221), GeoSite source d74acca73490cb57a937674ce8a8709d2a3021ba.
    // The three complete groups are signed with the app and have no expiry.
    public static let bundled = Self(
        tag: "20261126014317",
        publishedAt: "2026-11-26T01:44:48Z",
        rawSHA256: "35f58454ed79be85285a333716e3016727d536ef872c53e13c60e411d43b7dd7",
        groups: originalConsentGroups.merging([
            .debian: domainGroup(
                typedSHA256: "06c514bb68567fdf422969927719a7e6c19442509cb2c69eb43cb02efbc83aeb",
                domains: ["debian.map.fastlydns.net", "debian.org", "dotdeb.org"]
            )
        ]) { _, current in current }
    )

    public static let originalConsentGroups: [AccessGeoSiteCategory: Group] = [
        .debian: domainGroup(
            typedSHA256: "d865d67c829d0f13bf508e152ef402d5d9634227ed12a8b49434d231baf5a643",
            domains: ["debian.org", "dotdeb.org"]
        ),
        .douban: domainGroup(
            typedSHA256: "62cfcbf5e006744783206139a2cbb6a3dffb05dbc366f1784a193e887e038619",
            domains: ["douban.com", "douban.fm", "doubanio.com"]
        ),
        .meituan: domainGroup(
            typedSHA256: "7f23061fb1a46f4150077aa56c369188cfda5bb49bd99649264c5bfb7bf8efa9",
            domains: [
                "100.me", "51ping.com", "baobaoaichi.cn", "ddcorp.net", "ddfresh.net",
                "ddimg.mobi", "ddmaicai.net", "ddmc.mobi", "dduser.mobi", "ddxq.mobi",
                "dianping.com", "dpfile.com", "imaicai.mobi", "maoyan.com", "meituan.com",
                "meituan.net", "mtyun.com", "neixin.cn", "sankuai.com"
            ]
        )
    ]

    private static func domainGroup(typedSHA256: String, domains: [String]) -> Group {
        Group(typedSHA256: typedSHA256, rules: domains.map { Rule(kind: .domain, host: $0) })
    }
}
