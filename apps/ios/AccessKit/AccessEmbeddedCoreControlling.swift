import Foundation

/// In-process Access core. Implementations must not start a subprocess.
public protocol AccessEmbeddedCoreControlling: AnyObject, Sendable {
    var isRunning: Bool { get }
    /// Atomically starts this configuration. A running foreign instance must
    /// cause failure. Success transfers responsibility for stopping to the caller.
    func start(configData: Data) async throws
    func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream
    /// Returns after the owned instance and its native stream operations have stopped.
    func stop() async
}

/// Fail-closed core used until a verified xcframework is linked.
public final class AccessUnverifiedEmbeddedCore: AccessEmbeddedCoreControlling, @unchecked Sendable {
    public init() {}

    public var isRunning: Bool { false }

    public func start(configData: Data) async throws {
        _ = configData
        throw AccessEmbeddedCoreError.unverifiedAsset
    }

    public func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        _ = host
        _ = port
        throw AccessEmbeddedCoreError.unverifiedAsset
    }

    public func stop() async {}
}
