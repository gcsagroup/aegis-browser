import Foundation

/// Reality dialer backed by the in-process core. Never falls back to URLSession.
public final class AccessEmbeddedRealityDialer: AccessRealityPathDialing, @unchecked Sendable {
    private let core: any AccessEmbeddedCoreControlling

    public init(core: any AccessEmbeddedCoreControlling) {
        self.core = core
    }

    public func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        guard core.isRunning else {
            throw AccessEmbeddedCoreError.unverifiedAsset
        }
        return try await core.dial(host: host, port: port)
    }
}
