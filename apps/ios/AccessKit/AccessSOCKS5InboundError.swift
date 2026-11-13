import Foundation

/// Fail-closed errors for the loopback SOCKS5 inbound listener (no-auth).
public enum AccessSOCKS5InboundError: Error, Equatable, Sendable {
    case transportNotSOCKS5(AccessInboundTransport)
    case leaseInactive
    case alreadyListening
    case notListening
    case bindFailed(String)
    case incompleteGreeting
    case malformedGreeting
    case noAcceptableAuthMethod
    case usernamePasswordNotAdmitted
    case incompleteRequest
    case malformedRequest
    case unsupportedCommand(UInt8)
    case unsupportedAddressType(UInt8)
    case responseWriteFailed
}
