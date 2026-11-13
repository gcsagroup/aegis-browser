import Foundation
import os

/// Bounded set of exact hosts published together for one site intent (G).
///
/// Not a suffix / eTLD+1 expander. Members must already be normalized exact hosts.
/// iOS execution still maps each member to its own `AccessHostStoreKey`; this type
/// only carries the authorized set and generation for atomic publish/revoke.
public enum AccessSiteRuleGroupCapacity {
    /// Missing or unknown channels use the Release cap. Runtime preferences cannot raise it.
    public static func limit(for channel: AccessReleaseChannel) -> Int {
        switch channel {
        case .dev:
            return 128
        case .alpha:
            return 64
        case .beta:
            return 32
        case .release, .unknown:
            return 16
        }
    }
}

public struct AccessSiteRuleGroup: Sendable, Equatable, Hashable {
    /// Release / unknown cap. Construct with an explicit channel for DEV/Alpha/Beta.
    public static let maxMemberCount = AccessSiteRuleGroupCapacity.limit(for: .release)

    public let groupID: UUID
    public let scopeID: String
    public let isPrivate: Bool
    public let primaryHost: AccessSiteHost
    public let memberHosts: [AccessSiteHost]
    public let generation: UInt64

    public init(
        groupID: UUID = UUID(),
        scopeID: String,
        isPrivate: Bool,
        primaryHost: AccessSiteHost,
        memberHosts: [AccessSiteHost],
        generation: UInt64,
        channel: AccessReleaseChannel = .release
    ) throws {
        let trimmedScope = scopeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedScope.isEmpty, trimmedScope == scopeID else {
            throw AccessSiteRuleGroupError.invalidScopeID
        }
        guard generation > 0 else {
            throw AccessSiteRuleGroupError.invalidGeneration
        }

        let memberLimit = AccessSiteRuleGroupCapacity.limit(for: channel)
        var ordered: [AccessSiteHost] = []
        var seen = Set<AccessSiteHost>()
        func appendUnique(_ host: AccessSiteHost) throws {
            if seen.contains(host) { return }
            guard ordered.count < memberLimit else {
                throw AccessSiteRuleGroupError.tooManyMembers
            }
            seen.insert(host)
            ordered.append(host)
        }

        try appendUnique(primaryHost)
        for host in memberHosts {
            try appendUnique(host)
        }

        self.groupID = groupID
        self.scopeID = scopeID
        self.isPrivate = isPrivate
        self.primaryHost = primaryHost
        self.memberHosts = ordered
        self.generation = generation
        self.channel = channel
    }

    public let channel: AccessReleaseChannel

    /// A group saved under a wider channel is not auto-executable after a downgrade.
    public func isExecutable(on channel: AccessReleaseChannel) -> Bool {
        memberHosts.count <= AccessSiteRuleGroupCapacity.limit(for: channel)
    }

    /// True when `host` is in the published exact-host set.
    public func contains(_ host: AccessSiteHost) -> Bool {
        memberHosts.contains(host)
    }

    /// Store keys for every member under this group's scope/privacy.
    public func hostStoreKeys() -> [AccessHostStoreKey] {
        memberHosts.map { AccessHostStoreKey(scopeID: scopeID, host: $0, isPrivate: isPrivate) }
    }
}

public enum AccessSiteRuleGroupError: Error, Equatable, Sendable {
    case invalidScopeID
    case invalidGeneration
    case tooManyMembers
}

public enum AccessSiteRulePublishOutcome: Equatable, Sendable {
    case published(replaced: AccessSiteRuleGroup?)
    case rejectedStale(current: AccessSiteRuleGroup?)
}

/// Manual DEV/Alpha suggestion. Normal navigation does not run this.
/// Already-proxied hosts are skipped. At most three hosts, one 15-second budget.
public struct AccessSiteProbePlan: Sendable, Equatable {
    public static let maxHosts = 3
    public static let budget: Duration = .seconds(15)

    public var hosts: [AccessSiteHost]

    public init(hosts: [AccessSiteHost]) {
        self.hosts = hosts
    }

    public static func make(
        candidates: [AccessSiteHost],
        alreadyRequiringProxy: Set<AccessSiteHost>,
        channel: AccessReleaseChannel
    ) -> AccessSiteProbePlan? {
        guard channel == .dev || channel == .alpha else { return nil }
        var chosen: [AccessSiteHost] = []
        var seen = Set<AccessSiteHost>()
        for host in candidates {
            if alreadyRequiringProxy.contains(host) || seen.contains(host) { continue }
            if chosen.count == AccessSiteProbePlan.maxHosts { break }
            seen.insert(host)
            chosen.append(host)
        }
        guard !chosen.isEmpty else { return nil }
        return AccessSiteProbePlan(hosts: chosen)
    }
}

