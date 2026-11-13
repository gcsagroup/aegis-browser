import Foundation

/// Product publisher used until a verified in-process core is linked.
@MainActor
public final class AccessFailClosedProxyEntryPublisher: AccessProxyEntryPublishing {
    public init() {}

    public var currentEndpoint: AccessManagedProxyEndpoint? { nil }

    public var stateChanges: AsyncStream<AccessManagedProxyEndpoint> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    public func prepare(_ request: AccessProxyEntryPrepareRequest) async throws -> AccessProxyEntryPrepareResult {
        _ = request
        throw AccessSiteSessionError.nodeUnavailable
    }

    public func cancel(operationID: UUID) {
        _ = operationID
    }

    public func validateReady(_ result: AccessProxyEntryPrepareResult) -> Bool {
        _ = result
        return false
    }

    public func retain(_ endpoint: AccessManagedProxyEndpoint, for key: AccessHostStoreKey) -> Bool {
        _ = endpoint
        _ = key
        return false
    }

    public func release(for key: AccessHostStoreKey) {
        _ = key
    }
}
