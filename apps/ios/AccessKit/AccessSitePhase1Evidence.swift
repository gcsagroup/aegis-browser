import Foundation

/// Product Phase 1 five-step evidence stages (acceptance A2-1..A2-5).
/// Distinct from the engineering F14 matrix and from the P-iOS-5 fault drill:
/// the product exit path starts at enable and inserts an explicit "load via
/// PROXY" observation before fault/recovery/off.
public enum AccessSitePhase1EvidenceStep: String, CaseIterable, Sendable, Equatable {
    case on
    case load
    case fault
    case recovery
    case off

    public var acceptanceId: String {
        switch self {
        case .on: return "A2-1"
        case .load: return "A2-2"
        case .fault: return "A2-3"
        case .recovery: return "A2-4"
        case .off: return "A2-5"
        }
    }

    /// Fault and recovery require the P-iOS-5 fail-closed fixture API.
    public var requiresFaultFixtureAPI: Bool {
        self == .fault || self == .recovery
    }
}

/// Correlation ID convention (A4 / P0-4):
///   aegis-ios-p1/<candidate8>/<run_id>/<step>
/// Links AccessKit logs, node-side traces, and optional UI captures for one
/// candidate SHA. Never reuse a correlation ID across candidates or runs.
public enum AccessSitePhase1EvidenceCorrelation {
    public static let prefix = "aegis-ios-p1"

    public static func buildCorrelationId(
        candidateSha: String,
        runId: String,
        step: AccessSitePhase1EvidenceStep
    ) -> String {
        let candidate8 = normalizedCandidate8(candidateSha)
        return "\(prefix)/\(candidate8)/\(runId)/\(step.rawValue)"
    }

    public static func isValid(_ correlationId: String) -> Bool {
        let parts = correlationId.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == Substring(prefix),
              parts[1].count == 8,
              parts[1].unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }),
              isRunToken(String(parts[2])),
              AccessSitePhase1EvidenceStep(rawValue: String(parts[3])) != nil
        else {
            return false
        }
        return true
    }

    public static func normalizedCandidate8(_ candidateSha: String) -> String {
        let lowered = candidateSha.lowercased()
        if lowered.count >= 8 {
            return String(lowered.prefix(8))
        }
        return lowered.padding(toLength: 8, withPad: "0", startingAt: 0)
    }

    private static func isRunToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
