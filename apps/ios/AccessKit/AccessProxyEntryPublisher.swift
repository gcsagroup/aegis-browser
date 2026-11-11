import Foundation

/// Shared loopback entry. A healthy instance is reused; a new instance gets a new generation.
@MainActor
public final class AccessProxyEntryPublisher: AccessProxyEntryPublishing {
    public struct Provision: Sendable, Equatable {
        public var endpoint: AccessManagedProxyEndpoint
        public var listenerReady: Bool
        public var runtimeHealthy: Bool
        public var bridgeInstalled: Bool

        public init(
            endpoint: AccessManagedProxyEndpoint,
            listenerReady: Bool,
            runtimeHealthy: Bool,
            bridgeInstalled: Bool
        ) {
            self.endpoint = endpoint
            self.listenerReady = listenerReady
            self.runtimeHealthy = runtimeHealthy
            self.bridgeInstalled = bridgeInstalled
        }
    }

    private let provision: @MainActor (UInt64, Duration) async throws -> Provision
    private let shutdown: @MainActor (String) -> Void
    private var instance: Provision?
    private var consumers: [AccessHostStoreKey: String] = [:]
    private var waiters: Set<UUID> = []
    private var inflight: Task<Provision, Error>?
    private var inflightGeneration: UInt64 = 0
    private var closedGenerations: Set<UInt64> = []
    private var nextGeneration: UInt64 = 0
    public private(set) var provisionCount: UInt64 = 0
    private var streamContinuation: AsyncStream<AccessManagedProxyEndpoint>.Continuation?
    private var cachedStream: AsyncStream<AccessManagedProxyEndpoint>?

    public init(
        provision: @escaping @MainActor (UInt64, Duration) async throws -> Provision,
        shutdown: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.provision = provision
        self.shutdown = shutdown
    }

    public var currentEndpoint: AccessManagedProxyEndpoint? {
        guard let instance, isHealthy(instance), !closedGenerations.contains(instance.endpoint.generation) else {
            return nil
        }
        return instance.endpoint
    }

    public var stateChanges: AsyncStream<AccessManagedProxyEndpoint> {
        if let cachedStream { return cachedStream }
        let created = AsyncStream<AccessManagedProxyEndpoint> { continuation in
            self.streamContinuation = continuation
        }
        cachedStream = created
        return created
    }

    public func prepare(_ request: AccessProxyEntryPrepareRequest) async throws -> AccessProxyEntryPrepareResult {
        waiters.insert(request.operationID)
        if let current = currentEndpoint {
            return AccessProxyEntryPrepareResult(operationID: request.operationID, endpoint: current)
        }
        let task: Task<Provision, Error>
        if let inflight {
            task = inflight
        } else {
            nextGeneration += 1
            provisionCount += 1
            let generation = nextGeneration
            inflightGeneration = generation
            let deadline = request.deadline
            let started = Task { @MainActor in
                try await self.provision(generation, deadline)
            }
            inflight = started
            task = started
        }
        let generation = inflightGeneration
        let provisioned: Provision
        do {
            provisioned = try await task.value
        } catch {
            if inflightGeneration == generation {
                closedGenerations.insert(generation)
                inflight = nil
                if var failed = instance, failed.endpoint.generation == generation {
                    failed.endpoint.state = .failed
                    failed.listenerReady = false
                    instance = failed
                    emit(failed.endpoint)
                }
            }
            throw error
        }
        if inflightGeneration == generation {
            inflight = nil
        }
        guard waiters.contains(request.operationID) else {
            // Last waiter cancelled while provision finished: destroy the unclaimed entry.
            // If other waiters remain, leave the provision for them to install.
            if waiters.isEmpty, consumers.isEmpty, instance == nil {
                closedGenerations.insert(provisioned.endpoint.generation)
                shutdown(provisioned.endpoint.identity)
            }
            throw CancellationError()
        }
        guard !closedGenerations.contains(generation) else {
            throw AccessSiteSessionError.prepareFailed("入口这一代已经结束")
        }
        guard provisioned.endpoint.generation == generation else {
            throw AccessSiteSessionError.prepareFailed("入口版本与这次准备不一致")
        }
        instance = provisioned
        emit(provisioned.endpoint)
        return AccessProxyEntryPrepareResult(operationID: request.operationID, endpoint: provisioned.endpoint)
    }

    /// Removes one waiter. Retained host stores keep the entry.
    public func cancel(operationID: UUID) {
        waiters.remove(operationID)
        reapIfIdle()
    }

    public func validateReady(_ result: AccessProxyEntryPrepareResult) -> Bool {
        guard waiters.contains(result.operationID) else { return false }
        guard let instance, isHealthy(instance) else { return false }
        guard !closedGenerations.contains(instance.endpoint.generation) else { return false }
        guard result.endpoint.identity == instance.endpoint.identity else { return false }
        guard result.endpoint.generation == instance.endpoint.generation else { return false }
        guard result.endpoint.state == .ready else { return false }
        guard result.endpoint.loopbackHost == "127.0.0.1", result.endpoint.port != 0 else { return false }
        return true
    }

    public func retain(_ endpoint: AccessManagedProxyEndpoint, for key: AccessHostStoreKey) -> Bool {
        guard let instance, isHealthy(instance) else { return false }
        guard endpoint.identity == instance.endpoint.identity,
              endpoint.generation == instance.endpoint.generation
        else { return false }
        consumers[key] = endpoint.identity
        return true
    }

    public func release(for key: AccessHostStoreKey) {
        consumers.removeValue(forKey: key)
        reapIfIdle()
    }

    /// Marks the current generation finished. A later success for that generation stays failed.
    public func closeCurrentGeneration() {
        guard let instance else { return }
        closedGenerations.insert(instance.endpoint.generation)
        var failed = instance
        failed.endpoint.state = .failed
        failed.listenerReady = false
        failed.runtimeHealthy = false
        self.instance = failed
        emit(failed.endpoint)
    }

    private func isHealthy(_ provision: Provision) -> Bool {
        provision.listenerReady
            && provision.runtimeHealthy
            && provision.bridgeInstalled
            && provision.endpoint.state == .ready
            && provision.endpoint.loopbackHost == "127.0.0.1"
            && provision.endpoint.port != 0
            && !provision.endpoint.identity.isEmpty
    }

    private func emit(_ endpoint: AccessManagedProxyEndpoint) {
        streamContinuation?.yield(endpoint)
    }

    private func reapIfIdle() {
        guard waiters.isEmpty, consumers.isEmpty, let instance else { return }
        let identity = instance.endpoint.identity
        self.instance = nil
        shutdown(identity)
    }
}
