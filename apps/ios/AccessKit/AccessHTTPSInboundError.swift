import Foundation

/// Fail-closed errors for the loopback HTTPS inbound TLS front (F5).
///
/// This is a local TLS shell in front of CONNECT — not a site MITM.
public enum AccessHTTPSInboundError: Error, Equatable, Sendable {
    case transportNotHTTPS(AccessInboundTransport)
    case leaseInactive
    case emptyIdentityLabel
    case identityLabelNotCanonical
    case tlsIdentityUnavailable(String)
    case alreadyListening
    case notListening
    case bindFailed(String)
}
