import Foundation
import os

/// Keeps ordinary and private Access state in independent buckets.
///
/// Responsibilities (F13 / A3-2):
/// - Independent registration, lease generation, proxy fixture, credentials,
///   and site-intent entries per browsing bucket
/// - Fail closed when a resource minted for one bucket is reused in the other
/// - Destroy all private Access state when the private browsing session ends
///
/// Extends F9's `applyToOrdinaryStore` / `applyToPrivateStore` boundary into a
/// real ownership controller. WebKit write paths still use the applicator; this
/// type decides which fixture / registration is legal for each store.
public final class AccessBrowsingIsolationController: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var ordinary = AccessBrowsingAccessState(bucket: .ordinary)
    private var privateState = AccessBrowsingAccessState(bucket: .privateBrowsing)

    /// Registration ids currently or previously bound to a bucket.
    /// Destroyed private ids stay mapped so they cannot migrate into ordinary.
    private var registrationOwners: [AccessRegistrationID: AccessBrowsingBucket] = [:]

    /// Credential slots currently or previously bound to a bucket.
    private var credentialOwners: [AccessCredentialSlot: AccessBrowsingBucket] = [:]

    public init() {}

    // MARK: - Session lifecycle

    /// Ensures the private Access lane is writable after a prior destroy.
    public func beginPrivateBrowsingSession() {
        lock.lock(); defer { lock.unlock() }
        if privateState.isDestroyed {
            try? privateState.beginFreshPrivateSession()
        }
    }

    /// Clears and destroys private Access registration / credentials / proxy /
    /// intents. Ordinary state is untouched.
    public func endPrivateBrowsingSession() {
        lock.lock(); defer { lock.unlock() }
        if !privateState.isDestroyed {
            try? privateState.destroy()
        }
    }

    public func isPrivateAccessDestroyed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return privateState.isDestroyed
    }

    // MARK: - Install

    public func install(registration: AccessRegistration, into bucket: AccessBrowsingBucket) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureBucketWritable(bucket)
        try rejectCrossBucketRegistrationReuse(registration.id, into: bucket)
        // Reject before any write. A failed install must not replace the slot's owner.
        try rejectCrossBucketCredentialReuse(registration.credentialSlot, into: bucket)

        let ownerBucket = try AccessBrowsingBucket.from(ownerProfile: registration.owner.profile)
        guard ownerBucket == bucket else {
            throw AccessBrowsingIsolationError.browsingBucketMismatch(
                expected: bucket,
                actual: ownerBucket
            )
        }

        try mutate(bucket) { state in
            try state.install(registration: registration)
        }
        registrationOwners[registration.id] = bucket
        credentialOwners[registration.credentialSlot] = bucket
    }

    public func bind(credentialSlot: AccessCredentialSlot, into bucket: AccessBrowsingBucket) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureBucketWritable(bucket)
        try rejectCrossBucketCredentialReuse(credentialSlot, into: bucket)

        try mutate(bucket) { state in
            try state.bind(credentialSlot: credentialSlot)
        }
        credentialOwners[credentialSlot] = bucket
    }

    public func install(
        proxyFixture: AccessProxyRegistrationFixture,
        into bucket: AccessBrowsingBucket
    ) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureBucketWritable(bucket)

        let fixtureBucket = AccessBrowsingBucket.from(dataStoreKind: proxyFixture.dataStoreKind)
        guard fixtureBucket == bucket else {
            throw AccessBrowsingIsolationError.browsingBucketMismatch(
                expected: bucket,
                actual: fixtureBucket
            )
        }

        try mutate(bucket) { state in
            try state.install(proxyFixture: proxyFixture)
        }
    }

    public func setIntent(
        _ intent: AccessSiteIntent,
        for host: AccessSiteHost,
        in bucket: AccessBrowsingBucket
    ) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureBucketWritable(bucket)
        try mutate(bucket) { state in
            try state.setIntent(intent, for: host)
        }
    }

    // MARK: - Query

    public func snapshot(for bucket: AccessBrowsingBucket) throws -> AccessBrowsingAccessState {
        lock.lock(); defer { lock.unlock() }
        let state = stateRef(bucket)
        if state.isDestroyed {
            throw AccessBrowsingIsolationError.privateAccessStateDestroyed
        }
        return state
    }

    public func registration(in bucket: AccessBrowsingBucket) throws -> AccessRegistration {
        let state = try snapshot(for: bucket)
        guard let registration = state.registration else {
            throw AccessBrowsingIsolationError.registrationNotInstalled(nil)
        }
        return registration
    }

    public func proxyFixture(in bucket: AccessBrowsingBucket) throws -> AccessProxyRegistrationFixture {
        let state = try snapshot(for: bucket)
        guard let fixture = state.proxyFixture else {
            throw AccessBrowsingIsolationError.proxyFixtureNotInstalled
        }
        return fixture
    }

    public func intent(for host: AccessSiteHost, in bucket: AccessBrowsingBucket) throws -> AccessSiteIntent {
        try snapshot(for: bucket).intent(for: host)
    }

    public func intentStore(in bucket: AccessBrowsingBucket) throws -> AccessSiteIntentStore {
        try snapshot(for: bucket).intentStore
    }

    // MARK: - Cross-bucket guards

    /// Rejects using a registration owned by another bucket (or a destroyed
    /// private registration that must not migrate).
    public func requireRegistration(
        _ id: AccessRegistrationID,
        belongsTo bucket: AccessBrowsingBucket
    ) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureBucketWritable(bucket)
        guard let owner = registrationOwners[id] else {
            throw AccessBrowsingIsolationError.registrationNotInstalled(id)
        }
        guard owner == bucket else {
            throw AccessBrowsingIsolationError.crossBucketReuseRejected(
                resource: "registration:\(id.rawValue)",
                owningBucket: owner,
                requestedBucket: bucket
            )
        }
        let state = stateRef(bucket)
        guard state.registration?.id == id else {
            // Owned historically by this bucket but no longer live (e.g. after
            // private destroy). Fail closed — do not revive across lanes.
            throw AccessBrowsingIsolationError.registrationNotInstalled(id)
        }
    }

    public func requireCredentialSlot(
        _ slot: AccessCredentialSlot,
        belongsTo bucket: AccessBrowsingBucket
    ) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureBucketWritable(bucket)
        guard let owner = credentialOwners[slot] else {
            throw AccessBrowsingIsolationError.credentialSlotNotInstalled(slot)
        }
        guard owner == bucket else {
            throw AccessBrowsingIsolationError.crossBucketReuseRejected(
                resource: "credential:\(slot.id)",
                owningBucket: owner,
                requestedBucket: bucket
            )
        }
        let state = stateRef(bucket)
        guard state.credentialSlots.contains(slot) else {
            throw AccessBrowsingIsolationError.credentialSlotNotInstalled(slot)
        }
    }

    public func requireProxyFixture(
        _ fixture: AccessProxyRegistrationFixture,
        belongsTo bucket: AccessBrowsingBucket
    ) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureBucketWritable(bucket)
        let fixtureBucket = AccessBrowsingBucket.from(dataStoreKind: fixture.dataStoreKind)
        guard fixtureBucket == bucket else {
            throw AccessBrowsingIsolationError.crossBucketReuseRejected(
                resource: "proxyFixture:\(fixture.registrationId)",
                owningBucket: fixtureBucket,
                requestedBucket: bucket
            )
        }
        let state = stateRef(bucket)
        guard state.proxyFixture == fixture else {
            throw AccessBrowsingIsolationError.proxyFixtureNotInstalled
        }
    }

    // MARK: - Private helpers

    private func ensureBucketWritable(_ bucket: AccessBrowsingBucket) throws {
        if bucket == .privateBrowsing, privateState.isDestroyed {
            throw AccessBrowsingIsolationError.privateAccessStateDestroyed
        }
    }

    private func rejectCrossBucketRegistrationReuse(
        _ id: AccessRegistrationID,
        into bucket: AccessBrowsingBucket
    ) throws {
        if let owner = registrationOwners[id], owner != bucket {
            throw AccessBrowsingIsolationError.crossBucketReuseRejected(
                resource: "registration:\(id.rawValue)",
                owningBucket: owner,
                requestedBucket: bucket
            )
        }
    }

    private func rejectCrossBucketCredentialReuse(
        _ slot: AccessCredentialSlot,
        into bucket: AccessBrowsingBucket
    ) throws {
        if let owner = credentialOwners[slot], owner != bucket {
            throw AccessBrowsingIsolationError.crossBucketReuseRejected(
                resource: "credential:\(slot.id)",
                owningBucket: owner,
                requestedBucket: bucket
            )
        }
    }

    private func stateRef(_ bucket: AccessBrowsingBucket) -> AccessBrowsingAccessState {
        switch bucket {
        case .ordinary:
            return ordinary
        case .privateBrowsing:
            return privateState
        }
    }

    private func mutate(
        _ bucket: AccessBrowsingBucket,
        _ body: (inout AccessBrowsingAccessState) throws -> Void
    ) throws {
        switch bucket {
        case .ordinary:
            try body(&ordinary)
        case .privateBrowsing:
            try body(&privateState)
        }
    }
}
