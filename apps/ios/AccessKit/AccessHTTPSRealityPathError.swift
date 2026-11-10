import Foundation

/// Fail-closed errors for the F12 HTTPS inbound → reality path bridge.
///
/// Certificate / TLS-identity failures never fall through to a DIRECT dial.
public enum AccessHTTPSRealityPathError: Error, Equatable, Sendable {
    case transportNotHTTPS(AccessInboundTransport)
    case leaseInactive
    case runtimeNotRunning
    case profileNotAdmitted(String)
    case directDialNotAdmitted
    case tlsIdentityUnavailable(String)
    case dialFailed(String)
    case emptyTargetHost
}
