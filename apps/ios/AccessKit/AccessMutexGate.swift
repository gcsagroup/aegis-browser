import os

/// Drop-in replacement for `NSLock` on iOS 18 / Swift 6.
/// Prefer `Synchronization.Mutex` when state can live inside the lock.
/// Never hold across `await`.
struct AccessMutexGate: Sendable {
    private let unfair = OSAllocatedUnfairLock()

    func lock() { unfair.lock() }
    func unlock() { unfair.unlock() }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        unfair.lock()
        defer { unfair.unlock() }
        return try body()
    }
}
