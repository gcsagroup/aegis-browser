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

    public init() throws {
        #if !canImport(AegisEmbeddedCore)
        throw LinkError.frameworkNotLinked
        #endif
    }

    public var isRunning: Bool {
        #if canImport(AegisEmbeddedCore)
        return EmbeddedcoreIsRunning()
        #else
        return false
        #endif
    }

    public func start(configData: Data) async throws {
        #if canImport(AegisEmbeddedCore)
        guard let json = String(data: configData, encoding: .utf8) else {
            throw AccessEmbeddedCoreError.unverifiedAsset
        }
        try await Task.detached(priority: .userInitiated) {
            var error: NSError?
            guard EmbeddedcoreStart(json, &error) else {
                throw error ?? AccessEmbeddedCoreError.unverifiedAsset
            }
        }.value
        #else
        throw LinkError.frameworkNotLinked
        #endif
    }

    public func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        #if canImport(AegisEmbeddedCore)
        guard isRunning else { throw AccessEmbeddedCoreError.unverifiedAsset }
        let streamID = try await Task.detached(priority: .userInitiated) { () throws -> Int64 in
            var error: NSError?
            var id: Int64 = 0
            guard EmbeddedcoreDial(host, Int(port), &id, &error) else {
                throw error ?? AccessEmbeddedCoreError.unverifiedAsset
            }
            return id
        }.value
        return AccessGoEmbeddedStream(streamID: streamID)
        #else
        throw LinkError.frameworkNotLinked
        #endif
    }

    public func stop() async {
        #if canImport(AegisEmbeddedCore)
        await Task.detached(priority: .utility) {
            var error: NSError?
            _ = EmbeddedcoreStop(&error)
        }.value
        #endif
    }
}

#if canImport(AegisEmbeddedCore)
private final class AccessGoEmbeddedStream: AccessRealityPathStream, @unchecked Sendable {
    private let streamID: Int64
    /// Short critical section only — never held across `await`.
    private let closed = Mutex(false)

    init(streamID: Int64) {
        self.streamID = streamID
    }

    var isOpen: Bool {
        closed.withLock { !$0 }
    }

    func read(maxBytes: Int) async throws -> Data? {
        try await Task.detached(priority: .userInitiated) { [streamID] in
            var error: NSError?
            let data = EmbeddedcoreRead(streamID, maxBytes, &error)
            if let error { throw error }
            if let data, data.isEmpty { return nil }
            return data
        }.value
    }

    func write(_ data: Data) async throws {
        try await Task.detached(priority: .userInitiated) { [streamID] in
            var error: NSError?
            guard EmbeddedcoreWrite(streamID, data, &error) else {
                throw error ?? AccessEmbeddedCoreError.unverifiedAsset
            }
        }.value
    }

    func close() {
        let shouldClose = closed.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard shouldClose else { return }
        EmbeddedcoreCloseStream(streamID)
    }

    deinit { close() }
}
#endif
