import AccessKit
import BrowserKit
import Foundation
import WebKit

/// App adapter for exact-host stores. Ordinary scope is shared by every window.
/// A private scope id is the browser's current private session.
@MainActor
final class AccessHostStoreCoordinator: ObservableObject, BrowserHostStoreCoordinating {
    let registry = AccessHostDataStoreRegistry()
    let publisher: any AccessProxyEntryPublishing
    let clock: any AccessPreparationClock
    let releaseChannel: AccessReleaseChannel
    let prepareBudget: Duration = .seconds(15)
    @Published private(set) var revision: UInt64 = 0
    /// Explicit `suggestProbe` / `runProbe` calls. Recovery and page loads do not increment this.
    private(set) var probeInvocationCount: UInt64 = 0
    private let ruleGroups = AccessSiteRuleGroupRegistry()
    private var intents: [AccessHostStoreKey: AccessProxyIntentState] = [:]
    private var executing: Set<AccessHostStoreKey> = []
    /// Tabs that have actually entered a proxy recovery send, bound to the host
    /// key they recovered. Scope-wide `executing` alone must not route a healthy
    /// sibling (or the same tab on a different host) onto another host store.
    private var executingTabs: [String: AccessHostStoreKey] = [:]
    private var hostRevisions: [AccessHostStoreKey: UInt64] = [:]
    private var operations: [UUID: RecoveryOperation] = [:]
    private var phases: [String: RecoveryPhase] = [:]
    private var probeLines: [String: [String]] = [:]
    private var probeBusyTabs: Set<String> = []
    private var probeTasks: [String: Task<Void, Never>] = [:]
    private var probeGenerations: [String: UInt64] = [:]
    /// Site host the probe was started for; results must not survive an in-place navigation.
    private var probeSiteHosts: [String: AccessSiteHost] = [:]
    private var probeRunner = AccessSiteProbeRunner()
    var tabs: () -> [BrowserTab] = { [] }
    private var sweepTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    init(
        publisher: (any AccessProxyEntryPublishing)? = nil,
        clock: (any AccessPreparationClock)? = nil,
        channel: AccessReleaseChannel = .release,
        probeRunner: AccessSiteProbeRunner = AccessSiteProbeRunner()
    ) {
        self.publisher = publisher ?? AccessFailClosedProxyEntryPublisher()
        self.clock = clock ?? AccessContinuousPreparationClock()
        self.releaseChannel = channel == .unknown ? .release : channel
        self.probeRunner = probeRunner
        let publisher = self.publisher
        stateTask = Task { @MainActor [weak self] in
            for await endpoint in publisher.stateChanges {
                self?.applySharedState(endpoint)
            }
        }
    }

    var lastRecoveryFailure: String?

