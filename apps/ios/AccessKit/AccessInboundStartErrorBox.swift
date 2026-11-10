import Foundation
import Synchronization

/// Thread-safe slot for NWListener start failures captured from a state handler.
/// Prefer `AccessNWListenerBootstrap.awaitReady` for new code.
final class AccessInboundStartErrorBox: @unchecked Sendable {
    private let storage = Mutex<String?>(nil)

    var value: String? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
