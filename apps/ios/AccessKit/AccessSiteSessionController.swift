import Foundation
import os

/// Orchestrates per-host Access sessions onto the reality_vision path.
///
/// Product Phase 1 (P-iOS-2 / P-iOS-5):
/// - `enable` (allow): PrepareCandidate → Publish → ACK → ready
/// - `block`: commit local refuse; tear down any published proxy for the host
/// - `disable` (off): stop publishing / clear proxy for the host
/// - `notifyRuntimeFault`: keep allow intent; Fail or Wait; never DIRECT
/// - `recoverFromFault`: re-run enable path (PROXY only)
///
/// Intent and connection health stay separate. Failures stay readable and must
/// not be reported as DIRECT success.
public final class AccessSiteSessionController: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var intentStore: AccessSiteIntentStore
    private let orchestrator: AccessSiteSessionOrchestrating
    private var snapshots: [AccessSiteHost: AccessSiteSessionSnapshot] = [:]
    private var activeCandidates: [AccessSiteHost: AccessSiteSessionCandidate] = [:]

    public init(
        intentStore: AccessSiteIntentStore = AccessSiteIntentStore(),
        orchestrator: AccessSiteSessionOrchestrating
    ) {
        self.intentStore = intentStore
        self.orchestrator = orchestrator
    }

    public func intentStoreSnapshot() -> AccessSiteIntentStore {
        lock.lock(); defer { lock.unlock() }
        return intentStore
    }

    public func snapshot(for host: AccessSiteHost) -> AccessSiteSessionSnapshot {
        lock.lock(); defer { lock.unlock() }
        if let existing = snapshots[host] {
            return existing
        }
        let intent = intentStore.intent(for: host)
        return AccessSiteSessionSnapshot(
            host: host,
            intent: intent,
            phase: intent == .off ? .idle : .unavailable,
            connectionState: .idle,
            faultMode: .none
        )
    }

    /// Allow path: persist intent, then orchestrate onto the reality path.
    @discardableResult
    public func enable(host: AccessSiteHost) throws -> AccessSiteSessionSnapshot {
        lock.lock()
        intentStore.setIntent(.allow, for: host)
        writeLocked(
            AccessSiteSessionSnapshot(
                host: host,
                intent: .allow,
                phase: .preparingCandidate,
                connectionState: .connecting,
                faultMode: .none
            )
        )
        lock.unlock()

        do {
            try tearDownActiveIfNeeded(host: host)

            let candidate = try runPhase(host: host, phase: .preparingCandidate) {
                try orchestrator.prepareCandidate(for: host)
            }

            lock.lock()
            activeCandidates[host] = candidate
            writeLocked(
                AccessSiteSessionSnapshot(
                    host: host,
                    intent: .allow,
                    phase: .publishing,
                    connectionState: .connecting,
                    faultMode: .none,
                    registrationID: candidate.registration.id
                )
            )
            lock.unlock()

            let publication = try runPhase(host: host, phase: .publishing) {
                try orchestrator.publish(candidate)
            }

            lock.lock()
            writeLocked(
                AccessSiteSessionSnapshot(
                    host: host,
                    intent: .allow,
                    phase: .awaitingAck,
                    connectionState: .connecting,
                    faultMode: .none,
                    registrationID: candidate.registration.id
                )
            )
            lock.unlock()

            let ack = try runPhase(host: host, phase: .awaitingAck) {
                try orchestrator.acknowledge(publication)
            }

            guard ack.registrationID == candidate.registration.id,
                  ack.publicationToken == publication.publicationToken
            else {
                throw AccessSiteSessionError.ackFailed("ACK does not match published candidate")
            }

            try runPhase(host: host, phase: .awaitingAck) {
                try orchestrator.activateRealityPath(ack: ack, candidate: candidate)
            }

            let ready = AccessSiteSessionSnapshot(
                host: host,
                intent: .allow,
                phase: .ready,
                connectionState: .ready,
                faultMode: .none,
                registrationID: candidate.registration.id
            )
            lock.lock()
            writeLocked(ready)
            lock.unlock()
            return ready
        } catch let error as AccessSiteSessionError {
            try? tearDownActiveIfNeeded(host: host)
            markUnavailable(host: host, intent: .allow, error: error)
            throw error
        } catch {
            try? tearDownActiveIfNeeded(host: host)
            let wrapped = AccessSiteSessionError.prepareFailed(String(describing: error))
            markUnavailable(host: host, intent: .allow, error: wrapped)
            throw wrapped
        }
    }

    /// Block path: local refuse for the host; never publishes a proxy path.
    @discardableResult
    public func block(host: AccessSiteHost) throws -> AccessSiteSessionSnapshot {
        do {
            try tearDownActiveIfNeeded(host: host)
            lock.lock()
            intentStore.setIntent(.block, for: host)
            let snap = AccessSiteSessionSnapshot(
                host: host,
                intent: .block,
                phase: .ready,
                connectionState: .unavailable,
                faultMode: .none,
                failureReason: "Local block: Access proxying refused for this host."
            )
            writeLocked(snap)
            lock.unlock()
            return snap
        } catch let error as AccessSiteSessionError {
            markUnavailable(host: host, intent: .block, error: error)
            throw error
        } catch {
            let wrapped = AccessSiteSessionError.tearDownFailed(String(describing: error))
            markUnavailable(host: host, intent: .block, error: wrapped)
            throw wrapped
        }
    }

    /// DEV ALLOW/BLOCK debug entry (P-iOS-4): intent-only apply via the store.
    ///
    /// Channel-gated. Does not publish/ACK on allow. Block/off tear down any
    /// active publication and keep connection honest (local refuse / idle) —
    /// never silent DIRECT success.
    @discardableResult
    public func applyDevAllowBlock(
        channel: AccessReleaseChannel,
        rawHost: String,
        action: AccessDevAllowBlockAction
    ) -> AccessDevAllowBlockApplyResult {
        lock.lock()
        var store = intentStore
        let result = AccessDevAllowBlockPanel.apply(
            store: &store,
            channel: channel,
            rawHost: rawHost,
            action: action
        )
        intentStore = store
        let appliedHost = result.host
        lock.unlock()

        guard result.status == .applied, let host = appliedHost else {
            return result
        }

        switch action {
        case .allow:
            lock.lock()
            let prior = snapshots[host]
            writeLocked(
                AccessSiteSessionSnapshot(
                    host: host,
                    intent: .allow,
                    phase: prior?.phase ?? .idle,
                    connectionState: prior?.connectionState ?? .idle,
                    registrationID: prior?.registrationID ?? activeCandidates[host]?.registration.id,
                    failureReason: prior?.failureReason
                )
            )
            lock.unlock()
        case .block:
            try? tearDownActiveIfNeeded(host: host)
            lock.lock()
            writeLocked(
                AccessSiteSessionSnapshot(
                    host: host,
                    intent: .block,
                    phase: .ready,
                    connectionState: .unavailable,
                    failureReason: "Local block: Access proxying refused for this host."
                )
            )
            lock.unlock()
        case .off:
            try? tearDownActiveIfNeeded(host: host)
            lock.lock()
            writeLocked(AccessSiteSessionSnapshot.idle(host: host))
            lock.unlock()
        }
        return result
    }

    /// Off path: clear intent and stop publishing for the host.
    @discardableResult
    public func disable(host: AccessSiteHost) throws -> AccessSiteSessionSnapshot {
        do {
            try tearDownActiveIfNeeded(host: host)
            lock.lock()
            intentStore.setIntent(.off, for: host)
            let snap = AccessSiteSessionSnapshot.idle(host: host)
            writeLocked(snap)
            lock.unlock()
            return snap
        } catch let error as AccessSiteSessionError {
            markUnavailable(host: host, intent: .off, error: error)
            throw error
        } catch {
            let wrapped = AccessSiteSessionError.tearDownFailed(String(describing: error))
            markUnavailable(host: host, intent: .off, error: wrapped)
            throw wrapped
        }
    }

    /// P-iOS-5: node/runtime fault while allow stays allow. Never treats DIRECT
    /// / native success as Access success and never tears down the published
    /// candidate. New requests must Fail (`failClosed`) or Wait (`wait`).
    @discardableResult
    public func notifyRuntimeFault(
        host: AccessSiteHost,
        mode: AccessSiteSessionFaultMode,
        detail: String = ""
    ) -> AccessSiteSessionSnapshot {
        if mode == .none {
            return snapshot(for: host)
        }

        lock.lock()
        defer { lock.unlock() }

        intentStore.setIntent(.allow, for: host)
        let prior = snapshots[host]
        let registrationID = activeCandidates[host]?.registration.id
            ?? prior?.registrationID
        let reason = AccessSiteSessionError.runtimeFault(detail).readableMessage

        let snap: AccessSiteSessionSnapshot
        if mode == .wait {
            snap = AccessSiteSessionSnapshot(
                host: host,
                intent: .allow,
                phase: .preparingCandidate,
                connectionState: .connecting,
                faultMode: .wait,
                registrationID: registrationID,
                failureReason: reason
            )
        } else {
            snap = AccessSiteSessionSnapshot(
                host: host,
                intent: .allow,
                phase: .unavailable,
                connectionState: .unavailable,
                faultMode: .failClosed,
                registrationID: registrationID,
                failureReason: reason
            )
        }
        writeLocked(snap)
        return snap
    }

    /// Re-arms the allow path after the node/runtime recovers
    /// (Prepare → Publish → ACK → activate). Never claims ready via DIRECT.
    @discardableResult
    public func recoverFromFault(host: AccessSiteHost) throws -> AccessSiteSessionSnapshot {
        try enable(host: host)
    }

    private func runPhase<T>(
        host: AccessSiteHost,
        phase: AccessSiteSessionPhase,
        work: () throws -> T
    ) throws -> T {
        do {
            return try work()
        } catch let error as AccessSiteSessionError {
            throw error
        } catch {
            switch phase {
            case .preparingCandidate:
                throw AccessSiteSessionError.prepareFailed(String(describing: error))
            case .publishing:
                throw AccessSiteSessionError.publishFailed(String(describing: error))
            case .awaitingAck:
                throw AccessSiteSessionError.ackFailed(String(describing: error))
            default:
                throw AccessSiteSessionError.prepareFailed(String(describing: error))
            }
        }
    }

    private func tearDownActiveIfNeeded(host: AccessSiteHost) throws {
        lock.lock()
        let candidate = activeCandidates[host]
        lock.unlock()
        guard let candidate else { return }
        do {
            try orchestrator.tearDown(registrationID: candidate.registration.id)
        } catch let error as AccessSiteSessionError {
            throw error
        } catch {
            throw AccessSiteSessionError.tearDownFailed(String(describing: error))
        }
        lock.lock()
        if activeCandidates[host]?.registration.id == candidate.registration.id {
            activeCandidates.removeValue(forKey: host)
        }
        lock.unlock()
    }

    private func markUnavailable(
        host: AccessSiteHost,
        intent: AccessSiteIntent,
        error: AccessSiteSessionError
    ) {
        lock.lock()
        intentStore.setIntent(intent == .off ? .off : intent, for: host)
        let registrationID = activeCandidates[host]?.registration.id
        writeLocked(
            AccessSiteSessionSnapshot(
                host: host,
                intent: intent,
                phase: .unavailable,
                connectionState: .unavailable,
                faultMode: .none,
                registrationID: registrationID,
                failureReason: error.readableMessage
            )
        )
        lock.unlock()
    }

    private func writeLocked(_ snapshot: AccessSiteSessionSnapshot) {
        snapshots[snapshot.host] = snapshot
    }
}
