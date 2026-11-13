import Foundation

/// User intent for Access on one exact host (product Phase 1).
///
/// - `off`: no Access site-proxy selection for this host
/// - `allow`: route this host through the admitted Access path
/// - `block`: locally refuse Access proxying for this host (DEV/product block)
///
/// Intent is not connection health. Controllers keep those separate.
public enum AccessSiteIntent: String, Codable, Sendable, Equatable, Hashable {
    case off
    case allow
    case block

    public static func parse(rawValue: String) throws -> AccessSiteIntent {
        switch rawValue {
        case AccessSiteIntent.off.rawValue:
            return .off
        case AccessSiteIntent.allow.rawValue:
            return .allow
        case AccessSiteIntent.block.rawValue:
            return .block
        default:
            throw AccessSiteIntentError.unknownIntent(rawValue)
        }
    }
}

/// Exact-host key for site intent. No scheme, path, port, or userinfo.
public struct AccessSiteHost: Codable, Sendable, Equatable, Hashable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AccessSiteIntentError.emptyHost
        }
        guard trimmed == rawValue else {
            throw AccessSiteIntentError.hostNotCanonical
        }
        guard !trimmed.unicodeScalars.contains(where: Self.isRejectedHostScalar) else {
            throw AccessSiteIntentError.hostNotCanonical
        }
        let lower = trimmed.lowercased()
        guard lower == trimmed else {
            throw AccessSiteIntentError.hostNotCanonical
        }
        if trimmed.contains("://") || trimmed.contains("/") || trimmed.contains("@") {
            throw AccessSiteIntentError.hostContainsSchemeOrPath
        }
        // Reject embedded ports here so product keys stay exact-host only.
        if trimmed.contains(":") {
            throw AccessSiteIntentError.hostNotCanonical
        }
        self.rawValue = trimmed
    }

    private static func isRejectedHostScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
            || CharacterSet.controlCharacters.contains(scalar)
            || scalar.value == 0x7F
    }

    /// Normalizes browser-facing host text into an exact-host key.
    public static func normalize(_ raw: String) throws -> AccessSiteHost {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = text.firstIndex(of: "@") {
            text = String(text[text.index(after: at)...])
        }
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        }
        if let slash = text.firstIndex(of: "/") {
            text = String(text[..<slash])
        }
        if text.hasPrefix("[") , let end = text.firstIndex(of: "]") {
            text = String(text[text.index(after: text.startIndex)..<end])
        } else if let colon = text.lastIndex(of: ":"), text[text.index(after: colon)...].allSatisfy(\.isNumber) {
            text = String(text[..<colon])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return try AccessSiteHost(text)
    }
}
