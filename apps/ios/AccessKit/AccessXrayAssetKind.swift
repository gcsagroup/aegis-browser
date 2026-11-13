import Foundation

/// Xray asset kinds admitted for the iOS Access REALITY path.
public enum AccessXrayAssetKind: String, Codable, Sendable, Equatable, Hashable {
    case coreBinary = "core_binary"

    public static func parse(rawValue: String) throws -> AccessXrayAssetKind {
        switch rawValue {
        case AccessXrayAssetKind.coreBinary.rawValue:
            return .coreBinary
        default:
            throw AccessContractError.unknownXrayAssetKind(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = try Self.parse(rawValue: raw)
    }
}
