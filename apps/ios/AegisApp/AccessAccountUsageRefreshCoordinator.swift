import Foundation

/// One application-wide schedule shared by every window and visible usage surface.
/// Cancelling observation never cancels the session-owned request it awaits.
@MainActor
final class AccessAccountUsageRefreshCoordinator {
    private let refresh: () -> Task<Void, Never>?
    private let sleep: @Sendable (Duration) async throws -> Void
    private let uptime: () -> TimeInterval
    private var owners: Set<UUID> = []
    private var active = false
    private var failures = 0
    private var lastManualUptime: TimeInterval?
    private var generation = UUID()
    private var timerGeneration = UUID()
    private var timer: Task<Void, Never>?
    private var observation: Task<Void, Never>?

    init(
        refresh: @escaping () -> Task<Void, Never>?,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.refresh = refresh
        self.uptime = uptime
        self.sleep = sleep
    }

    func setVisible(_ visible: Bool, owner: UUID) {
        let wasVisible = !owners.isEmpty
        if visible { owners.insert(owner) }
        else { owners.remove(owner) }
        guard active, wasVisible != !owners.isEmpty, failures == 0 else { return }
        if !owners.isEmpty { requestImmediately() }
        else { scheduleNext() }
    }

    /// App-level scene phase aggregates windows; one inactive window must not stop another.
    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        if active { requestImmediately() }
        else { stopObserving() }
    }

    /// Leading-edge debounce: the first tap is immediate; a burst shares one read.
    func refreshNow() {
        guard active else { return }
        let now = uptime()
        if let last = lastManualUptime, now >= last, now - last < 1 { return }
        lastManualUptime = now
        requestImmediately()
    }

    /// Called only for the current identity's validated request result.
    func didComplete(succeeded: Bool) {
        failures = succeeded ? 0 : min(failures + 1, 2)
        if observation == nil { scheduleNext() }
    }

    /// No retry/debounce state or late observation may cross an identity boundary.
    func identityDidChange() {
        stopObserving()
        failures = 0
        lastManualUptime = nil
        scheduleNext()
    }

    private func requestImmediately() {
        guard active, observation == nil else { return }
        cancelTimer()
        let request = refresh()
        // Reading credentials can synchronously invalidate the old identity/schedule.
        cancelTimer()
        guard let request else { scheduleNext(); return }
        let generation = generation
        observation = Task { [weak self] in
            await request.value
            guard !Task.isCancelled, self?.generation == generation else { return }
            self?.observation = nil
            self?.scheduleNext()
        }
    }

    private func scheduleNext() {
        guard active, observation == nil else { return }
        cancelTimer()
        let delay: Duration = failures == 1 ? .seconds(15)
            : failures >= 2 ? .seconds(30)
            : owners.isEmpty ? .seconds(30) : .seconds(5)
        let timerGeneration = timerGeneration
        let sleep = sleep
        timer = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do { try await sleep(delay) }
            catch { return }
            guard !Task.isCancelled, self?.timerGeneration == timerGeneration else { return }
            self?.timer = nil
            self?.requestImmediately()
        }
    }

    private func cancelTimer() {
        timerGeneration = UUID()
        timer?.cancel()
        timer = nil
    }

    private func stopObserving() {
        generation = UUID()
        cancelTimer()
        observation?.cancel()
        observation = nil
    }
}
