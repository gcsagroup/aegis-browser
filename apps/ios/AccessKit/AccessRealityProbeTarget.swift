import Foundation

/// Authorized controlled-node target for a REALITY path probe.
///
/// When no authorized node is available, callers must not invent a host — use
/// `AccessRealityProbe.run` without a target so the result is `blockedResource`.
public struct AccessRealityProbeTarget: Sendable, Equatable, Hashable {
    public let host: String
    public let port: UInt16
    public let authorizationID: String

    public init(host: String, port: UInt16, authorizationID: String) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw AccessRealityProbeError.emptyField("host")
        }
        guard trimmedHost == host, !trimmedHost.contains("\0") else {
            throw AccessRealityProbeError.fieldNotCanonical("host")
        }
        guard port > 0 else {
            throw AccessRealityProbeError.emptyField("port")
        }
        let trimmedAuth = authorizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAuth.isEmpty else {
            throw AccessRealityProbeError.emptyField("authorizationID")
        }
        guard trimmedAuth == authorizationID, !trimmedAuth.contains("\0") else {
            throw AccessRealityProbeError.fieldNotCanonical("authorizationID")
        }
        self.host = trimmedHost
        self.port = port
        self.authorizationID = trimmedAuth
    }
}
