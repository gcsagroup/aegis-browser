import AegisPolicyKit
import Foundation

public enum AccessOverseasCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case video = "VIDEO"
    case ai = "AI"
    case web = "WEB"
    case social = "SOCIAL"
    case news = "NEWS"
    case development = "DEV"
    case reference = "REFERENCE"
    case cloud = "CLOUD"
}

/// One verified revision of the overseas contribution. It never authorizes a
/// page on behalf of a different source or inherits a previous page's decision.
public struct AccessOverseasCatalogue: Sendable {
    public enum Scope: Equatable, Sendable {
        case all
        case categories(Set<AccessOverseasCategory>)
    }

    public struct Counts: Equatable, Sendable {
        public let source: Int
        public let admitted: Int
        public let rejected: Int
        public let unsupported: Int
        public let exclusions: Int
    }

    public enum RuleKind: UInt64, Codable, Sendable {
        case keyword = 0, regexp = 1, domain = 2, full = 3
    }

    public struct UnusedRule: Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            case hostRejected
            case unsupportedKeyword
            case unsupportedRegexp
        }

        public let value: String
        public let kind: RuleKind
        public let reason: Reason
    }

    static let positiveTag = "GFWLIST-CN"
    static let exclusionTag = "GFWLIST-CN-EXCLUDE"
    static let positiveLimit = 8_192
    static let exclusionLimit = 512

    struct Projection: Hashable, Sendable {
        let category: AccessOverseasCategory
        let host: String
        let source: String
    }

    // Explicit product selections from the reviewed v1 catalogue. A service
    // group justifies its own listed host, not the whole group or any aliases.
    static let projection: [Projection] = [
        .init(category: .video, host: "www.youtube.com", source: "YOUTUBE"),
        .init(category: .video, host: "www.netflix.com", source: "NETFLIX"),
        .init(category: .video, host: "vimeo.com", source: "VIMEO"),
        .init(category: .video, host: "www.twitch.tv", source: "TWITCH"),
        // WebKit on iPhone is redirected to these hosts from the entries above.
        // Each is still proven by GFWLIST-CN and its own service group.
        .init(category: .video, host: "m.youtube.com", source: "YOUTUBE"),
        .init(category: .video, host: "m.twitch.tv", source: "TWITCH"),
        .init(category: .ai, host: "chatgpt.com", source: "OPENAI"),
        .init(category: .ai, host: "claude.ai", source: "ANTHROPIC"),
        .init(category: .ai, host: "gemini.google.com", source: "GOOGLE-GEMINI"),
        .init(category: .ai, host: "www.perplexity.ai", source: "PERPLEXITY"),
        .init(category: .web, host: "www.google.com", source: "GOOGLE"),
        .init(category: .web, host: "duckduckgo.com", source: "DUCKDUCKGO"),
        .init(category: .web, host: "search.yahoo.com", source: "YAHOO"),
        .init(category: .social, host: "x.com", source: "TWITTER"),
        .init(category: .social, host: "www.instagram.com", source: "INSTAGRAM"),
        .init(category: .social, host: "t.me", source: "TELEGRAM"),
        .init(category: .social, host: "telegram.org", source: "TELEGRAM"),
        .init(category: .social, host: "discord.com", source: "DISCORD"),
        .init(category: .news, host: "www.bbc.com", source: "BBC"),
        .init(category: .news, host: "www.nytimes.com", source: "NYTIMES"),
        .init(category: .news, host: "www.reuters.com", source: "REUTERS"),
        .init(category: .news, host: "www.dw.com", source: "DW"),
        .init(category: .development, host: "github.com", source: "GITHUB"),
        .init(category: .development, host: "gist.github.com", source: "GITHUB"),
        .init(category: .development, host: "raw.githubusercontent.com", source: "GITHUB"),
        .init(category: .development, host: "hub.docker.com", source: "DOCKER"),
        .init(category: .reference, host: "zh.wikipedia.org", source: "WIKIMEDIA"),
        .init(category: .reference, host: "scholar.google.com", source: "GOOGLE-SCHOLAR"),
        .init(category: .reference, host: "archive.org", source: "ARCHIVE"),
        .init(category: .cloud, host: "drive.google.com", source: "GOOGLE"),
        .init(category: .cloud, host: "docs.google.com", source: "GOOGLE"),
        .init(category: .cloud, host: "accounts.google.com", source: "GOOGLE"),
        .init(category: .cloud, host: "www.dropbox.com", source: "DROPBOX"),
        .init(category: .cloud, host: "onedrive.live.com", source: "MICROSOFT"),
    ]

    public struct Record: Codable, Hashable, Sendable, Comparable {
        public let kind: RuleKind
        public let value: String

        public static func < (lhs: Record, rhs: Record) -> Bool {
            (lhs.kind.rawValue, lhs.value) < (rhs.kind.rawValue, rhs.value)
        }

        func contains(_ host: String) -> Bool {
            host == value || (kind == .domain && host.hasSuffix("." + value))
        }

        // Valid policy values need no JSON escaping. Charge 21 bytes for
        // the object and one for its array separator.
        fileprivate var snapshotRowBytes: Int { value.utf8.count + 22 }
    }

    private struct HostIndex: Sendable {
        var exact: Set<String> = []
        var domains: Set<String> = []
        var ancestors: Set<String> = []
        var domainAncestors: Set<String> = []

        mutating func insert(_ rule: Record, recordingAncestors: Bool = false) {
            if rule.kind == .full { exact.insert(rule.value) }
            if rule.kind == .domain { domains.insert(rule.value) }
            guard recordingAncestors else { return }
            var suffix = rule.value[...]
            while let dot = suffix.firstIndex(of: ".") {
                suffix = suffix[suffix.index(after: dot)...]
                ancestors.insert(String(suffix))
                if rule.kind == .domain { domainAncestors.insert(String(suffix)) }
            }
        }

        func contains(_ host: String, includingDescendants: Bool = false) -> Bool {
            if !includingDescendants && exact.contains(host) { return true }
            var suffix = host[...]
            while true {
                if domains.contains(String(suffix)) { return true }
                guard let dot = suffix.firstIndex(of: ".") else { return false }
                suffix = suffix[suffix.index(after: dot)...]
            }
        }

        func containsStrictDomainAncestor(of host: String) -> Bool {
            guard let dot = host.firstIndex(of: ".") else { return false }
            return contains(String(host[host.index(after: dot)...]), includingDescendants: true)
        }
    }

    /// Comparable route coverage. Scoped snapshots store these sorted rows,
    /// and validate the admitted data again before rebuilding their index.
    public struct Policy: Equatable, Sendable {
        // Wire admission applies the source limits separately. A snapshot
        // may include rows from both sides of an intersection.
        private static let maximumRuleCount = 2 * (positiveLimit + projection.count)
        private static let maximumExclusionCount = 2 * exclusionLimit
        // Leave room in the 4 MiB blob for the receipt, checksum and selection.
        private static let maximumSnapshotRowBytes = 4 * 1024 * 1024 - 16 * 1024

        public let rules: [Record]
        public let exclusions: [Record]
        private let positive: HostIndex
        private let negative: HostIndex
        private let keywords: Set<String>

        public init(rules: [Record], exclusions: [Record]) throws {
            guard rules.count <= Self.maximumRuleCount, exclusions.count <= Self.maximumExclusionCount,
                  rules.reduce(0, { $0 + $1.snapshotRowBytes }) + exclusions.reduce(0, { $0 + $1.snapshotRowBytes })
                    <= Self.maximumSnapshotRowBytes,
                  Set(rules).count == rules.count, Set(exclusions).count == exclusions.count else {
                throw AccessGeoSiteAdmission.Failure.malformedDatabase
            }
            var positive = HostIndex()
            var negative = HostIndex()
            var keywords: Set<String> = []
            for row in rules {
                guard row.kind == .domain || row.kind == .full,
                      RegisteredDomain.allowsGeoSiteHost(row.value, includingDescendants: row.kind == .domain)
                else { throw AccessGeoSiteAdmission.Failure.malformedDatabase }
                positive.insert(row, recordingAncestors: true)
            }
            for row in exclusions {
                guard AccessOverseasCatalogue.validExclusion(row) else {
                    throw AccessGeoSiteAdmission.Failure.malformedDatabase
                }
                if row.kind == .keyword { keywords.insert(row.value) }
                negative.insert(row)
            }
            self.rules = rules.sorted()
            self.exclusions = exclusions.sorted()
            self.positive = positive
            self.negative = negative
            self.keywords = keywords
        }

        public static func == (lhs: Policy, rhs: Policy) -> Bool {
            lhs.rules == rhs.rules && lhs.exclusions == rhs.exclusions
        }

        public func matches(_ url: URL) -> Bool {
            guard let host = AccessOverseasCatalogue.eligibleHost(url) else { return false }
            return positive.contains(host) && !isExcluded(host)
        }

        private func isExcluded(_ host: String) -> Bool {
            negative.contains(host) || keywords.contains(where: { host.contains($0) })
        }

        private func excludesDomain(_ host: String) -> Bool {
            negative.contains(host, includingDescendants: true) || keywords.contains(where: { host.contains($0) })
                || (negative.exact.contains(host) && keywordExcludesDescendants(of: host))
        }

        private func keywordExcludesDescendants(of host: String) -> Bool {
            let qualifiedSuffix = "." + host
            return keywords.contains { qualifiedSuffix.contains($0) }
        }

        public var effectiveRules: [Record] {
            let effective = rules.compactMap { rule -> Record? in
                if rule.kind == .full { return isExcluded(rule.value) ? nil : rule }
                guard !excludesDomain(rule.value) else { return nil }
                if keywordExcludesDescendants(of: rule.value) {
                    return isExcluded(rule.value) ? nil : Record(kind: .full, value: rule.value)
                }
                return rule
            }
            return Array(Set(effective)).sorted()
        }

        /// Conservative, bounded difference. Removing an exception can
        /// increase reach even if the positive inventory is unchanged.
        public func expansion(over prior: Policy) -> (rules: [Record], removedExclusions: [Record]) {
            let reachable = effectiveRules
            if reachable.allSatisfy({ $0.kind == .full }) {
                // For exact hosts, only exceptions that actually change reach
                // matter. Present each newly reachable host once.
                return (reachable.filter { !prior.positive.contains($0.value) || prior.isExcluded($0.value) }, [])
            }
            let newlyCovered = reachable.filter { !prior.positive.contains($0.value, includingDescendants: $0.kind == .domain) }
            let added = Self.minimalPositiveRules(newlyCovered)
            var addedDomains = HostIndex()
            for row in added where row.kind == .domain { addedDomains.insert(row) }
            let addedExact = Set(added.filter { $0.kind == .full }.map(\.value))
            let priorHasKeywords = prior.exclusions.contains { $0.kind == .keyword }
            let keywordMayAffectSuffix = priorHasKeywords && reachable.contains { row in
                guard row.kind == .domain else { return false }
                if prior.positive.contains(row.value, includingDescendants: true) { return true }
                guard prior.positive.domainAncestors.contains(row.value) else { return false }
                return prior.positive.domains.contains {
                    row.contains($0) && !excludesDomain($0) && !keywordExcludesDescendants(of: $0)
                }
            }
            let retainedExactHosts = priorHasKeywords && !keywordMayAffectSuffix
                ? Set(reachable.filter { $0.kind == .full }.map(\.value))
                    .union(prior.positive.exact).union(prior.positive.domains).filter {
                        positive.contains($0) && prior.positive.contains($0) && !isExcluded($0)
                    }
                : []
            let removed = prior.exclusions.filter { row in
                if row.kind == .keyword {
                    guard !keywords.contains(where: { row.value.contains($0) }) else { return false }
                    return keywordMayAffectSuffix || retainedExactHosts.contains { $0.contains(row.value) }
                }
                let restrictedPriorCoverage = prior.positive.contains(row.value)
                    || (row.kind == .domain && prior.positive.ancestors.contains(row.value))
                if !restrictedPriorCoverage && addedDomains.contains(row.value, includingDescendants: true) { return false }
                if row.kind == .full {
                    return !addedExact.contains(row.value) && positive.contains(row.value) && !isExcluded(row.value)
                }
                if positive.contains(row.value, includingDescendants: true) { return !excludesDomain(row.value) }
                if positive.domainAncestors.contains(row.value),
                   positive.domains.contains(where: { row.contains($0) && !excludesDomain($0) }) {
                    return true
                }
                guard positive.exact.contains(row.value) || positive.ancestors.contains(row.value) else { return false }
                return positive.exact.contains { row.contains($0) && !isExcluded($0) && !addedExact.contains($0) }
            }
            return (added, rules.isEmpty ? [] : removed)
        }

        public func intersection(with other: Policy) -> Policy? {
            let common = Set(effectiveRules.filter { other.positive.contains($0.value, includingDescendants: $0.kind == .domain) })
                .union(other.effectiveRules.filter { positive.contains($0.value, includingDescendants: $0.kind == .domain) })
                .compactMap { row -> Record? in
                    if row.kind == .domain {
                        guard !excludesDomain(row.value), !other.excludesDomain(row.value) else { return nil }
                        if !keywordExcludesDescendants(of: row.value), !other.keywordExcludesDescendants(of: row.value) { return row }
                    }
                    guard !isExcluded(row.value), !other.isExcluded(row.value) else { return nil }
                    return Record(kind: .full, value: row.value)
                }
            let narrower = Self.minimalPositiveRules(Array(Set(common)))
            if narrower.allSatisfy({ $0.kind == .full }) {
                return Self.boundedIntersection(rules: narrower, exclusions: [])
            }
            // Retain both sets of exclusions so a mixed update cannot re-admit
            // a previously excluded host before confirmation.
            var retained = HostIndex()
            for row in narrower { retained.insert(row, recordingAncestors: true) }
            let relevant = Set(exclusions).union(other.exclusions).filter { row in
                if row.kind == .keyword { return true }
                return retained.contains(row.value) || (row.kind == .domain && retained.ancestors.contains(row.value))
            }
            var excludedDomains = HostIndex()
            var excludedKeywords: Set<String> = []
            for row in relevant {
                if row.kind == .domain { excludedDomains.insert(row) }
                if row.kind == .keyword { excludedKeywords.insert(row.value) }
            }
            let minimalExclusions = relevant.filter { row in
                if excludedKeywords.contains(where: { row.value.contains($0) && (row.kind != .keyword || row.value != $0) }) {
                    return false
                }
                if row.kind == .domain { return !excludedDomains.containsStrictDomainAncestor(of: row.value) }
                return row.kind == .keyword || !excludedDomains.contains(row.value, includingDescendants: true)
            }
            let orderedExclusions = minimalExclusions.sorted()
            let keptExclusions = Array(orderedExclusions.prefix(Self.maximumExclusionCount))
            let omitted = orderedExclusions.dropFirst(keptExclusions.count)
            guard !omitted.isEmpty else {
                return Self.boundedIntersection(rules: narrower, exclusions: keptExclusions)
            }

            // A suffix can survive only if every omitted exception is
            // irrelevant to it. Revisit the uncompressed intersection so
            // exact hosts and unaffected subdomains can survive on their own.
            var omittedHosts = HostIndex()
            for row in omitted { omittedHosts.insert(row, recordingAncestors: true) }
            let omittedKeyword = omitted.contains { $0.kind == .keyword }
            let safe = common.compactMap { row -> Record? in
                guard row.kind == .domain else { return row }
                if !omittedKeyword, !omittedHosts.contains(row.value), !omittedHosts.ancestors.contains(row.value) {
                    return row
                }
                guard !isExcluded(row.value), !other.isExcluded(row.value) else { return nil }
                return Record(kind: .full, value: row.value)
            }
            let safeRules = Self.minimalPositiveRules(Array(Set(safe)))
            return Self.boundedIntersection(rules: safeRules, exclusions: keptExclusions)
        }

        private static func boundedIntersection(rules: [Record], exclusions: [Record]) -> Policy? {
            // Exact matches were already checked against both policies.
            let exclusions = rules.contains(where: { $0.kind == .domain }) ? exclusions : []
            var remaining = maximumSnapshotRowBytes - exclusions.reduce(0) { $0 + $1.snapshotRowBytes }
            if rules.count <= maximumRuleCount, rules.reduce(0, { $0 + $1.snapshotRowBytes }) <= remaining {
                return try? Policy(rules: rules, exclusions: exclusions)
            }

            // Prefer smaller rows on overflow. A suffix takes fewer bytes
            // than any of the descendant rules it already subsumes.
            let ordered = rules.sorted { ($0.snapshotRowBytes, $0) < ($1.snapshotRowBytes, $1) }
            var retained: [Record] = []
            for rule in ordered.prefix(maximumRuleCount) {
                guard rule.snapshotRowBytes <= remaining else { break }
                retained.append(rule)
                remaining -= rule.snapshotRowBytes
            }
            return try? Policy(rules: retained, exclusions: exclusions)
        }

        private static func minimalPositiveRules(_ rows: [Record]) -> [Record] {
            var domains = HostIndex()
            for row in rows where row.kind == .domain { domains.insert(row) }
            return rows.filter { row in
                if row.kind == .domain { return !domains.containsStrictDomainAncestor(of: row.value) }
                return !domains.contains(row.value, includingDescendants: true)
            }
        }
    }

    public let counts: Counts
    public let unusedRules: [UnusedRule]
    public let hosts: [AccessOverseasCategory: Set<String>]
    private let allProjectedHosts: Set<String>
    private let positive: HostIndex
    private let exclusions: HostIndex
    private let exclusionKeywords: [String]
    private let admittedRules: [Record]
    public let excludedRules: [Record]

    init(positive rows: [Record], exclusions negativeRows: [Record],
         provenProjections: Set<Projection>) throws {
        guard Set(rows).count == rows.count, Set(negativeRows).count == negativeRows.count else {
            throw AccessGeoSiteAdmission.Failure.malformedDatabase
        }
        var positive = HostIndex()
        var literalSource = HostIndex()
        var admitted = 0
        var rejected = 0
        var unsupported = 0
        var unusedRules: [UnusedRule] = []
        var admittedRules: [Record] = []
        for row in rows {
            guard row.kind == .domain || row.kind == .full else {
                unsupported += 1
                let reason: UnusedRule.Reason = row.kind == .keyword ? .unsupportedKeyword : .unsupportedRegexp
                unusedRules.append(.init(value: row.value, kind: row.kind, reason: reason))
                continue
            }
            literalSource.insert(row)
            guard RegisteredDomain.allowsGeoSiteHost(row.value, includingDescendants: row.kind == .domain) else {
                rejected += 1
                unusedRules.append(.init(value: row.value, kind: row.kind, reason: .hostRejected))
                continue
            }
            positive.insert(row)
            admittedRules.append(row)
            admitted += 1
        }
        var exclusions = HostIndex()
        var keywords: [String] = []
        for row in negativeRows {
            guard Self.validExclusion(row) else { throw AccessGeoSiteAdmission.Failure.malformedDatabase }
            switch row.kind {
            case .domain, .full:
                exclusions.insert(row)
            case .keyword:
                keywords.append(row.value)
            case .regexp:
                throw AccessGeoSiteAdmission.Failure.malformedDatabase
            }
        }
        var hosts: [AccessOverseasCategory: Set<String>] = [:]
        for entry in provenProjections {
            guard RegisteredDomain.allowsGeoSiteHost(entry.host, includingDescendants: false),
                  literalSource.contains(entry.host), !exclusions.contains(entry.host),
                  !keywords.contains(where: { entry.host.contains($0) }) else { continue }
            hosts[entry.category, default: []].insert(entry.host)
        }
        self.positive = positive
        self.exclusions = exclusions
        exclusionKeywords = keywords
        self.hosts = hosts
        self.unusedRules = unusedRules
        self.admittedRules = admittedRules
        excludedRules = negativeRows.sorted()
        allProjectedHosts = Set(hosts.values.joined())
        counts = Counts(source: rows.count, admitted: admitted, rejected: rejected,
                        unsupported: unsupported, exclusions: negativeRows.count)
    }

    public func matches(_ url: URL, scope: Scope) -> Bool {
        guard let host = Self.eligibleHost(url),
              !exclusions.contains(host), !exclusionKeywords.contains(where: { host.contains($0) }) else { return false }
        switch scope {
        case .all:
            return positive.contains(host) || allProjectedHosts.contains(host)
        case .categories(let categories):
            return categories.contains { hosts[$0]?.contains(host) == true }
        }
    }

    public static func eligibleHost(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil else { return nil }
        return AccessWebsiteRoutePolicy.websiteHost(url)?.rawValue
    }

    public static func mayProject(_ host: String, in categories: [AccessOverseasCategory]) -> Bool {
        projection.contains { $0.host == host && categories.contains($0.category) }
    }

    public func policy(for scope: Scope) throws -> Policy {
        let projected: Set<String>
        let rules: [Record]
        switch scope {
        case .all:
            projected = allProjectedHosts
            rules = admittedRules
        case .categories(let categories):
            projected = Set(categories.flatMap { hosts[$0] ?? [] })
            rules = []
        }
        return try Policy(rules: Array(Set(rules).union(projected.map { Record(kind: .full, value: $0) })),
                          exclusions: excludedRules)
    }

    private static func validExclusion(_ row: Record) -> Bool {
        switch row.kind {
        case .domain, .full:
            // An exception may cover a public suffix without granting it.
            return RegisteredDomain.isCanonicalDNSName(row.value, allowsSingleLabel: row.kind == .domain)
                && row.value.split(separator: ".").last?.utf8.contains(where: { (97...122).contains($0) }) == true
        case .keyword:
            return (1...253).contains(row.value.utf8.count)
                && row.value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }
        case .regexp: return false
        }
    }
}
