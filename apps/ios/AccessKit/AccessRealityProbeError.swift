import Foundation

/// Fail-closed errors for `reality_vision` path probes (F10).
public enum AccessRealityProbeError: Error, Equatable, Sendable {
    case profileNotAdmitted(String)
    case emptyField(String)
    case fieldNotCanonical(String)
    case directConnectNotAdmitted
    case runtimeNotRunning
}
