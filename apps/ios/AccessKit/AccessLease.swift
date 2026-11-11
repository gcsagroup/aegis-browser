import Foundation

/// Time-bounded lease attached to a registration generation.
///
/// A lease is valid only while `now < expiresAt` and the caller's observed
/// `generation` equals `generation`. Expiry never revives a prior generation:
/// callers must mint a new registration id and generation together.
public struct AccessLease: Codable, Sendable, Equatable, Hashable {
    public let generation: UInt64
    public let expiresAt: Date

    public init(generation: UInt64, expiresAt: Date) throws {
        guard generation > 0 else {
            throw AccessContractError.invalidLeaseGeneration(generation)
        }
        self.generation = generation
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let generation = try container.decode(UInt64.self, forKey: .generation)
        let expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        try self.init(generation: generation, expiresAt: expiresAt)
    }

    /// Fail-closed validity check used by accept paths and ProxyConfiguration appliers.
    public func isActive(at now: Date, observedGeneration: UInt64) -> Bool {
        guard observedGeneration == generation else {
            return false
        }
        return now < expiresAt
    }

    /// Returns a renewed lease that always advances generation.
    public func renewed(expiresAt nextExpiry: Date) throws -> AccessLease {
        let nextGeneration = generation &+ 1
        guard nextGeneration > generation else {
            throw AccessContractError.leaseGenerationOverflow
        }
        return try AccessLease(generation: nextGeneration, expiresAt: nextExpiry)
    }

    private enum CodingKeys: String, CodingKey {
        case generation
        case expiresAt
    }
}
