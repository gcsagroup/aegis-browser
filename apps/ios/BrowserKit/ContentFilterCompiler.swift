import Foundation

public struct ContentFilterCompilation: Codable, Sendable {
    public let json: String
    public let networkCount: Int
    public let cosmeticCount: Int
    public let skippedCount: Int
    public var ruleCount: Int { networkCount + cosmeticCount }
}

/// 将可准确表达的订阅规则转换成 WebKit 数据规则；不下载或执行脚本。
public enum ContentFilterCompiler {
    private static let resourceTypes = ["script", "image", "style-sheet", "font", "raw", "media", "svg-document", "ping"]
    private static let typeMap = ["script": "script", "image": "image", "stylesheet": "style-sheet", "font": "font", "xmlhttprequest": "raw", "media": "media", "ping": "ping", "other": "raw"]

    public static func compile(_ sources: [String]) throws -> ContentFilterCompilation {
        guard sources.reduce(0, { $0 + $1.utf8.count }) <= 12_000_000 else { throw ContentFilterError.tooLarge }
        let lines = sources.flatMap { $0.components(separatedBy: .newlines) }
        // 无法精确表达的元素例外宁可减少拦截范围，不把白名单当成广告规则。
        let cosmeticExceptions = Set(lines.compactMap { line -> String? in
            guard let range = line.range(of: "#@#") else { return nil }
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        })
        var blocks: [[String: Any]] = [], exceptions: [[String: Any]] = [], cosmetics: [[String: Any]] = []
        var seen = Set<String>(), skipped = 0
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
            guard line.utf8.count <= 4096 else { skipped += 1; continue }
            if let rule = cosmetic(line, exceptions: cosmeticExceptions) {
                let key = String(data: try JSONSerialization.data(withJSONObject: rule, options: [.sortedKeys]), encoding: .utf8)!
                if seen.insert(key).inserted { cosmetics.append(rule) }
            } else if let rule = network(line) {
                let key = String(data: try JSONSerialization.data(withJSONObject: rule, options: [.sortedKeys]), encoding: .utf8)!
                if seen.insert(key).inserted {
                    if line.hasPrefix("@@") { exceptions.append(rule) } else { blocks.append(rule) }
                }
            } else { skipped += 1 }
            guard blocks.count + exceptions.count + cosmetics.count <= 150_000 else { throw ContentFilterError.tooLarge }
        }
        let rules = cosmetics + blocks + exceptions
        guard !rules.isEmpty else { throw ContentFilterError.empty }
        let json = String(data: try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]), encoding: .utf8)!
        return ContentFilterCompilation(json: json, networkCount: blocks.count + exceptions.count, cosmeticCount: cosmetics.count, skippedCount: skipped)
    }

    private static func cosmetic(_ line: String, exceptions: Set<String>) -> [String: Any]? {
        guard let range = line.range(of: "##"), !line.contains("#@#"), !line.contains("#?#") else { return nil }
        let domains = String(line[..<range.lowerBound])
        let selector = String(line[range.upperBound...])
        guard !selector.isEmpty, !exceptions.contains(selector), !selector.contains(":"),
              selector.range(of: "^[a-zA-Z0-9_ .#\\[\\]=~^$*'\" >+(),|/-]+$", options: .regularExpression) != nil else { return nil }
        var trigger: [String: Any] = ["url-filter": ".*"]
        if !domains.isEmpty {
            guard let constraints = domainConstraints(domains.split(separator: ",").map(String.init)) else { return nil }
            trigger.merge(constraints) { _, new in new }
        }
        return ["trigger": trigger, "action": ["type": "css-display-none", "selector": selector]]
    }

    private static func network(_ input: String) -> [String: Any]? {
        var line = input
        let exception = line.hasPrefix("@@")
        if exception { line.removeFirst(2) }
        guard !line.contains("#"), line.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        let segments = line.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
        var pattern = String(segments[0])
        var trigger: [String: Any] = [:]
        var included: [String] = [], excluded = Set<String>()
        if segments.count == 2 {
            for option in segments[1].split(separator: ",") {
                let value = String(option)
                if value == "third-party" { trigger["load-type"] = ["third-party"] }
                else if value == "~third-party" { trigger["load-type"] = ["first-party"] }
                else if value == "match-case" { trigger["url-filter-is-case-sensitive"] = true }
                else if value.hasPrefix("domain=") {
                    guard let domains = domainConstraints(value.dropFirst(7).split(separator: "|").map(String.init)) else { return nil }
                    trigger.merge(domains) { _, new in new }
                } else if let type = typeMap[value] { included.append(type) }
                else if value.hasPrefix("~"), let type = typeMap[String(value.dropFirst())] { excluded.insert(type) }
                else { return nil }
            }
        }
        let types = Set(included.isEmpty ? resourceTypes : included).subtracting(excluded).sorted()
        guard !types.isEmpty else { return nil }
        trigger["resource-type"] = types
        let regex: String
        if pattern.hasPrefix("||") {
            pattern.removeFirst(2)
            let host = String(pattern.prefix { $0 != "/" && $0 != "^" })
            guard validHost(host) else { return nil }
            let suffix = String(pattern.dropFirst(host.count))
            if suffix.isEmpty || suffix == "^" { regex = "^https?://([^/]+\\.)?" + escape(host) + "[/:]" }
            else {
                guard suffix.hasPrefix("/"), !suffix.contains("^") else { return nil }
                regex = "^https?://([^/]+\\.)?" + escape(host) + "(:[0-9]+)?" + wildcard(suffix)
            }
        } else {
            guard !pattern.isEmpty, !pattern.hasPrefix("/"), !pattern.contains("^"), pattern.count >= 6 else { return nil }
            let start = pattern.hasPrefix("|"); if start { pattern.removeFirst() }
            let end = pattern.hasSuffix("|"); if end { pattern.removeLast() }
            guard !pattern.contains("|") else { return nil }
            regex = (start ? "^" : "") + wildcard(pattern) + (end ? "$" : "")
        }
        trigger["url-filter"] = regex
        return ["trigger": trigger, "action": ["type": exception ? "ignore-previous-rules" : "block"]]
    }
    private static func domainConstraints(_ domains: [String]) -> [String: Any]? {
        guard !domains.isEmpty else { return nil }
        let positive = domains.filter { !$0.hasPrefix("~") }
        let negative = domains.filter { $0.hasPrefix("~") }.map { String($0.dropFirst()) }
        // WebKit 的 if-domain 与 unless-domain 不能同时出现。
        guard positive.isEmpty || negative.isEmpty, (positive + negative).allSatisfy(validHost) else { return nil }
        return [positive.isEmpty ? "unless-domain" : "if-domain": (positive.isEmpty ? negative : positive).map { "*" + $0.lowercased() }]
    }
    private static func validHost(_ host: String) -> Bool {
        host.count <= 253 && host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".") && !host.contains("..") && host.range(of: "^[a-zA-Z0-9.-]+$", options: .regularExpression) != nil
    }
    private static func escape(_ value: String) -> String {
        value.reduce(into: "") { result, character in
            if ".+?[](){}^$|\\".contains(character) { result.append("\\") }
            result.append(character)
        }
    }
    private static func wildcard(_ value: String) -> String { value.components(separatedBy: "*").map(escape).joined(separator: ".*") }
}

public enum ContentFilterError: LocalizedError {
    case tooLarge, empty, invalidResponse
    public var errorDescription: String? {
        switch self {
        case .tooLarge: String(localized: "过滤列表超过处理上限，已保留原有规则。")
        case .empty: String(localized: "过滤列表没有可用规则，已保留原有规则。")
        case .invalidResponse: String(localized: "规则更新失败，已保留原有规则。请稍后重试。")
        }
    }
}
