import Foundation

/// Bridges an admitted HTTP CONNECT request onto the running `reality_vision` path.
///
/// F11 confluence: F4 CONNECT + F8 runtime (+ F9 ProxyConfiguration at the
/// WebKit edge, F10 probe for environment readiness). This type does not start
/// listeners or Xray itself — callers supply those.
public enum AccessHTTPRealityPath {
    public struct Handle: Sendable {
        public let registrationID: AccessRegistrationID
        public let targetHost: String
        public let targetPort: UInt16
        public let streamOpen: Bool

        public init(
            registrationID: AccessRegistrationID,
            targetHost: String,
            targetPort: UInt16,
            streamOpen: Bool
        ) {
            self.registrationID = registrationID
            self.targetHost = targetHost
            self.targetPort = targetPort
            self.streamOpen = streamOpen
        }
    }

    /// Opens a reality path for one CONNECT target.
    public static func open(
        connect: AccessHTTPConnectRequest,
        registration: AccessRegistration,
        runtime: AccessXrayRuntime,
        dialer: AccessRealityPathDialing,
        at now: Date = Date(),
        allowDirectDial: Bool = false
    ) throws -> (Handle, AccessRealityPathStream) {
        guard registration.transport == .http else {
            throw AccessHTTPRealityPathError.transportNotHTTP(registration.transport)
        }
        guard registration.isActive(at: now, observedGeneration: registration.generation) else {
            throw AccessHTTPRealityPathError.leaseInactive
        }
        guard runtime.isRunning else {
            throw AccessHTTPRealityPathError.runtimeNotRunning
        }
        guard runtime.outboundProfile == .realityVision else {
            throw AccessHTTPRealityPathError.profileNotAdmitted(runtime.outboundProfile.rawValue)
        }
        if allowDirectDial {
            throw AccessHTTPRealityPathError.directDialNotAdmitted
        }
        let host = connect.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw AccessHTTPRealityPathError.emptyTargetHost
        }

        let stream: AccessRealityPathStream
        do {
            stream = try dialer.dial(host: host, port: connect.port)
        } catch {
            throw AccessHTTPRealityPathError.dialFailed(String(describing: error))
        }

        let handle = Handle(
            registrationID: registration.id,
            targetHost: host,
            targetPort: connect.port,
            streamOpen: stream.isOpen
        )
        return (handle, stream)
    }
}
