import Foundation

/// Fail-closed errors for the loopback HTTP inbound listener (F3).
///
/// CONNECT handling, HTTPS TLS front, and credential secret checks belong to
/// later feats. This type only covers listener lifecycle and admission gates.
public enum AccessHTTPInboundError: Error, Equatable, Sendable {
    case transportNotHTTP(AccessInboundTransport)
    case leaseInactive
    case alreadyListening
    case notListening
    case bindFailed(String)
}
