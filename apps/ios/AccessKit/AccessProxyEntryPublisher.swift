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
    /// State lives only as long as a flight, callback, waiter or host owns this generation.
    /// Late completions share its terminal flags without retaining an ever-growing history.
    private final class Generation {
        let number: UInt64
        var isClosed = false
        var didDisposeProvision = false
        init(_ number: UInt64) { self.number = number }
    }
    private struct Publication {
        var provision: Provision
        let generation: Generation
    }
    private struct Flight {
        let task: Task<Provision, Error>
        let generation: Generation
    }
    private var instance: Publication?
    private var consumers: [AccessHostStoreKey: Publication] = [:]
    private var waiters: [UUID: Generation] = [:]
    private var inflight: Flight?
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
        guard let instance, isHealthy(instance.provision), !instance.generation.isClosed else { return nil }
        return instance.provision.endpoint
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
        if let current = currentEndpoint, let instance {
            waiters[request.operationID] = instance.generation
            return AccessProxyEntryPrepareResult(operationID: request.operationID, endpoint: current)
        }
        let flight: Flight
        if let inflight {
            flight = inflight
        } else {
            nextGeneration += 1
            provisionCount += 1
            let generation = Generation(nextGeneration)
            let deadline = request.deadline
            let task = Task { @MainActor in
                try await self.provision(generation.number, deadline)
            }
            flight = Flight(task: task, generation: generation)
            inflight = flight
        }
        let generation = flight.generation
        waiters[request.operationID] = generation
        let provisioned: Provision
        do {
            provisioned = try await flight.task.value
        } catch {
            if waiters[request.operationID] === generation { waiters.removeValue(forKey: request.operationID) }
            if inflight?.generation === generation {
                generation.isClosed = true
                inflight = nil
                // Drop abandoned waiters that only belonged to this failed generation.
                waiters = waiters.filter { $0.value !== generation }
            }
            throw error
        }
        let publication = Publication(provision: provisioned, generation: generation)
        guard waiters[request.operationID] === generation else {
            // Keep the completed flight available until a survivor publishes or the
            // last waiter leaves. A cancelled callback must not split this flight.
            discardIfUnclaimed(publication)
            throw CancellationError()
        }
        guard !generation.isClosed else {
            waiters.removeValue(forKey: request.operationID)
            throw AccessSiteSessionError.prepareFailed("入口这一代已经结束")
        }
        guard provisioned.endpoint.generation == generation.number else {
            waiters.removeValue(forKey: request.operationID)
            discardIfUnclaimed(publication)
            throw AccessSiteSessionError.prepareFailed("入口版本与这次准备不一致")
        }
        instance = publication
        if inflight?.generation === generation { inflight = nil }
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
        guard let instance, waiters[result.operationID] === instance.generation else { return false }
        guard !instance.generation.isClosed, isHealthy(instance.provision) else { return false }
        guard result.endpoint.identity == instance.provision.endpoint.identity else { return false }
        guard result.endpoint.generation == instance.generation.number else { return false }
        guard result.endpoint.state == .ready else { return false }
        guard result.endpoint.loopbackHost == "127.0.0.1", result.endpoint.port != 0 else { return false }
        return true
    }

    public func retain(_ endpoint: AccessManagedProxyEndpoint, for key: AccessHostStoreKey) -> Bool {
        guard let instance, !instance.generation.isClosed, isHealthy(instance.provision) else { return false }
        guard endpoint.identity == instance.provision.endpoint.identity,
              endpoint.generation == instance.generation.number
        else { return false }
        consumers[key] = instance
        return true
    }

    public func release(for key: AccessHostStoreKey) {
        consumers.removeValue(forKey: key)
        reapIfIdle()
    }

    /// Marks the current generation finished. A later success for that generation stays failed.
    public func closeCurrentGeneration() {
        guard var instance, !instance.generation.isClosed else { return }
        healthTask?.cancel()
        healthTask = nil
        instance.generation.isClosed = true
        instance.provision.endpoint.state = .failed
        instance.provision.listenerReady = false
        instance.provision.runtimeHealthy = false
        self.instance = instance
        // Explicit revocation stops even a retained transport. The session owns
        // the asynchronous core stop barrier before any later provision.
        stopOnce(instance)
        emit(instance.provision.endpoint)
    }

    private func startHealthWatch(generation: Generation) {
        guard let healthCheck else { return }
        healthTask?.cancel()
        healthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                guard self.instance?.generation === generation, !generation.isClosed else { return }
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

    private func discardIfUnclaimed(_ publication: Publication) {
        let generation = publication.generation
        guard !waiters.values.contains(where: { $0 === generation }),
              !consumers.values.contains(where: { $0.generation === generation && !$0.generation.isClosed })
        else { return }
        if inflight?.generation === generation { inflight = nil }
        generation.isClosed = true
        disposeIfUnowned(publication)
    }

    private func stopOnce(_ publication: Publication) {
        guard !publication.generation.didDisposeProvision else { return }
        publication.generation.didDisposeProvision = true
        shutdown(publication.provision.endpoint.identity)
    }

    private func disposeIfUnowned(_ publication: Publication) {
        let identity = publication.provision.endpoint.identity
        // shutdown accepts only a transport identity. Protect every live owner,
        // including an older generation if a producer reuses its listener.
        let ownedByInstance = instance.map {
            !$0.generation.isClosed && $0.provision.endpoint.identity == identity
        } ?? false
        let ownedByConsumer = consumers.values.contains {
            !$0.generation.isClosed && $0.provision.endpoint.identity == identity
        }
        if ownedByInstance || ownedByConsumer {
            publication.generation.didDisposeProvision = true
        } else {
            stopOnce(publication)
        }
    }

    private func reapIfIdle() {
        guard let instance,
              !waiters.values.contains(where: { $0 === instance.generation }),
              !consumers.values.contains(where: { $0.generation === instance.generation })
        else { return }
        healthTask?.cancel()
        healthTask = nil
        self.instance = nil
        instance.generation.isClosed = true
        disposeIfUnowned(instance)
    }
}
