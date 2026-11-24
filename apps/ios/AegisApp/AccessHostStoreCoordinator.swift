import AccessKit
import AegisPolicyKit
import BrowserKit
import Foundation
import WebKit

/// App adapter for exact-host stores. Ordinary scope is shared by every window.
/// A private scope id is the browser's current private session.
@MainActor
final class AccessHostStoreCoordinator: ObservableObject, BrowserHostStoreCoordinating {
    let registry: AccessHostDataStoreRegistry
    let publisher: any AccessProxyEntryPublishing
    let clock: any AccessPreparationClock
    let releaseChannel: AccessReleaseChannel
    let prepareBudget: Duration = .seconds(15)
    @Published private(set) var revision: UInt64 = 0
    /// Explicit `suggestProbe` / `runProbe` calls. Recovery and page loads do not increment this.
    private(set) var probeInvocationCount: UInt64 = 0
    private let ruleGroups = AccessSiteRuleGroupRegistry()
    private var intents: [AccessHostStoreKey: AccessProxyIntentState] = [:]
    var offersLocationService: Bool { !(publisher is AccessFailClosedProxyEntryPublisher) }
    /// Smart mode replaces the default location-privacy first attempt for sites outside its rules.
    var smartModeReplacesDefaultLocationPrivacy: Bool { defaultLocationPrivacy }
    private let defaultLocationPrivacy: Bool
    private let locationPreferences: UserDefaults?
    private static let directSitesKey = "browser.locationPrivacy.directSites"
    private static let accelerationModeKey = "browser.websiteAcceleration.mode"
    private static let accelerationChoicesKey = "browser.websiteAcceleration.siteChoices.v1"
    private static let accelerationCategoriesKey = "browser.websiteAcceleration.categories"
    private let websiteRoutePolicy: AccessWebsiteRoutePolicy
    let geoSiteCache: AccessGeoSiteCache?
    private var geoSiteView: AccessGeoSiteCache.View?
    private var comparingWebsitePolicy = false
    private var geoSiteRestoreTask: Task<Void, Never>?
    private let geoSiteTransport: AccessGeoSiteUpdateTransport?
    private var geoSiteForegroundWindows: [UUID: UUID] = [:]
    private var geoSiteRefresh: (context: AccessGeoSiteCache.Context, task: Task<Void, Never>)?
    private static let geoSiteRetry: [TimeInterval] = [60, 300, 1_800, 21_600]
    @Published private(set) var websiteAccelerationMode: AccessWebsiteAccelerationMode = .manual
    private var websiteRouteChoices: [AccessSiteHost: AccessWebsiteRouteChoice] = [:]
    private let categoryOwner = UUID()
    private var categorySelectionRevision: UInt64 = 0
    private var selectedWebsiteCategories: Set<AccessGeoSiteCategory> = []
    private var policyEpoch: UInt64 = 0
    // Website preparation and inherited landings can warm an endpoint.
    // Legacy default privacy and recovery need their own authorization.
    private var websiteOnlyEndpoints: Set<AccessHostStoreKey> = []
    // Bindings selected by a website route without an existing direct legacy binding.
    private var websiteBindings: [String: AccessHostStoreKey] = [:]
    private var landingBindings: [String: LandingRoute] = [:]
    private var defaultProtectedHosts: Set<AccessHostStoreKey> = []
    private var explicitDirect: Set<AccessHostStoreKey> = []
    private var executing: Set<AccessHostStoreKey> = []
    /// Tabs that have actually entered a proxy recovery send, bound to the host
    /// key they recovered. Scope-wide `executing` alone must not route a healthy
    /// sibling (or the same tab on a different host) onto another host store.
    // All tab keys below are live instance IDs, never persisted restore IDs.
    private var executingTabs: [String: AccessHostStoreKey] = [:]
    private var hostRevisions: [AccessHostStoreKey: UInt64] = [:]
    private var operations: [UUID: RecoveryOperation] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    var retainedOperationCount: Int { operations.count }
    private var phases: [String: RecoveryPhase] = [:]
    private var probeLines: [String: [String]] = [:]
    private var probeBusyTabs: Set<String> = []
    private var probeTasks: [String: Task<Void, Never>] = [:]
    private var probeGenerations: [String: UInt64] = [:]
    /// Site host the probe was started for; results must not survive an in-place navigation.
    private var probeSiteHosts: [String: AccessSiteHost] = [:]
    private var probeRunner = AccessSiteProbeRunner()
    private var sweepTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    init(
        publisher: (any AccessProxyEntryPublishing)? = nil,
        clock: (any AccessPreparationClock)? = nil,
        channel: AccessReleaseChannel = .release,
        probeRunner: AccessSiteProbeRunner = AccessSiteProbeRunner(),
        defaultLocationPrivacy: Bool = false,
        locationPreferences: UserDefaults? = nil,
        websiteRoutePolicy: AccessWebsiteRoutePolicy = AccessWebsiteRoutePolicy(),
        geoSiteCache: AccessGeoSiteCache? = nil,
        geoSiteTransport: AccessGeoSiteUpdateTransport? = nil,
        registry: AccessHostDataStoreRegistry = AccessHostDataStoreRegistry()
    ) {
        self.registry = registry
        self.publisher = publisher ?? AccessFailClosedProxyEntryPublisher()
        self.clock = clock ?? AccessContinuousPreparationClock()
        self.releaseChannel = channel == .unknown ? .release : channel
        self.probeRunner = probeRunner
        self.defaultLocationPrivacy = defaultLocationPrivacy
        self.locationPreferences = locationPreferences
        self.websiteRoutePolicy = websiteRoutePolicy
        self.geoSiteCache = channel == .dev ? geoSiteCache : nil
        self.geoSiteTransport = self.geoSiteCache == nil ? nil : geoSiteTransport
        geoSiteView = self.geoSiteCache?.view
        if self.releaseChannel == .dev {
            if locationPreferences?.object(forKey: Self.accelerationCategoriesKey) == nil {
                selectedWebsiteCategories = [.debian]
                if self.geoSiteCache == nil {
                    locationPreferences?.set([AccessGeoSiteCategory.debian.rawValue], forKey: Self.accelerationCategoriesKey)
                }
            } else {
                let stored = locationPreferences?.stringArray(forKey: Self.accelerationCategoriesKey) ?? []
                selectedWebsiteCategories = Set(stored.compactMap(AccessGeoSiteCategory.init(rawValue:)))
            }
        }
        if self.releaseChannel == .dev, let locationPreferences {
            websiteAccelerationMode = locationPreferences.string(forKey: Self.accelerationModeKey)
                .flatMap(AccessWebsiteAccelerationMode.init(rawValue:)) ?? .manual
            for (name, value) in locationPreferences.dictionary(forKey: Self.accelerationChoicesKey) ?? [:] {
                guard let url = URL(string: "https://\(name)/"), let host = AccessWebsiteRoutePolicy.websiteHost(url),
                      host.rawValue == name, let raw = value as? String,
                      let choice = AccessWebsiteRouteChoice(rawValue: raw) else { continue }
                websiteRouteChoices[host] = choice
            }
        }
        for name in locationPreferences?.stringArray(forKey: Self.directSitesKey) ?? [] {
            guard let host = try? AccessSiteHost(name) else { continue }
            let key = AccessHostStoreKey(scopeID: "ordinary", host: host, isPrivate: false)
            explicitDirect.insert(key)
            intents[key] = .off
        }
        if let selection = geoSiteView?.selection {
            websiteAccelerationMode = selection.mode
            selectedWebsiteCategories = selection.categories
        }
        let publisher = self.publisher
        registry.onRetire = { [weak self] key in
            self?.defaultProtectedHosts.remove(key)
            self?.websiteOnlyEndpoints.remove(key)
            self?.publisher.release(for: key)
        }
        stateTask = Task { @MainActor [weak self] in
            for await endpoint in publisher.stateChanges {
                self?.applySharedState(endpoint)
            }
        }
        if let cache = self.geoSiteCache {
            cache.onChange = { [weak self] view in self?.applyGeoSiteView(view) }
            let migration = AccessGeoSiteCache.Selection(mode: websiteAccelerationMode, categories: selectedWebsiteCategories)
            geoSiteRestoreTask = Task { await cache.restore(migrating: migration) }
        }
    }

    deinit {
        stateTask?.cancel()
        sweepTask?.cancel()
        geoSiteRestoreTask?.cancel()
        geoSiteRefresh?.task.cancel()
        timeoutTasks.values.forEach { $0.cancel() }
        probeTasks.values.forEach { $0.cancel() }
    }

    var lastRecoveryFailure: String?

