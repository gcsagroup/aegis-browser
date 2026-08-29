import Foundation

public struct LinkSanitizeResult: Equatable, Sendable {
    public let original: String
    public let cleaned: String
    public let removed: [String]
    public let changed: Bool

    public init(original: String, cleaned: String, removed: [String], changed: Bool) {
        self.original = original
        self.cleaned = cleaned
        self.removed = removed
        self.changed = changed
    }
}

public enum LinkSanitizer {
    public static let trackingQueryParameters: [String] = [
        "fbclid", "gclid", "gclsrc", "dclid", "msclkid", "mc_eid", "mc_cid",
        "igshid", "twclid", "ttclid", "yclid", "ybclid", "utm_source", "utm_medium",
        "utm_campaign", "utm_term", "utm_content", "utm_id", "_ga", "_gl", "vero_id",
        "wickedid", "oly_anon_id", "oly_enc_id", "gbraid", "wbraid", "gad_source",
        "gad_campaignid", "srsltid", "li_fat_id", "_hsenc", "_hsmi", "mkt_tok",
    ]

    public static func sanitize(
        _ rawURL: String,
        extraParameters: [String] = []
    ) -> LinkSanitizeResult {
        guard var components = URLComponents(string: rawURL), components.scheme != nil else {
            return unchanged(rawURL)
        }

        if let host = components.url?.host ?? components.host {
            components.host = host.lowercased()
        }
        if let scheme = components.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/"
        }

        let blocked = Set((trackingQueryParameters + extraParameters).map { $0.lowercased() })
        var removed: [String] = []

        if let rawQuery = components.percentEncodedQuery {
            let fields = parseFormFields(rawQuery)
            let retained = fields.filter { field in
                let shouldRemove = blocked.contains(field.name.lowercased())
                if shouldRemove {
                    removed.append(field.name)
                }
                return !shouldRemove
            }
            if retained.count != fields.count {
                components.percentEncodedQuery = retained.isEmpty
                    ? nil
                    : retained.map(serializeFormField).joined(separator: "&")
            }
        }

        if let fragment = components.percentEncodedFragment,
           fragment.range(
               of: "(?:utm_|fbclid|gclid)",
               options: [.regularExpression, .caseInsensitive]
           ) != nil {
            components.fragment = nil
            removed.append("#tracking-hash")
        }

        guard let cleaned = components.string else {
            return unchanged(rawURL)
        }
        return LinkSanitizeResult(
            original: rawURL,
            cleaned: cleaned,
            removed: removed,
            changed: cleaned != rawURL
        )
    }

    private struct FormField {
        let name: String
        let value: String
    }

    private static func parseFormFields(_ query: String) -> [FormField] {
        query.split(separator: "&", omittingEmptySubsequences: false).map { part in
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return FormField(
                name: formDecode(String(pieces[0])),
                value: pieces.count == 2 ? formDecode(String(pieces[1])) : ""
            )
        }
    }

    private static func serializeFormField(_ field: FormField) -> String {
        "\(formEncode(field.name))=\(formEncode(field.value))"
    }

    private static func formDecode(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            ?? value.replacingOccurrences(of: "+", with: " ")
    }

    private static func formEncode(_ value: String) -> String {
        var result = ""
        for byte in value.utf8 {
            switch byte {
            case 0x41 ... 0x5A, 0x61 ... 0x7A, 0x30 ... 0x39, 0x2A, 0x2D, 0x2E, 0x5F:
                result.append(Character(UnicodeScalar(byte)))
            case 0x20:
                result.append("+")
            default:
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    private static func unchanged(_ rawURL: String) -> LinkSanitizeResult {
        LinkSanitizeResult(
            original: rawURL,
            cleaned: rawURL,
            removed: [],
            changed: false
        )
    }
}
