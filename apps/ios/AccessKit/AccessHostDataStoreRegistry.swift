import Foundation
import Network
import WebKit

/// App-managed proxy entry. Ready requires an identity and generation, not merely a listening port.
public struct AccessManagedProxyEndpoint: Sendable, Equatable {
    public var identity: String
    public var generation: UInt64
    public var loopbackHost: String
    public var port: UInt16
    public var state: AccessProxyEndpointState

    public init(
        identity: String,
        generation: UInt64,
        loopbackHost: String,
        port: UInt16,
        state: AccessProxyEndpointState
    ) {
        self.identity = identity
        self.generation = generation
        self.loopbackHost = loopbackHost
        self.port = port
        self.state = state
    }
}

/// Holds one non-persistent store per scope and exact host.
@MainActor
public final class AccessHostDataStoreRegistry {
    public private(set) var switchGeneration: UInt64 = 0
    private var entries: [AccessHostStoreKey: Entry] = [:]
    private var endpoints: [AccessHostStoreKey: AccessManagedProxyEndpoint] = [:]
    public var onRetire: ((AccessHostStoreKey) -> Void)?

    private struct Entry {
        var store: WKWebsiteDataStore
        var record: AccessHostStoreRecord
        var appliedGeneration: UInt64?
        var retiringDocuments: Set<UUID> = []
    }

    public init() {}

    /// Snapshot includes canonical landing stores with a tab-scoped inherited route.
    public var endpointSnapshot: [AccessHostStoreKey: AccessManagedProxyEndpoint] { endpoints }

    public func endpoint(
        scopeID: String,
        host: AccessSiteHost,
        isPrivate: Bool
    ) -> AccessManagedProxyEndpoint? {
        endpoints[key(scopeID, host, isPrivate)]
    }

    /// Ignores a generation older than the one already accepted for this host.
    public func setEndpoint(
        _ endpoint: AccessManagedProxyEndpoint,
        scopeID: String,
        host: AccessSiteHost,
        isPrivate: Bool
    ) {
        let storeKey = key(scopeID, host, isPrivate)
        if let current = endpoints[storeKey], endpoint.generation < current.generation {
            return
        }
        endpoints[storeKey] = endpoint
        if endpoint.state == .ready, let entry = entries[storeKey] {
            apply(endpoint, to: entry.store)
            entries[storeKey]?.appliedGeneration = endpoint.generation
        }
    }

    public func setProxyEnabled(
        _ enabled: Bool,
        scopeID: String,
        host: AccessSiteHost,
        isPrivate: Bool
    ) {
        switchGeneration &+= 1
        let storeKey = key(scopeID, host, isPrivate)
        if var entry = entries[storeKey] {
            entry.record.proxyEnabled = enabled
            entries[storeKey] = entry
        }
        if !enabled {
            endpoints[storeKey]?.state = .unavailable
        }
    }

    /// Returns the dedicated store when the routing policy selects or keeps one.
    /// Returns nil when the tab must stay on its original store. Does not create a
    /// store while the entry is not ready and the tab is not already bound.
    public func storeForTab(
        tabID: String,
        scopeID: String,
        isPrivate: Bool,
        targetHost: AccessSiteHost?,
        boundHost: AccessSiteHost?,
        intent: AccessProxyIntentState,
        now: Date = Date()
    ) -> WKWebsiteDataStore? {
        let endpointState = targetHost.flatMap { endpoints[key(scopeID, $0, isPrivate)]?.state } ?? .unavailable
        let decision = AccessHostRoutingPolicy.decide(AccessHostRoutingRequest(
            intent: intent,
            endpoint: endpointState,
            targetHost: targetHost,
            boundHost: boundHost
        ))
        unbind(
            tabID,
            exceptHost: targetHost,
            scopeID: scopeID,
            isPrivate: isPrivate,
            decision: decision,
            now: now
        )
        switch decision {
        case .originalStore:
            sweep(now: now)
            return nil
        case .keepBoundHostStore, .useHostStore:
            guard let targetHost else {
                sweep(now: now)
                return nil
            }
            let store = attach(
                tabID: tabID,
                scopeID: scopeID,
                host: targetHost,
                isPrivate: isPrivate,
                now: now
            )
            sweep(now: now)
            return store
        }
    }

    /// Disables the host and drops its store. Returns tab ids that were bound so
    /// the caller can send each one back to its original store first.
    public func revoke(
        scopeID: String,
        host: AccessSiteHost,
        isPrivate: Bool,
        now: Date = Date()
    ) -> Set<String> {
        switchGeneration &+= 1
        let storeKey = key(scopeID, host, isPrivate)
        let tabs = entries[storeKey]?.record.boundTabIDs ?? []
        if var entry = entries[storeKey] {
            entry.record.proxyEnabled = false
            entry.record.boundTabIDs = []
            entries[storeKey] = entry
        }
        endpoints[storeKey]?.state = .unavailable
        sweep(now: now)
        return tabs
    }

    public func unbind(_ tabID: String, now: Date = Date()) {
        var changed = false
        for key in entries.keys {
            guard var entry = entries[key], entry.record.boundTabIDs.remove(tabID) != nil else { continue }
            if entry.record.boundTabIDs.isEmpty {
                entry.record.idleSince = now
            }
            entries[key] = entry
            changed = true
        }
        if changed { sweep(now: now) }
    }