    func startForegroundSweep() {
        sweepTask?.cancel()
        sweepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.registry.sweep(now: Date())
                self?.checkpointGeoSiteClock()
            }
        }
    }

    func releaseIdleResources() { registry.releaseIdleStores() }

    var geoSiteStatus: AccessGeoSiteCache.Status? { geoSiteView?.status }

    func setGeoSiteForeground(window: UUID, eligible: Bool) {
        guard geoSiteCache != nil else { return }
        if eligible {
            guard geoSiteForegroundWindows[window] == nil else { return }
            geoSiteForegroundWindows[window] = UUID()
            checkpointGeoSiteClock()
        } else {
            geoSiteForegroundWindows[window] = nil
            if let geoSiteTransport { reconcileGeoSiteRefresh(using: geoSiteTransport) }
        }
    }

    private func reconcileGeoSiteRefresh(using transport: AccessGeoSiteUpdateTransport) {
        guard let cache = geoSiteCache else { return }
        let context = geoSiteForegroundWindows.isEmpty ? nil : cache.updateContext()
        if let running = geoSiteRefresh {
            if context != running.context { running.task.cancel() }
            return
        }
        guard let context, cache.refreshState.nextAttempt.map({ $0 <= cache.effectiveTime }) != false else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshGeoSite(cache, transport: transport, context: context)
        }
        geoSiteRefresh = (context, task)
    }

    private func refreshGeoSite(_ cache: AccessGeoSiteCache, transport: AccessGeoSiteUpdateTransport,
                                context: AccessGeoSiteCache.Context) async {
        defer {
            geoSiteRefresh = nil
            if cache.updateContext() != context || Task.isCancelled {
                reconcileGeoSiteRefresh(using: transport)
            }
        }
        guard canPublishGeoSiteRefresh(context) else { return }
        let now = cache.effectiveTime
        let prior = cache.refreshState
        var attempting = prior
        attempting.lastRequest = now
        attempting.nextAttempt = now.addingTimeInterval(Self.geoSiteRetry[min(prior.failureCount, 3)])
        do { try cache.setRefreshState(attempting, using: context) }
        catch { return }

        do {
            let conditional = await cache.conditionalReceipt(using: context)
            guard canPublishGeoSiteRefresh(context) else { return }
            let result = try await transport.load(etag: conditional?.etag, highWater: cache.highWater, now: now)
            guard canPublishGeoSiteRefresh(context) else { return }
            var refreshed = AccessGeoSiteCache.RefreshState(nextAttempt: cache.effectiveTime.addingTimeInterval(86_400),
                                                            lastRequest: now)
            switch result {
            case .candidate(let candidate, let etag):
                refreshed.etag = etag
                try await cache.apply(candidate, using: context, refreshed: refreshed)
            case .notModified(let responseETag):
                guard let conditional, responseETag == nil || responseETag == conditional.etag,
                      await cache.conditionalReceipt(using: context) == conditional,
                      canPublishGeoSiteRefresh(context) else { throw AccessGeoSiteCache.Failure.stale }
                refreshed.etag = conditional.etag
                try cache.setRefreshState(refreshed, using: context)
            }
        } catch {
            guard canPublishGeoSiteRefresh(context) else { return }
            let failures = min(prior.failureCount + 1, Self.geoSiteRetry.count)
            let next = cache.effectiveTime.addingTimeInterval(Self.geoSiteRetry[failures - 1])
            try? cache.setRefreshState(.init(failureCount: failures, nextAttempt: next, lastRequest: now), using: context)
        }
    }

    private func canPublishGeoSiteRefresh(_ context: AccessGeoSiteCache.Context) -> Bool {
        !Task.isCancelled && !geoSiteForegroundWindows.isEmpty && geoSiteCache?.updateContext() == context
    }

    func checkpointGeoSiteClock() {
        if let cache = geoSiteCache, cache.status == .unavailable, cache.selection == nil {
            let migration = AccessGeoSiteCache.Selection(mode: websiteAccelerationMode, categories: selectedWebsiteCategories)
            geoSiteRestoreTask = Task { await cache.restore(migrating: migration) }
        } else {
            try? geoSiteCache?.checkpointClock()
        }
        if let geoSiteTransport { reconcileGeoSiteRefresh(using: geoSiteTransport) }
    }

    private func applyGeoSiteView(_ view: AccessGeoSiteCache.View) {
        let selection = view.selection
        let modeChanged = selection.map { $0.mode != websiteAccelerationMode } == true
        changeWebsitePolicy(modeChanged ? .mode : .catalogue) {
            geoSiteView = view
            if let selection {
                websiteAccelerationMode = selection.mode
                selectedWebsiteCategories = selection.categories
            }
            categorySelectionRevision &+= 1
        }
        if let geoSiteTransport { reconcileGeoSiteRefresh(using: geoSiteTransport) }
    }

    private func accelerationAllowed(for key: AccessHostStoreKey) -> Bool {
        accelerationAllowed(scopeID: key.scopeID, isPrivate: key.isPrivate)
    }

    private func accelerationAllowed(scopeID: String, isPrivate: Bool) -> Bool {
        releaseChannel == .dev && scopeID == "ordinary" && !isPrivate
    }

    func offersWebsiteAcceleration(for tab: BrowserTab) -> Bool {
        !tab.isDisposed && tab.hostCoordinator === self && tab.profile == .standard
            && accelerationAllowed(scopeID: tab.browsingScopeID, isPrivate: tab.profile.isPrivate)
    }

    // Ordinary DEV navigation can reach owner-scoped website policy and host stores.
    private func hasValidRouteOwner(for tab: BrowserTab) -> Bool {
        !accelerationAllowed(scopeID: tab.browsingScopeID, isPrivate: tab.profile.isPrivate)
            || offersWebsiteAcceleration(for: tab)
    }

    func setWebsiteAccelerationMode(_ mode: AccessWebsiteAccelerationMode, for tab: BrowserTab) {
        guard offersWebsiteAcceleration(for: tab), websiteAccelerationMode != mode else { return }
        if let geoSiteCache {
            try? geoSiteCache.setSelection(.init(mode: mode, categories: selectedWebsiteCategories))
            return
        }
        changeWebsitePolicy(.mode) {
            categorySelectionRevision &+= 1
            websiteAccelerationMode = mode
            locationPreferences?.set(mode.rawValue, forKey: Self.accelerationModeKey)
        }
    }

    struct WebsiteCategories {
        let catalogue: AccessGeoSiteCatalogue
        let selected: Set<AccessGeoSiteCategory>
        let scopes: [AccessGeoSiteCategory: AccessGeoSiteCache.Scope]?
        let staged: [AccessGeoSiteCategory: AccessGeoSiteCache.StagedScope]
        fileprivate let owner: UUID
        fileprivate let selectionRevision: UInt64
    }

    func websiteCategories(for tab: BrowserTab) -> WebsiteCategories? {
        guard offersWebsiteAcceleration(for: tab), websiteAccelerationMode == .smart else { return nil }
        if let geoSiteView, geoSiteView.selection == nil || geoSiteView.status != .ready { return nil }
        let catalogue = geoSiteView.map { view in
            let available = view.groups.compactMapValues { scope -> AccessGeoSiteCatalogue.Group? in
                guard case .available(let group, _) = scope else { return nil }
                return group
            }
            let bundle = AccessGeoSiteCatalogue.bundled
            return AccessGeoSiteCatalogue(tag: bundle.tag, publishedAt: bundle.publishedAt,
                                          rawSHA256: bundle.rawSHA256, groups: available)
        } ?? websiteRoutePolicy.catalogue
        return WebsiteCategories(catalogue: catalogue, selected: selectedWebsiteCategories, scopes: geoSiteView?.groups,
                                 staged: geoSiteView?.staged ?? [:],
                                 owner: categoryOwner, selectionRevision: categorySelectionRevision)
    }

    func setWebsiteCategory(_ category: AccessGeoSiteCategory, selected: Bool,
                            from displayed: WebsiteCategories, for tab: BrowserTab) {
        guard let current = websiteCategories(for: tab), displayed.owner == current.owner,
              displayed.selectionRevision == current.selectionRevision, displayed.catalogue == current.catalogue,
              current.scopes != nil || current.catalogue.groups[category] != nil,
              current.selected.contains(category) != selected else { return }
        if let geoSiteCache {
            var categories = selectedWebsiteCategories
            if selected { categories.insert(category) }
            else { categories.remove(category) }
            try? geoSiteCache.setSelection(.init(mode: websiteAccelerationMode, categories: categories))
            return
        }
        changeWebsitePolicy(.catalogue) {
            if selected { selectedWebsiteCategories.insert(category) }
            else { selectedWebsiteCategories.remove(category) }
            categorySelectionRevision &+= 1
            locationPreferences?.set(AccessGeoSiteCategory.allCases.filter { selectedWebsiteCategories.contains($0) }.map(\.rawValue),
                                     forKey: Self.accelerationCategoriesKey)
        }
    }

    func websiteCategoryProposal(_ category: AccessGeoSiteCategory, for browser: BrowserSession) -> AccessGeoSiteCache.Proposal? {
        guard geoSiteForegroundWindows[browser.standardProfileID] != nil, let tab = browser.activeTab,
              websiteCategories(for: tab)?.staged[category] != nil else { return nil }
        return geoSiteCache?.proposal(for: category)
    }

    func confirmWebsiteCategory(_ proposal: AccessGeoSiteCache.Proposal, for browser: BrowserSession) async -> Bool {
        guard let cache = geoSiteCache, let tab = browser.activeTab,
              let window = geoSiteForegroundWindows[browser.standardProfileID],
              websiteCategoryProposal(proposal.category, for: browser) == proposal else { return false }
        let tabRevision = browser.tabSelectionRevision
        do {
            try await cache.confirm(proposal) {
                self.geoSiteForegroundWindows[browser.standardProfileID] == window
                    && browser.tabSelectionRevision == tabRevision && browser.activeTab === tab
                    && self.offersWebsiteAcceleration(for: tab)
            }
            return true
        } catch {
            return false
        }
    }

    func websiteAccelerationHost(for tab: BrowserTab) -> AccessSiteHost? {
        websiteAccelerationSite(for: tab)?.host
    }

    private func websiteAccelerationSite(for tab: BrowserTab) -> (url: URL, host: AccessSiteHost)? {
        guard offersWebsiteAcceleration(for: tab), let url = tab.websiteRouteControlURL,
              let host = AccessWebsiteRoutePolicy.websiteHost(url),
              AccessLocalSite.classify(host.rawValue) == nil else { return nil }
        return (url, host)
    }

    func websiteRouteChoice(for tab: BrowserTab) -> AccessWebsiteRouteChoice? {
        websiteAccelerationHost(for: tab).flatMap { websiteRouteChoices[$0] }
    }

    func websiteRouteSelection(for tab: BrowserTab) -> AccessWebsiteRouteChoice? {
        guard let (url, host) = websiteAccelerationSite(for: tab) else { return nil }
        let key = AccessHostStoreKey(scopeID: tab.browsingScopeID, host: host, isPrivate: false)
        if requiresProxy(tab: tab, url: url) { return .service }
        if websiteRoute(tab: tab, url: url, key: key) == .original || explicitDirect.contains(key) { return .original }
        return nil
    }

    func setWebsiteRouteChoice(_ choice: AccessWebsiteRouteChoice?, for tab: BrowserTab, displayedHost: AccessSiteHost) {
        guard websiteAccelerationHost(for: tab) == displayedHost,
              websiteRouteChoices[displayedHost] != choice else { return }
        changeWebsitePolicy(.exact(displayedHost)) {
            websiteRouteChoices[displayedHost] = choice
            let stored = Dictionary(uniqueKeysWithValues: websiteRouteChoices.map { ($0.key.rawValue, $0.value.rawValue) })
            locationPreferences?.set(stored, forKey: Self.accelerationChoicesKey)
            if choice == .original {
                let key = AccessHostStoreKey(scopeID: "ordinary", host: displayedHost, isPrivate: false)
                executing.remove(key)
                executingTabs = executingTabs.filter { $0.value != key }
            }
        }
    }

    private enum WebsitePolicyChange: Equatable {
        case mode
        case exact(AccessSiteHost)
        case catalogue
    }

    private func boundWebsiteRouteURL(for tab: BrowserTab) -> URL? {
        [tab.liveCommittedDocumentURL, tab.addressBarURL].compactMap { $0 }
            .first { Self.httpHost($0)?.rawValue == tab.boundHostName } ?? tab.requestedURL
    }

    private func changeWebsitePolicy(_ scope: WebsitePolicyChange, _ change: () -> Void) {
        comparingWebsitePolicy = true
        defer { comparingWebsitePolicy = false }
        let tabs = BrowserSession.openTabs().filter { offersWebsiteAcceleration(for: $0) }
        let wasRequired = Set<UUID>(tabs.compactMap { tab in
            tab.addressBarURL.map { precludesOriginal(tab: tab, url: $0) } == true ? tab.instanceID : nil
        })
        let catalogueChange = scope == .catalogue
        let mayProtectOriginal = catalogueChange || scope == .mode
        var protectedBindings: Set<UUID> = []
        var originalDocuments: [UUID: URL] = [:]
        if mayProtectOriginal {
            for tab in tabs {
                if tab.boundHostName != nil {
                    if let url = boundWebsiteRouteURL(for: tab), requiresProxy(tab: tab, url: url) {
                        protectedBindings.insert(tab.instanceID)
                    }
                } else if let url = tab.liveCommittedDocumentURL, Self.httpHost(url) != nil,
                          !precludesOriginal(tab: tab, url: url) {
                    originalDocuments[tab.instanceID] = url
                }
            }
        }
        change()
        // Keep equivalent preparations live on catalogue changes, including
        // a host still protected by another category or an independent grant.
        if scope == .mode { policyEpoch &+= 1 }
        let tabsByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.instanceID.uuidString, $0) })
        var invalidatedTabs: Set<String> = []
        var affectedKeys: Set<AccessHostStoreKey> = []
        for (id, operation) in operations where accelerationAllowed(for: operation.key) {
            switch scope {
            case .mode, .catalogue: break
            case .exact(let editedHost):
                guard operation.key.host == editedHost || operation.landingParent?.host == editedHost else { continue }
            }
            if let tab = tabsByID[operation.tabID] {
                var checked = operation
                if scope == .mode, checked.policyEpoch != nil { checked.policyEpoch = policyEpoch }
                if authorizationStillValid(checked, tab: tab) {
                    operations[id] = checked
                    continue
                }
            }
            operations.removeValue(forKey: id)
            timeoutTasks.removeValue(forKey: id)?.cancel()
            publisher.cancel(operationID: id)
            affectedKeys.insert(operation.key)
            if operation.state == .preparing || operation.state == .sent {
                phases[operation.tabID] = nil
                invalidatedTabs.insert(operation.tabID)
            }
        }
        for key in affectedKeys { releaseUnstoredConsumerIfUnused(key) }
        for tab in tabs {
            let required = tab.addressBarURL.map { precludesOriginal(tab: tab, url: $0) } ?? false
            let boundURL = boundWebsiteRouteURL(for: tab)
            let mustDetach = tab.boundHostName != nil && (!catalogueChange || protectedBindings.contains(tab.instanceID))
                && !((boundURL ?? tab.requestedURL)
                .map { requiresProxy(tab: tab, url: $0) } ?? false)
            let newlyProtected = required && !wasRequired.contains(tab.instanceID)
            let interrupted = tab.isLoading && (invalidatedTabs.contains(tab.instanceID.uuidString)
                || required != wasRequired.contains(tab.instanceID))
            let retireOriginal = mayProtectOriginal && tab.boundHostName == nil
                && (tab.isLoading && newlyProtected
                    || originalDocuments[tab.instanceID].map { precludesOriginal(tab: tab, url: $0) } == true)
            // The address bar can show a pending request while the landing is still displayed.
            let landingURL = [tab.liveCommittedDocumentURL, boundURL].compactMap { $0 }
                .first { tab.parentForProxyLanding($0) != nil }
            if let landingURL, let host = Self.httpHost(landingURL), host.rawValue == tab.boundHostName {
                let key = AccessHostStoreKey(scopeID: tab.browsingScopeID, host: host, isPrivate: false)
                switch websiteRoute(tab: tab, url: landingURL, key: key) {
                case .landing: break
                case .service where landingRoute(tab: tab, url: landingURL, destination: key) != nil:
                    // A service choice can supersede the route while the inherited grant remains valid.
                    break
                default:
                    tab.clearProxyLanding()
                    landingBindings.removeValue(forKey: tab.instanceID.uuidString)
                }
            }
            guard mustDetach || interrupted || retireOriginal else { continue }
            if mustDetach, let bound = tab.boundHostName.flatMap({ try? AccessSiteHost($0) }) {
                let key = AccessHostStoreKey(scopeID: tab.browsingScopeID, host: bound, isPrivate: false)
                let release = registry.retainRetiringDocument(scopeID: key.scopeID, host: bound, isPrivate: false)
                registry.unbind(tab.instanceID.uuidString)
                if let release {
                    tab.afterCurrentDocumentBecomesInert { [weak self] in
                        release()
                        guard let self, !self.operations.values.contains(where: { $0.key == key }) else { return }
                        self.registry.releaseIdleStore(for: key)
                    }
                }
                websiteBindings.removeValue(forKey: tab.instanceID.uuidString)
                landingBindings.removeValue(forKey: tab.instanceID.uuidString)
                if !interrupted, let pending = tab.pendingAddressNavigation,
                   tab.detachStoreDuringProxyHold(pending) { continue }
            }
            if retireOriginal, !interrupted, let pending = tab.pendingAddressNavigation,
               tab.retireOriginalDocumentDuringProxyHold(pending) { continue }
            tab.pauseAfterWebsiteRouteChange(detachStore: mustDetach, retireOriginalDocument: retireOriginal)
        }
        revision &+= 1
    }

    func setProxyEnabled(
        _ enabled: Bool,
        host: AccessSiteHost,
        scopeID: String,
        isPrivate: Bool
    ) {
        let key = AccessHostStoreKey(scopeID: scopeID, host: host, isPrivate: isPrivate)
        let wasOn = intents[key] == .on
        intents[key] = enabled ? .on : .off
        if enabled, wasOn {
            revision &+= 1
            return
        }
        if enabled {
            if explicitDirect.remove(key) != nil { saveDirectSites(afterChanging: key) }
            registry.setProxyEnabled(true, scopeID: scopeID, host: host, isPrivate: isPrivate)
            revision &+= 1
            return
        }
        if websiteChoice(for: key) == .service || (groupStillLists(key) && !explicitDirect.contains(key)) {
            revision &+= 1
            return
        }
        releaseBinding(key)
        revision &+= 1
    }

    func setProxyEnabled(_ enabled: Bool, for tab: BrowserTab) {
        guard hasValidRouteOwner(for: tab), let host = host(for: tab) else { return }
        if enabled {
            if tab.loadingErrorAllowsProxyRetry {
                _ = startRecovery(tab: tab, trigger: .userToggle)
            } else {
                let key = AccessHostStoreKey(
                    scopeID: tab.browsingScopeID,
                    host: host,
                    isPrivate: tab.profile.isPrivate
                )
                _ = beginPrepare(for: tab, key: key, failure: nil, trigger: .userToggle)
            }
        } else {
            setProxyEnabled(false, host: host, scopeID: tab.browsingScopeID, isPrivate: tab.profile.isPrivate)
        }
    }

    /// An explicit page route has priority over optional automatic recovery.
    /// Revalidate the host shown by the control before changing any shared state.
    func setSiteProxyEnabled(_ enabled: Bool, for tab: BrowserTab, displayedHost: AccessSiteHost, forLocationControl: Bool = false) {
        let currentHost = forLocationControl ? locationControlHost(for: tab) : host(for: tab)
        guard !tab.isDisposed, hasValidRouteOwner(for: tab), currentHost == displayedHost else { return }
        let key = AccessHostStoreKey(scopeID: tab.browsingScopeID, host: displayedHost, isPrivate: tab.profile.isPrivate)
        let affected = BrowserSession.openTabs().filter { current in
            // A committed document may remain visible while a different host is
            // loading or held for proxy preparation. Its new navigation is not
            // owned by the previous document's site toggle.
            let targetHost = current.isLoading
                ? current.addressBarURL.flatMap(Self.httpHost) : host(for: current)
            return current.browsingScopeID == key.scopeID && current.profile.isPrivate == key.isPrivate
                && targetHost == key.host
        }
        let reloads = affected.compactMap { current -> (BrowserTab, URLRequest)? in
            guard let request = current.safeRouteReloadRequest, let url = request.url,
                  Self.httpHost(url) == key.host else { return nil }
            return (current, request)
        }
        if !enabled, explicitDirect.insert(key).inserted { saveDirectSites(afterChanging: key) }
        setProxyEnabled(enabled, host: key.host, scopeID: key.scopeID, isPrivate: key.isPrivate)
        for current in affected where !reloads.contains(where: { $0.0 === current }) {
            current.pauseAfterRouteChange()
        }
        for (current, request) in reloads { current.load(request) }
        revision &+= 1
    }

    func requiresProxy(tab: BrowserTab, url: URL) -> Bool {
        guard let host = Self.httpHost(url) else { return false }
        let key = AccessHostStoreKey(scopeID: tab.browsingScopeID, host: host, isPrivate: tab.profile.isPrivate)
        let route = websiteRoute(tab: tab, url: url, key: key)
        return navigationIntent(tab: tab, key: key, route: route) == .on
    }

    func isMainFrameRouteIndeterminate(tab: BrowserTab, url: URL) -> Bool {
        guard let host = Self.httpHost(url), tab.hostCoordinator === self, geoSiteCache != nil else { return false }
        let key = AccessHostStoreKey(scopeID: tab.browsingScopeID, host: host, isPrivate: tab.profile.isPrivate)
        return websiteRoute(tab: tab, url: url, key: key) == .indeterminate
    }

    private func precludesOriginal(tab: BrowserTab, url: URL) -> Bool {
        requiresProxy(tab: tab, url: url) || isMainFrameRouteIndeterminate(tab: tab, url: url)
    }

    private func websiteChoice(for key: AccessHostStoreKey) -> AccessWebsiteRouteChoice? {
        accelerationAllowed(for: key) ? websiteRouteChoices[key.host] : nil
    }

    private enum WebsiteRoute: Equatable {
        case legacy
        case original
        case indeterminate
        case service
        case landing(LandingRoute)

        var requiredPreparation: RoutePreparation? {
            switch self {
            case .service, .landing: .website(self)
            case .legacy, .original, .indeterminate: nil
            }
        }
    }

    private struct LandingRoute: Equatable {
        let parent: AccessHostStoreKey
        let destination: AccessHostStoreKey
        let parentRevision: UInt64
        // The grant survives idle retirement of the parent and a mode change
        // suppressing new default preparations.
        let inheritsDefaultPrivacy: Bool
    }

    private func websiteRoute(tab: BrowserTab, url: URL, key: AccessHostStoreKey, allowLanding: Bool = true) -> WebsiteRoute {
        guard hasValidRouteOwner(for: tab) else { return .original }
        if let choice = websiteChoice(for: key) {
            return choice == .service ? .service : .original
        }
        if explicitDirect.contains(key) || intents[key] == .off {
            // Legacy .off still permits an independently authorized recovery group.
            if accelerationAllowed(for: key), websiteAccelerationMode == .smart {
                return legacyRouteIntent(tab: tab, key: key) == .on ? .legacy : .original
            }
            return .legacy
        }
        if intents[key] == .on { return .legacy }
        if allowLanding, let landing = landingRoute(tab: tab, url: url, destination: key) {
            return .landing(landing)
        }
        guard accelerationAllowed(for: key) else { return .legacy }
        let smart = smartMatch(url)
        if smart == .managed { return .service }
        // A one-shot address action, explicit recovery group, or an already
        // protected document retains its independent authorization.
        if legacyRouteIntent(tab: tab, key: key) == .on { return .legacy }
        if smart == .indeterminate { return .indeterminate }
        return websiteAccelerationMode == .smart ? .original : .legacy
    }

    private func smartMatch(_ url: URL) -> AccessGeoSiteCache.Match {
        if let geoSiteCache {
            let view = comparingWebsitePolicy ? geoSiteView : geoSiteCache.runtimeView()
            return view?.match(url) ?? .indeterminate
        }
        return websiteAccelerationMode == .smart && websiteRoutePolicy.matches(url, categories: selectedWebsiteCategories)
            ? .managed : .original
    }

    private func landingRoute(tab: BrowserTab, url: URL, destination: AccessHostStoreKey) -> LandingRoute? {
        guard !tab.isDisposed, tab.hostCoordinator === self,
              let rawParent = tab.parentForProxyLanding(url), let parentHost = try? AccessSiteHost(rawParent),
              let parentURL = URL(string: "https://\(parentHost.rawValue)/"),
              let boundHost = tab.boundHostName.flatMap({ try? AccessSiteHost($0) }),
              registry.store(scopeID: destination.scopeID, host: boundHost, isPrivate: destination.isPrivate)
                  === tab.websiteDataStore else { return nil }
        let parent = AccessHostStoreKey(scopeID: destination.scopeID, host: parentHost, isPrivate: destination.isPrivate)
        let bound = AccessHostStoreKey(scopeID: destination.scopeID, host: boundHost, isPrivate: destination.isPrivate)
        guard bound == parent || bound == destination ||
            RegisteredDomain.isCanonicalLandingHost(boundHost.rawValue, for: parentHost.rawValue) else { return nil }

        let tabID = tab.instanceID.uuidString
        let parentRevision = hostRevisions[parent] ?? 0
        let fromParent = bound == parent && registry.isBound(tabID, to: parent)
        let inherited = landingBindings[tabID].flatMap { landing -> LandingRoute? in
            // Store selection can reserve the destination before WebKit swaps views.
            guard landing.parent == parent, landing.parentRevision == parentRevision,
                  landing.destination == bound || landing.destination == destination,
                  registry.isBound(tabID, to: landing.destination) else { return nil }
            return landing
        }
        guard fromParent || inherited != nil else { return nil }

        let inheritsDefault = inherited?.inheritsDefaultPrivacy == true || (fromParent
            && websiteBindings[tabID] != parent && !websiteOnlyEndpoints.contains(parent)
            && defaultProtectedHosts.contains(parent))
        let parentRoute = websiteRoute(tab: tab, url: parentURL, key: parent, allowLanding: false)
        if parentRoute != .service {
            guard websiteChoice(for: parent) != .original, !explicitDirect.contains(parent),
                  intents[parent] == .on || (intents[parent] == nil && inheritsDefault)
                    || (executingTabs[tabID] == parent && groupStillLists(parent)) else { return nil }
        }
        return LandingRoute(parent: parent, destination: destination, parentRevision: parentRevision,
                            inheritsDefaultPrivacy: inheritsDefault)
    }

    private func endpoint(for key: AccessHostStoreKey) -> AccessManagedProxyEndpoint? {
        registry.endpoint(scopeID: key.scopeID, host: key.host, isPrivate: key.isPrivate)
    }

    private func readyWebsiteEndpoint(for key: AccessHostStoreKey) -> AccessManagedProxyEndpoint? {
        guard let endpoint = endpoint(for: key), endpoint.state == .ready,
              publisher.currentEndpoint == endpoint else { return nil }
        return endpoint
    }

    private func readyLandingEndpoint(_ landing: LandingRoute, tab: BrowserTab) -> AccessManagedProxyEndpoint? {
        let key = landing.destination
        if let ready = readyWebsiteEndpoint(for: key) { return ready }
        guard let bound = tab.boundHostName.flatMap({ try? AccessSiteHost($0) }), bound != key.host,
              let ready = readyWebsiteEndpoint(for: .init(scopeID: key.scopeID, host: bound, isPrivate: key.isPrivate)),
              ready.generation >= (endpoint(for: key)?.generation ?? 0) else { return nil }
        return ready
    }

    private func legacyStoreBinding(tab: BrowserTab, key: AccessHostStoreKey) -> WKWebsiteDataStore? {
        let tabID = tab.instanceID.uuidString
        guard tab.boundHostName == key.host.rawValue, websiteBindings[tabID] != key,
              registry.isBound(tabID, to: key),
              let store = registry.store(scopeID: key.scopeID, host: key.host, isPrivate: key.isPrivate),
              store === tab.websiteDataStore else { return nil }
        return store
    }

    private func navigationIntent(tab: BrowserTab, key: AccessHostStoreKey, route: WebsiteRoute) -> AccessProxyIntentState {
        switch route {
        case .original, .indeterminate: .off
        case .service, .landing: .on
        case .legacy: legacyRouteIntent(tab: tab, key: key)
        }
    }

    private enum RoutePreparation: Equatable {
        case website(WebsiteRoute)
        case legacyRequired
        case legacyOptional
    }

    private func routePreparation(tab: BrowserTab, url: URL, key: AccessHostStoreKey) -> RoutePreparation? {
        let route = websiteRoute(tab: tab, url: url, key: key)
        switch route {
        case .original, .indeterminate:
            return nil
        case .service:
            return readyWebsiteEndpoint(for: key) == nil ? route.requiredPreparation : nil
        case .landing(let landing):
            return readyLandingEndpoint(landing, tab: tab) == nil ? route.requiredPreparation : nil
        case .legacy:
            guard endpoint(for: key)?.state != .ready ||
                (websiteOnlyEndpoints.contains(key) && legacyRouteIntent(tab: tab, key: key) != .on) else { return nil }
            if intents[key] == .on { return .legacyRequired }
            let bound = tab.boundHostName == key.host.rawValue
            if bound && legacyRouteIntent(tab: tab, key: key) == .on && hasIndependentRoute(key) {
                return .legacyRequired
            }
            guard usesDefaultRoute(key), bound || tab.canTryDefaultRoute(for: url) else { return nil }
            return bound ? .legacyRequired : .legacyOptional
        }
    }

    func requiresProxyPreparation(tab: BrowserTab, url: URL) -> Bool {
        guard let host = Self.httpHost(url) else { return false }
        let key = AccessHostStoreKey(scopeID: tab.browsingScopeID, host: host, isPrivate: tab.profile.isPrivate)
        return routePreparation(tab: tab, url: url, key: key) != nil
    }

    func canSendMainFrame(tab: BrowserTab, url: URL) -> Bool {
        guard hasValidRouteOwner(for: tab) else { return false }
        guard let host = Self.httpHost(url) else { return true }
        let key = AccessHostStoreKey(scopeID: tab.browsingScopeID, host: host, isPrivate: tab.profile.isPrivate)
        switch websiteRoute(tab: tab, url: url, key: key) {
        case .service, .landing:
            return tab.boundHostName == host.rawValue && readyWebsiteEndpoint(for: key) != nil
                && registry.isBound(tab.instanceID.uuidString, to: key)
        case .indeterminate:
            return false
        case .original, .legacy:
            // A deferred landing must realign before it can use another route.
            return tab.parentForProxyLanding(url) == nil
        }
    }

    func prepareProxyNavigation(tab: BrowserTab, request: URLRequest) -> Bool {
        guard let url = request.url, let host = Self.httpHost(url) else { return false }
        let key = AccessHostStoreKey(scopeID: tab.browsingScopeID, host: host, isPrivate: tab.profile.isPrivate)
        guard let preparation = routePreparation(tab: tab, url: url, key: key) else { return false }
        let optional = preparation == .legacyOptional
        // Website and optional holds keep the previous document until store
        // alignment. Required legacy holds retire it before preparation.
        let pending = preparation == .legacyRequired ? tab.holdForProxy(request) : tab.holdForOptionalProxy(request)
        guard let pending else { return false }
        _ = beginPrepare(for: tab, key: key, failure: nil, trigger: optional ? .automatic : .userRetry,
                         addressNavigation: pending, routePreparation: preparation)
        return true
    }

    func attachment(tab: BrowserTab, host: AccessSiteHost) -> AccessProxyAttachment {
        guard tab.boundHostName == host.rawValue else { return .notAttached }
        let endpoint = registry.endpoint(
            scopeID: tab.browsingScopeID,
            host: host,
            isPrivate: tab.profile.isPrivate
        )?.state ?? .unavailable
        if endpoint == .ready { return .ready }
        return .attachedUnavailable
    }

    func snapshot(for tab: BrowserTab, forLocationControl: Bool = false) -> AccessSiteProxyToggleSnapshot {
        _ = revision
        let displayedHost = forLocationControl ? locationControlHost(for: tab) : host(for: tab)
        guard let host = displayedHost else {
            var snapshot = AccessSiteProxyToggleSnapshot()
            snapshot.intentStatus = .noTrustedSite
            return snapshot
        }
        let key = AccessHostStoreKey(
            scopeID: tab.browsingScopeID,
            host: host,
            isPrivate: tab.profile.isPrivate
        )
        let inherited = tab.boundHostName == host.rawValue && tab.proxyLandingParent != nil
        let attachment = attachment(tab: tab, host: host)
        let intentOn = websitePrivacyEnabled(for: key) || inherited || usesDefaultRoute(key) && attachment != .notAttached
        var snapshot = AccessSiteProxyToggleSnapshot()
        snapshot.hasTrustedSite = true
        snapshot.host = host
        let autoListed = !ruleGroups.groups(
            containing: host,
            scopeID: key.scopeID,
            isPrivate: key.isPrivate
        ).isEmpty
        let boundUnavailable = attachment == .attachedUnavailable
        snapshot.intent = intentOn ? .allow : .off
        snapshot.toggleEnabled = true
        snapshot.toggleOn = intentOn
        // Bound-but-failed auto recovery must not look idle just because manual intent is off.
        if attachment == .ready {
            snapshot.connection = .ready
        } else if operations.values.contains(where: {
            $0.tabID == tab.instanceID.uuidString && $0.key == key && $0.state == .preparing
        }) {
            snapshot.connection = .connecting
        } else if intentOn || (boundUnavailable && (autoListed || executingTabs[tab.instanceID.uuidString] == key)) {
            snapshot.connection = .unavailable
        } else {
            snapshot.connection = .idle
        }
        snapshot.connectionStatus = AccessSiteProxyToggleModel.connectionStatus(snapshot.connection)
        snapshot.intentStatus = AccessSiteProxyToggleModel.intentStatus(
            intent: snapshot.intent,
            connection: snapshot.connection,
            attachment: attachment
        )
        snapshot.attachment = attachment
        if boundUnavailable, intentOn || autoListed || executingTabs[tab.instanceID.uuidString] == key {
            // Auto-bound failures must still explain the broken proxy path when
            // manual intent is off (attachmentLine used to no-op on `.off`).
            snapshot.failureReason = AccessSiteProxyToggleModel.attachmentLine(
                for: .attachedUnavailable,
                intent: intentOn ? .allow : .off
            )
        }
        let listed = ruleGroups.groups(
            containing: host,
            scopeID: key.scopeID,
            isPrivate: key.isPrivate
        )
        snapshot.autoRecoveryEnabled = !listed.isEmpty
        snapshot.autoRecoveryLine = autoRecoveryLine(for: tab, host: host, listed: listed)
        snapshot.showsDebugSiteGroupDetails = showsDebugSiteGroupDetails
        if showsDebugSiteGroupDetails {
            snapshot.debugMemberHosts = listed.first?.memberHosts.map(\.rawValue) ?? []
            let tabID = tab.instanceID.uuidString
            if probeSiteHosts[tabID] == host {
                snapshot.probeSuggestionLines = probeLines[tabID] ?? []
            } else {
                snapshot.probeSuggestionLines = []
            }
            snapshot.probeBusy = probeBusyTabs.contains(tabID)
                && (probeSiteHosts[tabID] == nil || probeSiteHosts[tabID] == host)
        }
        return snapshot
    }

    /// Preflight body-less writes before touching the registry or releasing the live document.
    func wouldSwitchStore(tab: BrowserTab, url: URL) -> Bool {
        guard hasValidRouteOwner(for: tab) else { return false }
        guard let host = Self.httpHost(url) else { return tab.boundHostName != nil }
        let key = AccessHostStoreKey(scopeID: tab.browsingScopeID, host: host, isPrivate: tab.profile.isPrivate)
        let bound = tab.boundHostName == host.rawValue
        let route = websiteRoute(tab: tab, url: url, key: key)
        let intent = navigationIntent(tab: tab, key: key, route: route)
        if bound {
            return intent != .on
        }
        if tab.boundHostName != nil { return true }
        return intent == .on
    }

    func dataStoreForMainFrame(tab: BrowserTab, url: URL) -> WKWebsiteDataStore? {
        guard !tab.isDisposed, hasValidRouteOwner(for: tab) else { return nil }
        let bound = tab.boundHostName.flatMap { try? AccessSiteHost($0) }
        let tabID = tab.instanceID.uuidString
        guard let host = Self.httpHost(url) else {
            if let bound, let release = registry.retainRetiringDocument(scopeID: tab.browsingScopeID,
                host: bound, isPrivate: tab.profile.isPrivate) {
                tab.afterCurrentDocumentBecomesInert(release)
            }
            registry.unbind(tabID)
            websiteBindings.removeValue(forKey: tabID)
            landingBindings.removeValue(forKey: tabID)
            return nil
        }
        let key = AccessHostStoreKey(
            scopeID: tab.browsingScopeID,
            host: host,
            isPrivate: tab.profile.isPrivate
        )
        let route = websiteRoute(tab: tab, url: url, key: key)
        guard route != .indeterminate else { return nil }
        let intent = navigationIntent(tab: tab, key: key, route: route)
        if route == .service && readyWebsiteEndpoint(for: key) == nil { return nil }
        if case .landing(let landing) = route {
            // Leave the displayed store alone until the destination owns a ready entry.
            guard let ready = readyLandingEndpoint(landing, tab: tab),
                  ready == endpoint(for: key) || retainLandingEndpoint(ready, for: key) else { return nil }
            if accelerationAllowed(for: key), !defaultProtectedHosts.contains(key) {
                websiteOnlyEndpoints.insert(key)
            }
        } else if route != .service || bound != host || landingRoute(tab: tab, url: url, destination: key) == nil {
            tab.clearProxyLanding()
            landingBindings.removeValue(forKey: tabID)
        }
        if let bound, bound != host || intent != .on,
           let release = registry.retainRetiringDocument(scopeID: key.scopeID, host: bound, isPrivate: key.isPrivate) {
            tab.afterCurrentDocumentBecomesInert(release)
        }
        // Store selection can attach a new tab to an existing host store.
        let previousLegacyStore = route.requiredPreparation == nil ? nil : legacyStoreBinding(tab: tab, key: key)
        let store = registry.storeForTab(
            tabID: tabID,
            scopeID: tab.browsingScopeID,
            isPrivate: tab.profile.isPrivate,
            targetHost: host,
            boundHost: bound,
            intent: intent
        )
        if let store {
            if case .landing(let landing) = route { landingBindings[tabID] = landing }
            switch route {
            case .service, .landing:
                if accelerationAllowed(for: key) {
                    websiteBindings[tabID] = store === previousLegacyStore ? nil : key
                }
            default:
                websiteBindings.removeValue(forKey: tabID)
            }
            if route == .legacy, usesDefaultRoute(key), !websiteOnlyEndpoints.contains(key),
               endpoint(for: key)?.state == .ready {
                defaultProtectedHosts.insert(key)
            }
        } else {
            websiteBindings.removeValue(forKey: tabID)
            landingBindings.removeValue(forKey: tabID)
        }
        return store
    }

    /// A landing store owns its entry independently of the idle redirect source.
    func retainLandingEndpoint(_ endpoint: AccessManagedProxyEndpoint, for key: AccessHostStoreKey) -> Bool {
        guard endpoint.state == .ready, endpoint.hasAdmittedBinding else { return false }
        if let current = registry.endpoint(scopeID: key.scopeID, host: key.host, isPrivate: key.isPrivate),
           current.generation > endpoint.generation { return false }
        return publisher.retain(endpoint, for: key) {
            registry.setEndpoint(endpoint, scopeID: key.scopeID, host: key.host, isPrivate: key.isPrivate)
        }
    }

    @discardableResult
    func setAutoRecoveryEnabled(
        _ enabled: Bool,
        for tab: BrowserTab,
        members: [AccessSiteHost] = []
    ) -> AccessAutoRecoveryChange {
        guard let host = host(for: tab) else { return .rejected(.noTrustedHost) }
        let scopeID = tab.browsingScopeID
        let isPrivate = tab.profile.isPrivate
        if !enabled {
            if let own = ruleGroups.group(primaryHost: host, scopeID: scopeID, isPrivate: isPrivate) {
                revokeGroup(own)
            } else {
                for group in ruleGroups.groups(containing: host, scopeID: scopeID, isPrivate: isPrivate) {
                    _ = removeMember(host, from: group)
                }
            }
            // Auto-recovery off must not revoke an independently armed manual proxy.
            revision &+= 1
            return .revoked
        }
        let prior = ruleGroups.group(primaryHost: host, scopeID: scopeID, isPrivate: isPrivate)
        switch publishGroup(
            scopeID: scopeID,
            isPrivate: isPrivate,
            primary: host,
            members: members,
            prior: prior
        ) {
        case .rejected(let reason):
            return .rejected(reason)
        case .armed(let group):
            revision &+= 1
            guard tab.loadingErrorAllowsProxyRetry,
                  let failure = tab.lastMainFrameFailure,
                  let failedHost = Self.httpHost(failure.url),
                  group.contains(failedHost),
                  let operationID = beginPrepare(
                    for: tab,
                    key: AccessHostStoreKey(scopeID: scopeID, host: failedHost, isPrivate: isPrivate),
                    failure: failure,
                    trigger: .userToggle,
                    authorization: AccessAutoRecoveryGrant(groupID: group.groupID, generation: group.generation)
                  )
            else {
                return .armed(group)
            }
            return .recovering(operationID)
        case .recovering, .revoked, .unchanged:
            return .unchanged
        }
    }

    @discardableResult
    func appendAutoRecoveryMember(_ member: AccessSiteHost, for tab: BrowserTab) -> AccessAutoRecoveryChange {
        guard let host = host(for: tab) else { return .rejected(.noTrustedHost) }
        guard let prior = ruleGroups.group(
            primaryHost: host,
            scopeID: tab.browsingScopeID,
            isPrivate: tab.profile.isPrivate
        ) else {
            return .rejected(.noTrustedHost)
        }
        let change = publishGroup(
            scopeID: prior.scopeID,
            isPrivate: prior.isPrivate,
            primary: prior.primaryHost,
            members: prior.memberHosts + [member],
            prior: prior
        )
        if case .armed = change { revision &+= 1 }
        return change
    }

    /// Keeps a previously published group, including one that is too wide for the current channel.
    func preserveAutoRecoveryGroup(_ group: AccessSiteRuleGroup) {
        _ = ruleGroups.publish(group)
        revision &+= 1
    }

    func autoRecoveryGroups(for tab: BrowserTab) -> [AccessSiteRuleGroup] {
        guard let host = host(for: tab) else { return [] }
        return ruleGroups.groups(
            containing: host,
            scopeID: tab.browsingScopeID,
            isPrivate: tab.profile.isPrivate
        )
    }

    /// DEV/Alpha suggestion only. Does not prepare an entry, open a store, or run during navigation.
    func suggestProbe(
        candidates: [AccessSiteHost],
        scopeID: String? = nil,
        isPrivate: Bool? = nil
    ) -> AccessSiteProbePlan? {
        probeInvocationCount += 1
        // Keep every candidate in the plan; per-request recheck (scoped) decides skips.
        // Do not leak another browsing scope's proxy arm into this suggestion set.
        _ = scopeID
        _ = isPrivate
        return AccessSiteProbePlan.make(
            candidates: candidates,
            alreadyRequiringProxy: [],
            channel: releaseChannel
        )
    }

    /// DEV/Alpha manual probe. Suggestions only; does not publish groups or prepare entries.
    @discardableResult
    func runProbe(for tab: BrowserTab, candidates: [AccessSiteHost]? = nil) -> Bool {
        guard !tab.isDisposed, showsDebugSiteGroupDetails else { return false }
        let tabID = tab.instanceID.uuidString
        let currentHost = host(for: tab)
        if probeBusyTabs.contains(tabID) {
            // Busy only blocks another probe of the same site. A new host may start.
            if probeSiteHosts[tabID] == nil || probeSiteHosts[tabID] == currentHost {
                return false
            }
            probeTasks[tabID]?.cancel()
            probeBusyTabs.remove(tabID)
        }
        let groups = autoRecoveryGroups(for: tab)
        let plannedCandidates: [AccessSiteHost]
        if let candidates, !candidates.isEmpty {
            plannedCandidates = candidates
        } else if let members = groups.first?.memberHosts, !members.isEmpty {
            plannedCandidates = members
        } else if let host = host(for: tab) {
            plannedCandidates = [host]
        } else {
            return false
        }
        let scopeID = tab.browsingScopeID
        let isPrivate = tab.profile.isPrivate
        guard let plan = suggestProbe(
            candidates: plannedCandidates,
            scopeID: scopeID,
            isPrivate: isPrivate
        ) else { return false }
        probeBusyTabs.insert(tabID)
        let generation = (probeGenerations[tabID] ?? 0) + 1
        probeGenerations[tabID] = generation
        let siteHost = host(for: tab)
        probeLines[tabID] = nil
        probeSiteHosts[tabID] = siteHost
        revision &+= 1
        let runner = probeRunner
        probeTasks[tabID]?.cancel()
        probeTasks[tabID] = Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await runner.run(
                plan: plan,
                alreadyRequiringProxy: [],
                requiresProxy: { [weak self] host in
                    await MainActor.run {
                        self?.hostRequiresProxy(
                            host,
                            scopeID: scopeID,
                            isPrivate: isPrivate
                        ) ?? false
                    }
                }
            )
            guard !Task.isCancelled else { return }
            guard self.probeGenerations[tabID] == generation else { return }
            if let siteHost, self.host(for: tab) != siteHost {
                // In-place navigation left the originating site; drop stale suggestions.
                self.probeLines[tabID] = nil
                self.probeSiteHosts[tabID] = nil
            } else {
                self.probeLines[tabID] = report.suggestionLines
                if let siteHost {
                    self.probeSiteHosts[tabID] = siteHost
                }
            }
            self.probeBusyTabs.remove(tabID)
            self.probeTasks[tabID] = nil
            self.revision &+= 1
        }
        return true
    }

    private func hostRequiresProxy(
        _ host: AccessSiteHost,
        scopeID: String,
        isPrivate: Bool
    ) -> Bool {
        let key = AccessHostStoreKey(scopeID: scopeID, host: host, isPrivate: isPrivate)
        if let choice = websiteChoice(for: key) { return choice == .service }
        if accelerationAllowed(for: key), websiteAccelerationMode == .smart, intents[key] != .off,
           !explicitDirect.contains(key), let url = URL(string: "https://\(host.rawValue)/"),
           smartMatch(url) == .managed { return true }
        if BrowserSession.openTabs().contains(where: {
            $0.browsingScopeID == scopeID && $0.profile.isPrivate == isPrivate &&
                $0.boundHostName == host.rawValue && $0.proxyLandingParent != nil
        }) { return true }
        if websitePrivacyEnabled(for: key) { return true }
        if executing.contains(key) { return true }
        if executingTabs.values.contains(key) { return true }
        return operations.values.contains {
            $0.key == key && ($0.state == .preparing || $0.state == .sent)
        }
    }

    private func cancelProbes(scopeID: String? = nil, isPrivate: Bool? = nil, tabID: String? = nil) {
        if let tabID {
            probeTasks[tabID]?.cancel()
            probeTasks[tabID] = nil
            probeBusyTabs.remove(tabID)
            probeLines[tabID] = nil
            probeSiteHosts[tabID] = nil
            probeGenerations[tabID, default: 0] += 1
            return
        }
        let open = Dictionary(uniqueKeysWithValues: BrowserSession.openTabs().map { ($0.instanceID.uuidString, $0) })
        for id in Array(probeBusyTabs) + Array(probeTasks.keys) + Array(probeLines.keys) {
            if let tab = open[id] {
                if let scopeID, tab.browsingScopeID != scopeID { continue }
                if let isPrivate, tab.profile.isPrivate != isPrivate { continue }
            } else if scopeID != nil || isPrivate != nil {
                // Closed tab results still clear when ending a private scope.
                if isPrivate != true { continue }
            }
            probeTasks[id]?.cancel()
            probeTasks[id] = nil
            probeBusyTabs.remove(id)
            probeLines[id] = nil
            probeSiteHosts[id] = nil
            probeGenerations[id, default: 0] += 1
        }
    }

    var showsDebugSiteGroupDetails: Bool {
        releaseChannel == .dev || releaseChannel == .alpha
    }

    func mainFrameFailed(tab: BrowserTab, failure: BrowserMainFrameFailure, error: NSError) {
        guard !tab.isDisposed, hasValidRouteOwner(for: tab) else { return }
        guard BrowserNavigationFailure.isRecoverableNetworkFailure(error) else { return }
        guard failure.recoveryOperationID == nil else { return }
        guard !failure.hasReplayableBody else { return }
        guard let host = Self.httpHost(failure.url) else { return }
        let method = failure.method.uppercased()
        guard method == "GET" || method == "HEAD" else { return }
        let key = AccessHostStoreKey(
            scopeID: tab.browsingScopeID,
            host: host,
            isPrivate: tab.profile.isPrivate
        )
        // Consumed / in-flight / finished tickets for the same failure must not re-arm.
        guard websiteChoice(for: key) != .original, !explicitDirect.contains(key) else { return }
        let route = websiteRoute(tab: tab, url: failure.url, key: key)
        if route == .service { return }
        if case .landing = route { return }
        if operations.values.contains(where: {
            $0.tabID == tab.instanceID.uuidString && $0.failureID == failure.failureID
        }) {
            return
        }
        if operations.values.contains(where: {
            $0.tabID == tab.instanceID.uuidString
                && $0.navigationID == failure.navigationID
                && ($0.state == .preparing || $0.state == .sent || $0.state == .completed)
        }) {
            return
        }
        let operationID = UUID()
        var ticket = AccessNavigationRetryTicket(
            tabID: tab.instanceID.uuidString,
            scopeID: tab.browsingScopeID,
            navigationID: failure.navigationID,
            host: host,
            url: failure.url,
            method: method,
            hasReplayableBody: failure.hasReplayableBody,
            switchGeneration: registry.switchGeneration,
            failureID: failure.failureID,
            operationID: operationID,
            trigger: .automatic
        )
        let ready = registry.endpoint(
            scopeID: key.scopeID,
            host: key.host,
            isPrivate: key.isPrivate
        )?.state == .ready && intents[key] == .on
        let decision = AccessNavigationRetryPolicy.evaluate(
            ticket: ticket,
            currentTabID: tab.instanceID.uuidString,
            currentNavigationID: failure.navigationID,
            currentSwitchGeneration: registry.switchGeneration,
            endpointReady: ready,
            currentFailureID: failure.failureID
        )
        guard decision == .consumeAndRetry else {
            if let group = executableGroup(containing: key) {
                _ = beginPrepare(
                    for: tab,
                    key: key,
                    failure: failure,
                    trigger: .automatic,
                    authorization: AccessAutoRecoveryGrant(groupID: group.groupID, generation: group.generation)
                )
                return
            }
            guard route != .original else { return }
            operations[operationID] = RecoveryOperation(
                id: operationID,
                key: key,
                hostRevision: hostRevisions[key] ?? 0,
                tabID: tab.instanceID.uuidString,
                failureID: failure.failureID,
                navigationID: failure.navigationID,
                deadline: clock.now,
                state: .failed,
                ticket: ticket,
                authorization: nil
            )
            return
        }
        ticket = AccessNavigationRetryPolicy.consume(ticket)
        operations[operationID] = RecoveryOperation(
            id: operationID,
            key: key,
            hostRevision: hostRevisions[key] ?? 0,
            tabID: tab.instanceID.uuidString,
            failureID: failure.failureID,
            navigationID: failure.navigationID,
            deadline: clock.now,
            state: .sent,
            ticket: ticket,
            authorization: nil
        )
        phases[tab.instanceID.uuidString] = .sent
        send(ticket, to: tab)
    }

    enum FailureProxyRetry: Equatable {
        case unavailable
        case optional
        case required
    }

    func failureProxyRetry(for tab: BrowserTab) -> FailureProxyRetry {
        guard let (failure, key) = failedProxyTarget(for: tab),
              let route = manualProxyRoute(tab: tab, url: failure.url, key: key) else { return .unavailable }
        if navigationIntent(tab: tab, key: key, route: route) == .on { return .required }
        return offersLocationService ? .optional : .unavailable
    }

    @discardableResult
    func retryViaProxy(tab: BrowserTab) -> UUID? {
        startRecovery(tab: tab, trigger: .userRetry)
    }

    enum PendingAddressProxyState: Equatable {
        case unavailable
        case available
        case preparing
    }

    func pendingAddressProxyState(tab: BrowserTab, pending: BrowserPendingAddressNavigation) -> PendingAddressProxyState {
        switch pendingAddressProxyAction(tab: tab, pending: pending) {
        case .prepare: .available
        case .reuse: .preparing
        case nil: .unavailable
        }
    }

    func isPreparingAddressProxy(tab: BrowserTab) -> Bool {
        guard let pending = tab.pendingAddressNavigation else { return false }
        return pendingAddressProxyState(tab: tab, pending: pending) == .preparing
    }

    /// A visible address choice authorizes only this safe, still-pending target.
    /// No failed-navigation ticket or trusted committed host is synthesized.
    @discardableResult
    func openPendingAddressViaProxy(tab: BrowserTab, pending: BrowserPendingAddressNavigation) -> UUID? {
        switch pendingAddressProxyAction(tab: tab, pending: pending) {
        case .reuse(let operationID):
            return operationID
        case .prepare(let key, let preparation):
            guard tab.ensureProxyHold(pending) else { return nil }
            return beginPrepare(for: tab, key: key, failure: nil, trigger: .userRetry, addressNavigation: pending,
                                routePreparation: preparation)
        case nil:
            return nil
        }
    }

    private enum PendingAddressProxyAction {
        case prepare(AccessHostStoreKey, RoutePreparation?)
        case reuse(UUID)
    }

    private func pendingAddressProxyAction(tab: BrowserTab, pending: BrowserPendingAddressNavigation) -> PendingAddressProxyAction? {
        guard tab.hostCoordinator === self, tab.matchesPendingAddressNavigation(pending),
              let host = Self.httpHost(pending.url) else { return nil }
        let key = AccessHostStoreKey(scopeID: tab.browsingScopeID, host: host, isPrivate: tab.profile.isPrivate)
        let tabID = tab.instanceID.uuidString
        // An authorized hold can already be preparing a safe HEAD or a required route.
        if let existing = operations.values.first(where: {
            $0.tabID == tabID && $0.addressNavigation == pending && $0.state == .preparing
        }) {
            guard existing.key == key, existing.hostRevision == (hostRevisions[key] ?? 0),
                  clock.now < existing.deadline, authorizationStillValid(existing, tab: tab) else { return nil }
            return .reuse(existing.id)
        }
        guard offersLocationService, tab.safeRouteReloadRequest?.httpMethod == "GET",
              let route = manualProxyRoute(tab: tab, url: pending.url, key: key) else { return nil }
        return .prepare(key, route.requiredPreparation)
    }

    private func failedProxyTarget(for tab: BrowserTab) -> (BrowserMainFrameFailure, AccessHostStoreKey)? {
        guard tab.hostCoordinator === self, !tab.isLoading, tab.loadingErrorAllowsProxyRetry,
              let failure = tab.lastMainFrameFailure, let request = tab.safeRouteReloadRequest,
              request.url == failure.url, request.httpMethod == failure.method,
              let host = Self.httpHost(failure.url) else { return nil }
        let key = AccessHostStoreKey(
            scopeID: tab.browsingScopeID,
            host: host,
            isPrivate: tab.profile.isPrivate
        )
        return (failure, key)
    }

    private func manualProxyRoute(tab: BrowserTab, url: URL, key: AccessHostStoreKey) -> WebsiteRoute? {
        // A Smart-mode miss can still opt into location privacy. An exact original choice takes precedence.
        guard hasValidRouteOwner(for: tab), websiteChoice(for: key) != .original else { return nil }
        let route = websiteRoute(tab: tab, url: url, key: key)
        // An inherited landing can retry or resume only through an authorized route.
        guard route.requiredPreparation != nil || tab.parentForProxyLanding(url) == nil else { return nil }
        return route
    }

    private func startRecovery(tab: BrowserTab, trigger: AccessNavigationRetryTrigger) -> UUID? {
        guard let (failure, key) = failedProxyTarget(for: tab) else { return nil }
        return beginPrepare(for: tab, key: key, failure: failure, trigger: trigger)
    }

    func retryReadyTabs(operationID: UUID) {
        guard var operation = operations[operationID], operation.state == .preparing || operation.state == .sent else { return }
        guard var ticket = operation.ticket else { return }
        guard let tab = tabOwning(operation) else { return }
        guard let failure = tab.lastMainFrameFailure, failure.failureID == ticket.failureID else { return }
        guard failure.navigationID == ticket.navigationID else { return }
        guard hostRevisions[operation.key] ?? 0 == operation.hostRevision else { return }
        guard authorizationStillValid(operation, tab: tab) else { return }
        let ready = if case .website? = operation.routePreparation {
            readyWebsiteEndpoint(for: operation.key) != nil
        } else {
            endpoint(for: operation.key)?.state == .ready
        }
        let decision = AccessNavigationRetryPolicy.evaluate(
            ticket: ticket,
            currentTabID: tab.instanceID.uuidString,
            currentNavigationID: failure.navigationID,
            currentSwitchGeneration: registry.switchGeneration,
            endpointReady: ready,
            currentFailureID: failure.failureID
        )
        guard decision == .consumeAndRetry else { return }
        ticket = AccessNavigationRetryPolicy.consume(ticket)
        operation.ticket = ticket
        operation.state = .sent
        operations[operationID] = operation
        timeoutTasks.removeValue(forKey: operationID)?.cancel()
        if operation.authorization != nil || intents[operation.key] == .on {
            executing.insert(operation.key)
            executingTabs[operation.tabID] = operation.key
        }
        phases[operation.tabID] = .sent
        send(ticket, to: tab)
        publisher.cancel(operationID: operationID)
    }

    func pendingRecoveryInvalidated(tab: BrowserTab) {
        let tabID = tab.instanceID.uuidString
        let affectedKeys = Set(operations.values.filter { $0.tabID == tabID }.map(\.key))
        for (id, operation) in operations where operation.tabID == tabID {
            operations.removeValue(forKey: id)
            timeoutTasks.removeValue(forKey: id)?.cancel()
            publisher.cancel(operationID: id)
        }
        for key in affectedKeys { releaseUnstoredConsumerIfUnused(key) }
        tab.invalidateDeferredDocumentLoad()
        if !operations.values.contains(where: { $0.tabID == tabID && $0.state == .preparing }) {
            if phases[tabID] == .preparing { phases[tabID] = nil }
        }
        revision &+= 1
    }

    private func releaseUnstoredConsumerIfUnused(_ key: AccessHostStoreKey) {
        guard registry.store(scopeID: key.scopeID, host: key.host, isPrivate: key.isPrivate) == nil,
              !operations.values.contains(where: { $0.key == key && ($0.state == .preparing || $0.state == .sent) })
        else { return }
        registry.removeUnstoredEndpoint(for: key)
        websiteOnlyEndpoints.remove(key)
        publisher.release(for: key)
    }

    func tabClosed(_ tab: BrowserTab) {
        pendingRecoveryInvalidated(tab: tab)
        registry.unbind(tab.instanceID.uuidString)
        executingTabs.removeValue(forKey: tab.instanceID.uuidString)
        websiteBindings.removeValue(forKey: tab.instanceID.uuidString)
        landingBindings.removeValue(forKey: tab.instanceID.uuidString)
        cancelProbes(tabID: tab.instanceID.uuidString)
        phases.removeValue(forKey: tab.instanceID.uuidString)
        probeGenerations.removeValue(forKey: tab.instanceID.uuidString)
    }

    func willRestoreOriginalStore(tab: BrowserTab) {
        guard let finish = registry.detachTab(tab.instanceID.uuidString, from: tab.websiteDataStore)
        else { return }
        tab.afterCurrentDocumentBecomesInert(finish)
    }

    func ordinaryHostStores() -> [WKWebsiteDataStore] {
        registry.ordinaryStores()
    }

    func endPrivateSession(scopeID: String) {
        for group in ruleGroups.revokeAll(scopeID: scopeID, isPrivate: true) {
            invalidateOperations(groupID: group.groupID)
        }
        executing = executing.filter { !($0.isPrivate && $0.scopeID == scopeID) }
        executingTabs = executingTabs.filter { !($0.value.isPrivate && $0.value.scopeID == scopeID) }
        for key in hostRevisions.keys where key.isPrivate && key.scopeID == scopeID {
            hostRevisions[key, default: 0] += 1
        }
        // Release every private consumer for this scope, including already-sent ones.
        var releasedKeys = Set<AccessHostStoreKey>()
        for (id, operation) in operations where operation.key.isPrivate && operation.key.scopeID == scopeID {
            if operation.state == .preparing || operation.state == .sent {
                var cancelled = operation
                cancelled.state = .cancelled
                operations[id] = cancelled
                publisher.cancel(operationID: id)
            }
            if releasedKeys.insert(operation.key).inserted {
                publisher.release(for: operation.key)
            }
            executingTabs.removeValue(forKey: operation.tabID)
            if let tab = BrowserSession.openTabs().first(where: { $0.instanceID.uuidString == operation.tabID }) {
                tab.invalidateDeferredDocumentLoad()
            }
        }
        cancelProbes(scopeID: scopeID, isPrivate: true)
        registry.endPrivateSession(scopeID: scopeID)
        intents = intents.filter { !($0.key.isPrivate && $0.key.scopeID == scopeID) }
        explicitDirect = explicitDirect.filter { !($0.isPrivate && $0.scopeID == scopeID) }
        for (id, operation) in operations where operation.key.isPrivate && operation.key.scopeID == scopeID {
            operations.removeValue(forKey: id)
            timeoutTasks.removeValue(forKey: id)?.cancel()
            phases.removeValue(forKey: operation.tabID)
        }
        hostRevisions = hostRevisions.filter { !($0.key.isPrivate && $0.key.scopeID == scopeID) }
        revision &+= 1
    }

    private func beginPrepare(
        for tab: BrowserTab,
        key: AccessHostStoreKey,
        failure: BrowserMainFrameFailure?,
        trigger: AccessNavigationRetryTrigger,
        authorization: AccessAutoRecoveryGrant? = nil,
        addressNavigation: BrowserPendingAddressNavigation? = nil,
        routePreparation: RoutePreparation? = nil
    ) -> UUID? {
        guard !tab.isDisposed, hasValidRouteOwner(for: tab) else { return nil }
        let method = (failure?.method ?? "GET").uppercased()
        let preparation: RoutePreparation?
        if let failure {
            guard !failure.hasReplayableBody, method == "GET" || method == "HEAD",
                  let route = manualProxyRoute(tab: tab, url: failure.url, key: key) else { return nil }
            if let existing = operations.values.first(where: {
                $0.tabID == tab.instanceID.uuidString && $0.failureID == failure.failureID && $0.state == .preparing
            }) { return existing.id }
            preparation = route.requiredPreparation
        } else {
            guard websiteChoice(for: key) != .original else { return nil }
            preparation = routePreparation
        }
        for (id, operation) in operations where operation.tabID == tab.instanceID.uuidString && operation.state != .preparing {
            operations.removeValue(forKey: id)
            timeoutTasks.removeValue(forKey: id)?.cancel()
        }
        let operationID = UUID()
        let deadline = clock.now + prepareBudget
        if addressNavigation == nil, authorization == nil, preparation == nil, intents[key] != .on {
            setProxyEnabled(true, host: key.host, scopeID: key.scopeID, isPrivate: key.isPrivate)
        }
        var ticket: AccessNavigationRetryTicket?
        if let failure {
            ticket = AccessNavigationRetryTicket(
                tabID: tab.instanceID.uuidString,
                scopeID: key.scopeID,
                navigationID: failure.navigationID,
                host: key.host,
                url: failure.url,
                method: method,
                hasReplayableBody: failure.hasReplayableBody,
                switchGeneration: registry.switchGeneration,
                failureID: failure.failureID,
                operationID: operationID,
                trigger: trigger
            )
        }
        operations[operationID] = RecoveryOperation(
            id: operationID,
            key: key,
            hostRevision: hostRevisions[key] ?? 0,
            tabID: tab.instanceID.uuidString,
            failureID: failure?.failureID,
            navigationID: failure?.navigationID,
            deadline: deadline,
            state: .preparing,
            ticket: ticket,
            authorization: authorization,
            addressNavigation: addressNavigation,
            routePreparation: preparation,
            policyEpoch: accelerationAllowed(for: key) ? policyEpoch : nil
        )
        phases[tab.instanceID.uuidString] = .preparing
        armTimeout(operationID: operationID, deadline: deadline)
        tab.afterProxyHoldDocumentStops { [weak self] in
            guard let self else { return }
            let publisher = self.publisher
            Task { @MainActor [weak self] in
                // A synchronous Stop/Off may run before this task gets its first turn.
                guard let operation = self?.operations[operationID], operation.state == .preparing else { return }
                if case .website? = operation.routePreparation, self?.tabOwning(operation) == nil {
                    self?.fail(operationID, reason: "这次准备已经失效")
                    return
                }
                // Cancellation or owner teardown can race the awaited preparation.
                // The task must remove its own waiter even when no operation survives.
                defer { publisher.cancel(operationID: operationID) }
                do {
                    let result = try await publisher.prepare(
                        AccessProxyEntryPrepareRequest(operationID: operationID, deadline: deadline)
                    )
                    self?.finishPrepare(operationID, result: result)
                } catch {
                    self?.fail(operationID, reason: (error as? AccessSiteSessionError)?.readableMessage ?? "代理没有就绪")
                }
            }
        }
        revision &+= 1
        return operationID
    }

    private func finishPrepare(_ operationID: UUID, result: AccessProxyEntryPrepareResult) {
        guard var operation = operations[operationID], operation.state == .preparing else { return }
        guard clock.now < operation.deadline else {
            fail(operationID, reason: "代理在 15 秒内没有就绪")
            return
        }
        guard hostRevisions[operation.key] ?? 0 == operation.hostRevision else {
            fail(operationID, reason: "这次准备已经失效")
            return
        }
        guard let tab = tabOwning(operation), authorizationStillValid(operation, tab: tab) else {
            fail(operationID, reason: "这次准备已经失效")
            return
        }
        if let pending = operation.addressNavigation, !tab.matchesPendingAddressNavigation(pending) {
            pendingRecoveryInvalidated(tab: tab)
            return
        }
        if let failureID = operation.failureID,
           (tab.lastMainFrameFailure?.failureID != failureID || tab.lastMainFrameFailure?.navigationID != operation.navigationID) {
            pendingRecoveryInvalidated(tab: tab)
            return
        }
        guard result.operationID == operationID,
              result.endpoint.generation >= (endpoint(for: operation.key)?.generation ?? 0),
              publisher.validateReady(result), retainLandingEndpoint(result.endpoint, for: operation.key) else {
            fail(operationID, reason: "代理入口还不能使用")
            return
        }
        if case .website? = operation.routePreparation {
            if accelerationAllowed(for: operation.key), !defaultProtectedHosts.contains(operation.key) {
                websiteOnlyEndpoints.insert(operation.key)
            }
        } else {
            websiteOnlyEndpoints.remove(operation.key)
        }
        if let pending = operation.addressNavigation {
            if operation.routePreparation == nil {
                // A user-invoked legacy address action keeps its established behavior.
                setProxyEnabled(true, host: operation.key.host, scopeID: operation.key.scopeID, isPrivate: operation.key.isPrivate)
                executing.insert(operation.key)
                executingTabs[operation.tabID] = operation.key
            }
            operation.state = .sent
            operations[operationID] = operation
            timeoutTasks.removeValue(forKey: operationID)?.cancel()
            phases[operation.tabID] = .sent
            _ = tab.openPendingAddressViaProxy(pending, recoveryOperationID: operationID)
            publisher.cancel(operationID: operationID)
        } else if operation.ticket != nil {
            retryReadyTabs(operationID: operationID)
        } else {
            operation.state = .completed
            operations[operationID] = operation
            timeoutTasks.removeValue(forKey: operationID)?.cancel()
            phases[operation.tabID] = nil
            publisher.cancel(operationID: operationID)
        }
        revision &+= 1
    }

    private func armTimeout(operationID: UUID, deadline: Duration) {
        let clock = self.clock
        timeoutTasks[operationID] = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard let self, self.operations[operationID]?.state == .preparing else { return }
            self.fail(operationID, reason: "代理在 15 秒内没有就绪")
            self.publisher.cancel(operationID: operationID)
        }
    }

    private func tabOwning(_ operation: RecoveryOperation) -> BrowserTab? {
        BrowserSession.openTabs().first {
            $0.instanceID.uuidString == operation.tabID && $0.hostCoordinator === self && !$0.isDisposed
                && $0.browsingScopeID == operation.key.scopeID && $0.profile.isPrivate == operation.key.isPrivate
        }
    }

    private func fail(_ operationID: UUID, reason: String) {
        timeoutTasks.removeValue(forKey: operationID)?.cancel()
        guard var operation = operations[operationID], operation.state == .preparing else { return }
        operation.state = .failed
        operations[operationID] = operation
        phases[operation.tabID] = .failed
        lastRecoveryFailure = reason
        if let pending = operation.addressNavigation, let tab = tabOwning(operation) {
            if operation.automaticFirstVisit, authorizationStillValid(operation, tab: tab),
               tab.boundHostName != operation.key.host.rawValue {
                tab.continueWithoutDefaultRoute(pending)
            } else {
                tab.failPendingProxyNavigation(pending)
            }
        }
        publisher.cancel(operationID: operationID)
        releaseUnstoredConsumerIfUnused(operation.key)
        revision &+= 1
    }

    private func cancelOperations(for key: AccessHostStoreKey, preservingDefaultPreparation: Bool) {
        for (id, operation) in operations where operation.key == key && operation.state == .preparing {
            if preservingDefaultPreparation && operation.automaticFirstVisit {
                // Group revocation only invalidates requests authorized by that group.
                // A held first visit keeps its own deadline and navigation identity.
                operations[id]?.hostRevision = hostRevisions[key, default: 0]
                continue
            }
            var cancelled = operation
            cancelled.state = .cancelled
            operations[id] = cancelled
            timeoutTasks.removeValue(forKey: id)?.cancel()
            publisher.cancel(operationID: id)
            phases[operation.tabID] = nil
            if let pending = operation.addressNavigation, let tab = tabOwning(operation),
               tab.matchesPendingAddressNavigation(pending) {
                // The original navigation was retired by holdForProxy. Cancelling
                // its preparation and deadline must also settle that UI hold.
                tab.failPendingProxyNavigation(pending)
                phases[operation.tabID] = .failed
            }
        }
    }

    private func applySharedState(_ endpoint: AccessManagedProxyEndpoint) {
        guard endpoint.state == .failed else { return }
        for (key, current) in registry.endpointSnapshot where current.identity == endpoint.identity && current.generation == endpoint.generation {
            registry.setEndpoint(
                endpoint,
                scopeID: key.scopeID,
                host: key.host,
                isPrivate: key.isPrivate
            )
            // Auto-group hosts must leave the "opened" product line when the entry fails.
            for (tabID, phase) in phases where phase == .sent {
                if let tab = BrowserSession.openTabs().first(where: { $0.instanceID.uuidString == tabID }),
                   let host = host(for: tab),
                   host == key.host,
                   tab.browsingScopeID == key.scopeID,
                   tab.profile.isPrivate == key.isPrivate {
                    phases[tabID] = .failed
                }
            }
            lastRecoveryFailure = AccessAutoRecoveryCopy.unavailable
        }
        revision &+= 1
    }

    func retireManagedDocuments(identity: String, finish: @escaping @MainActor () -> Void) {
        if var endpoint = registry.endpointSnapshot.values.first(where: { $0.identity == identity && $0.state == .ready }) {
            endpoint.state = .failed
            applySharedState(endpoint)
        }
        let bound = registry.retireListener(identity: identity, finish: finish)
        let tabs = BrowserSession.openTabs()
        for (key, tabIDs) in bound {
            guard let store = registry.store(scopeID: key.scopeID, host: key.host, isPrivate: key.isPrivate) else { continue }
            for tab in tabs where tab.websiteDataStore === store && tabIDs.contains(tab.instanceID.uuidString) {
                let tabID = tab.instanceID.uuidString
                tab.retireFailedProxyDocument { [registry] in
                    registry.acknowledgeRetiredTab(tabID, key: key, identity: identity)
                }
            }
        }
    }

    private func publishGroup(
        scopeID: String,
        isPrivate: Bool,
        primary: AccessSiteHost,
        members: [AccessSiteHost],
        prior: AccessSiteRuleGroup?
    ) -> AccessAutoRecoveryChange {
        let generation = (prior?.generation ?? 0) + 1
        let built: AccessSiteRuleGroup
        do {
            built = try AccessSiteRuleGroup(
                scopeID: scopeID,
                isPrivate: isPrivate,
                primaryHost: primary,
                memberHosts: members,
                generation: generation,
                channel: releaseChannel
            )
        } catch AccessSiteRuleGroupError.tooManyMembers {
            return .rejected(.tooManyMembers)
        } catch {
            return .rejected(.noTrustedHost)
        }
        guard built.isExecutable(on: releaseChannel) else {
            return .rejected(.notExecutable)
        }
        switch ruleGroups.publish(built, expectedPriorGeneration: prior?.generation ?? 0) {
        case .published:
            return .armed(built)
        case .rejectedStale:
            return .rejected(.staleCatalog)
        }
    }

    private func removeMember(
        _ host: AccessSiteHost,
        from group: AccessSiteRuleGroup
    ) -> AccessAutoRecoveryChange {
        let remaining = group.memberHosts.filter { $0 != host && $0 != group.primaryHost }
        let change = publishGroup(
            scopeID: group.scopeID,
            isPrivate: group.isPrivate,
            primary: group.primaryHost,
            members: remaining,
            prior: group
        )
        let key = AccessHostStoreKey(scopeID: group.scopeID, host: host, isPrivate: group.isPrivate)
        if !groupStillLists(key), !hasIndependentRoute(key) {
            releaseBinding(key, preservingDefaultPreparation: true)
        }
        return change
    }

    private func revokeGroup(_ group: AccessSiteRuleGroup) {
        guard let removed = ruleGroups.remove(groupID: group.groupID) else { return }
        invalidateOperations(groupID: removed.groupID)
        for host in removed.memberHosts {
            let key = AccessHostStoreKey(scopeID: removed.scopeID, host: host, isPrivate: removed.isPrivate)
            if !groupStillLists(key), !hasIndependentRoute(key) {
                releaseBinding(key, preservingDefaultPreparation: true)
            }
        }
    }

    private func invalidateOperations(groupID: UUID) {
        for (id, operation) in operations where operation.authorization?.groupID == groupID {
            let priorState = operation.state
            guard priorState == .preparing || priorState == .sent else { continue }
            var cancelled = operation
            cancelled.state = .cancelled
            operations[id] = cancelled
            if priorState == .preparing {
                publisher.cancel(operationID: id)
            }
            if executingTabs[operation.tabID] == operation.key {
                executingTabs.removeValue(forKey: operation.tabID)
            }
            if !groupStillLists(operation.key), intents[operation.key] != .on {
                executing.remove(operation.key)
            }
            if phases[operation.tabID] == .preparing || phases[operation.tabID] == .sent {
                phases[operation.tabID] = nil
            }
        }
    }

    private func groupStillLists(_ key: AccessHostStoreKey) -> Bool {
        !ruleGroups.groups(containing: key.host, scopeID: key.scopeID, isPrivate: key.isPrivate).isEmpty
    }

    private func executableGroup(containing key: AccessHostStoreKey) -> AccessSiteRuleGroup? {
        ruleGroups.groups(containing: key.host, scopeID: key.scopeID, isPrivate: key.isPrivate)
            .first { $0.isExecutable(on: releaseChannel) }
    }

    private func authorizationStillValid(_ operation: RecoveryOperation, tab: BrowserTab? = nil) -> Bool {
        if let epoch = operation.policyEpoch, epoch != policyEpoch { return false }
        guard websiteChoice(for: operation.key) != .original else { return false }
        if let preparation = operation.routePreparation {
            guard let tab, let url = operation.addressNavigation?.url ?? operation.ticket?.url else { return false }
            let route = websiteRoute(tab: tab, url: url, key: operation.key)
            switch preparation {
            case .website(let authorized):
                return route == authorized
            case .legacyRequired:
                return route == .legacy && legacyRouteIntent(tab: tab, key: operation.key) == .on
            case .legacyOptional:
                return route == .legacy && usesDefaultRoute(operation.key)
            }
        }
        if let pending = operation.addressNavigation {
            guard let tab, let route = manualProxyRoute(tab: tab, url: pending.url, key: operation.key) else { return false }
            return route.requiredPreparation == nil
        }
        guard let grant = operation.authorization else {
            return intents[operation.key] == .on
        }
        guard let group = ruleGroups.group(groupID: grant.groupID) else { return false }
        return group.generation == grant.generation
            && group.scopeID == operation.key.scopeID
            && group.isPrivate == operation.key.isPrivate
            && group.contains(operation.key.host)
            && group.isExecutable(on: releaseChannel)
    }

    private func hasIndependentRoute(_ key: AccessHostStoreKey) -> Bool {
        if let choice = websiteChoice(for: key) { return choice == .service }
        if explicitDirect.contains(key) || intents[key] == .off { return false }
        if accelerationAllowed(for: key), websiteAccelerationMode == .smart,
           let url = URL(string: "https://\(key.host.rawValue)/"),
           smartMatch(url) == .managed { return true }
        return intents[key] == .on || defaultProtectedHosts.contains(key)
    }

    private func releaseBinding(_ key: AccessHostStoreKey, preservingDefaultPreparation: Bool = false) {
        defaultProtectedHosts.remove(key)
        executing.remove(key)
        hostRevisions[key, default: 0] += 1
        cancelOperations(for: key, preservingDefaultPreparation: preservingDefaultPreparation)
        let tabs = BrowserSession.openTabs()
        for tab in tabs where tab.browsingScopeID == key.scopeID && tab.profile.isPrivate == key.isPrivate
            && tab.boundHostName == key.host.rawValue {
            if let release = registry.retainRetiringDocument(scopeID: key.scopeID, host: key.host, isPrivate: key.isPrivate) {
                tab.afterCurrentDocumentBecomesInert(release)
            }
        }
        registry.setProxyEnabled(false, scopeID: key.scopeID, host: key.host, isPrivate: key.isPrivate)
        let bound = registry.revoke(scopeID: key.scopeID, host: key.host, isPrivate: key.isPrivate)
        publisher.release(for: key)
        for tab in tabs where bound.contains(tab.instanceID.uuidString)
            || (tab.hostCoordinator === self && tab.browsingScopeID == key.scopeID
                && tab.profile.isPrivate == key.isPrivate && tab.proxyLandingParent == key.host.rawValue) {
            let tabID = tab.instanceID.uuidString
            let inheritsRevokedRoute = tab.proxyLandingParent == key.host.rawValue
            let interruptsLanding = tab.isLoading && operations.values.contains {
                $0.tabID == tabID && $0.landingParent == key && ($0.state == .preparing || $0.state == .sent)
            }
            if inheritsRevokedRoute, let rawHost = tab.boundHostName,
               let host = try? AccessSiteHost(rawHost), host != key.host {
                tab.clearProxyLanding()
                landingBindings.removeValue(forKey: tabID)
                let landing = AccessHostStoreKey(scopeID: key.scopeID, host: host, isPrivate: key.isPrivate)
                // Reevaluate this tab after withdrawing its inherited grant.
                let independentlyProtected = if accelerationAllowed(for: landing),
                    let url = URL(string: "https://\(host.rawValue)/") {
                    requiresProxy(tab: tab, url: url)
                } else {
                    hasIndependentRoute(landing) || executingTabs[tabID] == landing
                }
                if independentlyProtected {
                    if interruptsLanding { tab.pauseAfterWebsiteRouteChange(detachStore: false) }
                    continue
                }
                // The child owns a different store from the parent being revoked.
                if let release = registry.retainRetiringDocument(scopeID: key.scopeID, host: host, isPrivate: key.isPrivate) {
                    tab.afterCurrentDocumentBecomesInert(release)
                }
            }
            registry.unbind(tabID)
            websiteBindings.removeValue(forKey: tabID)
            landingBindings.removeValue(forKey: tabID)
            if executingTabs[tabID] == key { executingTabs.removeValue(forKey: tabID) }
            if !interruptsLanding, let pending = tab.pendingAddressNavigation, let target = Self.httpHost(pending.url),
               target != key.host, tab.detachStoreDuringProxyHold(pending) { continue }
            if inheritsRevokedRoute {
                tab.pauseAfterWebsiteRouteChange(detachStore: true)
            } else {
                tab.invalidateDeferredDocumentLoad()
                tab.rebindWebsiteDataStore(tab.originalWebsiteDataStore, host: nil)
            }
        }
        for operation in operations.values where operation.key == key {
            if executingTabs[operation.tabID] == key {
                executingTabs.removeValue(forKey: operation.tabID)
            }
        }
    }

    private func autoRecoveryLine(
        for tab: BrowserTab,
        host: AccessSiteHost,
        listed: [AccessSiteRuleGroup]
    ) -> String? {
        guard !listed.isEmpty else { return nil }
        switch phases[tab.instanceID.uuidString] {
        case .preparing:
            return AccessAutoRecoveryCopy.preparing
        case .failed:
            return AccessAutoRecoveryCopy.unavailable
        case .sent, nil:
            break
        }
        if tab.proxyRecoveryCommitted, tab.boundHostName == host.rawValue {
            let isPrimary = listed.contains { $0.primaryHost == host }
            return isPrimary ? AccessAutoRecoveryCopy.opened : AccessAutoRecoveryCopy.openedMember
        }
        if phases[tab.instanceID.uuidString] == .sent {
            return AccessAutoRecoveryCopy.preparing
        }
        return AccessAutoRecoveryCopy.armed
    }

    private func saveDirectSites(afterChanging key: AccessHostStoreKey) {
        guard !key.isPrivate, key.scopeID == "ordinary", let locationPreferences else { return }
        let names = explicitDirect.filter { !$0.isPrivate && $0.scopeID == "ordinary" }.map { $0.host.rawValue }
        locationPreferences.set(names.sorted(), forKey: Self.directSitesKey)
    }

    private func websitePrivacyEnabled(for key: AccessHostStoreKey) -> Bool {
        if explicitDirect.contains(key) { return false }
        if let intent = intents[key] { return intent == .on }
        return usesDefaultRoute(key) && !websiteOnlyEndpoints.contains(key) &&
            registry.endpoint(scopeID: key.scopeID, host: key.host, isPrivate: key.isPrivate)?.state == .ready
    }

    private func usesDefaultRoute(_ key: AccessHostStoreKey) -> Bool {
        defaultLocationPrivacy && intents[key] == nil && !explicitDirect.contains(key)
            && AccessLocalSite.classify(key.host.rawValue) == nil
            && (!accelerationAllowed(for: key) || websiteAccelerationMode != .smart)
    }

    func canManageRecovery(for tab: BrowserTab, displayedHost: AccessSiteHost?) -> Bool {
        guard let displayedHost else { return false }
        return displayedHost == host(for: tab)
    }

    private func locationControlHost(for tab: BrowserTab) -> AccessSiteHost? {
        guard let url = tab.addressBarURL, let target = Self.httpHost(url) else { return nil }
        // A user may change their choice while the visible GET/HEAD is still loading.
        if tab.isLoading, tab.safeRouteReloadRequest?.url == url { return target }
        return target == host(for: tab) ? target : nil
    }

    private func host(for tab: BrowserTab) -> AccessSiteHost? {
        if let failure = tab.lastMainFrameFailure,
           let host = Self.httpHost(failure.url) {
            return host
        }
        return tab.committedMainFrameURL.flatMap(Self.httpHost)
    }

    private static func httpHost(_ url: URL) -> AccessSiteHost? {
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https"].contains(scheme), let raw = url.host else { return nil }
        return AccessWebsiteRoutePolicy.websiteHost(url) ?? (try? AccessSiteHost.normalize(raw))
    }

    private func send(_ ticket: AccessNavigationRetryTicket, to tab: BrowserTab) {
        var request = URLRequest(url: ticket.url)
        request.httpMethod = ticket.method
        _ = tab.retryFailedNavigation(
            request,
            expectedNavigationID: ticket.navigationID,
            recoveryOperationID: ticket.operationID
        )
    }

    private struct RecoveryOperation {
        var id: UUID
        var key: AccessHostStoreKey
        var hostRevision: UInt64
        var tabID: String
        var failureID: UUID?
        var navigationID: String?
        var deadline: Duration
        var state: RecoveryState
        var ticket: AccessNavigationRetryTicket?
        var authorization: AccessAutoRecoveryGrant?
        var addressNavigation: BrowserPendingAddressNavigation? = nil
        var routePreparation: RoutePreparation? = nil
        var policyEpoch: UInt64? = nil
        var automaticFirstVisit: Bool { routePreparation == .legacyOptional }

        var landingParent: AccessHostStoreKey? {
            guard case .website(.landing(let landing))? = routePreparation else { return nil }
            return landing.parent
        }
    }

    private enum RecoveryState {
        case preparing
        case sent
        case failed
        case cancelled
        case completed
    }

    private enum RecoveryPhase: Equatable {
        case preparing
        case sent
        case failed
    }

    private func legacyRouteIntent(tab: BrowserTab, key: AccessHostStoreKey) -> AccessProxyIntentState {
        if explicitDirect.contains(key) { return .off }
        let tabID = tab.instanceID.uuidString
        let legacyBound = if accelerationAllowed(for: key) {
            legacyStoreBinding(tab: tab, key: key) != nil
        } else {
            tab.boundHostName == key.host.rawValue
        }
        if websitePrivacyEnabled(for: key) { return .on }
        if legacyBound, intents[key] == nil, !websiteOnlyEndpoints.contains(key),
           usesDefaultRoute(key) || defaultProtectedHosts.contains(key) { return .on }
        // Only the tab that recovered this exact host may keep using its host store.
        if executingTabs[tabID] == key, groupStillLists(key) || intents[key] == .on || executing.contains(key) {
            return .on
        }
        if legacyBound, groupStillLists(key) || executing.contains(key) { return .on }
        if operations.values.contains(where: {
            $0.tabID == tabID
                && $0.key == key
                && $0.addressNavigation == nil
                && ($0.state == .preparing || $0.state == .sent)
                && authorizationStillValid($0)
        }) {
            return .on
        }
        return .off
    }
}

