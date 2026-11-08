import Foundation

/// Live Access registration / lease / proxy / credential / intent state for one
/// browsing bucket.
///
/// Private buckets may be destroyed when the private session ends. Destroyed
/// state rejects every read and install until a fresh private session begins.
public struct AccessBrowsingAccessState: Sendable, Equatable {
    public let bucket: AccessBrowsingBucket
    public private(set) var isDestroyed: Bool
    public private(set) var registration: AccessRegistration?
    public private(set) var credentialSlots: Set<AccessCredentialSlot>
    public private(set) var proxyFixture: AccessProxyRegistrationFixture?
    public private(set) var intentStore: AccessSiteIntentStore

    public init(bucket: AccessBrowsingBucket) {
        self.bucket = bucket
        self.isDestroyed = false
        self.registration = nil
        self.credentialSlots = []
        self.proxyFixture = nil
        self.intentStore = AccessSiteIntentStore()
    }

    public var hasLiveEntry: Bool {
        !isDestroyed && registration != nil
    }

    public mutating func install(registration: AccessRegistration) throws {
        try ensureWritable()
        let ownerBucket = try AccessBrowsingBucket.from(ownerProfile: registration.owner.profile)
        guard ownerBucket == bucket else {
            throw AccessBrowsingIsolationError.browsingBucketMismatch(
                expected: bucket,
                actual: ownerBucket
            )
        }
        self.registration = registration
        credentialSlots.insert(registration.credentialSlot)
    }

    public mutating func bind(credentialSlot: AccessCredentialSlot) throws {
        try ensureWritable()
        credentialSlots.insert(credentialSlot)
    }

    public mutating func install(proxyFixture: AccessProxyRegistrationFixture) throws {
        try ensureWritable()
        let fixtureBucket = AccessBrowsingBucket.from(dataStoreKind: proxyFixture.dataStoreKind)
        guard fixtureBucket == bucket else {
            throw AccessBrowsingIsolationError.browsingBucketMismatch(
                expected: bucket,
                actual: fixtureBucket
            )
        }
        self.proxyFixture = proxyFixture
    }

    public mutating func setIntent(_ intent: AccessSiteIntent, for host: AccessSiteHost) throws {
        try ensureWritable()
        intentStore.setIntent(intent, for: host)
    }

    public func intent(for host: AccessSiteHost) throws -> AccessSiteIntent {
        try ensureReadable()
        return intentStore.intent(for: host)
    }

    public mutating func clearProxyFixture() throws {
        try ensureWritable()
        proxyFixture = nil
    }

    /// Wipes registration, credentials, proxy config, and intents.
    ///
    /// Only private browsing state may be destroyed. Ordinary state stays for
    /// the app lifetime and is cleared through explicit product off paths.
    public mutating func destroy() throws {
        guard bucket == .privateBrowsing else {
            throw AccessBrowsingIsolationError.browsingBucketMismatch(
                expected: .privateBrowsing,
                actual: bucket
            )
        }
        registration = nil
        credentialSlots = []
        proxyFixture = nil
        intentStore = AccessSiteIntentStore()
        isDestroyed = true
    }

    /// Starts a fresh private Access lane after a prior destroy.
    public mutating func beginFreshPrivateSession() throws {
        guard bucket == .privateBrowsing else {
            throw AccessBrowsingIsolationError.browsingBucketMismatch(
                expected: .privateBrowsing,
                actual: bucket
            )
        }
        registration = nil
        credentialSlots = []
        proxyFixture = nil
        intentStore = AccessSiteIntentStore()
        isDestroyed = false
    }

    private func ensureWritable() throws {
        if isDestroyed {
            throw AccessBrowsingIsolationError.privateAccessStateDestroyed
        }
    }

    private func ensureReadable() throws {
        if isDestroyed {
            throw AccessBrowsingIsolationError.privateAccessStateDestroyed
        }
    }
}
