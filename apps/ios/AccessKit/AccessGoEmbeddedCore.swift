import Foundation
import os
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

    private static let legacyOwnership = AccessGoRuntimeOwnership()
    private let native: any AccessGoNativeCore
    private let ownership: AccessGoRuntimeOwnership
    private let operations = AccessGoOperationLifetime()

    public init(isolated: Bool = false) throws {
        #if canImport(AegisEmbeddedCore)
        if isolated {
            guard let runtime = EmbeddedcoreNewRuntime() else { throw LinkError.frameworkNotLinked }
            native = AccessGomobileCore(runtime: runtime)
            ownership = AccessGoRuntimeOwnership()
        } else {
            native = AccessGomobileCore(runtime: nil)
            ownership = Self.legacyOwnership
        }
        #else
        throw LinkError.frameworkNotLinked
        #endif
    }

    /// Uses the same asynchronous contract for gomobile and controlled tests.
    init(native: any AccessGoNativeCore, ownership: AccessGoRuntimeOwnership = AccessGoRuntimeOwnership()) {
        self.native = native
        self.ownership = ownership
    }

    public var isRunning: Bool { operations.ownsRuntime && native.isRunning }

    static func validateRealityClientFields(fingerprint: String, spiderX: String) throws {
        #if canImport(AegisEmbeddedCore)
        let field = EmbeddedcoreValidateRealityClientFields(fingerprint, spiderX)
        guard field.isEmpty else { throw AccessRealityVisionOutboundConfigError.fieldNotCanonical(field) }
        #else
        throw LinkError.frameworkNotLinked
        #endif
    }

    static func newLogCaptureGeneration() -> Int64 {
        #if canImport(AegisEmbeddedCore)
        EmbeddedcoreNewLogCaptureGeneration()
        #else
        0
        #endif
    }

    static func retireLogCaptureGeneration(_ generation: Int64) {
        #if canImport(AegisEmbeddedCore)
        EmbeddedcoreRetireLogCaptureGeneration(generation)
        #endif
    }

    public func start(configData: Data) async throws {
        guard let json = String(data: configData, encoding: .utf8) else {
            throw AccessEmbeddedCoreError.unverifiedAsset
        }
        try await operations.start(native, config: json, ownership: ownership)
    }

    public func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        guard isRunning, let generation = operations.begin() else { throw AccessEmbeddedCoreError.unverifiedAsset }
        defer { operations.end() }
        let id = try await native.dial(host: host, port: port)
        if Task.isCancelled || !operations.isCurrent(generation) {
            operations.close(id, generation: generation, native: native)
            throw CancellationError()
        }
        return AccessGoEmbeddedStream(streamID: id, generation: generation, native: native, operations: operations)
    }

    public func stop() async {
        _ = await stopAndConfirm()
    }

    /// Returns whether native stop acknowledged instance close without error.
    public func stopAndConfirm() async -> Bool {
        await operations.stop(native, ownership: ownership)
    }
}

/// Read, write, dial and stop run in Go. The synchronous close gives Swift an
/// acknowledgement on its dedicated close queue without waiting on a caller.
protocol AccessGoNativeCore: Sendable {
    var isRunning: Bool { get }
    func start(_ json: String) async throws
    func dial(host: String, port: UInt16) async throws -> Int64
    func read(_ id: Int64, maxBytes: Int) async throws -> Data?
    func write(_ id: Int64, data: Data) async throws
    func close(_ id: Int64)
    func stop() async throws
}

/// The legacy native runtime is shared across adapters. Keep its claim through
/// the callback drain, even after native IsRunning first turns false.
final class AccessGoRuntimeOwnership: Sendable {
    private let claimed = Mutex(false)

    func claim() -> Bool {
        claimed.withLock {
            guard !$0 else { return false }
            $0 = true
            return true
        }
    }

    func release() { claimed.withLock { $0 = false } }
}

private final class AccessGoOperationLifetime: Sendable {
    private struct State {
        var generation: UInt64 = 0
        var ownsRuntime = false
        var startup: Task<Void, Error>?
        var stop: Task<Bool, Never>?
    }

    private let state = Mutex(State())
    private let active = DispatchGroup()
    private let closes = DispatchQueue(label: "aegis.access.native-close", qos: .utility)

    var ownsRuntime: Bool { state.withLock { $0.ownsRuntime } }

    func begin(generation: UInt64? = nil) -> UInt64? {
        state.withLock {
            guard $0.ownsRuntime, generation == nil || generation == $0.generation else { return nil }
            active.enter()
            return $0.generation
        }
    }

    func end() { active.leave() }

    func isCurrent(_ generation: UInt64) -> Bool {
        state.withLock { $0.ownsRuntime && $0.generation == generation }
    }

    func close(_ id: Int64, generation: UInt64, native: any AccessGoNativeCore) {
        guard begin(generation: generation) != nil else { return }
        closes.async { [active] in
            native.close(id)
            active.leave()
        }
    }

