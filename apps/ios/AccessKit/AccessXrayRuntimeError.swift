import Foundation

/// Fail-closed errors for the embedded Xray runtime lifecycle (F8).
public enum AccessXrayRuntimeError: Error, Equatable, Sendable {
    case digestMismatch(expected: String, actual: String)
    case executableMissing
    case alreadyRunning
    case notRunning
    case launchFailed(String)
    case configEncodingFailed
    case profileNotAdmitted(String)
}
