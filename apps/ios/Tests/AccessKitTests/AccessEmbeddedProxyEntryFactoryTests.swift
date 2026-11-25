import Network
import Synchronization
import XCTest
@testable import AccessKit

@MainActor
final class AccessEmbeddedProxyEntryFactoryTests: XCTestCase {
    func testValidProductConfigurationWithoutRetirementProviderStaysClosed() async {
        let lock = Data(#"{"status":"verified_build","xrayCore":{"commit":"676eaf66f8f05d4d558ee7a74b4736623d3feeb9","tag":"v26.11.9"},"artifacts":{"iosArm64Sha256":"aa","iosArm64SimulatorSha256":"bb"}}"#.utf8)
        let core = RecordingEmbeddedCoreForFactory()
        let publisher = AccessEmbeddedProxyEntryFactory.makeProductPublisher(lockData: lock, configPath: nil,
            verifiedCore: core, parameters: {
                XCTFail("Document retirement must be required before authorization")
                throw URLError(.userAuthenticationRequired)
            })
        XCTAssertTrue(publisher is AccessFailClosedProxyEntryPublisher)
        do {
            _ = try await publisher.prepare(.init(operationID: UUID(), deadline: .seconds(1)))
            XCTFail("Published with no document retirement provider")
        } catch {}
        XCTAssertFalse(core.isRunning)
        XCTAssertNil(publisher.currentEndpoint)
    }

    func testMissingConfigStaysFailClosedEvenWithVerifiedLock() async {
        let json = """
        {"status":"verified_build","xrayCore":{"commit":"676eaf66f8f05d4d558ee7a74b4736623d3feeb9","tag":"v26.11.9"},"artifacts":{"iosArm64Sha256":"aa","iosArm64SimulatorSha256":"bb"}}
        """
        let publisher = AccessEmbeddedProxyEntryFactory.makeProductPublisher(
            lockData: Data(json.utf8),
            configPath: nil,
            verifiedCore: RecordingEmbeddedCoreForFactory(), retireDocuments: { _, finish in finish() }
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
            }, retireDocuments: { _, finish in finish() })
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
            configPath: "/unused/static/node", verifiedCore: core, parameters: { throw URLError(.cannotConnectToHost) },
            retireDocuments: { _, finish in finish() })
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
            verifiedCore: RecordingEmbeddedCoreForFactory(), retireDocuments: { _, finish in finish() }
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

private final class RecordingEmbeddedCoreForFactory: AccessEmbeddedCoreControlling, Sendable {
    private struct State {
        var running = false
        var configuration: Data?
    }
    private let state = Mutex(State())
    var configuration: Data? { state.withLock { $0.configuration } }
    var isRunning: Bool { state.withLock { $0.running } }

    func start(configData: Data) async throws {
        try state.withLock {
            guard !$0.running else { throw AccessEmbeddedCoreError.unverifiedAsset }
            $0.configuration = configData
            $0.running = true
        }
    }

    func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        _ = host
        _ = port
        guard isRunning else { throw AccessEmbeddedCoreError.unverifiedAsset }
        return AccessMemoryRealityStream()
    }

    func stop() async {
        state.withLock { $0.running = false }
    }
}

@MainActor
final class AccessEmbeddedTeardownTests: XCTestCase {
    func testForeignStartAfterInitialHealthReadCannotReachSocketOrOwnTeardown() async throws {
        let core = ForeignStartDuringHealthRead()
        let parameters = try AccessRealityVisionParameters(address: "owned.invalid", port: 443,
            userID: "550e8400-e29b-41d4-a716-446655440000", serverName: "owned.invalid", publicKey: "fixture-key", shortID: "")
        let session = AccessEmbeddedProxyEntrySession(core: core, parameters: { parameters },
            retireDocuments: { _, _ in XCTFail("A failed provision cannot owe a document") },
            reserveSocket: { XCTFail("A foreign core reached listener reservation"); throw CancellationError() })
        do {
            _ = try await session.provision(generation: 1, deadline: .seconds(1))
            XCTFail("A foreign core published")
        } catch {}
        XCTAssertEqual(core.starts.withLock { $0 }, 1)
        XCTAssertEqual(core.stops.withLock { $0 }, 0)
        XCTAssertTrue(core.isRunning)
    }

