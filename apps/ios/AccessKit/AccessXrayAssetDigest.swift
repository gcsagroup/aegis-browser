import Foundation

/// Lowercase SHA-256 hex digest for a trusted Access asset.
public struct AccessXrayAssetDigest: Codable, Sendable, Equatable, Hashable {
    public let sha256Hex: String

    public init(sha256Hex: String) throws {
        guard sha256Hex.count == 64 else {
            throw AccessContractError.malformedAssetDigest
        }
        guard sha256Hex.unicodeScalars.allSatisfy({ Self.lowercaseHex.contains($0) }) else {
            throw AccessContractError.malformedAssetDigest
        }
        self.sha256Hex = sha256Hex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        try self.init(sha256Hex: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(sha256Hex)
    }

    private static let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
}
