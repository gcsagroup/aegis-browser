import AccessKit
import Foundation
import WebKit

/// Access intent sessions keyed by the real `WKWebsiteDataStore`.
///
/// Ordinary windows share `WKWebsiteDataStore.default()`, so they share one
/// session. A private store is released with that store; it is not merged
/// into the ordinary lane. This is not a production proxy pipeline.
@MainActor
final class AccessSiteProxyStoreRegistry: ObservableObject {
    @Published private(set) var revision: UInt64 = 0
    private var stores: [ObjectIdentifier: AccessSiteProxySessionStore] = [:]
    weak var hostRouting: AccessHostStoreCoordinator? {
        didSet {
            for store in stores.values {
                store.hostRouting = hostRouting
            }
        }
    }

    func store(
        for dataStore: WKWebsiteDataStore,
        isPrivate: Bool
    ) -> AccessSiteProxySessionStore {
        let key = ObjectIdentifier(dataStore)
        if let existing = stores[key] {
            return existing
        }
        let created = AccessSiteProxySessionStore()
        created.hostRouting = hostRouting
        stores[key] = created
        if isPrivate {
            created.noteNavigationChanged()
        }
        return created
    }

    func release(_ dataStores: [WKWebsiteDataStore]) {
        var changed = false
        for dataStore in dataStores {
            if stores.removeValue(forKey: ObjectIdentifier(dataStore)) != nil {
                changed = true
            }
        }
        if changed {
            revision &+= 1
        }
    }
}