    func testFreshPublishersWithRevisedOutboundOnSamePortHaveDistinctReceipts() async throws {
        let firstSocket = try await AccessEmbeddedProxyEntrySession.reserveLoopbackSocket()
        let port = try XCTUnwrap(firstSocket.port)
        let operation = UUID()
        var bindings: [AccessManagedProxyEndpoint] = []
        var configurations: [Data] = []
        for (index, host) in ["first.invalid", "revised.invalid"].enumerated() {
            let core = RecordingEmbeddedCoreForFactory()
            var retiring: [String] = []
            let parameters = try AccessRealityVisionParameters(address: host, port: 443,
                userID: "550e8400-e29b-41d4-a716-446655440000", serverName: host, publicKey: "fixture-key", shortID: "")
            let session = AccessEmbeddedProxyEntrySession(core: core, parameters: { parameters },
                retireDocuments: { identity, finish in retiring.append(identity); finish() },
                reserveSocket: {
                    if index == 0 { return firstSocket }
                    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                    while true {
                        do { return try await AccessEmbeddedProxyEntrySession.reserveLoopbackSocket(on: port) }
                        catch NWError.posix(.EADDRINUSE) where ContinuousClock.now < deadline {
                            try await Task.sleep(for: .milliseconds(20))
                        }
                    }
                })
            let publisher = AccessProxyEntryPublisher(
                provision: { try await session.provision(generation: $0, deadline: $1) },
                shutdown: { session.shutdown(identity: $0) }, activate: { session.activate() },
                healthCheck: { session.isRuntimeHealthy })
            defer { publisher.cancel(operationID: operation) }
            let result = try await publisher.prepare(.init(operationID: operation, deadline: .seconds(5)))
            XCTAssertEqual(result.endpoint.port, port.rawValue)
            XCTAssertEqual(result.endpoint.generation, 1)
            XCTAssertTrue(publisher.validateReady(result))
            if let old = bindings.first {
                XCTAssertFalse(publisher.validateReady(.init(operationID: operation, endpoint: old)))
                session.shutdown(identity: old.identity)
                XCTAssertTrue(publisher.validateReady(result))
                XCTAssertTrue(session.isRuntimeHealthy)
                XCTAssertTrue(retiring.isEmpty)
            } else {
                do {
                    let duplicate = try await AccessEmbeddedProxyEntrySession.reserveLoopbackSocket(on: port)
                    duplicate.cancel()
                    XCTFail("A fixed-port reservation displaced the live listener")
                } catch NWError.posix(.EADDRINUSE) {}
                XCTAssertTrue(session.isRuntimeHealthy)
            }
            bindings.append(result.endpoint)
            configurations.append(try XCTUnwrap(core.configuration))
            publisher.closeCurrentGeneration()
            XCTAssertEqual(retiring, [result.endpoint.identity])
        }
        XCTAssertNotEqual(bindings[0].identity, bindings[1].identity)
        XCTAssertNotEqual(configurations[0], configurations[1])
    }

    func testThirdPrepareKeepsSharedListenerWhenCancelledWaiterResumesFirst() async throws {
        try await assertThirdPrepareKeepsSharedListener(cancelledFirst: true)
    }

    func testThirdPrepareKeepsSharedListenerWhenSurvivorResumesFirst() async throws {
        try await assertThirdPrepareKeepsSharedListener(cancelledFirst: false)
    }

