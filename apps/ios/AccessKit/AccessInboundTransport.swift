import Foundation

/// Browser-local inbound transports admitted for iOS Access.
///
/// Wire values are fixed: `http = 1`, `https = 2`, `socks5 = 3`.
/// This batch may construct only HTTP and HTTPS. SOCKS5 remains reserved and
/// fail-closed at construction and decode time.
public enum AccessInboundTransport: UInt8, Codable, Sendable, Equatable, Hashable {
    case http = 1
    case https = 2

    /// Reserved wire value. Not a constructible case in this batch.
    public static let reservedSocks5RawValue: UInt8 = 3

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(UInt8.self)
        switch raw {
        case Self.http.rawValue:
            self = .http
        case Self.https.rawValue:
            self = .https
        case Self.reservedSocks5RawValue:
            throw AccessContractError.socks5NotAdmitted
        default:
            throw AccessContractError.unknownInboundTransport(raw)
        }
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
        case AccessInboundTransport.reservedSocks5RawValue:
            throw AccessContractError.socks5NotAdmitted
        default:
            throw AccessContractError.unknownInboundTransport(rawValue)
        }
    }
}
