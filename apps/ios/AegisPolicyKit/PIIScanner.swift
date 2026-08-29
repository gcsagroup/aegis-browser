import Foundation

public enum PIIKind: String, Codable, CaseIterable, Equatable, Sendable {
    case email
    case phone
    case idCard
    case creditCard
    case ssn
    case secret
    case addressHint
}

public struct PIIMatch: Codable, Equatable, Sendable {
    public let kind: PIIKind
    public let value: String
    /// UTF-16 code-unit offset, matching JavaScript RegExp indices.
    public let start: Int
    /// UTF-16 code-unit offset, matching JavaScript String.slice boundaries.
    public let end: Int

    public init(kind: PIIKind, value: String, start: Int, end: Int) {
        self.kind = kind
        self.value = value
        self.start = start
        self.end = end
    }
}

public struct PIIScanResult: Codable, Equatable, Sendable {
    public let matches: [PIIMatch]
    public let redacted: String
    public let blocked: Bool

    public init(matches: [PIIMatch], redacted: String, blocked: Bool) {
        self.matches = matches
        self.redacted = redacted
        self.blocked = blocked
    }
}

public struct OutboundTextGateResult: Equatable, Sendable {
    public let allowed: Bool
    public let payload: String
    public let scan: PIIScanResult

    public init(allowed: Bool, payload: String, scan: PIIScanResult) {
        self.allowed = allowed
        self.payload = payload
        self.scan = scan
    }
}

public enum PIIScanner {
    public static func scan(_ text: String) -> PIIScanResult {
        let source = text as NSString
        var candidates: [DetectedMatch] = []
        var sequence = 0

        for (patternIndex, definition) in patterns.enumerated() {
            let matches = definition.expression.matches(
                in: text,
                range: NSRange(location: 0, length: source.length)
            )
            for match in matches {
                let value = source.substring(with: match.range)
                if definition.kind == .creditCard, !isValidCreditCard(value) {
                    continue
                }
                candidates.append(
                    DetectedMatch(
                        kind: definition.kind,
                        value: value,
                        range: match.range,
                        patternIndex: patternIndex,
                        sequence: sequence
                    )
                )
                sequence += 1
            }
        }

        candidates.sort { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            if lhs.patternIndex != rhs.patternIndex {
                return lhs.patternIndex < rhs.patternIndex
            }
            return lhs.sequence < rhs.sequence
        }

        var cursor = -1
        var accepted: [DetectedMatch] = []
        for candidate in candidates where candidate.range.location >= cursor {
            accepted.append(candidate)
            cursor = NSMaxRange(candidate.range)
        }

        let redacted = NSMutableString(string: text)
        for match in accepted.reversed() {
            redacted.replaceCharacters(
                in: match.range,
                with: mask(match.value, as: match.kind)
            )
        }

        let publicMatches = accepted.map { match in
            PIIMatch(
                kind: match.kind,
                value: match.value,
                start: match.range.location,
                end: NSMaxRange(match.range)
            )
        }
        return PIIScanResult(
            matches: publicMatches,
            redacted: redacted as String,
            blocked: !publicMatches.isEmpty
        )
    }

    public static func gateOutboundText(
        _ text: String,
        userApproved: Bool
    ) -> OutboundTextGateResult {
        let scan = scan(text)
        guard scan.blocked else {
            return OutboundTextGateResult(allowed: true, payload: text, scan: scan)
        }
        return OutboundTextGateResult(
            allowed: userApproved,
            payload: scan.redacted,
            scan: scan
        )
    }

    private struct PatternDefinition {
        let kind: PIIKind
        let expression: NSRegularExpression

        init(_ kind: PIIKind, _ pattern: String, options: NSRegularExpression.Options = []) {
            self.kind = kind
            self.expression = try! NSRegularExpression(pattern: pattern, options: options)
        }
    }

    private struct DetectedMatch {
        let kind: PIIKind
        let value: String
        let range: NSRange
        let patternIndex: Int
        let sequence: Int
    }

    private static let patterns: [PatternDefinition] = [
        PatternDefinition(
            .secret,
            #"\b(?:bearer\s+[A-Z0-9._~+/-]{8,}={0,2}|eyJ[A-Z0-9_-]{5,}\.[A-Z0-9_-]{5,}\.[A-Z0-9_-]{5,}|AKIA[0-9A-Z]{16}|(?:api[_-]?key|access[_-]?token|refresh[_-]?token|auth(?:orization)?|secret|password|passwd|token)\s*[:=]\s*(?:bearer\s+)?["']?[A-Z0-9._~+/-]{8,}={0,2}["']?)"#,
            options: [.caseInsensitive]
        ),
        PatternDefinition(
            .email,
            #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            options: [.caseInsensitive]
        ),
        PatternDefinition(
            .phone,
            #"(?<![0-9])(?:\+?86[-\s]?)?1[3-9][0-9]{9}(?![0-9])|\b(?:\+?1[-.\s]?)?\(?[0-9]{3}\)?[-.\s]?[0-9]{3}[-.\s]?[0-9]{4}\b"#
        ),
        PatternDefinition(
            .idCard,
            #"\b[1-9][0-9]{5}(?:19|20)[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9Xx]\b"#
        ),
        PatternDefinition(.ssn, #"\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b"#),
        PatternDefinition(.creditCard, #"\b(?:[0-9][ -]*?){13,19}\b"#),
        PatternDefinition(
            .addressHint,
            #"\b[0-9]{1,5}\s+[A-Za-z0-9_.\u4e00-\u9fff]+(?:\s+[A-Za-z0-9_.\u4e00-\u9fff]+){0,4}\s+(?:street|st|road|rd|ave|avenue|blvd|lane|ln|drive|dr|路|街|巷|号)\b"#,
            options: [.caseInsensitive]
        ),
    ]

    private static func mask(_ value: String, as kind: PIIKind) -> String {
        let source = value as NSString
        switch kind {
        case .secret:
            return "[REDACTED_SECRET]"
        case .email:
            let components = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2 else { return value }
            return "\(components[0].prefix(1))***@\(components[1])"
        case .phone:
            guard source.length >= 5 else { return value }
            return "\(source.substring(to: 3))****\(source.substring(from: source.length - 2))"
        case .idCard:
            guard source.length >= 8 else { return value }
            return "\(source.substring(to: 4))**********\(source.substring(from: source.length - 4))"
        case .ssn:
            return "***-**-****"
        case .creditCard:
            let digits = value.filter(\.isNumber)
            guard (13 ... 19).contains(digits.count) else { return value }
            return "\(digits.prefix(4)) **** **** \(digits.suffix(4))"
        case .addressHint:
            return "[REDACTED_ADDRESS]"
        }
    }

    private static func isValidCreditCard(_ value: String) -> Bool {
        let digits = value.compactMap { character -> Int? in
            guard character.isASCII, character.isNumber else { return nil }
            return character.wholeNumberValue
        }
        guard (13 ... 19).contains(digits.count) else { return false }

        var sum = 0
        var alternate = false
        for digit in digits.reversed() {
            var value = digit
            if alternate {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
            alternate.toggle()
        }
        return sum.isMultiple(of: 10)
    }
}
