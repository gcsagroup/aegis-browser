import Foundation
import Network
import Synchronization

/// Async bootstrap for `NWListener` ready/failed — no `DispatchSemaphore`.
enum AccessNWListenerBootstrap {
    enum Failure: Error, Equatable {
        case timedOut
        case failed(String)
    }

    static func awaitReady(
        _ listener: NWListener,
        on queue: DispatchQueue,
        timeout: Duration = .seconds(2),
        observeState: @escaping @Sendable (NWListener.State) -> Void = { _ in }
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        let resume = OnceVoidResume(continuation)
                        listener.stateUpdateHandler = { state in
                            // The same observer remains installed across and after readiness.
                            observeState(state)
                            switch state {
                            case .ready:
                                resume.finish(returning: ())
                            case .failed(let error):
                                resume.finish(throwing: Failure.failed(String(describing: error)))
                            case .cancelled:
                                resume.finish(throwing: CancellationError())
                            default:
                                break
                            }
                        }
                        listener.start(queue: queue)
                    }
                } onCancel: {
                    listener.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timedOut
            }
            try await group.next()
            group.cancelAll()
        }
    }
}

private final class OnceVoidResume: Sendable {
    private let state: Mutex<CheckedContinuation<Void, Error>?>

    init(_ continuation: CheckedContinuation<Void, Error>) {
        state = Mutex(continuation)
    }

    func finish(returning _: Void) {
        take()?.resume(returning: ())
    }

    func finish(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Void, Error>? {
        state.withLock { pending in
            let value = pending
            pending = nil
            return value
        }
    }
}
