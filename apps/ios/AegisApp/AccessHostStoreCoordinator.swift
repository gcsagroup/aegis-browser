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
    let prepareBudget: Duration = .seconds(15)
    @Published private(set) var revision: UInt64 = 0
    private var intents: [AccessHostStoreKey: AccessProxyIntentState] = [:]
    private var hostRevisions: [AccessHostStoreKey: UInt64] = [:]
    private var operations: [UUID: RecoveryOperation] = [:]
    var tabs: () -> [BrowserTab] = { [] }
    private var sweepTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    init(
        publisher: (any AccessProxyEntryPublishing)? = nil,
        clock: (any AccessPreparationClock)? = nil
    ) {
        self.publisher = publisher ?? AccessFailClosedProxyEntryPublisher()
        self.clock = clock ?? AccessContinuousPreparationClock()
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
        registry.setProxyEnabled(enabled, scopeID: scopeID, host: host, isPrivate: isPrivate)
        if !enabled {
            hostRevisions[key, default: 0] += 1
            cancelOperations(for: key)
            let bound = registry.revoke(scopeID: scopeID, host: host, isPrivate: isPrivate)
            publisher.release(for: key)
            for tab in BrowserSession.openTabs() where bound.contains(tab.id.uuidString) {
                tab.rebindWebsiteDataStore(tab.originalWebsiteDataStore, host: nil)
            }
        }
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
        let endpoint = registry.endpoint(
            scopeID: tab.browsingScopeID,
            host: host,
            isPrivate: tab.profile.isPrivate
        )?.state ?? .unavailable
        if endpoint == .ready { return .ready }
        if tab.boundHostName == host.rawValue { return .attachedUnavailable }
        return .notAttached
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
        snapshot.intent = intentOn ? .allow : .off
        snapshot.toggleEnabled = true
        snapshot.toggleOn = intentOn
        snapshot.connection = attachment == .ready ? .ready : (intentOn ? .unavailable : .idle)
        snapshot.connectionStatus = AccessSiteProxyToggleModel.connectionStatus(snapshot.connection)
        snapshot.intentStatus = AccessSiteProxyToggleModel.intentStatus(
            intent: snapshot.intent,
            connection: snapshot.connection
        )
        snapshot.attachment = attachment
        if intentOn, attachment == .notAttached {
            snapshot.failureReason = "代理还没有就绪"
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
            intent: intents[key] ?? .off
        )
    }

    func mainFrameFailed(tab: BrowserTab, failure: BrowserMainFrameFailure, error: NSError) {
        guard BrowserNavigationFailure.isRecoverableNetworkFailure(error) else { return }
        guard failure.recoveryOperationID == nil else { return }
        guard let host = try? AccessSiteHost.normalize(failure.url.host ?? "") else { return }
        let method = failure.method.uppercased()
        guard method == "GET" || method == "HEAD" else { return }
        let key = AccessHostStoreKey(
            scopeID: tab.browsingScopeID,
            host: host,
            isPrivate: tab.profile.isPrivate
        )
        let operationID = UUID()
        var ticket = AccessNavigationRetryTicket(
            tabID: tab.id.uuidString,
            scopeID: tab.browsingScopeID,
            navigationID: failure.navigationID,
            host: host,
            url: failure.url,
            method: method,
            hasReplayableBody: false,
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
            operations[operationID] = RecoveryOperation(
                id: operationID,
                key: key,
                hostRevision: hostRevisions[key] ?? 0,
                tabID: tab.id.uuidString,
                failureID: failure.failureID,
                navigationID: failure.navigationID,
                deadline: clock.now,
                state: .failed,
                ticket: ticket
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
            ticket: ticket
        )
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
        guard intents[operation.key] == .on else { return }
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
        revision &+= 1
    }

    func tabClosed(_ tab: BrowserTab) {
        pendingRecoveryInvalidated(tab: tab)
        registry.unbind(tab.id.uuidString)
    }

    func ordinaryHostStores() -> [WKWebsiteDataStore] {
        registry.ordinaryStores()
    }

    func endPrivateSession(scopeID: String) {
        for key in hostRevisions.keys where key.isPrivate && key.scopeID == scopeID {
            hostRevisions[key, default: 0] += 1
        }
        for (id, operation) in operations where operation.key.isPrivate && operation.key.scopeID == scopeID && operation.state == .preparing {
            var cancelled = operation
            cancelled.state = .cancelled
            operations[id] = cancelled
            publisher.cancel(operationID: id)
            publisher.release(for: operation.key)
        }
        registry.endPrivateSession(scopeID: scopeID)
        revision &+= 1
    }

    private func beginPrepare(
        for tab: BrowserTab,
        key: AccessHostStoreKey,
        failure: BrowserMainFrameFailure?,
        trigger: AccessNavigationRetryTrigger
    ) -> UUID? {
        let method = (failure?.method ?? "GET").uppercased()
        if failure != nil, method != "GET", method != "HEAD" { return nil }
        if let failure, let existing = operations.values.first(where: {
            $0.tabID == tab.id.uuidString && $0.failureID == failure.failureID && $0.state == .preparing
        }) {
            return existing.id
        }
        let operationID = UUID()
        let deadline = clock.now + prepareBudget
        let turnedOn = intents[key] != .on
        if turnedOn, let failure {
            setProxyEnabled(true, host: key.host, scopeID: key.scopeID, isPrivate: key.isPrivate)
        } else if turnedOn, failure == nil {
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
                hasReplayableBody: false,
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
            ticket: ticket
        )
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
        guard clock.now <= operation.deadline else {
            fail(operationID, reason: "代理在 15 秒内没有就绪")
            return
        }
        guard hostRevisions[operation.key] ?? 0 == operation.hostRevision else {
            fail(operationID, reason: "这次准备已经失效")
            return
        }
        guard intents[operation.key] == .on else {
            fail(operationID, reason: "代理已关闭")
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
        lastRecoveryFailure = reason
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
        return found
    }

    private func host(for tab: BrowserTab) -> AccessSiteHost? {
        if let failure = tab.lastMainFrameFailure, let host = try? AccessSiteHost.normalize(failure.url.host ?? "") {
            return host
        }
        let url = tab.requestedURL ?? tab.url
        guard let raw = url?.host else { return nil }
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
    }

    private enum RecoveryState {
        case preparing
        case sent
        case failed
        case cancelled
        case completed
    }
}

enum AccessProxyAttachment: Equatable {
    case notAttached
    case attachedUnavailable
    case ready
}
