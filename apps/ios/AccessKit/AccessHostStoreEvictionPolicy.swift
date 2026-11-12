import Foundation

/// Scope + exact host. Ordinary windows share one scope. One private session
/// has its own scope id.
public struct AccessHostStoreKey: Hashable, Sendable, Equatable {
    public let scopeID: String
    public let host: AccessSiteHost
    public let isPrivate: Bool

    public init(scopeID: String, host: AccessSiteHost, isPrivate: Bool) {
        self.scopeID = scopeID
        self.host = host
        self.isPrivate = isPrivate
    }
}

public struct AccessHostStoreRecord: Sendable, Equatable {
    public var key: AccessHostStoreKey
    public var boundTabIDs: Set<String>
    public var proxyEnabled: Bool
    public var idleSince: Date?

    public init(
        key: AccessHostStoreKey,
        boundTabIDs: Set<String>,
        proxyEnabled: Bool,
        idleSince: Date?
    ) {
        self.key = key
        self.boundTabIDs = boundTabIDs
        self.proxyEnabled = proxyEnabled
        self.idleSince = idleSince
    }

    public var isInUse: Bool { !boundTabIDs.isEmpty }
}

public enum AccessHostStoreEvictionKind: String, Sendable, Equatable {
    /// Close proxy or end the private session. Unbind tabs before dropping the store.
    case forced
    /// Idle TTL or the per-scope cap. In-use stores are never included.
    case idle
}

public struct AccessHostStoreEviction: Sendable, Equatable {
    public let key: AccessHostStoreKey
    public let kind: AccessHostStoreEvictionKind

    public init(key: AccessHostStoreKey, kind: AccessHostStoreEvictionKind) {
        self.key = key
        self.kind = kind
    }
}

public enum AccessHostStoreEvictionPolicy {
    public static let idleLimit: TimeInterval = 30 * 60
    public static let idleCap = 8

    /// Forced revocation is listed before idle reclamation.
    /// In-use stores are omitted from idle results. They do not consume `idleCap`.
    public static func evictions(
        records: [AccessHostStoreRecord],
        now: Date,
        endingPrivateScopeID: String? = nil
    ) -> [AccessHostStoreEviction] {
        var forced: [AccessHostStoreEviction] = []
        var idlePool: [AccessHostStoreRecord] = []
        for record in records {
            let sessionEnded = record.key.isPrivate && record.key.scopeID == endingPrivateScopeID
            if !record.proxyEnabled || sessionEnded {
                forced.append(AccessHostStoreEviction(key: record.key, kind: .forced))
                continue
            }
            if !record.isInUse {
                idlePool.append(record)
            }
        }

        var idleKeys = Set<AccessHostStoreKey>()
        for record in idlePool {
            if let idleSince = record.idleSince, now.timeIntervalSince(idleSince) >= idleLimit {
                idleKeys.insert(record.key)
            }
        }
        let surviving = idlePool
            .filter { !idleKeys.contains($0.key) }
            .sorted { lhs, rhs in
                let left = lhs.idleSince ?? .distantFuture
                let right = rhs.idleSince ?? .distantFuture
                if left != right { return left < right }
                return lhs.key.host.rawValue < rhs.key.host.rawValue
            }
        if surviving.count > idleCap {
            for record in surviving.prefix(surviving.count - idleCap) {
                idleKeys.insert(record.key)
            }
        }
        let idle = idlePool
            .filter { idleKeys.contains($0.key) }
            .sorted { ($0.idleSince ?? .distantFuture) < ($1.idleSince ?? .distantFuture) }
            .map { AccessHostStoreEviction(key: $0.key, kind: .idle) }
        return forced + idle
    }
}
