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

    /// Uses the same dispatch boundary for production gomobile and controlled tests.
    init(native: any AccessGoNativeCore) { self.native = native }

    public var isRunning: Bool { native.isRunning }

    public func start(configData: Data) async throws {
        guard let json = String(data: configData, encoding: .utf8) else {
            throw AccessEmbeddedCoreError.unverifiedAsset
        }
        try await AccessGoBlockingIO.run(on: .control) { [native] in try native.start(json) }
    }

    public func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        guard isRunning else { throw AccessEmbeddedCoreError.unverifiedAsset }
        let id = try await AccessGoBlockingIO.run(on: .io) { [native] in
            try native.dial(host: host, port: port)
        }
        return AccessGoEmbeddedStream(streamID: id, native: native)
    }

    public func stop() async {
        _ = try? await AccessGoBlockingIO.run(on: .control) { [native] in native.stop() }
    }
}

/// Synchronous native ABI. Only the short running-state lookup stays on the caller.
protocol AccessGoNativeCore: Sendable {
    var isRunning: Bool { get }
    func start(_ json: String) throws
    func dial(host: String, port: UInt16) throws -> Int64
    func read(_ id: Int64, maxBytes: Int) throws -> Data?
    func write(_ id: Int64, data: Data) throws
    func close(_ id: Int64)
    func stop()
}

/// Blocking Go calls must never occupy Swift's cooperative workers. Separate
/// concurrent queues let writes/dials and teardown progress while reads park.
/// Cancellation does not resume early: the native call owns the single resume;
/// closing a stream or stopping the core wakes its pending I/O.
private enum AccessGoBlockingIO {
    enum Lane { case read, io, control }
    private static let reads = DispatchQueue(label: "accesskit.go.read", qos: .userInitiated, attributes: .concurrent)
    private static let io = DispatchQueue(label: "accesskit.go.io", qos: .userInitiated, attributes: .concurrent)
    private static let control = DispatchQueue(label: "accesskit.go.control", qos: .userInitiated, attributes: .concurrent)

    static func run<T: Sendable>(on lane: Lane, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(on: lane) {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    static func enqueue(on lane: Lane, _ work: @escaping @Sendable () -> Void) {
        let queue: DispatchQueue
        switch lane {
        case .read: queue = reads
        case .io: queue = io
        case .control: queue = control
        }
        queue.async(execute: work)
    }
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
        try await AccessGoBlockingIO.run(on: .read) { [native, streamID] in
            let data = try native.read(streamID, maxBytes: maxBytes)
            return data?.isEmpty == true ? nil : data
        }
    }

    func write(_ data: Data) async throws {
        try await AccessGoBlockingIO.run(on: .io) { [native, streamID] in
            try native.write(streamID, data: data)
        }
    }

    func close() {
        let shouldClose = closed.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard shouldClose else { return }
        AccessGoBlockingIO.enqueue(on: .control) { [native, streamID] in native.close(streamID) }
    }

    deinit { close() }
}

#if canImport(AegisEmbeddedCore)
private struct AccessGomobileCore: AccessGoNativeCore {
    var isRunning: Bool { EmbeddedcoreIsRunning() }
    func start(_ json: String) throws {
        var error: NSError?
        guard EmbeddedcoreStart(json, &error) else {
            throw error ?? AccessEmbeddedCoreError.unverifiedAsset
        }
    }
    func dial(host: String, port: UInt16) throws -> Int64 {
        var error: NSError?
        var id: Int64 = 0
        guard EmbeddedcoreDial(host, Int(port), &id, &error) else {
            throw error ?? AccessEmbeddedCoreError.unverifiedAsset
        }
        return id
    }
    func read(_ id: Int64, maxBytes: Int) throws -> Data? {
        var error: NSError?
        let data = EmbeddedcoreRead(id, maxBytes, &error)
        if let error { throw error }
        return data
    }
    func write(_ id: Int64, data: Data) throws {
        var error: NSError?
        guard EmbeddedcoreWrite(id, data, &error) else {
            throw error ?? AccessEmbeddedCoreError.unverifiedAsset
        }
    }
    func close(_ id: Int64) { EmbeddedcoreCloseStream(id) }
    func stop() {
        var error: NSError?
        _ = EmbeddedcoreStop(&error)
    }
}
#endif
