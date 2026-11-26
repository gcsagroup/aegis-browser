import Foundation

public struct AccessProxyEntryPrepareRequest: Sendable, Equatable {
    public let operationID: UUID
    public let deadline: Duration

    public init(operationID: UUID, deadline: Duration) {
        self.operationID = operationID
        self.deadline = deadline
    }
}

public struct AccessProxyEntryPrepareResult: Sendable, Equatable {
    public let operationID: UUID
    public let endpoint: AccessManagedProxyEndpoint

    public init(operationID: UUID, endpoint: AccessManagedProxyEndpoint) {
        self.operationID = operationID
        self.endpoint = endpoint
    }
}

/// One app-wide WebKit entry. Host stores decide which tabs use it.
@MainActor
public protocol AccessProxyEntryPublishing: AnyObject {
    var currentEndpoint: AccessManagedProxyEndpoint? { get }
    var stateChanges: AsyncStream<AccessManagedProxyEndpoint> { get }
    func prepare(_ request: AccessProxyEntryPrepareRequest) async throws -> AccessProxyEntryPrepareResult
    func cancel(operationID: UUID)
    func validateReady(_ result: AccessProxyEntryPrepareResult) -> Bool
    /// Checks acceptance before replacing an existing store consumer.
    func retain(_ endpoint: AccessManagedProxyEndpoint, for key: AccessHostStoreKey,
                admitting: () -> Bool) -> Bool
    func release(for key: AccessHostStoreKey)
}

public extension AccessProxyEntryPublishing {
    func retain(_ endpoint: AccessManagedProxyEndpoint, for key: AccessHostStoreKey) -> Bool {
        retain(endpoint, for: key, admitting: { true })
    }
}
