import Foundation

/// Injectable PrepareCandidate → Publish → ACK → reality-path pipeline.
///
/// Production hosts wire F8 runtime, F9 ProxyConfiguration, and F11 dial
/// readiness. Unit tests supply doubles. Implementations must never report
/// success via a DIRECT origin dial.
public protocol AccessSiteSessionOrchestrating: AnyObject {
    /// Mints registration/lease + proxy fixture for the host.
    func prepareCandidate(for host: AccessSiteHost) throws -> AccessSiteSessionCandidate

    /// Publishes the candidate (inbound registration + proxy selection).
    func publish(_ candidate: AccessSiteSessionCandidate) throws -> AccessSiteSessionPublication

    /// Acknowledges the exact publication; stale tokens fail closed.
    func acknowledge(_ publication: AccessSiteSessionPublication) throws -> AccessSiteSessionAck

    /// Ensures runtime + ProxyConfiguration + reality dial seam for the ACK.
    ///
    /// Must throw `AccessSiteSessionError.directFallbackNotAdmitted` when asked
    /// to treat a direct dial as success.
    func activateRealityPath(
        ack: AccessSiteSessionAck,
        candidate: AccessSiteSessionCandidate
    ) throws

    /// Stops publishing for one registration and clears proxy configuration.
    func tearDown(registrationID: AccessRegistrationID) throws
}
