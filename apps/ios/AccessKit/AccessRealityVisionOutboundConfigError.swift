import Foundation

/// Fail-closed errors while building a `reality_vision` Xray outbound config.
public enum AccessRealityVisionOutboundConfigError: Error, Equatable, Sendable {
    case emptyField(String)
    case fieldNotCanonical(String)
    case invalidPort(UInt16)
    case invalidUserID
    case unsupportedFlow(String)
    case unsupportedNetwork(String)
    case unsupportedSecurity(String)
    case allowInsecureRejected
    case profileNotAdmitted(String)
}
