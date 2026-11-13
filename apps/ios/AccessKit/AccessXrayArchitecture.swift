import Foundation

/// Architectures with pinned Xray assets for iOS Access.
public enum AccessXrayArchitecture: String, Codable, Sendable, Equatable, Hashable {
    case iosArm64 = "ios-arm64"

    public static func parse(rawValue: String) throws -> AccessXrayArchitecture {
        switch rawValue {
        case AccessXrayArchitecture.iosArm64.rawValue:
            return .iosArm64
        default:
            throw AccessContractError.unknownXrayArchitecture(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = try Self.parse(rawValue: raw)
    }
}
