import Foundation

/// Fail-closed errors for the F11 HTTP inbound → reality path bridge.
public enum AccessHTTPRealityPathError: Error, Equatable, Sendable {
    case transportNotHTTP(AccessInboundTransport)
    case leaseInactive
    case runtimeNotRunning
    case profileNotAdmitted(String)
    case directDialNotAdmitted
    case dialFailed(String)
    case emptyTargetHost
}
