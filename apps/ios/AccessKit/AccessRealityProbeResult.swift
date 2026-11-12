import Foundation

/// Outcome of a `reality_vision` path probe.
///
/// `passed` is reserved for an authorized controlled node. Direct origin
/// connect must never be treated as a REALITY pass.
public enum AccessRealityProbeResult: Sendable, Equatable {
    /// No authorized controlled node is configured for this environment.
    case blockedResource(reason: String)
    /// Probe ran against an authorized node and the REALITY path failed.
    case failed(AccessRealityProbeError)
    /// Probe ran against an authorized node and the REALITY path succeeded.
    case passed(authorizationID: String)
}
