import Foundation

/// PSL 的精确、通配与例外规则；保留私有后缀，避免将共享托管的不同租户视为同站。
public enum RegisteredDomain {
    private final class ResourceAnchor: NSObject { }
    private static let rules: Set<String> = {
        guard let url = Bundle(for: ResourceAnchor.self).url(forResource: "public_suffix_list", withExtension: "dat"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { line in
            let rule = line.trimmingCharacters(in: .whitespaces)
            guard !rule.isEmpty, !rule.hasPrefix("//") else { return nil }
            let prefix = rule.hasPrefix("!") ? "!" : (rule.hasPrefix("*.") ? "*." : "")
            return normalizedHost(String(rule.dropFirst(prefix.count))).map { prefix + $0 }
        })
    }()

    public static func normalizedHost(_ raw: String) -> String? {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, !host.contains("/"), !host.contains("@"),
              let url = URL(string: "https://\(host)/"), let normalized = url.host else { return nil }
        return normalized.lowercased()
    }

    public static func of(_ raw: String) -> String? {
        guard let host = normalizedHost(raw) else { return nil }
        if host.contains(":") || host.split(separator: ".").allSatisfy({ Int($0) != nil }) { return host }
        let labels = host.split(separator: ".").map(String.init)
        var suffixCount = 1
        for index in labels.indices {
            let suffix = labels[index...].joined(separator: ".")
            if rules.contains("!" + suffix) { suffixCount = labels.count - index - 1; break }
            if rules.contains(suffix) { suffixCount = max(suffixCount, labels.count - index) }
            if index > 0, rules.contains("*." + suffix) { suffixCount = max(suffixCount, labels.count - index + 1) }
        }
        guard labels.count > suffixCount else { return nil }
        return labels.suffix(suffixCount + 1).joined(separator: ".")
    }
}