    private func assertThirdPrepareKeepsSharedListener(cancelledFirst: Bool) async throws {
        let core = DelayedStopCore()
        let coreStopped = XCTestExpectation(description: "shared core stopped after last owner")
        core.onStop = { [weak core] _ in core?.finishStop(); coreStopped.fulfill() }
        let parameters = try AccessRealityVisionParameters(address: "node.invalid", port: 443,
            userID: "550e8400-e29b-41d4-a716-446655440000", serverName: "www.example.com", publicKey: "fixture-key", shortID: "")
        let session = AccessEmbeddedProxyEntrySession(core: core, parameters: { parameters }, retireDocuments: { _, finish in finish() })
        let deadline: Duration = .seconds(5)
        // Stage the real listener before controlling the two waiters' handoff.
        let initial = try await session.provision(generation: 1, deadline: deadline)
        defer { session.shutdown(identity: initial.endpoint.identity) }

        let firstGate = AccessProvisionTestGate(entered: XCTestExpectation(description: "shared provision held before publication"))
        let thirdGate = AccessProvisionTestGate(entered: XCTestExpectation(description: "unexpected second flight"))
        defer { firstGate.finish(); thirdGate.finish() }
        let thirdBoundary = XCTestExpectation(description: "third caller finished or second provision reached its gate")
        var signalledThird = false
        @MainActor func signalThird() {
            guard !signalledThird else { return }
            signalledThird = true
            thirdBoundary.fulfill()
        }
        var stopped: [String] = []
        let publisher = AccessProxyEntryPublisher(provision: { generation, deadline in
            if generation == 1 {
                await firstGate.wait()
                return initial
            }
            let ready = try await session.provision(generation: generation, deadline: deadline)
            signalThird()
            await thirdGate.wait()
            return ready
        }, shutdown: { stopped.append($0); session.shutdown(identity: $0) }, activate: { session.activate() })
        let cancelledID = UUID(), survivorID = UUID(), thirdID = UUID()
        let secondCallback = AccessProvisionTestGate(entered: XCTestExpectation(description: "second callback at publication"))
        publisher.beforeFlightPublication = { id in
            if id == (cancelledFirst ? survivorID : cancelledID) { await secondCallback.wait() }
        }
        defer { secondCallback.finish() }
        var callbackOrder: [UUID] = []
        let survivorFinished = XCTestExpectation(description: "survivor prepare returned")
        let host = AccessHostStoreKey(scopeID: "ordinary", host: try AccessSiteHost("winner.invalid"), isPrivate: false)
        let survivor = Task {
            defer { survivorFinished.fulfill() }
            try Task.checkCancellation()
            let result = try await publisher.prepare(.init(operationID: survivorID, deadline: deadline))
            callbackOrder.append(survivorID)
            return result
        }
        defer {
            survivor.cancel()
            publisher.cancel(operationID: survivorID)
            publisher.release(for: host)
        }
        guard await XCTWaiter.fulfillment(of: [firstGate.entered], timeout: 2) == .completed else {
            return XCTFail("Survivor did not start the shared flight")
        }
        let cancelledEntered = XCTestExpectation(description: "cancelled caller joined shared flight")
        // Enter the third prepare in the same actor turn as the cancelled callback.
        let thirdFinished = XCTestExpectation(description: "third prepare returned")
        let third = Task { @MainActor () throws -> AccessProxyEntryPrepareResult in
            defer { signalThird() }
            defer { thirdFinished.fulfill() }
            try Task.checkCancellation()
            // prepare registers on MainActor before suspending on the flight.
            cancelledEntered.fulfill()
            do {
                _ = try await publisher.prepare(.init(operationID: cancelledID, deadline: deadline))
                XCTFail("Cancelled caller claimed the provision")
            } catch is CancellationError {
                callbackOrder.append(cancelledID)
                if cancelledFirst {
                    XCTAssertNil(publisher.currentEndpoint, "The cancelled callback must precede any publication")
                } else {
                    XCTAssertEqual(publisher.currentEndpoint, initial.endpoint)
                }
                try Task.checkCancellation()
                return try await publisher.prepare(.init(operationID: thirdID, deadline: deadline))
            }
            throw AccessSiteSessionError.prepareFailed("Cancelled caller did not enter third preparation")
        }
        defer {
            third.cancel()
            publisher.cancel(operationID: cancelledID)
            publisher.cancel(operationID: thirdID)
        }
        guard await XCTWaiter.fulfillment(of: [cancelledEntered], timeout: 2) == .completed else {
            return XCTFail("Second waiter did not enter the shared flight")
        }
        publisher.cancel(operationID: cancelledID)
        firstGate.finish()
        guard await XCTWaiter.fulfillment(of: [secondCallback.entered], timeout: 2) == .completed else {
            return XCTFail("Second callback did not reach the publication gate")
        }
        let firstCompletion = cancelledFirst ? thirdBoundary : survivorFinished
        guard await XCTWaiter.fulfillment(of: [firstCompletion], timeout: 2) == .completed else {
            return XCTFail("First callback did not resolve while the second was held")
        }
        XCTAssertEqual(callbackOrder, [cancelledFirst ? cancelledID : survivorID])
        secondCallback.finish()
        // Hold any split flight after it provisions so cancellation exercises disposal.
        let remainingCompletion = cancelledFirst ? survivorFinished : thirdBoundary
        guard await XCTWaiter.fulfillment(of: [remainingCompletion], timeout: 2) == .completed else {
            return XCTFail("Second callback did not resolve")
        }
        XCTAssertEqual(callbackOrder, cancelledFirst ? [cancelledID, survivorID] : [survivorID, cancelledID])
        let winner = try await survivor.value
        XCTAssertTrue(publisher.retain(winner.endpoint, for: host))
        publisher.cancel(operationID: survivorID)
        publisher.cancel(operationID: thirdID)
        thirdGate.finish()
        guard await XCTWaiter.fulfillment(of: [thirdFinished], timeout: 2) == .completed else {
            return XCTFail("Third prepare did not return after cleanup")
        }
        do {
            let shared = try await third.value
            XCTAssertEqual(shared.endpoint, winner.endpoint)
        } catch is CancellationError {
            XCTAssertGreaterThan(publisher.provisionCount, 1, "The shared third prepare must return before cleanup")
        }
        XCTAssertEqual(publisher.provisionCount, 1, "One returned provision must remain shared until publication")
        XCTAssertTrue(session.isRuntimeHealthy, "Cancelling a third caller must not stop the retained winner's listener")
        XCTAssertTrue(stopped.isEmpty)
        publisher.release(for: host)
        let stopResult = await XCTWaiter.fulfillment(of: [coreStopped], timeout: 2)
        XCTAssertEqual(stopResult, .completed)
        XCTAssertEqual(stopped, [winner.endpoint.identity])
    }

