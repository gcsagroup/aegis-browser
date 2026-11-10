import Foundation

/// Probes the admitted `reality_vision` path against a controlled node.
///
/// F10 scope:
/// - Require `reality_vision` profile + running Xray runtime
/// - Without an authorized target → `blockedResource` (never fake a pass)
/// - With a target → require an executor; success only when executor returns true
/// - Reject any attempt to treat direct connect as success
///
/// Out of scope: opening product traffic, inbound CONNECT wiring (F11).
public enum AccessRealityProbe {
    public static let missingAuthorizedNodeReason =
        "No authorized controlled REALITY node is configured for this environment"

    /// Runs a probe. Omit `target` when the environment has no authorized node.
    public static func run(
        profile: AccessOutboundProfile = .realityVision,
        runtime: AccessXrayRuntime,
        target: AccessRealityProbeTarget? = nil,
        executor: AccessRealityProbeExecuting? = nil,
        allowDirectConnectAsPass: Bool = false
    ) throws -> AccessRealityProbeResult {
        guard profile == .realityVision else {
            throw AccessRealityProbeError.profileNotAdmitted(profile.rawValue)
        }
        // Explicit poison pill: product code must never flip this on.
        if allowDirectConnectAsPass {
            throw AccessRealityProbeError.directConnectNotAdmitted
        }
        guard runtime.isRunning else {
            return .failed(.runtimeNotRunning)
        }
        guard let target else {
            return .blockedResource(reason: missingAuthorizedNodeReason)
        }
        guard let executor else {
            // Authorized target without a probe executor is still not a pass.
            return .blockedResource(reason: missingAuthorizedNodeReason)
        }
        let ok: Bool
        do {
            ok = try executor.probe(target: target)
        } catch let error as AccessRealityProbeError {
            return .failed(error)
        } catch {
            return .failed(.fieldNotCanonical("probe"))
        }
        if ok {
            return .passed(authorizationID: target.authorizationID)
        }
        return .failed(.fieldNotCanonical("probeResult"))
    }

    /// Convenience for the no-node path without constructing a runtime.
    public static func blockedResourceIfNoTarget(
        profile: AccessOutboundProfile = .realityVision,
        target: AccessRealityProbeTarget?
    ) throws -> AccessRealityProbeResult {
        guard profile == .realityVision else {
            throw AccessRealityProbeError.profileNotAdmitted(profile.rawValue)
        }
        guard target == nil else {
            throw AccessRealityProbeError.fieldNotCanonical("target")
        }
        return .blockedResource(reason: missingAuthorizedNodeReason)
    }
}
