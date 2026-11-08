import Foundation

/// Browser-local inbound transports admitted for iOS Access.
///
/// Wire values are fixed: `http = 1`, `https = 2`, `socks5 = 3`.
/// SOCKS5 inbound in this batch is no-authentication only; username/password
/// negotiation remains fail-closed in the SOCKS5 listener.
public enum AccessInboundTransport: UInt8, Codable, Sendable, Equatable, Hashable {
    case http = 1
    case https = 2
    case socks5 = 3

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(UInt8.self)
        self = try Self.parse(rawValue: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Fail-closed parser for non-Decodable call sites.
    public static func parse(rawValue: UInt8) throws -> AccessInboundTransport {
        switch rawValue {
        case AccessInboundTransport.http.rawValue:
            return .http
        case AccessInboundTransport.https.rawValue:
            return .https
        case AccessInboundTransport.socks5.rawValue:
            return .socks5
        default:
            throw AccessContractError.unknownInboundTransport(rawValue)
        }
    }
}
