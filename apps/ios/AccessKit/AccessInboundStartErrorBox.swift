import Foundation

/// Thread-safe slot for NWListener start failures captured from a state handler.
final class AccessInboundStartErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
