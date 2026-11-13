import Foundation

/// Validated inputs for a `reality_vision` (VLESS + RAW + REALITY + Vision) outbound.
///
/// Secrets may be present in memory here for config generation; callers must not
/// log `userID` / `publicKey`. This type does not start Xray (F8).
public struct AccessRealityVisionParameters: Sendable, Equatable {
    public let address: String
    public let port: UInt16
    public let userID: String
    public let serverName: String
    public let publicKey: String
    public let shortID: String
    public let fingerprint: String

    public static let admittedFlow = "xtls-rprx-vision"
    public static let admittedNetwork = "tcp"
    public static let admittedSecurity = "reality"
    public static let admittedEncryption = "none"
    public static let defaultFingerprint = "chrome"

    public init(
        address: String,
        port: UInt16,
        userID: String,
        serverName: String,
        publicKey: String,
        shortID: String,
        fingerprint: String = AccessRealityVisionParameters.defaultFingerprint
    ) throws {
        self.address = try Self.canonicalNonEmpty(address, field: "address")
        guard port > 0 else {
            throw AccessRealityVisionOutboundConfigError.invalidPort(port)
        }
        self.port = port
        self.userID = try Self.canonicalUserID(userID)
        self.serverName = try Self.canonicalNonEmpty(serverName, field: "serverName")
        self.publicKey = try Self.canonicalNonEmpty(publicKey, field: "publicKey")
        self.shortID = try Self.canonicalShortID(shortID)
        self.fingerprint = try Self.canonicalNonEmpty(fingerprint, field: "fingerprint")
    }

    private static func canonicalNonEmpty(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AccessRealityVisionOutboundConfigError.emptyField(field)
        }
        guard trimmed == value, !trimmed.contains("\0") else {
            throw AccessRealityVisionOutboundConfigError.fieldNotCanonical(field)
        }
        return trimmed
    }

    private static func canonicalUserID(_ value: String) throws -> String {
        let trimmed = try canonicalNonEmpty(value, field: "userID")
        guard UUID(uuidString: trimmed) != nil else {
            throw AccessRealityVisionOutboundConfigError.invalidUserID
        }
        // Prefer lowercase canonical UUID text.
        return trimmed.lowercased()
    }

    private static func canonicalShortID(_ value: String) throws -> String {
        let trimmed = try canonicalNonEmpty(value, field: "shortID")
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw AccessRealityVisionOutboundConfigError.fieldNotCanonical("shortID")
        }
        guard trimmed.count <= 16 else {
            throw AccessRealityVisionOutboundConfigError.fieldNotCanonical("shortID")
        }
        return trimmed.lowercased()
    }
}