    public func endPrivateSession(scopeID: String, now: Date = Date()) {
        switchGeneration &+= 1
        let keys = entries.keys.filter { $0.isPrivate && $0.scopeID == scopeID }
        for key in keys {
            entries[key]?.record.boundTabIDs = []
            entries[key]?.record.proxyEnabled = false
        }
        sweep(now: now, endingPrivateScopeID: scopeID)
    }

    public func sweep(now: Date, endingPrivateScopeID: String? = nil) {
        let evictions = AccessHostStoreEvictionPolicy.evictions(
            records: entries.values.map { entry in
                var record = entry.record
                if !entry.retiringDocuments.isEmpty { record.boundTabIDs.insert("retiring-document") }
                return record
            },
            now: now,
            endingPrivateScopeID: endingPrivateScopeID
        )
        for eviction in evictions {
            retire(eviction.key)
        }
    }

    public func ordinaryStores() -> [WKWebsiteDataStore] {
        entries.values.filter { !$0.record.key.isPrivate }.map(\.store)
    }

    /// The registry can select a replacement before WebKit acknowledges that
    /// the previous realm is inert. Such a store is not idle yet.
    public func retainRetiringDocument(scopeID: String, host: AccessSiteHost, isPrivate: Bool) -> (@MainActor () -> Void)? {
        let storeKey = key(scopeID, host, isPrivate)
        guard entries[storeKey] != nil else { return nil }
        let token = UUID()
        entries[storeKey]?.retiringDocuments.insert(token)
        return { [weak self] in
            guard let self else { return }
            self.entries[storeKey]?.retiringDocuments.remove(token)
            if self.entries[storeKey]?.retiringDocuments.isEmpty == true,
               self.entries[storeKey]?.record.boundTabIDs.isEmpty == true {
                self.entries[storeKey]?.record.idleSince = Date()
            }
            self.sweep(now: Date())
        }
    }

    public func removeUnstoredEndpoint(for key: AccessHostStoreKey) {
        guard entries[key] == nil else { return }
        endpoints[key] = nil
    }

    public func releaseIdleStores() {
        for (key, entry) in entries where !entry.record.isInUse { retire(key) }
    }

    public func store(
        scopeID: String,
        host: AccessSiteHost,
        isPrivate: Bool
    ) -> WKWebsiteDataStore? {
        entries[key(scopeID, host, isPrivate)]?.store
    }

    private func attach(
        tabID: String,
        scopeID: String,
        host: AccessSiteHost,
        isPrivate: Bool,
        now: Date
    ) -> WKWebsiteDataStore? {
        let storeKey = key(scopeID, host, isPrivate)
        let endpoint = endpoints[storeKey]
        if entries[storeKey] == nil {
            guard endpoint?.state == .ready else { return nil }
            let store = WKWebsiteDataStore.nonPersistent()
            if let endpoint {
                apply(endpoint, to: store)
            }
            entries[storeKey] = Entry(
                store: store,
                record: AccessHostStoreRecord(
                    key: storeKey,
                    boundTabIDs: [],
                    proxyEnabled: true,
                    idleSince: nil
                ),
                appliedGeneration: endpoint?.generation
            )
        }
        guard var entry = entries[storeKey] else { return nil }
        entry.record.boundTabIDs.insert(tabID)
        entry.record.idleSince = nil
        if let endpoint, endpoint.state == .ready, entry.appliedGeneration != endpoint.generation {
            apply(endpoint, to: entry.store)
            entry.appliedGeneration = endpoint.generation
        }
        entries[storeKey] = entry
        _ = now
        return entry.store
    }

    private func unbind(
        _ tabID: String,
        exceptHost: AccessSiteHost?,
        scopeID: String,
        isPrivate: Bool,
        decision: AccessHostRoutingDecision,
        now: Date
    ) {
        let keep: AccessSiteHost?
        switch decision {
        case .originalStore:
            keep = nil
        case .keepBoundHostStore, .useHostStore:
            keep = exceptHost
        }
        for key in entries.keys {
            let sameScope = key.scopeID == scopeID && key.isPrivate == isPrivate
            guard sameScope, key.host != keep, var entry = entries[key] else { continue }
            if entry.record.boundTabIDs.remove(tabID) != nil, entry.record.boundTabIDs.isEmpty {
                entry.record.idleSince = now
            }
            entries[key] = entry
        }
    }

    private func retire(_ key: AccessHostStoreKey) {
        guard entries[key]?.retiringDocuments.isEmpty == true,
              let entry = entries.removeValue(forKey: key) else { return }
        entry.store.proxyConfigurations = []
        endpoints[key] = nil
        onRetire?(key)
    }

    private func apply(_ endpoint: AccessManagedProxyEndpoint, to store: WKWebsiteDataStore) {
        guard endpoint.state == .ready,
              endpoint.port != 0,
              let port = NWEndpoint.Port(rawValue: endpoint.port)
        else { return }
        var configuration = ProxyConfiguration(httpCONNECTProxy: .hostPort(
            host: NWEndpoint.Host(endpoint.loopbackHost),
            port: port
        ))
        configuration.allowFailover = false
        store.proxyConfigurations = [configuration]
    }

    private func key(
        _ scopeID: String,
        _ host: AccessSiteHost,
        _ isPrivate: Bool
    ) -> AccessHostStoreKey {
        AccessHostStoreKey(scopeID: scopeID, host: host, isPrivate: isPrivate)
    }
}