    func startForegroundSweep() {
        sweepTask?.cancel()
        sweepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                self?.registry.sweep(now: Date())
            }
        }
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
            registry.setProxyEnabled(true, scopeID: scopeID, host: host, isPrivate: isPrivate)
            revision &+= 1
            return
        }
        if groupStillLists(key) {
            revision &+= 1
            return
        }
        releaseBinding(key)
        revision &+= 1
    }

    func setProxyEnabled(_ enabled: Bool, for tab: BrowserTab) {
        guard let host = host(for: tab) else { return }
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

    func snapshot(for tab: BrowserTab) -> AccessSiteProxyToggleSnapshot {
        _ = revision
        guard let host = host(for: tab) else {
            var snapshot = AccessSiteProxyToggleSnapshot()
            snapshot.intentStatus = .noTrustedSite
            return snapshot
        }
        let key = AccessHostStoreKey(
            scopeID: tab.browsingScopeID,
            host: host,
            isPrivate: tab.profile.isPrivate
        )
        let intentOn = intents[key] == .on
        let attachment = attachment(tab: tab, host: host)
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
        } else if intentOn || (boundUnavailable && (autoListed || executingTabs[tab.id.uuidString] == key)) {
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
        if boundUnavailable, intentOn || autoListed || executingTabs[tab.id.uuidString] == key {
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
            let tabID = tab.id.uuidString
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

    func dataStoreForMainFrame(tab: BrowserTab, url: URL) -> WKWebsiteDataStore? {
        guard let host = try? AccessSiteHost.normalize(url.host ?? "") else { return nil }
        let key = AccessHostStoreKey(
            scopeID: tab.browsingScopeID,
            host: host,
            isPrivate: tab.profile.isPrivate
        )
        let bound = tab.boundHostName.flatMap { try? AccessSiteHost($0) }
        return registry.storeForTab(
            tabID: tab.id.uuidString,
            scopeID: tab.browsingScopeID,
            isPrivate: tab.profile.isPrivate,
            targetHost: host,
            boundHost: bound,
            intent: routeIntent(
                key: key,
                boundToTarget: bound == host,
                tabID: tab.id.uuidString
            )
        )
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
        guard showsDebugSiteGroupDetails else { return false }
        let tabID = tab.id.uuidString
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
        if intents[key] == .on { return true }
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
        let open = Dictionary(uniqueKeysWithValues: BrowserSession.openTabs().map { ($0.id.uuidString, $0) })
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
        guard BrowserNavigationFailure.isRecoverableNetworkFailure(error) else { return }
        guard failure.recoveryOperationID == nil else { return }
        guard !failure.hasReplayableBody else { return }
        guard let host = try? AccessSiteHost.normalize(failure.url.host ?? "") else { return }
        let method = failure.method.uppercased()
        guard method == "GET" || method == "HEAD" else { return }
        let key = AccessHostStoreKey(
            scopeID: tab.browsingScopeID,
            host: host,
            isPrivate: tab.profile.isPrivate
        )
        // Consumed / in-flight / finished tickets for the same failure must not re-arm.
        if operations.values.contains(where: {
            $0.tabID == tab.id.uuidString && $0.failureID == failure.failureID
        }) {
            return
        }
        if operations.values.contains(where: {
            $0.tabID == tab.id.uuidString
                && $0.navigationID == failure.navigationID
                && ($0.state == .preparing || $0.state == .sent || $0.state == .completed)
        }) {
            return
        }
        let operationID = UUID()
        var ticket = AccessNavigationRetryTicket(
            tabID: tab.id.uuidString,
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
            currentTabID: tab.id.uuidString,
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
            operations[operationID] = RecoveryOperation(
                id: operationID,
                key: key,
                hostRevision: hostRevisions[key] ?? 0,
                tabID: tab.id.uuidString,
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
            tabID: tab.id.uuidString,
            failureID: failure.failureID,
            navigationID: failure.navigationID,
            deadline: clock.now,
            state: .sent,
            ticket: ticket,
            authorization: nil
        )
        phases[tab.id.uuidString] = .sent
        send(ticket, to: tab)
    }

    @discardableResult
    func retryViaProxy(tab: BrowserTab) -> UUID? {
        startRecovery(tab: tab, trigger: .userRetry)
    }

    private func startRecovery(tab: BrowserTab, trigger: AccessNavigationRetryTrigger) -> UUID? {
        guard tab.loadingErrorAllowsProxyRetry, let failure = tab.lastMainFrameFailure else { return nil }
        guard let host = try? AccessSiteHost.normalize(failure.url.host ?? "") else { return nil }
        let key = AccessHostStoreKey(
            scopeID: tab.browsingScopeID,
            host: host,
            isPrivate: tab.profile.isPrivate
        )
        if let existing = operations.values.first(where: {
            $0.tabID == tab.id.uuidString && $0.failureID == failure.failureID && $0.state == .preparing
        }) {
            return existing.id
        }
        return beginPrepare(for: tab, key: key, failure: failure, trigger: trigger)
    }

    func retryReadyTabs(operationID: UUID) {
        guard var operation = operations[operationID], operation.state == .preparing || operation.state == .sent else { return }
        guard var ticket = operation.ticket else { return }
        guard let tab = BrowserSession.openTabs().first(where: { $0.id.uuidString == operation.tabID }) else { return }
        guard let failure = tab.lastMainFrameFailure, failure.failureID == ticket.failureID else { return }
        guard failure.navigationID == ticket.navigationID else { return }
        guard hostRevisions[operation.key] ?? 0 == operation.hostRevision else { return }
        guard authorizationStillValid(operation) else { return }
        let ready = registry.endpoint(
            scopeID: operation.key.scopeID,
            host: operation.key.host,
            isPrivate: operation.key.isPrivate
        )?.state == .ready
        let decision = AccessNavigationRetryPolicy.evaluate(
            ticket: ticket,
            currentTabID: tab.id.uuidString,
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
        if operation.authorization != nil || intents[operation.key] == .on {
            executing.insert(operation.key)
            executingTabs[operation.tabID] = operation.key
        }
        phases[operation.tabID] = .sent
        send(ticket, to: tab)
        publisher.cancel(operationID: operationID)
    }

    func pendingRecoveryInvalidated(tab: BrowserTab) {
        let tabID = tab.id.uuidString
        for (id, operation) in operations where operation.tabID == tabID && operation.state == .preparing {
            var cancelled = operation
            cancelled.state = .cancelled
            operations[id] = cancelled
            publisher.cancel(operationID: id)
        }
        tab.invalidateDeferredDocumentLoad()
        if !operations.values.contains(where: { $0.tabID == tabID && $0.state == .preparing }) {
            if phases[tabID] == .preparing { phases[tabID] = nil }
        }
        revision &+= 1
    }

    func tabClosed(_ tab: BrowserTab) {
        pendingRecoveryInvalidated(tab: tab)
        registry.unbind(tab.id.uuidString)
        executingTabs.removeValue(forKey: tab.id.uuidString)
        cancelProbes(tabID: tab.id.uuidString)
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
            if let tab = BrowserSession.openTabs().first(where: { $0.id.uuidString == operation.tabID }) {
                tab.invalidateDeferredDocumentLoad()
            }
        }
        cancelProbes(scopeID: scopeID, isPrivate: true)
        registry.endPrivateSession(scopeID: scopeID)
        revision &+= 1
    }

    private func beginPrepare(
        for tab: BrowserTab,
        key: AccessHostStoreKey,
        failure: BrowserMainFrameFailure?,
        trigger: AccessNavigationRetryTrigger,
        authorization: AccessAutoRecoveryGrant? = nil
    ) -> UUID? {
        let method = (failure?.method ?? "GET").uppercased()
        if failure != nil, method != "GET", method != "HEAD" { return nil }
        if let failure, failure.hasReplayableBody { return nil }
        if let failure, let existing = operations.values.first(where: {
            $0.tabID == tab.id.uuidString && $0.failureID == failure.failureID && $0.state == .preparing
        }) {
            return existing.id
        }
        let operationID = UUID()
        let deadline = clock.now + prepareBudget
        if authorization == nil, intents[key] != .on {
            setProxyEnabled(true, host: key.host, scopeID: key.scopeID, isPrivate: key.isPrivate)
        }
        var ticket: AccessNavigationRetryTicket?
        if let failure {
            ticket = AccessNavigationRetryTicket(
                tabID: tab.id.uuidString,
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
            tabID: tab.id.uuidString,
            failureID: failure?.failureID,
            navigationID: failure?.navigationID,
            deadline: deadline,
            state: .preparing,
            ticket: ticket,
            authorization: authorization
        )
        phases[tab.id.uuidString] = .preparing
        armTimeout(operationID: operationID, deadline: deadline)
        let publisher = self.publisher
        Task { @MainActor in
            do {
                let result = try await publisher.prepare(
                    AccessProxyEntryPrepareRequest(operationID: operationID, deadline: deadline)
                )
                self.finishPrepare(operationID, result: result)
            } catch {
                self.fail(operationID, reason: (error as? AccessSiteSessionError)?.readableMessage ?? "代理没有就绪")
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
        guard authorizationStillValid(operation) else {
            fail(operationID, reason: "这次准备已经失效")
            publisher.cancel(operationID: operationID)
            return
        }
        guard publisher.validateReady(result), publisher.retain(result.endpoint, for: operation.key) else {
            fail(operationID, reason: "代理入口还不能使用")
            return
        }
        registry.setEndpoint(
            result.endpoint,
            scopeID: operation.key.scopeID,
            host: operation.key.host,
            isPrivate: operation.key.isPrivate
        )
        if operation.ticket != nil {
            retryReadyTabs(operationID: operationID)
        } else {
            operation.state = .completed
            operations[operationID] = operation
            phases[operation.tabID] = nil
            publisher.cancel(operationID: operationID)
        }
        revision &+= 1
    }

    private func armTimeout(operationID: UUID, deadline: Duration) {
        Task { @MainActor in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard operations[operationID]?.state == .preparing else { return }
            self.fail(operationID, reason: "代理在 15 秒内没有就绪")
            self.publisher.cancel(operationID: operationID)
        }
    }

    private func fail(_ operationID: UUID, reason: String) {
        guard var operation = operations[operationID], operation.state == .preparing else { return }
        operation.state = .failed
        operations[operationID] = operation
        phases[operation.tabID] = .failed
        lastRecoveryFailure = reason
        publisher.cancel(operationID: operationID)
        revision &+= 1
    }

    private func cancelOperations(for key: AccessHostStoreKey) {
        for (id, operation) in operations where operation.key == key && operation.state == .preparing {
            var cancelled = operation
            cancelled.state = .cancelled
            operations[id] = cancelled
            publisher.cancel(operationID: id)
        }
    }

    private func applySharedState(_ endpoint: AccessManagedProxyEndpoint) {
        guard endpoint.state == .failed else { return }
        for (key, current) in registryEndpoints() where current.identity == endpoint.identity && current.generation == endpoint.generation {
            registry.setEndpoint(
                endpoint,
                scopeID: key.scopeID,
                host: key.host,
                isPrivate: key.isPrivate
            )
            // Auto-group hosts must leave the "opened" product line when the entry fails.
            for (tabID, phase) in phases where phase == .sent {
                if let tab = BrowserSession.openTabs().first(where: { $0.id.uuidString == tabID }),
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

    private func registryEndpoints() -> [AccessHostStoreKey: AccessManagedProxyEndpoint] {
        var found: [AccessHostStoreKey: AccessManagedProxyEndpoint] = [:]
        for key in intents.keys {
            if let endpoint = registry.endpoint(scopeID: key.scopeID, host: key.host, isPrivate: key.isPrivate) {
                found[key] = endpoint
            }
        }
        // Include hosts that are only authorized by an auto-recovery group.
        for key in executing {
            if found[key] != nil { continue }
            if let endpoint = registry.endpoint(scopeID: key.scopeID, host: key.host, isPrivate: key.isPrivate) {
                found[key] = endpoint
            }
        }
        for operation in operations.values where operation.authorization != nil {
            let key = operation.key
            if found[key] != nil { continue }
            if let endpoint = registry.endpoint(scopeID: key.scopeID, host: key.host, isPrivate: key.isPrivate) {
                found[key] = endpoint
            }
        }
        return found
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
        if !groupStillLists(key), intents[key] != .on {
            releaseBinding(key)
        }
        return change
    }

    private func revokeGroup(_ group: AccessSiteRuleGroup) {
        guard let removed = ruleGroups.remove(groupID: group.groupID) else { return }
        invalidateOperations(groupID: removed.groupID)
        for host in removed.memberHosts {
            let key = AccessHostStoreKey(scopeID: removed.scopeID, host: host, isPrivate: removed.isPrivate)
            if !groupStillLists(key), intents[key] != .on {
                releaseBinding(key)
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

    private func authorizationStillValid(_ operation: RecoveryOperation) -> Bool {
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

    private func releaseBinding(_ key: AccessHostStoreKey) {
        executing.remove(key)
        hostRevisions[key, default: 0] += 1
        cancelOperations(for: key)
        registry.setProxyEnabled(false, scopeID: key.scopeID, host: key.host, isPrivate: key.isPrivate)
        let bound = registry.revoke(scopeID: key.scopeID, host: key.host, isPrivate: key.isPrivate)
        publisher.release(for: key)
        for tab in BrowserSession.openTabs() where bound.contains(tab.id.uuidString) {
            if executingTabs[tab.id.uuidString] == key {
                executingTabs.removeValue(forKey: tab.id.uuidString)
            }
            tab.invalidateDeferredDocumentLoad()
            tab.rebindWebsiteDataStore(tab.originalWebsiteDataStore, host: nil)
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
        switch phases[tab.id.uuidString] {
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
        if phases[tab.id.uuidString] == .sent {
            return AccessAutoRecoveryCopy.preparing
        }
        return AccessAutoRecoveryCopy.armed
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
        return try? AccessSiteHost.normalize(raw)
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

    private func routeIntent(
        key: AccessHostStoreKey,
        boundToTarget: Bool,
        tabID: String
    ) -> AccessProxyIntentState {
        if intents[key] == .on { return .on }
        // Only the tab that recovered this exact host may keep using its host store.
        if executingTabs[tabID] == key, groupStillLists(key) || intents[key] == .on || executing.contains(key) {
            return .on
        }
        if boundToTarget, groupStillLists(key) || executing.contains(key) { return .on }
        if operations.values.contains(where: {
            $0.tabID == tabID
                && $0.key == key
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
    static let explanation = "先用当前连接打开本站和已知登录站点。页面打不开时，自动尝试用代理加载该页及其资源。"
    static let scopeWarning = "恢复后的页面及其资源会使用该页的专用存储，可能包括第三方域名。"
    static let armed = "已开启 · 当前使用原连接"
    static let preparing = "正在准备代理"
    static let opened = "已通过代理打开"
    static let openedMember = "登录页已通过代理打开"
    static let unavailable = "入口暂不可用"
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
