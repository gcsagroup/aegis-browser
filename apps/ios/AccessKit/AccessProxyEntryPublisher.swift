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
    private let healthCheck: (@MainActor () -> Bool)?
    private struct ProvisionID: Hashable {
        let identity: String
        let generation: UInt64
        init(_ endpoint: AccessManagedProxyEndpoint) {
            identity = endpoint.identity
            generation = endpoint.generation
        }
    }
    private var instance: Provision?
    private var consumers: [AccessHostStoreKey: ProvisionID] = [:]
    private var stoppedProvisions: Set<ProvisionID> = []
    /// Waiters keyed by operation, scoped to the generation they joined.
    private var waiters: [UUID: UInt64] = [:]
    private var inflight: Task<Provision, Error>?
    private var inflightGeneration: UInt64 = 0
    private var closedGenerations: Set<UInt64> = []
    private var nextGeneration: UInt64 = 0
    public private(set) var provisionCount: UInt64 = 0
    private var streamContinuation: AsyncStream<AccessManagedProxyEndpoint>.Continuation?
    private var cachedStream: AsyncStream<AccessManagedProxyEndpoint>?
    private var healthTask: Task<Void, Never>?

    public init(
        provision: @escaping @MainActor (UInt64, Duration) async throws -> Provision,
        shutdown: @escaping @MainActor (String) -> Void = { _ in },
        healthCheck: (@MainActor () -> Bool)? = nil
    ) {
        self.provision = provision
        self.shutdown = shutdown
        self.healthCheck = healthCheck
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
        if let current = currentEndpoint {
            waiters[request.operationID] = current.generation
            return AccessProxyEntryPrepareResult(operationID: request.operationID, endpoint: current)
        }
        let task: Task<Provision, Error>
        let generation: UInt64
        if let inflight {
            task = inflight
            generation = inflightGeneration
        } else {
            nextGeneration += 1
            provisionCount += 1
            generation = nextGeneration
            inflightGeneration = generation
            let deadline = request.deadline
            let started = Task { @MainActor in
                try await self.provision(generation, deadline)
            }
            inflight = started
            task = started
        }
        waiters[request.operationID] = generation
        let provisioned: Provision
        do {
            provisioned = try await task.value
        } catch {
            if waiters[request.operationID] == generation { waiters.removeValue(forKey: request.operationID) }
            if inflightGeneration == generation {
                closedGenerations.insert(generation)
                inflight = nil
                if var failed = instance, failed.endpoint.generation == generation {
                    failed.endpoint.state = .failed
                    failed.listenerReady = false
                    instance = failed
                    emit(failed.endpoint)
                }
                // Drop abandoned waiters that only belonged to this failed generation.
                waiters = waiters.filter { $0.value != generation }
            }
            throw error
        }
        if inflightGeneration == generation {
            inflight = nil
        }
        guard waiters[request.operationID] == generation else {
            // Last waiter cancelled while provision finished: destroy the unclaimed entry.
            // If other waiters remain for this generation, leave the provision for them.
            discardIfUnclaimed(provisioned, preparedFor: generation)
            throw CancellationError()
        }
        guard !closedGenerations.contains(generation) else {
            waiters.removeValue(forKey: request.operationID)
            throw AccessSiteSessionError.prepareFailed("入口这一代已经结束")
        }
        guard provisioned.endpoint.generation == generation else {
            waiters.removeValue(forKey: request.operationID)
            discardIfUnclaimed(provisioned, preparedFor: generation)
            throw AccessSiteSessionError.prepareFailed("入口版本与这次准备不一致")
        }
        instance = provisioned
        emit(provisioned.endpoint)
        startHealthWatch(generation: generation)
        return AccessProxyEntryPrepareResult(operationID: request.operationID, endpoint: provisioned.endpoint)
    }

    /// Removes one waiter. Retained host stores keep the entry.
    public func cancel(operationID: UUID) {
        waiters.removeValue(forKey: operationID)
        reapIfIdle()
    }

    public func validateReady(_ result: AccessProxyEntryPrepareResult) -> Bool {
        guard waiters[result.operationID] == result.endpoint.generation else { return false }
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
        consumers[key] = ProvisionID(endpoint)
        return true
    }

    public func release(for key: AccessHostStoreKey) {
        consumers.removeValue(forKey: key)
        reapIfIdle()
    }

    /// Marks the current generation finished. A later success for that generation stays failed.
    public func closeCurrentGeneration() {
        guard let instance, !closedGenerations.contains(instance.endpoint.generation) else { return }
        healthTask?.cancel()
        healthTask = nil
        closedGenerations.insert(instance.endpoint.generation)
        var failed = instance
        failed.endpoint.state = .failed
        failed.listenerReady = false
        failed.runtimeHealthy = false
        self.instance = failed
        // Failed metadata must not leave retained WebKit consumers on a live transport.
        // The session owns an asynchronous stop barrier before any later provision.
        stopOnce(instance)
        emit(failed.endpoint)
    }

    private func startHealthWatch(generation: UInt64) {
        guard let healthCheck else { return }
        healthTask?.cancel()
        healthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                guard self.instance?.endpoint.generation == generation,
                      !self.closedGenerations.contains(generation)
                else { return }
                if !healthCheck() {
                    self.closeCurrentGeneration()
                    return
                }
            }
        }
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

    private func discardIfUnclaimed(_ provision: Provision, preparedFor generation: UInt64) {
        let id = ProvisionID(provision.endpoint)
        guard !waiters.values.contains(generation), !consumers.values.contains(id) else { return }
        // A cancelled sibling can finish after a winner publishes this transport.
        // shutdown takes only an identity, so never stop a newer live publication
        // using that same identity either. Older failed metadata owns neither.
        if let instance, instance.endpoint.identity == id.identity,
           instance.endpoint.generation >= id.generation,
           !closedGenerations.contains(instance.endpoint.generation) { return }
        closedGenerations.insert(id.generation)
        stopOnce(provision)
    }

    private func stopOnce(_ provision: Provision) {
        guard stoppedProvisions.insert(ProvisionID(provision.endpoint)).inserted else { return }
        shutdown(provision.endpoint.identity)
    }

    private func reapIfIdle() {
        guard let instance, !waiters.values.contains(instance.endpoint.generation),
              !consumers.values.contains(ProvisionID(instance.endpoint)) else { return }
        healthTask?.cancel()
        healthTask = nil
        self.instance = nil
        closedGenerations.insert(instance.endpoint.generation)
        stopOnce(instance)
    }
}
