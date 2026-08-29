import Foundation

public struct PolicyPageSnapshot: Equatable, Sendable {
    public let url: String
    public let title: String
    public let textSample: String
    public let forms: Int
    public let passwordFields: Int
    public let crossSiteFormActions: Int

    public init(
        url: String,
        title: String,
        textSample: String,
        forms: Int = 0,
        passwordFields: Int = 0,
        crossSiteFormActions: Int = 0
    ) {
        self.url = url
        self.title = title
        self.textSample = textSample
        self.forms = max(0, forms)
        self.passwordFields = max(0, passwordFields)
        self.crossSiteFormActions = max(0, crossSiteFormActions)
    }
}
public enum PhishSeverity: String, Codable, Equatable, Sendable {
    case low
    case medium
    case high
    case critical
}

public struct PhishReason: Codable, Equatable, Sendable {
    public let code: String
    public let weight: Int
    public let detail: String?

    public init(code: String, weight: Int, detail: String? = nil) {
        self.code = code
        self.weight = weight
        self.detail = detail
    }
}

public struct PhishAssessment: Codable, Equatable, Sendable {
    public let score: Int
    public let severity: PhishSeverity
    public let reasons: [PhishReason]
    public let shouldBlock: Bool
    public let url: String

    public init(
        score: Int,
        severity: PhishSeverity,
        reasons: [PhishReason],
        shouldBlock: Bool,
        url: String
    ) {
        self.score = score
        self.severity = severity
        self.reasons = reasons
        self.shouldBlock = shouldBlock
        self.url = url
    }
}