    func testCancelledReplacementStopsItsListenerAndNextPrepareWaitsForItsCore() async throws {
        let core = DelayedStopCore()
        defer { core.finishStop() }
        let stops = (1...3).map { expectation(description: "core stop \($0) entered") }
        let finalStopFinished = expectation(description: "final stop completed")
        core.onStop = { count in if count <= stops.count { stops[count - 1].fulfill() } }
        core.onStopFinished = { count in if count == 3 { finalStopFinished.fulfill() } }
        let gate = AccessProvisionTestGate(entered: expectation(description: "replacement socket is bound before publication"))
        defer { gate.finish() }
        let thirdEntered = expectation(description: "third preparation entered session")
        let parameters = try AccessRealityVisionParameters(address: "node.invalid", port: 443,
            userID: "550e8400-e29b-41d4-a716-446655440000", serverName: "www.example.com", publicKey: "fixture-key", shortID: "")
        var reads = 0
        let session = AccessEmbeddedProxyEntrySession(core: core, parameters: { reads += 1; return parameters },
            retireDocuments: { _, finish in finish() })
        var replacement: AccessProxyEntryPublisher.Provision?
        var stopped: [String] = []
        let publisher = AccessProxyEntryPublisher(provision: { generation, deadline in
            if generation == 3 { thirdEntered.fulfill() }
            let provisioned = try await session.provision(generation: generation, deadline: deadline)
            if generation == 2 { replacement = provisioned; await gate.wait() }
            return provisioned
        }, shutdown: { identity in stopped.append(identity); session.shutdown(identity: identity) }, activate: { session.activate() })
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
        XCTAssertFalse(session.isRuntimeHealthy, "A bound replacement is paused before publication")
        XCTAssertEqual(core.startCount, 2)
        publisher.cancel(operationID: replacementID)
        let refused = expectation(description: "paused replacement closes a new connection")
        let client = NWConnection(host: "127.0.0.1",
                                  port: try XCTUnwrap(NWEndpoint.Port(rawValue: second.endpoint.port)), using: .tcp)
        defer { client.cancel() }
        client.stateUpdateHandler = { [weak client] state in
            guard case .ready = state, let client else { return }
            client.send(content: Data("CONNECT probe.invalid:443 HTTP/1.1\r\nHost: probe.invalid:443\r\n\r\n".utf8),
                        completion: .contentProcessed { _ in })
            client.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, complete, error in
                XCTAssertTrue(data?.isEmpty != false)
                XCTAssertTrue(complete || error != nil)
                refused.fulfill()
            }
        }
        client.start(queue: .global())
        await fulfillment(of: [refused], timeout: 2)
        XCTAssertEqual(core.dialCount, 0, "A cancelled waiter's paused listener must never dial")
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
        var retiringIdentity: String?
        var releasePort: (@MainActor () -> Void)?
        defer { releasePort?() }
        let session = AccessEmbeddedProxyEntrySession(core: core, parameters: {
            reads += 1
            guard authorized else { throw URLError(.userAuthenticationRequired) }
            return parameters
        }, retireDocuments: { identity, finish in
            retiringIdentity = identity
            releasePort = finish
        })
        let publisher = AccessProxyEntryPublisher(provision: { try await session.provision(generation: $0, deadline: $1) },
            shutdown: { session.shutdown(identity: $0) }, activate: { session.activate() }, healthCheck: { session.isRuntimeHealthy && authorized })
        let firstID = UUID()
        let first = try await publisher.prepare(.init(operationID: firstID, deadline: .seconds(5)))
        let key = AccessHostStoreKey(scopeID: "retained", host: try AccessSiteHost("site.invalid"), isPrivate: false)
        XCTAssertTrue(publisher.retain(first.endpoint, for: key))
        publisher.cancel(operationID: firstID)
        authorized = false
        // Exercise the actual health watcher rather than manually marking metadata failed.
        for _ in 0..<150 where core.stopCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(core.stopCount, 1)
        XCTAssertFalse(session.isRuntimeHealthy, "Retained listener must be fenced on revocation")
        XCTAssertNil(publisher.currentEndpoint)
        XCTAssertEqual(retiringIdentity, first.endpoint.identity)
        XCTAssertNotNil(releasePort)
        let fenced = expectation(description: "The old socket stays bound and closes new proxy traffic")
        let peer = NWConnection(host: "127.0.0.1",
            port: try XCTUnwrap(NWEndpoint.Port(rawValue: first.endpoint.port)), using: .tcp)
        defer { peer.cancel() }
        peer.stateUpdateHandler = { [weak peer] state in
            guard case .ready = state, let peer else { return }
            peer.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, complete, error in
                XCTAssertTrue(data?.isEmpty != false)
                XCTAssertTrue(complete || error != nil)
                fenced.fulfill()
            }
        }
        peer.start(queue: .global())
        await fulfillment(of: [fenced], timeout: 2)
        XCTAssertEqual(core.dialCount, 0)
        let nextID = UUID()
        let next = Task { try await publisher.prepare(.init(operationID: nextID, deadline: .seconds(5))) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(reads, 1, "New authorization must wait for old transport teardown")
        core.finishStop()
        do { _ = try await next.value; XCTFail("Revoked account reused its running transport") } catch { }
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(core.startCount, 1)
        XCTAssertFalse(core.isRunning)
        releasePort?()
        releasePort = nil
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
        let session = AccessEmbeddedProxyEntrySession(core: core, outbound: outbound, retireDocuments: { _, finish in finish() })
        let publisher = AccessProxyEntryPublisher(
            provision: { try await session.provision(generation: $0, deadline: $1) },
            shutdown: { session.shutdown(identity: $0) },
            activate: { session.activate() },
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

    func testSynchronousDocumentReceiptKeepsPortUntilCoreStop() async throws {
        try await assertPortRetirementWaitsForBoth(documentFirst: true)
    }

    func testCompletedCoreStopKeepsPortUntilDocumentReceipt() async throws {
        try await assertPortRetirementWaitsForBoth(documentFirst: false)
    }

    func testProvisionCannotAdoptAnAlreadyRunningCoreItDoesNotOwn() async throws {
        let core = DelayedStopCore()
        core.start(configData: Data())
        let session = AccessEmbeddedProxyEntrySession(core: core, parameters: {
            XCTFail("A foreign core must fail before authorization")
            throw URLError(.userAuthenticationRequired)
        }, retireDocuments: { _, finish in finish() })
        do {
            _ = try await session.provision(generation: 1, deadline: .seconds(2))
            XCTFail("A foreign core cannot be published under this session")
        } catch AccessSiteSessionError.runtimeNotReady {}
        XCTAssertTrue(core.isRunning)
        XCTAssertEqual(core.stopCount, 0)
    }

    private func assertPortRetirementWaitsForBoth(documentFirst: Bool) async throws {
        let core = DelayedStopCore()
        let stopStarted = expectation(description: "native stop entered")
        let stopFinished = expectation(description: "native stop finished")
        core.onStop = { _ in stopStarted.fulfill() }
        core.onStopFinished = { _ in stopFinished.fulfill() }
        let parameters = try AccessRealityVisionParameters(address: "node.invalid", port: 443,
            userID: "550e8400-e29b-41d4-a716-446655440000", serverName: "www.example.com", publicKey: "fixture-key", shortID: "")
        var documentReceipt: (@MainActor () -> Void)?
        let session = AccessEmbeddedProxyEntrySession(core: core, parameters: { parameters }, retireDocuments: { _, receipt in
            if documentFirst { receipt() } else { documentReceipt = receipt }
        })
        let provision = try await session.provision(generation: 1, deadline: .seconds(3))
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: provision.endpoint.port))
        XCTAssertTrue(session.activate())
        session.shutdown(identity: provision.endpoint.identity)
        defer { core.finishStop(); documentReceipt?() }
        XCTAssertFalse(session.isRuntimeHealthy)
        await fulfillment(of: [stopStarted], timeout: 2)
        let boundDuringStop = await Self.canBind(port)
        XCTAssertFalse(boundDuringStop)
        core.finishStop()
        await fulfillment(of: [stopFinished], timeout: 2)
        if !documentFirst {
            let boundBeforeReceipt = await Self.canBind(port)
            XCTAssertFalse(boundBeforeReceipt)
            try XCTUnwrap(documentReceipt)()
            documentReceipt = nil
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await Self.canBind(port) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Both completed retirement obligations must release the old port")
    }

    private static func canBind(_ port: NWEndpoint.Port) async -> Bool {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        guard let listener = try? NWListener(using: parameters) else { return false }
        listener.newConnectionHandler = { $0.cancel() }
        defer { listener.cancel() }
        do {
            try await AccessNWListenerBootstrap.awaitReady(listener, on: .global())
            return true
        } catch {
            return false
        }
    }
}

