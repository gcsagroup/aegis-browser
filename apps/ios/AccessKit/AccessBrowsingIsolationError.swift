import Foundation

/// Fail-closed errors for ordinary / private Access isolation (F13).
public enum AccessBrowsingIsolationError: Error, Equatable, Sendable {
    case unknownOwnerProfile(String)
    case privateAccessStateDestroyed
    case browsingBucketMismatch(
        expected: AccessBrowsingBucket,
        actual: AccessBrowsingBucket
    )
    case registrationNotInstalled(AccessRegistrationID?)
    case credentialSlotNotInstalled(AccessCredentialSlot)
    case proxyFixtureNotInstalled
    case crossBucketReuseRejected(
        resource: String,
        owningBucket: AccessBrowsingBucket,
        requestedBucket: AccessBrowsingBucket
    )
}
