import Foundation

/// Parsed `CONNECT host:port HTTP/1.x` request line.
///
/// F4 admits CONNECT only. Absolute-form GETs and other methods fail closed.
/// Upstream dialing through REALITY is F11 — this type is request admission only.
public struct AccessHTTPConnectRequest: Sendable, Equatable, Hashable {
    public let host: String
    public let port: UInt16
    public let httpVersion: String

    public init(host: String, port: UInt16, httpVersion: String) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, trimmedHost == host, !trimmedHost.contains("\0") else {
            throw AccessHTTPConnectError.malformedTarget(host)
        }
        guard port > 0 else {
            throw AccessHTTPConnectError.invalidTargetPort(port)
        }
        let trimmedVersion = httpVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedVersion.hasPrefix("HTTP/1.") else {
            throw AccessHTTPConnectError.malformedRequestLine
        }
        self.host = trimmedHost
        self.port = port
        self.httpVersion = trimmedVersion
    }

    public var authority: String { "\(host):\(port)" }
}
