import Foundation

/// Opaque one-shot registration identity. Never reused after revoke, expiry,
/// or port recycle.
public struct AccessRegistrationID: Codable, Sendable, Equatable, Hashable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AccessContractError.emptyRegistrationID
        }
        guard trimmed == rawValue, !trimmed.contains("\0") else {
            throw AccessContractError.registrationIDNotCanonical
        }
        self.rawValue = trimmed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Browser-owned inbound registration published to WebKit / probe callers.
///
/// `id` is opaque and one-shot. Recycling a TCP port still requires a new id
/// and a new lease generation. SOCKS5 registrations are no-auth only; the
/// SOCKS5 listener rejects username/password negotiation.
public struct AccessRegistration: Codable, Sendable, Equatable, Hashable {
    public let id: AccessRegistrationID
    public let owner: AccessOwner
    public let transport: AccessInboundTransport
    public let endpoint: AccessEndpoint
    public let credentialSlot: AccessCredentialSlot
    public let lease: AccessLease

    public init(
        id: AccessRegistrationID,
        owner: AccessOwner,
        transport: AccessInboundTransport,
        endpoint: AccessEndpoint,
        credentialSlot: AccessCredentialSlot,
        lease: AccessLease
    ) {
        self.id = id
        self.owner = owner
        self.transport = transport
        self.endpoint = endpoint
        self.credentialSlot = credentialSlot
        self.lease = lease
    }

    public var generation: UInt64 { lease.generation }
    public var leaseExpiry: Date { lease.expiresAt }

    public func isActive(at now: Date, observedGeneration: UInt64) -> Bool {
        lease.isActive(at: now, observedGeneration: observedGeneration)
    }

    /// Port recycle / rotate path: same owner+transport, new id + endpoint + lease.
    public func rotated(
        id: AccessRegistrationID,
        endpoint: AccessEndpoint,
        credentialSlot: AccessCredentialSlot,
        lease: AccessLease
    ) throws -> AccessRegistration {
        guard id != self.id else {
            throw AccessContractError.registrationIDReused
        }
        guard lease.generation > self.lease.generation else {
            throw AccessContractError.staleLeaseGeneration(lease.generation)
        }
        return AccessRegistration(
            id: id,
            owner: owner,
            transport: transport,
            endpoint: endpoint,
            credentialSlot: credentialSlot,
            lease: lease
        )
    }
}
