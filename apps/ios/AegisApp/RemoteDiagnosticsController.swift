import Combine
import Foundation

struct RemoteDiagnosticsResponse: Sendable {
    let values: [String: String]
    let fetchedAt: Date
}

@MainActor
protocol RemoteDiagnosticsSource: AnyObject {
    func fetch(after revocation: Date?) async throws -> RemoteDiagnosticsResponse
    func deleteInstallation() async throws
}

/// Serializes SDK work so deletion happens after any outstanding fetch, including
/// a quick off/on transition. User consent lives outside this controller.
@MainActor
final class RemoteDiagnosticsController: ObservableObject {
    enum State { case off, fetching, ready, unavailable, expired, cleaning, cleanupFailed }

    @Published private(set) var enabled: Bool
    @Published private(set) var state: State = .off
    @Published private(set) var policy: RemoteDiagnosticsPolicy?
    @Published private(set) var busy = false
    private(set) var initialRefreshCompleted = false
    var onChange: (() -> Void)?

    private let preferences: FirebaseInstallPreferences
    private let source: any RemoteDiagnosticsSource
    private let now: () -> Date
    private let schedulesExpiration: Bool
    private var generation: UInt64 = 0
    private var lastAttemptGeneration: UInt64?
    private var task: Task<Void, Never>?
    private var expiration: Task<Void, Never>?

    init(preferences: FirebaseInstallPreferences, source: any RemoteDiagnosticsSource,
         now: @escaping () -> Date = Date.init, schedulesExpiration: Bool = true) {
        self.preferences = preferences
        self.source = source
        self.now = now
        self.schedulesExpiration = schedulesExpiration
        enabled = preferences.isEnabled(.remoteConfiguration)
        if !enabled {
            preferences.saveRemotePolicy(nil)
            if preferences.remoteInstallationUsed { preferences.remoteCleanupRequired = true }
        } else if !preferences.remoteCleanupRequired, preferences.remoteRevokedAt == nil,
                  let stored = preferences.remotePolicy, stored.isValid(at: now()) {
            policy = stored
            state = .ready
        }
    }

    func start() {
        scheduleExpiration()
        refresh()
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        generation &+= 1
        enabled = value
        preferences.setEnabled(value, for: .remoteConfiguration)
        if !value {
            policy = nil
            preferences.saveRemotePolicy(nil)
            expiration?.cancel()
            preferences.remoteRevokedAt = now()
            if preferences.remoteInstallationUsed { preferences.remoteCleanupRequired = true }
            state = preferences.remoteCleanupRequired ? .cleaning : .off
        }
        onChange?()
        refresh()
    }

    func permits(_ collection: FirebaseInstallPreferences.Collection, localChoice: Bool) -> Bool {
        guard localChoice else { return false }
        guard enabled else { return true }
        return policy?.permits(collection, localChoice: true, now: now()) == true
    }

    func refresh() {
        guard task == nil, enabled || preferences.remoteCleanupRequired else { return }
        busy = true
        task = Task { [weak self] in
            guard let self else { return }
            await update()
            initialRefreshCompleted = true
            busy = false
            task = nil
            onChange?()
            // A replacement request may run only after deletion has succeeded.
            if enabled, lastAttemptGeneration != generation, !preferences.remoteCleanupRequired {
                refresh()
            }
        }
    }

    func invalidateIfExpired() {
        guard enabled, let policy, !policy.isValid(at: now()) else { return }
        self.policy = nil
        preferences.saveRemotePolicy(nil)
        state = .expired
        onChange?()
    }

    private func update() async {
        if preferences.remoteCleanupRequired, !(await cleanUp()) { return }
        guard enabled else { state = .off; return }
        let requestGeneration = generation
        lastAttemptGeneration = requestGeneration
        state = .fetching
        preferences.remoteInstallationUsed = true
        onChange?()
        do {
            let cutoff = preferences.remoteRevokedAt
            let response = try await source.fetch(after: cutoff)
            if enabled, requestGeneration == generation {
                if let cutoff, response.fetchedAt <= cutoff {
                    policy = nil
                } else {
                    policy = RemoteDiagnosticsPolicy(values: response.values, fetchedAt: response.fetchedAt, now: now())
                }
                preferences.saveRemotePolicy(policy)
                if policy != nil { preferences.remoteRevokedAt = nil }
                state = policy == nil ? .unavailable : .ready
            }
        } catch {
            if enabled, requestGeneration == generation {
                invalidateIfExpired()
                state = .unavailable
            }
        }
        if preferences.remoteCleanupRequired { _ = await cleanUp() }
        scheduleExpiration()
    }

    private func cleanUp() async -> Bool {
        state = .cleaning
        onChange?()
        do {
            try await source.deleteInstallation()
            // A late fetch can write the SDK cache even after the user opts out.
            // Deleting FIS does not erase that cache. Fence all pre-cleanup values.
            preferences.remoteRevokedAt = now()
            preferences.remoteInstallationUsed = false
            preferences.remoteCleanupRequired = false
            state = enabled ? .unavailable : .off
            return true
        } catch {
            state = .cleanupFailed
            return false
        }
    }

    private func scheduleExpiration() {
        expiration?.cancel()
        guard schedulesExpiration, enabled, let policy else { return }
        let delay = max(0, policy.fetchedAt.addingTimeInterval(RemoteDiagnosticsPolicy.maximumAge).timeIntervalSince(now()))
        expiration = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            invalidateIfExpired()
            refresh()
        }
    }
}