struct AccessAutoRecoveryGrant: Equatable {
    var groupID: UUID
    var generation: UInt64
}

enum AccessAutoRecoveryRejection: Equatable {
    case noTrustedHost
    case tooManyMembers
    case staleCatalog
    case notExecutable
}

enum AccessAutoRecoveryChange: Equatable {
    case armed(AccessSiteRuleGroup)
    case recovering(UUID)
    case revoked
    case unchanged
    case rejected(AccessAutoRecoveryRejection)

    var isArmed: Bool {
        if case .armed = self { return true }
        return false
    }

    var isRecovering: Bool {
        if case .recovering = self { return true }
        return false
    }
}

enum AccessAutoRecoveryCopy {
    static let toggleTitle = "本站打不开时自动重试"
    static let explanation = "先用当前连接打开网站；加载失败时尝试隐藏地理位置。"
    static let scopeWarning = "恢复后的页面及其资源会使用该页的专用存储，可能包括第三方域名。"
    static let armed = "使用浏览器原有连接"
    static let preparing = "正在准备连接"
    static let opened = "已通过服务连接打开"
    static let openedMember = "登录页已通过服务连接打开"
    static let unavailable = "连接暂不可用"
}

/// Product channel for site-group capacity. Independent of the Firebase telemetry switch.
enum AccessProductChannel {
    static let infoDictionaryKey = "AegisAccessReleaseChannel"

    static func resolve(infoValue: String?) -> AccessReleaseChannel {
        let parsed = AccessReleaseChannel.parse(infoValue)
        return parsed == .unknown ? .release : parsed
    }

    static func resolve(bundle: Bundle = .main) -> AccessReleaseChannel {
        let raw = bundle.object(forInfoDictionaryKey: infoDictionaryKey) as? String
        return resolve(infoValue: raw)
    }
}

enum AccessProxyAttachment: Equatable {
    case notAttached
    case attachedUnavailable
    case ready
}
