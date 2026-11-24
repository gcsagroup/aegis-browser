import CryptoKit
import Foundation

/// PSL 的精确、通配与例外规则；保留私有后缀，避免将共享托管的不同租户视为同站。
public enum RegisteredDomain {
    private final class ResourceAnchor: NSObject { }
    private static let data: Data? = {
        guard let url = Bundle(for: ResourceAnchor.self).url(forResource: "public_suffix_list", withExtension: "dat")
        else { return nil }
        return try? Data(contentsOf: url)
    }()

    private static let rules: Set<String> = {
        guard let data, let text = String(data: data, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { line in
            let rule = line.trimmingCharacters(in: .whitespaces)
            guard !rule.isEmpty, !rule.hasPrefix("//") else { return nil }
            let prefix = rule.hasPrefix("!") ? "!" : (rule.hasPrefix("*.") ? "*." : "")
            return normalizedHost(String(rule.dropFirst(prefix.count))).map { prefix + $0 }
        })
    }()

    private static let pinnedSHA256 = "ba7d836c0ea57a8bcf9f1fcb868066a7554bed029b441ecc6204ad8494a32612"

    private struct GeoSiteSuffixList {
        let knownRoots: Set<String>
        let nestedBoundaries: Set<String>
    }

    private static let strictGeoSiteList: GeoSiteSuffixList? = {
        guard let data, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == pinnedSHA256,
              !rules.isEmpty else { return nil }
        var knownRoots: Set<String> = []
        var nested: Set<String> = []
        for rule in rules {
            let wildcard = rule.hasPrefix("*.")
            var suffix = rule.dropFirst(wildcard ? 2 : (rule.hasPrefix("!") ? 1 : 0))
            if wildcard { nested.insert(String(suffix)) }
            while let dot = suffix.firstIndex(of: ".") {
                suffix = suffix[suffix.index(after: dot)...]
                nested.insert(String(suffix))
            }
            knownRoots.insert(String(suffix))
        }
        return GeoSiteSuffixList(knownRoots: knownRoots, nestedBoundaries: nested)
    }()

    /// Available only when the exact pinned ICANN and PRIVATE resource loaded.
    public static var verifiedGeoSiteSuffixListSHA256: String? {
        strictGeoSiteList == nil ? nil : pinnedSHA256
    }

    /// Checks an already-canonical release rule. Broad rules cannot enclose
    /// another ICANN or PRIVATE boundary, including a wildcard suffix.
    public static func allowsGeoSiteHost(_ host: String, includingDescendants: Bool) -> Bool {
        guard let list = strictGeoSiteList, (1...253).contains(host.utf8.count),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              host != "home.arpa", !host.hasSuffix(".home.arpa") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let root = labels.last, list.knownRoots.contains(String(root)),
              labels.allSatisfy({ label in
                  (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                      && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }),
              labels.count > suffixLength(labels.map(String.init)),
              !includingDescendants || !list.nestedBoundaries.contains(host)
        else { return false }
        if labels.contains(where: { $0.hasPrefix("xn--") }) {
            guard let unicode = URLComponents(string: "https://\(host)/")?.host,
                  unicode.utf8.contains(where: { $0 >= 128 }),
                  var components = URLComponents(string: "https://example.com/") else { return false }
            components.host = unicode
            return components.url?.host == host
        }
        return true
    }

    public static func normalizedHost(_ raw: String) -> String? {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, !host.contains("/"), !host.contains("@"),
              let url = URL(string: "https://\(host)/"), let normalized = url.host else { return nil }
        return normalized.lowercased()
    }

    /// Recognize conventional HTTPS landing hosts only when the pinned PSL is available.
    public static func isCanonicalLandingHost(_ target: String, for source: String) -> Bool {
        guard !rules.isEmpty, let apex = of(source), apex == source else { return false }
        return target == "www." + apex || target == "m." + apex
    }

    public static func of(_ raw: String) -> String? {
        guard let host = normalizedHost(raw) else { return nil }
        if host.contains(":") || host.split(separator: ".").allSatisfy({ Int($0) != nil }) { return host }
        let labels = host.split(separator: ".").map(String.init)
        let suffixCount = suffixLength(labels)
        guard labels.count > suffixCount else { return nil }
        return labels.suffix(suffixCount + 1).joined(separator: ".")
    }

    private static func suffixLength(_ labels: [String]) -> Int {
        var suffixCount = 1
        for index in labels.indices {
            let suffix = labels[index...].joined(separator: ".")
            if rules.contains("!" + suffix) { return labels.count - index - 1 }
            if rules.contains(suffix) { suffixCount = max(suffixCount, labels.count - index) }
            if index > 0, rules.contains("*." + suffix) { suffixCount = max(suffixCount, labels.count - index + 1) }
        }
        return suffixCount
    }
}