/// In-memory registry: at most one active group per (scopeID, isPrivate, primaryHost).
public final class AccessSiteRuleGroupRegistry: @unchecked Sendable {
    private var groups: [AccessSiteRuleGroup] = []
    private let lock = OSAllocatedUnfairLock()

    public init() {}

    public func activeGroups() -> [AccessSiteRuleGroup] {
        lock.withLock { groups }
    }

    public func group(containing host: AccessSiteHost, scopeID: String, isPrivate: Bool) -> AccessSiteRuleGroup? {
        lock.withLock {
            groups.first {
                $0.scopeID == scopeID && $0.isPrivate == isPrivate && $0.contains(host)
            }
        }
    }

    /// Replaces any prior group with the same scope/privacy/primary. Returns the prior group if any.
    @discardableResult
    public func publish(_ group: AccessSiteRuleGroup) -> AccessSiteRuleGroup? {
        lock.withLock {
            let priorIndex = groups.firstIndex {
                $0.scopeID == group.scopeID
                    && $0.isPrivate == group.isPrivate
                    && $0.primaryHost == group.primaryHost
            }
            let prior = priorIndex.map { groups[$0] }
            if let priorIndex {
                groups[priorIndex] = group
            } else {
                groups.append(group)
            }
            return prior
        }
    }

    public func groups(containing host: AccessSiteHost, scopeID: String, isPrivate: Bool) -> [AccessSiteRuleGroup] {
        lock.withLock {
            groups.filter {
                $0.scopeID == scopeID && $0.isPrivate == isPrivate && $0.contains(host)
            }
        }
    }

    public func group(groupID: UUID) -> AccessSiteRuleGroup? {
        lock.withLock { groups.first { $0.groupID == groupID } }
    }

    public func group(primaryHost: AccessSiteHost, scopeID: String, isPrivate: Bool) -> AccessSiteRuleGroup? {
        lock.withLock {
            groups.first {
                $0.scopeID == scopeID && $0.isPrivate == isPrivate && $0.primaryHost == primaryHost
            }
        }
    }

    /// Replaces the primary's group only when its generation is still `expectedPriorGeneration`.
    /// Zero means there must be no prior group. A mismatch keeps the current group.
    public func publish(
        _ group: AccessSiteRuleGroup,
        expectedPriorGeneration: UInt64
    ) -> AccessSiteRulePublishOutcome {
        lock.withLock {
            let priorIndex = groups.firstIndex {
                $0.scopeID == group.scopeID
                    && $0.isPrivate == group.isPrivate
                    && $0.primaryHost == group.primaryHost
            }
            let prior = priorIndex.map { groups[$0] }
            let actual = prior?.generation ?? 0
            guard actual == expectedPriorGeneration else {
                return .rejectedStale(current: prior)
            }
            if let priorIndex {
                groups[priorIndex] = group
            } else {
                groups.append(group)
            }
            return .published(replaced: prior)
        }
    }

    @discardableResult
    public func remove(groupID: UUID) -> AccessSiteRuleGroup? {
        lock.withLock {
            guard let index = groups.firstIndex(where: { $0.groupID == groupID }) else { return nil }
            return groups.remove(at: index)
        }
    }

    /// Revokes the group for this primary (exact match on scope/privacy/primary).
    @discardableResult
    public func revoke(primaryHost: AccessSiteHost, scopeID: String, isPrivate: Bool) -> AccessSiteRuleGroup? {
        lock.withLock {
            guard let index = groups.firstIndex(where: {
                $0.scopeID == scopeID && $0.isPrivate == isPrivate && $0.primaryHost == primaryHost
            }) else {
                return nil
            }
            return groups.remove(at: index)
        }
    }

    /// Ends every group in a private session scope.
    public func revokeAll(scopeID: String, isPrivate: Bool) -> [AccessSiteRuleGroup] {
        lock.withLock {
            let removed = groups.filter { $0.scopeID == scopeID && $0.isPrivate == isPrivate }
            groups.removeAll { $0.scopeID == scopeID && $0.isPrivate == isPrivate }
            return removed
        }
    }
}
