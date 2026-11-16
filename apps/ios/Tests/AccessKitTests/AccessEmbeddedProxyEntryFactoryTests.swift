import XCTest
@testable import AccessKit

@MainActor
final class AccessEmbeddedProxyEntryFactoryTests: XCTestCase {
    func testMissingConfigStaysFailClosedEvenWithVerifiedLock() async {
        let json = """
        {"status":"verified_build","xrayCore":{"commit":"676eaf66f8f05d4d558ee7a74b4736623d3feeb9","tag":"v26.11.9"},"artifacts":{"iosArm64Sha256":"aa","iosArm64SimulatorSha256":"bb"}}
        """
        let publisher = AccessEmbeddedProxyEntryFactory.makeProductPublisher(
            lockData: Data(json.utf8),
            configPath: nil,
            verifiedCore: RecordingEmbeddedCoreForFactory()
        )
        do {
            _ = try await publisher.prepare(
                AccessProxyEntryPrepareRequest(operationID: UUID(), deadline: .seconds(5))
            )
            XCTFail("missing config must stay fail-closed")
        } catch let error as AccessSiteSessionError {
            XCTAssertEqual(error, .nodeUnavailable)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAccountProviderLoadsBeforeCoreStartWithoutStaticConfiguration() async throws {
        let json = """
        {"status":"verified_build","xrayCore":{"commit":"676eaf66f8f05d4d558ee7a74b4736623d3feeb9","tag":"v26.11.9"},"artifacts":{"iosArm64Sha256":"aa","iosArm64SimulatorSha256":"bb"}}
        """
        let core = RecordingEmbeddedCoreForFactory()
        var reads = 0
        let publisher = AccessEmbeddedProxyEntryFactory.makeProductPublisher(lockData: Data(json.utf8), configPath: nil,
            verifiedCore: core, parameters: {
                reads += 1
                return try AccessRealityVisionParameters(address: "node.invalid", port: 443,
                    userID: "550e8400-e29b-41d4-a716-446655440000", serverName: "www.example.com",
                    publicKey: "fixture-key", shortID: "")
            })
        XCTAssertEqual(reads, 0, "Do not fetch credentials during app initialization")
        let id = UUID()
        let result = try await publisher.prepare(.init(operationID: id, deadline: .seconds(5)))
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(publisher.validateReady(result))
        publisher.cancel(operationID: id)
    }

    func testAccountProviderFailureCannotFallBackToStaticNode() async throws {
        let json = """
        {"status":"verified_build","xrayCore":{"commit":"676eaf66f8f05d4d558ee7a74b4736623d3feeb9","tag":"v26.11.9"},"artifacts":{"iosArm64Sha256":"aa","iosArm64SimulatorSha256":"bb"}}
        """
        let core = RecordingEmbeddedCoreForFactory()
        let publisher = AccessEmbeddedProxyEntryFactory.makeProductPublisher(lockData: Data(json.utf8),
            configPath: "/unused/static/node", verifiedCore: core, parameters: { throw URLError(.cannotConnectToHost) })
        do {
            _ = try await publisher.prepare(.init(operationID: UUID(), deadline: .seconds(5)))
            XCTFail("Account failure must not reuse a static node")
        } catch { }
        XCTAssertFalse(core.isRunning)
        XCTAssertNil(publisher.currentEndpoint)
    }

    func testSourceCandidateStaysFailClosed() async {
        let json = """
        {"status":"source_candidate","xrayCore":{"commit":"676eaf66f8f05d4d558ee7a74b4736623d3feeb9","tag":"v26.11.9"},"artifacts":{"iosArm64Sha256":"aa","iosArm64SimulatorSha256":"bb"}}
        """
        let publisher = AccessEmbeddedProxyEntryFactory.makeProductPublisher(
            lockData: Data(json.utf8),
            configPath: "/tmp/does-not-matter",
            verifiedCore: RecordingEmbeddedCoreForFactory()
        )
        do {
            _ = try await publisher.prepare(
                AccessProxyEntryPrepareRequest(operationID: UUID(), deadline: .seconds(5))
            )
            XCTFail("source_candidate must stay fail-closed")
        } catch let error as AccessSiteSessionError {
            XCTAssertEqual(error, .nodeUnavailable)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

private final class RecordingEmbeddedCoreForFactory: AccessEmbeddedCoreControlling, @unchecked Sendable {
    nonisolated(unsafe) private var running = false
    var isRunning: Bool { running }

    func start(configData: Data) async throws {
        _ = configData
        running = true
    }

    func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        _ = host
        _ = port
        guard running else { throw AccessEmbeddedCoreError.unverifiedAsset }
        return AccessMemoryRealityStream()
    }

    func stop() async {
        running = false
    }
}

@MainActor
final class AccessEmbeddedTeardownTests: XCTestCase {
    func testThirdPrepareKeepsSharedListenerWhenCancelledWaiterResumesFirst() async throws {
        try await assertThirdPrepareKeepsSharedListener(cancelledPriority: .high, survivorPriority: .background)
    }

    func testThirdPrepareKeepsSharedListenerWhenSurvivorResumesFirst() async throws {
        try await assertThirdPrepareKeepsSharedListener(cancelledPriority: .background, survivorPriority: .high)
    }

    private func assertThirdPrepareKeepsSharedListener(cancelledPriority: TaskPriority, survivorPriority: TaskPriority) async throws {
        let core = DelayedStopCore()
        let coreStopped = expectation(description: "shared core stopped after last owner")
        core.onStop = { [weak core] _ in core?.finishStop(); coreStopped.fulfill() }
        defer { core.finishStop() }
        let firstGate = AccessProvisionTestGate(entered: expectation(description: "shared listener provisioned"))
        let thirdGate = AccessProvisionTestGate(entered: XCTestExpectation(description: "unexpected second flight"))
        defer { firstGate.finish(); thirdGate.finish() }
        let thirdBoundary = expectation(description: "third caller joined or started provision")
        var signalledThird = false
        @MainActor func signalThird() {
            guard !signalledThird else { return }
            signalledThird = true
            thirdBoundary.fulfill()
        }
        let parameters = try AccessRealityVisionParameters(address: "node.invalid", port: 443,
            userID: "550e8400-e29b-41d4-a716-446655440000", serverName: "www.example.com", publicKey: "fixture-key", shortID: "")
        let session = AccessEmbeddedProxyEntrySession(core: core, parameters: { parameters })
        var stopped: [String] = []
        let publisher = AccessProxyEntryPublisher(provision: { generation, deadline in
            let ready = try await session.provision(generation: generation, deadline: deadline)
            if generation == 1 { await firstGate.wait() }
            else { signalThird(); await thirdGate.wait() }
            return ready
        }, shutdown: { stopped.append($0); session.shutdown(identity: $0) })
        let cancelledID = UUID(), survivorID = UUID(), thirdID = UUID()
        let survivor = Task(priority: survivorPriority) {
            try await publisher.prepare(.init(operationID: survivorID, deadline: .seconds(5)))
        }
        await fulfillment(of: [firstGate.entered], timeout: 2)
        let cancelledEntered = expectation(description: "cancelled caller joined shared flight")
        // The third caller enters directly from the cancelled caller's completion,
        // without another task hop that would first let the survivor publish.
        let third = Task(priority: cancelledPriority) { @MainActor () throws -> AccessProxyEntryPrepareResult in
            cancelledEntered.fulfill()
            do {
                _ = try await publisher.prepare(.init(operationID: cancelledID, deadline: .seconds(5)))
                XCTFail("Cancelled caller claimed the provision")
            } catch is CancellationError {
                defer { signalThird() }
                return try await publisher.prepare(.init(operationID: thirdID, deadline: .seconds(5)))
            }
            throw AccessSiteSessionError.prepareFailed("Cancelled caller did not enter third preparation")
        }
        await fulfillment(of: [cancelledEntered], timeout: 2)
        publisher.cancel(operationID: cancelledID)
        firstGate.finish()
        // Either the third caller already got the shared result, or a faulty
        // split flight reached its real session provision and is held above.
        await fulfillment(of: [thirdBoundary], timeout: 2)
        let winner = try await survivor.value
        let host = AccessHostStoreKey(scopeID: "ordinary", host: try AccessSiteHost("winner.invalid"), isPrivate: false)
        XCTAssertTrue(publisher.retain(winner.endpoint, for: host))
        publisher.cancel(operationID: survivorID)
        publisher.cancel(operationID: thirdID)
        thirdGate.finish()
        do {
            let shared = try await third.value
            XCTAssertEqual(shared.endpoint.generation, winner.endpoint.generation)
        } catch is CancellationError { }
        XCTAssertEqual(publisher.provisionCount, 1, "One returned provision must remain shared until publication")
        XCTAssertTrue(session.isRuntimeHealthy, "Cancelling a third caller must not stop the retained winner's listener")
        XCTAssertTrue(stopped.isEmpty)
        publisher.release(for: host)
        await fulfillment(of: [coreStopped], timeout: 2)
        XCTAssertEqual(stopped, [winner.endpoint.identity])
    }

    func testCancelledReplacementStopsItsListenerAndNextPrepareWaitsForItsCore() async throws {
        let core = DelayedStopCore()
        defer { core.finishStop() }
        let stops = (1...3).map { expectation(description: "core stop \($0) entered") }
        let finalStopFinished = expectation(description: "final stop completed")
        core.onStop = { count in if count <= stops.count { stops[count - 1].fulfill() } }
        core.onStopFinished = { count in if count == 3 { finalStopFinished.fulfill() } }
        let gate = AccessProvisionTestGate(entered: expectation(description: "replacement listener is live"))
        defer { gate.finish() }
        let thirdEntered = expectation(description: "third preparation entered session")
        let parameters = try AccessRealityVisionParameters(address: "node.invalid", port: 443,
            userID: "550e8400-e29b-41d4-a716-446655440000", serverName: "www.example.com", publicKey: "fixture-key", shortID: "")
        var reads = 0
        let session = AccessEmbeddedProxyEntrySession(core: core, parameters: { reads += 1; return parameters })
        var replacement: AccessProxyEntryPublisher.Provision?
        var stopped: [String] = []
        let publisher = AccessProxyEntryPublisher(provision: { generation, deadline in
            if generation == 3 { thirdEntered.fulfill() }
            let provisioned = try await session.provision(generation: generation, deadline: deadline)
            if generation == 2 { replacement = provisioned; await gate.wait() }
            return provisioned
        }, shutdown: { identity in stopped.append(identity); session.shutdown(identity: identity) })
        let oldID = UUID(), replacementID = UUID(), thirdID = UUID()
        let first = try await publisher.prepare(.init(operationID: oldID, deadline: .seconds(5)))
        let oldHost = AccessHostStoreKey(scopeID: "ordinary", host: try AccessSiteHost("retained.invalid"), isPrivate: false)
        XCTAssertTrue(publisher.retain(first.endpoint, for: oldHost))
        publisher.cancel(operationID: oldID)
        publisher.closeCurrentGeneration()
        let next = Task { try await publisher.prepare(.init(operationID: replacementID, deadline: .seconds(5))) }
        await fulfillment(of: [stops[0]], timeout: 2)
        XCTAssertEqual(core.startCount, 1)
        core.finishStop()
        await fulfillment(of: [gate.entered], timeout: 2)
        let second = try XCTUnwrap(replacement)
        XCTAssertNotEqual(first.endpoint.identity, second.endpoint.identity)
        XCTAssertTrue(session.isRuntimeHealthy); XCTAssertEqual(core.startCount, 2)
        publisher.cancel(operationID: replacementID)
        gate.finish()
        do { _ = try await next.value; XCTFail("Cancelled replacement was published") }
        catch is CancellationError { }
        XCTAssertFalse(session.isRuntimeHealthy, "Unclaimed listener must close even while old host stores remain retained")
        await fulfillment(of: [stops[1]], timeout: 2)
        XCTAssertTrue(core.isRunning, "The synthetic stop barrier is still pending")
        let third = Task { try await publisher.prepare(.init(operationID: thirdID, deadline: .seconds(5))) }
        await fulfillment(of: [thirdEntered], timeout: 2)
        XCTAssertEqual(reads, 2); XCTAssertEqual(core.startCount, 2)
        XCTAssertNil(publisher.currentEndpoint)
        core.finishStop()
        let ready = try await third.value
        XCTAssertEqual(reads, 3); XCTAssertEqual(core.startCount, 3)
        XCTAssertTrue(publisher.validateReady(ready)); XCTAssertTrue(session.isRuntimeHealthy)
        publisher.cancel(operationID: thirdID)
        await fulfillment(of: [stops[2]], timeout: 2)
        publisher.release(for: oldHost)
        publisher.cancel(operationID: replacementID)
        publisher.closeCurrentGeneration()
        XCTAssertEqual(stopped, [first.endpoint.identity, second.endpoint.identity, ready.endpoint.identity])
        core.finishStop()
        await fulfillment(of: [finalStopFinished], timeout: 2)
        XCTAssertFalse(core.isRunning)
    }

    func testRevocationStopsRetainedTransportAndNextPrepareWaitsAndReauthorizes() async throws {
        let core = DelayedStopCore()
        let parameters = try AccessRealityVisionParameters(address: "node.invalid", port: 443,
            userID: "550e8400-e29b-41d4-a716-446655440000", serverName: "www.example.com", publicKey: "fixture-key", shortID: "")
        var authorized = true
        var reads = 0
        let session = AccessEmbeddedProxyEntrySession(core: core, parameters: {
            reads += 1
            guard authorized else { throw URLError(.userAuthenticationRequired) }
            return parameters
        })
        let publisher = AccessProxyEntryPublisher(provision: { try await session.provision(generation: $0, deadline: $1) },
            shutdown: { session.shutdown(identity: $0) }, healthCheck: { session.isRuntimeHealthy && authorized })
        let firstID = UUID()
        let first = try await publisher.prepare(.init(operationID: firstID, deadline: .seconds(5)))
        let key = AccessHostStoreKey(scopeID: "retained", host: try AccessSiteHost("site.invalid"), isPrivate: false)
        XCTAssertTrue(publisher.retain(first.endpoint, for: key))
        publisher.cancel(operationID: firstID)
        authorized = false
        // Exercise the actual health watcher rather than manually marking metadata failed.
        for _ in 0..<150 where core.stopCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(core.stopCount, 1)
        XCTAssertFalse(session.isRuntimeHealthy, "Retained listener must be closed on revocation")
        XCTAssertNil(publisher.currentEndpoint)
        let nextID = UUID()
        let next = Task { try await publisher.prepare(.init(operationID: nextID, deadline: .seconds(5))) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(reads, 1, "New authorization must wait for old transport teardown")
        core.finishStop()
        do { _ = try await next.value; XCTFail("Revoked account reused its running transport") } catch { }
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(core.startCount, 1)
        XCTAssertFalse(core.isRunning)
        publisher.release(for: key)
        publisher.cancel(operationID: nextID)
    }

    func testPublisherWaitsForOldStopBeforeNewReadyAndDial() async throws {
        let core = DelayedStopCore()
        let parameters = try AccessRealityVisionParameters(
            address: "198.51.100.10", port: 443,
            userID: "550e8400-e29b-41d4-a716-446655440000", serverName: "www.example.com",
            publicKey: "abcdefghijklmnopqrstuvwxyzABCDEFG", shortID: "abcd1234"
        )
        let outbound = try AccessRealityVisionOutboundConfigBuilder.build(parameters: parameters)
        let session = AccessEmbeddedProxyEntrySession(core: core, outbound: outbound)
        let publisher = AccessProxyEntryPublisher(
            provision: { try await session.provision(generation: $0, deadline: $1) },
            shutdown: { session.shutdown(identity: $0) },
            healthCheck: { session.isRuntimeHealthy }
        )
        let firstID = UUID()
        let first = try await publisher.prepare(.init(operationID: firstID, deadline: .seconds(5)))
        let host = try AccessSiteHost("controlled.invalid")
        let firstKey = AccessHostStoreKey(scopeID: "one", host: host, isPrivate: false)
        let otherKey = AccessHostStoreKey(scopeID: "two", host: host, isPrivate: false)
        XCTAssertTrue(publisher.retain(first.endpoint, for: firstKey))
        XCTAssertTrue(publisher.retain(first.endpoint, for: otherKey))
        publisher.cancel(operationID: firstID)
        publisher.release(for: firstKey)
        XCTAssertTrue(session.isRuntimeHealthy, "other retained client keeps generation alive")
        XCTAssertEqual(core.stopCount, 0)
        publisher.release(for: otherKey)

        let nextID = UUID(), cancelledID = UUID()
        var becameReady = false
        let next = Task {
            let result = try await publisher.prepare(.init(operationID: nextID, deadline: .seconds(5)))
            becameReady = true
            return result
        }
        let cancelled = Task {
            try await publisher.prepare(.init(operationID: cancelledID, deadline: .seconds(5)))
        }
        let limit = Date().addingTimeInterval(2)
        while core.stopCount == 0, Date() < limit { await Task.yield() }
        // Let both normal prepare waiters enter the pending teardown barrier.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(core.stopCount, 1)
        XCTAssertTrue(core.isRunning, "synthetic old stop has not finished")
        XCTAssertFalse(becameReady)
        XCTAssertNil(publisher.currentEndpoint)
        XCTAssertFalse(session.isRuntimeHealthy)
        XCTAssertEqual(core.startCount, 1)
        publisher.cancel(operationID: cancelledID)
        core.finishStop()
        let restarted = try await next.value
        do { _ = try await cancelled.value; XCTFail("cancelled waiter must not claim entry") }
        catch is CancellationError {}
        XCTAssertEqual(core.startCount, 2)
        XCTAssertNotEqual(restarted.endpoint.generation, first.endpoint.generation)
        XCTAssertTrue(publisher.validateReady(restarted))
        XCTAssertTrue(session.isRuntimeHealthy)
        let stream = try await core.dial(host: "controlled.invalid", port: 443)
        try await stream.write(Data("after restart".utf8))
        XCTAssertTrue(stream.isOpen)
        stream.close()
        publisher.cancel(operationID: nextID)
        let cleanupLimit = Date().addingTimeInterval(2)
        while core.stopCount < 2, Date() < cleanupLimit { await Task.yield() }
        XCTAssertEqual(core.stopCount, 2)
        core.finishStop()
    }
}

private final class DelayedStopCore: AccessEmbeddedCoreControlling, @unchecked Sendable {
    // All test mutations run on MainActor, including the async native stub.
    @MainActor init() {}
    @MainActor private var running = false
    @MainActor private(set) var startCount = 0
    @MainActor private(set) var stopCount = 0
    @MainActor private var stopContinuation: CheckedContinuation<Void, Never>?
    @MainActor var onStop: ((Int) -> Void)?
    @MainActor var onStopFinished: ((Int) -> Void)?
    var isRunning: Bool { MainActor.assumeIsolated { running } }
    @MainActor func start(configData: Data) { startCount += 1; running = true }
    @MainActor func dial(host: String, port: UInt16) throws -> any AccessRealityPathStream {
        guard running else { throw AccessEmbeddedCoreError.unverifiedAsset }
        return AccessMemoryRealityStream()
    }
    @MainActor func stop() async {
        await withCheckedContinuation { stopContinuation = $0; stopCount += 1; onStop?(stopCount) }
        running = false
        onStopFinished?(stopCount)
    }
    @MainActor func finishStop() { stopContinuation?.resume(); stopContinuation = nil }
}
