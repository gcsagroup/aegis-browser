import Foundation

/// Loopback-only listen endpoint for an inbound registration.
///
/// Non-loopback hosts fail closed at construction. Port `0` is rejected for
/// published registrations; callers bind dynamically then republish the
/// kernel-assigned port.
public struct AccessEndpoint: Codable, Sendable, Equatable, Hashable {
    public let host: String
    public let port: UInt16

    public static let loopbackHost = "127.0.0.1"

    public init(host: String, port: UInt16) throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == host, !trimmed.isEmpty, !trimmed.contains("\0") else {
            throw AccessContractError.endpointNotCanonical
        }
        guard Self.isLoopbackHost(trimmed) else {
            throw AccessContractError.nonLoopbackEndpoint(trimmed)
        }
        guard port > 0 else {
            throw AccessContractError.invalidEndpointPort(port)
        }
        self.host = trimmed
        self.port = port
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            host: try container.decode(String.self, forKey: .host),
            port: try container.decode(UInt16.self, forKey: .port)
        )
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        host == loopbackHost || host == "::1" || host == "localhost"
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case port
    }
}
