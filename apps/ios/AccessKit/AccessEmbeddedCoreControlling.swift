import Foundation

/// In-process Access core. Implementations must not start a subprocess.
public protocol AccessEmbeddedCoreControlling: AnyObject, Sendable {
    var isRunning: Bool { get }
    func start(configData: Data) async throws
    func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream
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
