import Foundation

/// Orchestration phase for one host (PrepareCandidate → Publish → ACK → ready).
public enum AccessSiteSessionPhase: String, Codable, Sendable, Equatable, Hashable {
    case idle
    case preparingCandidate
    case publishing
    case awaitingAck
    case ready
    case unavailable
}

/// Connection health distinct from user intent (A1-3).
public enum AccessSiteSessionConnectionState: String, Codable, Sendable, Equatable, Hashable {
    case idle
    case connecting
    case ready
    case unavailable
}

/// Point-in-time view of intent + orchestration for one exact host.
public struct AccessSiteSessionSnapshot: Sendable, Equatable {
    public let host: AccessSiteHost
    public let intent: AccessSiteIntent
    public let phase: AccessSiteSessionPhase
    public let connectionState: AccessSiteSessionConnectionState
    public let faultMode: AccessSiteSessionFaultMode
    public let registrationID: AccessRegistrationID?
    public let failureReason: String?

    public init(
        host: AccessSiteHost,
        intent: AccessSiteIntent,
        phase: AccessSiteSessionPhase,
        connectionState: AccessSiteSessionConnectionState,
        faultMode: AccessSiteSessionFaultMode = .none,
        registrationID: AccessRegistrationID? = nil,
        failureReason: String? = nil
    ) {
        self.host = host
        self.intent = intent
        self.phase = phase
        self.connectionState = connectionState
        self.faultMode = faultMode
        self.registrationID = registrationID
        self.failureReason = failureReason
    }

    public static func idle(host: AccessSiteHost) -> AccessSiteSessionSnapshot {
        AccessSiteSessionSnapshot(
            host: host,
            intent: .off,
            phase: .idle,
            connectionState: .idle,
            faultMode: .none
        )
    }
}

/// Prepared inbound + proxy fixture before publication.
public struct AccessSiteSessionCandidate: Sendable, Equatable {
    public let host: AccessSiteHost
    public let registration: AccessRegistration
    public let proxyFixture: AccessProxyRegistrationFixture

    public init(
        host: AccessSiteHost,
        registration: AccessRegistration,
        proxyFixture: AccessProxyRegistrationFixture
    ) {
        self.host = host
        self.registration = registration
        self.proxyFixture = proxyFixture
    }
}

/// Published candidate awaiting acknowledgement.
public struct AccessSiteSessionPublication: Sendable, Equatable {
    public let candidate: AccessSiteSessionCandidate
    public let publicationToken: String

    public init(candidate: AccessSiteSessionCandidate, publicationToken: String) {
        self.candidate = candidate
        self.publicationToken = publicationToken
    }
}

/// Exact ACK that activates the reality path for a publication.
public struct AccessSiteSessionAck: Sendable, Equatable {
    public let publicationToken: String
    public let registrationID: AccessRegistrationID

    public init(publicationToken: String, registrationID: AccessRegistrationID) {
        self.publicationToken = publicationToken
        self.registrationID = registrationID
    }
}
