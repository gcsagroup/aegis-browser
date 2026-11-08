import Foundation

/// Opaque browser-owned credential slot identity for a registration.
///
/// Secrets never live in this value. Callers bind username/password material
/// in Keychain or process memory keyed by `id`. Logging must not emit the
/// secret bytes, only this opaque id.
public struct AccessCredentialSlot: Codable, Sendable, Equatable, Hashable {
    public let id: String

    public init(id: String) throws {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AccessContractError.emptyCredentialSlot
        }
        guard trimmed == id, !trimmed.contains("\0") else {
            throw AccessContractError.credentialSlotNotCanonical
        }
        self.id = trimmed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(id: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}
