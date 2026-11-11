import Foundation

/// Client egress profiles admitted for iOS Access.
///
/// This batch admits only `reality_vision` (VLESS + RAW + REALITY + Vision).
/// Compatible WS+TLS is reserved and rejected.
public enum AccessOutboundProfile: String, Codable, Sendable, Equatable, Hashable {
    case realityVision = "reality_vision"

    public static let reservedWsTlsCompat = "ws_tls_compat"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = try Self.parse(rawValue: raw)
    }

    public static func parse(rawValue: String) throws -> AccessOutboundProfile {
        switch rawValue {
        case AccessOutboundProfile.realityVision.rawValue:
            return .realityVision
        case AccessOutboundProfile.reservedWsTlsCompat:
            throw AccessContractError.wsTlsCompatNotAdmitted
        default:
            throw AccessContractError.unknownOutboundProfile(rawValue)
        }
    }
}
