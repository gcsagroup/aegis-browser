import Foundation

/// Parsed SOCKS5 CONNECT target after a successful no-auth greeting.
public struct AccessSOCKS5ConnectRequest: Sendable, Equatable, Hashable {
    public enum Address: Sendable, Equatable, Hashable {
        case ipv4(String)
        case domain(String)
        case ipv6(String)
    }

    public let address: Address
    public let port: UInt16

    public init(address: Address, port: UInt16) throws {
        guard port > 0 else {
            throw AccessSOCKS5InboundError.malformedRequest
        }
        switch address {
        case .ipv4(let host), .domain(let host), .ipv6(let host):
            let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed == host, !trimmed.contains("\0") else {
                throw AccessSOCKS5InboundError.malformedRequest
            }
        }
        self.address = address
        self.port = port
    }

    public var host: String {
        switch address {
        case .ipv4(let host), .domain(let host), .ipv6(let host):
            return host
        }
    }
}
