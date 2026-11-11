import Foundation

/// Bridges an admitted HTTPS inbound CONNECT onto the running `reality_vision` path.
///
/// F12 confluence: F5 HTTPS TLS front + F4 CONNECT + F8 runtime (shared outbound
/// dial seam with F11). Uses the same `AccessRealityPathDialing` outbound as HTTP.
/// Certificate / TLS-identity failure is fail-closed with no DIRECT bypass.
public enum AccessHTTPSRealityPath {
    public struct Handle: Sendable {
        public let registrationID: AccessRegistrationID
        public let identityLabel: String
        public let targetHost: String
        public let targetPort: UInt16
        public let streamOpen: Bool

        public init(
            registrationID: AccessRegistrationID,
            identityLabel: String,
            targetHost: String,
            targetPort: UInt16,
            streamOpen: Bool
        ) {
            self.registrationID = registrationID
            self.identityLabel = identityLabel
            self.targetHost = targetHost
            self.targetPort = targetPort
            self.streamOpen = streamOpen
        }
    }

    /// Opens a reality path for one CONNECT target behind an HTTPS inbound front.
    public static func open(
        connect: AccessHTTPConnectRequest,
        registration: AccessRegistration,
        identityLabel: String,
        tlsProvider: AccessHTTPSInboundTLSProviding,
        runtime: AccessXrayRuntime,
        dialer: AccessRealityPathDialing,
        at now: Date = Date(),
        allowDirectDial: Bool = false
    ) throws -> (Handle, AccessRealityPathStream) {
        guard registration.transport == .https else {
            throw AccessHTTPSRealityPathError.transportNotHTTPS(registration.transport)
        }

        let plan: AccessHTTPSInboundFrontPlan
        do {
            plan = try AccessHTTPSInboundFrontBuilder.plan(
                registration: registration,
                identityLabel: identityLabel
            )
        } catch let error as AccessHTTPSInboundError {
            throw mapFrontError(error)
        } catch {
            throw AccessHTTPSRealityPathError.tlsIdentityUnavailable(String(describing: error))
        }

        guard plan.registration.isActive(at: now, observedGeneration: plan.registration.generation) else {
            throw AccessHTTPSRealityPathError.leaseInactive
        }
        guard runtime.isRunning else {
            throw AccessHTTPSRealityPathError.runtimeNotRunning
        }
        guard runtime.outboundProfile == .realityVision else {
            throw AccessHTTPSRealityPathError.profileNotAdmitted(runtime.outboundProfile.rawValue)
        }
        if allowDirectDial {
            throw AccessHTTPSRealityPathError.directDialNotAdmitted
        }

        // Certificate / local TLS identity must be available before any dial.
        // Failure has no bypass — never open a DIRECT origin path as success.
        do {
            _ = try tlsProvider.makeServerTLSOptions(identityLabel: plan.identityLabel)
        } catch let error as AccessHTTPSInboundError {
            throw mapFrontError(error)
        } catch let error as AccessHTTPSRealityPathError {
            throw error
        } catch {
            throw AccessHTTPSRealityPathError.tlsIdentityUnavailable(String(describing: error))
        }

        let host = connect.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw AccessHTTPSRealityPathError.emptyTargetHost
        }

        let stream: AccessRealityPathStream
        do {
            stream = try dialer.dial(host: host, port: connect.port)
        } catch {
            throw AccessHTTPSRealityPathError.dialFailed(String(describing: error))
        }

        let handle = Handle(
            registrationID: plan.registration.id,
            identityLabel: plan.identityLabel,
            targetHost: host,
            targetPort: connect.port,
            streamOpen: stream.isOpen
        )
        return (handle, stream)
    }

    private static func mapFrontError(_ error: AccessHTTPSInboundError) -> AccessHTTPSRealityPathError {
        switch error {
        case .transportNotHTTPS(let transport):
            return .transportNotHTTPS(transport)
        case .tlsIdentityUnavailable(let detail):
            return .tlsIdentityUnavailable(detail)
        case .emptyIdentityLabel:
            return .tlsIdentityUnavailable("empty identity label")
        case .identityLabelNotCanonical:
            return .tlsIdentityUnavailable("identity label not canonical")
        case .leaseInactive:
            return .leaseInactive
        case .alreadyListening, .notListening, .bindFailed:
            return .tlsIdentityUnavailable(String(describing: error))
        }
    }
}
