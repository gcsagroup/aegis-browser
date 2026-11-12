import Foundation

/// Performs the environment-specific controlled-node probe I/O.
///
/// Unit tests inject a double. Production hosts that lack an authorized node
/// never call this protocol — they take the `blockedResource` path instead.
public protocol AccessRealityProbeExecuting: AnyObject {
    /// Returns `true` only when the REALITY path through `target` succeeds.
    func probe(target: AccessRealityProbeTarget) throws -> Bool
}