private final class ForeignStartDuringHealthRead: AccessEmbeddedCoreControlling, Sendable {
    private let foreignRunning = Mutex(false)
    let starts = Mutex(0)
    let stops = Mutex(0)
    var isRunning: Bool {
        foreignRunning.withLock {
            let previous = $0
            $0 = true
            return previous
        }
    }
    func start(configData: Data) async throws {
        starts.withLock { $0 += 1 }
        throw AccessEmbeddedCoreError.unverifiedAsset
    }
    func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        throw AccessEmbeddedCoreError.unverifiedAsset
    }
    func stop() async { stops.withLock { $0 += 1 } }
}

private final class DelayedStopCore: AccessEmbeddedCoreControlling, @unchecked Sendable {
    // All test mutations run on MainActor, including the async native stub.
    @MainActor init() {}
    @MainActor private var running = false
    @MainActor private(set) var startCount = 0
    @MainActor private(set) var stopCount = 0
    @MainActor private(set) var dialCount = 0
    @MainActor private var stopContinuation: CheckedContinuation<Void, Never>?
    @MainActor var onStop: ((Int) -> Void)?
    @MainActor var onStopFinished: ((Int) -> Void)?
    var isRunning: Bool { MainActor.assumeIsolated { running } }
    @MainActor func start(configData: Data) { startCount += 1; running = true }
    @MainActor func dial(host: String, port: UInt16) throws -> any AccessRealityPathStream {
        dialCount += 1
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