    func start(_ native: any AccessGoNativeCore, config: String, ownership: AccessGoRuntimeOwnership) async throws {
        try Task.checkCancellation()
        let startup = try state.withLock { state -> Task<Void, Error> in
            guard state.startup == nil, !state.ownsRuntime else { throw AccessEmbeddedCoreError.unverifiedAsset }
            let priorStop = state.stop
            if priorStop != nil { state.generation &+= 1 }
            let task = Task {
                _ = await priorStop?.value
                guard ownership.claim() else { throw AccessEmbeddedCoreError.unverifiedAsset }
                do { try await native.start(config) }
                catch {
                    ownership.release()
                    throw error
                }
            }
            state.startup = task
            state.stop = nil
            return task
        }
        // A successful native start is always accounted for, even if the
        // caller was cancelled while waiting for its non-cancellable callback.
        let result = await startup.result
        let stoppedDuringStart = state.withLock {
            $0.startup = nil
            if case .success = result, $0.stop == nil { $0.ownsRuntime = true }
            return $0.stop != nil
        }
        try result.get()
        if stoppedDuringStart { throw CancellationError() }
    }

    /// Returns false only when native stop reported an instance-close error.
    func stop(_ native: any AccessGoNativeCore, ownership: AccessGoRuntimeOwnership) async -> Bool {
        let stop = state.withLock { state -> Task<Bool, Never>? in
            if let existing = state.stop { return existing }
            let startup = state.startup
            let wasOwner = state.ownsRuntime
            guard wasOwner || startup != nil else { return nil }
            state.ownsRuntime = false
            let task = Task { [active] () -> Bool in
                if !wasOwner {
                    guard case .success? = await startup?.result else { return true }
                }
                // Stop drains the native registry. A close which already
                // removed its handle from that registry can still be running.
                let acknowledged: Bool
                do {
                    try await native.stop()
                    acknowledged = true
                } catch {
                    // Go has already detached the instance and closed its stream table.
                    // Report the instance-close error without including native details.
                    Logger(subsystem: "com.gcsa.aegis", category: "Access").error("Embedded core instance close reported an error")
                    acknowledged = false
                }
                await withCheckedContinuation { continuation in
                    active.notify(queue: .global()) { continuation.resume() }
                }
                ownership.release()
                return acknowledged
            }
            state.stop = task
            return task
        }
        return await stop?.value ?? true
    }
}

private final class AccessGoEmbeddedStream: AccessRealityPathStream, @unchecked Sendable {
    private let streamID: Int64
    private let generation: UInt64
    private let native: any AccessGoNativeCore
    private let operations: AccessGoOperationLifetime
    private let closed = Mutex(false)

    init(streamID: Int64, generation: UInt64, native: any AccessGoNativeCore, operations: AccessGoOperationLifetime) {
        self.streamID = streamID
        self.generation = generation
        self.native = native
        self.operations = operations
    }

    var isOpen: Bool { closed.withLock { !$0 } && operations.isCurrent(generation) }

    func read(maxBytes: Int) async throws -> Data? {
        guard operations.begin(generation: generation) != nil else { return nil }
        defer { operations.end() }
        return try await withTaskCancellationHandler {
            let data = try await native.read(streamID, maxBytes: maxBytes)
            return data?.isEmpty == true ? nil : data
        } onCancel: { self.close() }
    }

    func write(_ data: Data) async throws {
        guard operations.begin(generation: generation) != nil else { throw CancellationError() }
        defer { operations.end() }
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
        operations.close(streamID, generation: generation, native: native)
    }

    deinit { close() }
}

#if canImport(AegisEmbeddedCore)
private struct AccessGomobileCore: AccessGoNativeCore, @unchecked Sendable {
    let runtime: EmbeddedcoreRuntime?
    var isRunning: Bool { runtime?.isRunning() ?? EmbeddedcoreIsRunning() }

    func start(_ json: String) async throws {
        _ = try await result { callback in
            if let runtime { runtime.startAsync(json, c: callback) }
            else { EmbeddedcoreStartAsync(json, callback) }
        }
    }
    func dial(host: String, port: UInt16) async throws -> Int64 {
        try await result { callback in
            if let runtime { runtime.dialAsync(host, port: Int(port), c: callback) }
            else { EmbeddedcoreDialAsync(host, Int(port), callback) }
        }.id
    }
    func read(_ id: Int64, maxBytes: Int) async throws -> Data? {
        try await result { callback in
            if let runtime { runtime.readAsync(id, maxBytes: maxBytes, c: callback) }
            else { EmbeddedcoreReadAsync(id, maxBytes, callback) }
        }.data
    }
    func write(_ id: Int64, data: Data) async throws {
        _ = try await result { callback in
            if let runtime { runtime.writeAsync(id, data: data, c: callback) }
            else { EmbeddedcoreWriteAsync(id, data, callback) }
        }
    }
    func close(_ id: Int64) {
        if let runtime { runtime.closeStream(id) }
        else { EmbeddedcoreCloseStream(id) }
    }
    func stop() async throws {
        _ = try await result { callback in
            if let runtime { runtime.stopAsync(callback) }
            else { EmbeddedcoreStopAsync(callback) }
        }
    }

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
