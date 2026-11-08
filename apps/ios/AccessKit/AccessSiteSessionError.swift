import Foundation

/// Fail-closed errors for per-host Access session orchestration (P-iOS-2).
///
/// Callers must surface `readableMessage` — never treat these as a silent
/// DIRECT success for allow/block paths.
public enum AccessSiteSessionError: Error, Equatable, Sendable {
    case nodeUnavailable
    case runtimeNotReady
    case prepareFailed(String)
    case publishFailed(String)
    case ackFailed(String)
    case dialSeamNotReady(String)
    case directFallbackNotAdmitted
    case proxyApplyFailed(String)
    case tearDownFailed(String)
    case sessionNotActive

    /// Human-readable failure text for UI / logs.
    public var readableMessage: String {
        switch self {
        case .nodeUnavailable:
            return "No Access node is available; cannot open the reality path."
        case .runtimeNotReady:
            return "Access runtime is not running; reality path is unavailable."
        case .prepareFailed(let detail):
            return "Failed to prepare Access candidate: \(detail)"
        case .publishFailed(let detail):
            return "Failed to publish Access session: \(detail)"
        case .ackFailed(let detail):
            return "Access session acknowledgement failed: \(detail)"
        case .dialSeamNotReady(let detail):
            return "Reality dial seam is not ready: \(detail)"
        case .directFallbackNotAdmitted:
            return "Direct fallback is not admitted on the allow/block path."
        case .proxyApplyFailed(let detail):
            return "Failed to apply Access proxy configuration: \(detail)"
        case .tearDownFailed(let detail):
            return "Failed to tear down Access session: \(detail)"
        case .sessionNotActive:
            return "No active Access session for this host."
        }
    }
}
