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
    @MainActor private var running = false
    @MainActor private(set) var startCount = 0
    @MainActor private(set) var stopCount = 0
    @MainActor private var stopContinuation: CheckedContinuation<Void, Never>?
    var isRunning: Bool { MainActor.assumeIsolated { running } }
    @MainActor func start(configData: Data) { startCount += 1; running = true }
    @MainActor func dial(host: String, port: UInt16) throws -> any AccessRealityPathStream {
        guard running else { throw AccessEmbeddedCoreError.unverifiedAsset }
        return AccessMemoryRealityStream()
    }
    @MainActor func stop() async {
        await withCheckedContinuation { stopContinuation = $0; stopCount += 1 }
        running = false
    }
    @MainActor func finishStop() { stopContinuation?.resume(); stopContinuation = nil }
}
