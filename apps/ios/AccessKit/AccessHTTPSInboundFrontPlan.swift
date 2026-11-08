import Foundation

/// Validated plan for a loopback HTTPS inbound TLS front.
///
/// The front terminates TLS locally, then speaks cleartext HTTP CONNECT to the
/// same admission path as F4. Origin certificates are never forged here.
public struct AccessHTTPSInboundFrontPlan: Sendable, Equatable, Hashable {
    public let registration: AccessRegistration
    public let identityLabel: String

    public init(registration: AccessRegistration, identityLabel: String) throws {
        guard registration.transport == .https else {
            throw AccessHTTPSInboundError.transportNotHTTPS(registration.transport)
        }
        let trimmed = identityLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AccessHTTPSInboundError.emptyIdentityLabel
        }
        guard trimmed == identityLabel, !trimmed.contains("\0") else {
            throw AccessHTTPSInboundError.identityLabelNotCanonical
        }
        self.registration = registration
        self.identityLabel = trimmed
    }
}

/// Builds HTTPS front plans from registrations.
public enum AccessHTTPSInboundFrontBuilder {
    public static func plan(
        registration: AccessRegistration,
        identityLabel: String
    ) throws -> AccessHTTPSInboundFrontPlan {
        try AccessHTTPSInboundFrontPlan(
            registration: registration,
            identityLabel: identityLabel
        )
    }
}
