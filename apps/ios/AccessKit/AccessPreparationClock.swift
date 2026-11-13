import Foundation

/// Monotonic clock for one prepare budget. `Date` stays on existing leases.
@MainActor
public protocol AccessPreparationClock: AnyObject {
    var now: Duration { get }
    func sleep(until deadline: Duration) async throws
}

@MainActor
public final class AccessContinuousPreparationClock: AccessPreparationClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() {
        origin = ContinuousClock.now
    }

    public var now: Duration {
        origin.duration(to: ContinuousClock.now)
    }

    public func sleep(until deadline: Duration) async throws {
        let remaining = deadline - now
        if remaining <= .zero { return }
        try await clock.sleep(for: remaining)
    }
}

/// Advances only when tests move it. Cancelling one wait resumes that continuation.
@MainActor
public final class AccessManualPreparationClock: AccessPreparationClock {
    public private(set) var now: Duration = .zero
    private var waiters: [UUID: Waiter] = [:]

    public init() {}

    public func sleep(until deadline: Duration) async throws {
        if now >= deadline { return }
        let box = WaiterBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let id = UUID()
                box.id = id
                waiters[id] = Waiter(deadline: deadline, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in
                guard let id = box.id else { return }
                self.waiters.removeValue(forKey: id)?.cancel()
            }
        }
    }

    public func advance(by interval: Duration) {
        now += interval
        resumeDue()
    }

    public func advance(to deadline: Duration) {
        now = deadline
        resumeDue()
    }

    private func resumeDue() {
        let due = waiters.filter { $0.value.deadline <= now }.map(\.key)
        for id in due {
            waiters.removeValue(forKey: id)?.resume()
        }
    }

    private final class WaiterBox: @unchecked Sendable {
        var id: UUID?
    }

    private final class Waiter {
        let deadline: Duration
        private var resumed = false
        private let continuation: CheckedContinuation<Void, Error>

        init(deadline: Duration, continuation: CheckedContinuation<Void, Error>) {
            self.deadline = deadline
            self.continuation = continuation
        }

        func resume() {
            guard !resumed else { return }
            resumed = true
            continuation.resume()
        }

        func cancel() {
            guard !resumed else { return }
            resumed = true
            continuation.resume(throwing: CancellationError())
        }
    }
}
