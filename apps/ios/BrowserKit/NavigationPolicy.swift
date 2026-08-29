import AegisPolicyKit
import Foundation

public enum BrowserNavigationPolicyKind: String, Equatable, Sendable {
    case allow
    case sanitized
    case blocked
}

public struct BrowserNavigationPolicyDecision: Equatable, Sendable {
    public let kind: BrowserNavigationPolicyKind
    public let originalURL: String
    public let effectiveURL: String
    public let removedQueryParameters: [String]
    public let phishingScore: Int
    public let reasonCodes: [String]

    public init(
        kind: BrowserNavigationPolicyKind,
        originalURL: String,
        effectiveURL: String,
        removedQueryParameters: [String],
        phishingScore: Int,
        reasonCodes: [String]
    ) {
        self.kind = kind
        self.originalURL = originalURL
        self.effectiveURL = effectiveURL
        self.removedQueryParameters = removedQueryParameters
        self.phishingScore = phishingScore
        self.reasonCodes = reasonCodes
    }
}

public enum BrowserNavigationPolicy {
    public static func evaluate(
        _ url: URL,
        httpMethod: String = "GET"
    ) -> BrowserNavigationPolicyDecision {
        let original = url.absoluteString
        let scheme = url.scheme?.lowercased()
        if scheme == "aegis" || (scheme == "about" && original.lowercased() == "about:blank") {
            return BrowserNavigationPolicyDecision(
                kind: .allow,
                originalURL: original,
                effectiveURL: original,
                removedQueryParameters: [],
                phishingScore: 0,
                reasonCodes: []
            )
        }
        guard scheme == "http" || scheme == "https" else {
            return blocked(
                originalURL: original,
                effectiveURL: original,
                reasonCodes: ["unsupported_top_level_scheme"]
            )
        }

        let sanitizeResult = LinkSanitizer.sanitize(original)
        let effective = URL(string: sanitizeResult.cleaned) ?? url
        let requiresTrackingSanitization = !sanitizeResult.removed.isEmpty
        let assessment = PhishingScorer.scoreURL(effective.absoluteString)
        var reasonCodes = assessment.reasons.map(\.code)
        if url.user != nil || url.password != nil {
            reasonCodes.append("credentialed_url")
            return blocked(
                originalURL: original,
                effectiveURL: effective.absoluteString,
                removedQueryParameters: sanitizeResult.removed,
                phishingScore: assessment.score,
                reasonCodes: reasonCodes
            )
        }
        let kind: BrowserNavigationPolicyKind
        if assessment.shouldBlock {
            kind = .blocked
        } else if requiresTrackingSanitization,
                  httpMethod.uppercased() != "GET",
                  httpMethod.uppercased() != "HEAD" {
            kind = .blocked
            reasonCodes.append("unsafe_sanitization_method")
        } else if requiresTrackingSanitization {
            kind = .sanitized
        } else {
            kind = .allow
        }

        return BrowserNavigationPolicyDecision(
            kind: kind,
            originalURL: original,
            effectiveURL: kind == .allow ? original : effective.absoluteString,
            removedQueryParameters: sanitizeResult.removed,
            phishingScore: assessment.score,
            reasonCodes: reasonCodes
        )
    }

    private static func blocked(
        originalURL: String,
        effectiveURL: String,
        removedQueryParameters: [String] = [],
        phishingScore: Int = 0,
        reasonCodes: [String]
    ) -> BrowserNavigationPolicyDecision {
        BrowserNavigationPolicyDecision(
            kind: .blocked,
            originalURL: originalURL,
            effectiveURL: effectiveURL,
            removedQueryParameters: removedQueryParameters,
            phishingScore: phishingScore,
            reasonCodes: reasonCodes
        )
    }
}
