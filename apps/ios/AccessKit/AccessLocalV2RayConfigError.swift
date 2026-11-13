import Foundation

/// Failures while importing a local V2Ray / Xray client config for Access tests.
public enum AccessLocalV2RayConfigError: Error, Equatable, Sendable {
    case pathNotSet
    case fileNotFound(String)
    case unreadableFile(String)
    case invalidJSON
    case noAdmittedRealityOutbound
    case unsupportedNetwork(String)
    case unsupportedSecurity(String)
    case unsupportedFlow(String)
    case allowInsecureRejected
    case emptyField(String)
    case fieldNotCanonical(String)
}
