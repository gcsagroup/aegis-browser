import Foundation
import Synchronization

#if canImport(AegisEmbeddedCore)
import AegisEmbeddedCore
#endif

/// In-process Xray bridge backed by the gomobile `AegisEmbeddedCore` package.
///
/// Construction succeeds only when the verified framework is linked. Digests
/// alone never start dialing.
public final class AccessGoEmbeddedCore: AccessEmbeddedCoreControlling, @unchecked Sendable {
    public enum LinkError: Error, Equatable {
        case frameworkNotLinked
    }

    private let native: any AccessGoNativeCore

    public init() throws {
        #if canImport(AegisEmbeddedCore)
        native = AccessGomobileCore()
        #else
        throw LinkError.frameworkNotLinked
        #endif
    }

    /// Uses the same asynchronous contract for gomobile and controlled tests.
    init(native: any AccessGoNativeCore) { self.native = native }

    public var isRunning: Bool { native.isRunning }

    public func start(configData: Data) async throws {
        guard let json = String(data: configData, encoding: .utf8) else {
            throw AccessEmbeddedCoreError.unverifiedAsset
        }
        try await native.start(json)
    }

    public func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        guard isRunning else { throw AccessEmbeddedCoreError.unverifiedAsset }
        let id = try await native.dial(host: host, port: port)
        if Task.isCancelled {
            native.close(id)
            throw CancellationError()
        }
        return AccessGoEmbeddedStream(streamID: id, native: native)
    }

    public func stop() async {
        await native.stop()
    }
}

/// Socket waits are owned by Go goroutines. No Swift or dispatch thread parks.
protocol AccessGoNativeCore: Sendable {
    var isRunning: Bool { get }
    func start(_ json: String) async throws
    func dial(host: String, port: UInt16) async throws -> Int64
    func read(_ id: Int64, maxBytes: Int) async throws -> Data?
    func write(_ id: Int64, data: Data) async throws
    func close(_ id: Int64)
    func stop() async
}

private final class AccessGoEmbeddedStream: AccessRealityPathStream, @unchecked Sendable {
    private let streamID: Int64
    private let native: any AccessGoNativeCore
    private let closed = Mutex(false)

    init(streamID: Int64, native: any AccessGoNativeCore) {
        self.streamID = streamID
        self.native = native
    }

    var isOpen: Bool { closed.withLock { !$0 } }

    func read(maxBytes: Int) async throws -> Data? {
        try await withTaskCancellationHandler {
            let data = try await native.read(streamID, maxBytes: maxBytes)
            return data?.isEmpty == true ? nil : data
        } onCancel: { self.close() }
    }

    func write(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try await native.write(streamID, data: data)
        } onCancel: { self.close() }
    }

    func close() {
        let shouldClose = closed.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard shouldClose else { return }
        native.close(streamID)
    }

    deinit { close() }
}

#if canImport(AegisEmbeddedCore)
private struct AccessGomobileCore: AccessGoNativeCore {
    var isRunning: Bool { EmbeddedcoreIsRunning() }

    func start(_ json: String) async throws {
        _ = try await result { EmbeddedcoreStartAsync(json, $0) }
    }
    func dial(host: String, port: UInt16) async throws -> Int64 {
        try await result { EmbeddedcoreDialAsync(host, Int(port), $0) }.id
    }
    func read(_ id: Int64, maxBytes: Int) async throws -> Data? {
        try await result { EmbeddedcoreReadAsync(id, maxBytes, $0) }.data
    }
    func write(_ id: Int64, data: Data) async throws {
        _ = try await result { EmbeddedcoreWriteAsync(id, data, $0) }
    }
    func close(_ id: Int64) { EmbeddedcoreCloseStreamAsync(id) }
    func stop() async { _ = try? await result { EmbeddedcoreStopAsync($0) } }

    private struct NativeResult: Sendable {
        let id: Int64
        let data: Data?
    }
    private func result(_ begin: (NativeCompletion) -> Void) async throws -> NativeResult {
        try await withCheckedThrowingContinuation { continuation in
            begin(NativeCompletion(continuation))
        }
    }
    /// Go retains this callback until the operation returns. Taking the
    /// continuation under a short lock also guards duplicate native callbacks.
    private final class NativeCompletion: NSObject, EmbeddedcoreCompletionProtocol, @unchecked Sendable {
        private let continuation: Mutex<CheckedContinuation<NativeResult, Error>?>
        init(_ continuation: CheckedContinuation<NativeResult, Error>) {
            self.continuation = Mutex(continuation)
        }
        func complete(_ value: Int64, data: Data?, failure: String?) {
            let pending = continuation.withLock { state in
                let pending = state; state = nil; return pending
            }
            guard let pending else { return }
            if let failure, !failure.isEmpty {
                pending.resume(throwing: NSError(domain: "AccessEmbeddedCore", code: 1,
                                                userInfo: [NSLocalizedDescriptionKey: failure]))
            } else {
                // Callback NSData borrows Go memory only until complete returns.
                let owned = data.map { bytes in bytes.withUnsafeBytes { Data($0) } }
                pending.resume(returning: NativeResult(id: value, data: owned))
            }
        }
    }
}
#endif
