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
    func retain(_ endpoint: AccessManagedProxyEndpoint, for key: AccessHostStoreKey) -> Bool
    func release(for key: AccessHostStoreKey)
}
