import XCTest
@testable import AccessKit

@MainActor
final class AccessProxyEntryPublisherTests: XCTestCase {
    private func provision(generation: UInt64, port: UInt16 = 18_081, identity: String = "entry-1") -> AccessProxyEntryPublisher.Provision {
        AccessProxyEntryPublisher.Provision(
            endpoint: AccessManagedProxyEndpoint(
                identity: identity,
                generation: generation,
                loopbackHost: "127.0.0.1",
                port: port,
                state: .ready
            ),
            listenerReady: true,
            runtimeHealthy: true,
            bridgeInstalled: true
        )
    }

    func testTwoHostsShareOnePreparationAndKeepSeparateKeys() async throws {
        let publisher = AccessProxyEntryPublisher { generation, _ in
            self.provision(generation: generation)
        }
        let first = try await publisher.prepare(
            AccessProxyEntryPrepareRequest(operationID: UUID(), deadline: .seconds(15))
        )
        let second = try await publisher.prepare(
            AccessProxyEntryPrepareRequest(operationID: UUID(), deadline: .seconds(15))
        )
        XCTAssertEqual(publisher.provisionCount, 1)
        XCTAssertEqual(first.endpoint.generation, second.endpoint.generation)
        XCTAssertNotEqual(first.operationID, second.operationID)
        let hostA = AccessHostStoreKey(scopeID: "ordinary", host: try AccessSiteHost("a.example"), isPrivate: false)
        let hostB = AccessHostStoreKey(scopeID: "private-1", host: try AccessSiteHost("a.example"), isPrivate: true)
        XCTAssertTrue(publisher.retain(first.endpoint, for: hostA))
        XCTAssertTrue(publisher.retain(second.endpoint, for: hostB))
        publisher.release(for: hostA)
        XCTAssertNotNil(publisher.currentEndpoint)
        publisher.release(for: hostB)
        publisher.cancel(operationID: first.operationID)
        publisher.cancel(operationID: second.operationID)
    }

    func testValidateReadyRejectsStaleIdentityAndUnhealthyBridge() async throws {
        let publisher = AccessProxyEntryPublisher { generation, _ in
            var value = self.provision(generation: generation)
            value.bridgeInstalled = false
            value.endpoint.loopbackHost = "10.0.0.1"
            value.endpoint.port = 0
            value.endpoint.identity = ""
            return value
        }
        let result = try await publisher.prepare(
            AccessProxyEntryPrepareRequest(operationID: UUID(), deadline: .seconds(15))
        )
        XCTAssertFalse(publisher.validateReady(result))
        let wrong = AccessProxyEntryPrepareResult(
            operationID: UUID(),
            endpoint: result.endpoint
        )
        XCTAssertFalse(publisher.validateReady(wrong))
    }

    func testReadyAndRetentionRejectForgedTransportOrPort() async throws {
        let publisher = AccessProxyEntryPublisher { generation, _ in self.provision(generation: generation) }
        let result = try await publisher.prepare(.init(operationID: UUID(), deadline: .seconds(5)))
        let key = AccessHostStoreKey(scopeID: "ordinary", host: try AccessSiteHost("a.example"), isPrivate: false)
        for changeTransport in [false, true] {
            var forged = result.endpoint
            if changeTransport { forged.transport = .socks5 } else { forged.port += 1 }
            XCTAssertFalse(publisher.validateReady(.init(operationID: result.operationID, endpoint: forged)))
            XCTAssertFalse(publisher.retain(forged, for: key))
        }
        publisher.cancel(operationID: result.operationID)
    }

    func testClosedGenerationDoesNotBecomeReadyAgain() async throws {
        let publisher = AccessProxyEntryPublisher { generation, _ in
            self.provision(generation: generation)
        }
        let result = try await publisher.prepare(
            AccessProxyEntryPrepareRequest(operationID: UUID(), deadline: .seconds(15))
        )
        XCTAssertTrue(publisher.validateReady(result))
        publisher.closeCurrentGeneration()
        XCTAssertFalse(publisher.validateReady(result))
        XCTAssertNil(publisher.currentEndpoint)
    }

    func testFailedGenerationWaiterDoesNotBlockLaterReap() async throws {
        var shutdownIdentities: [String] = []
        var shouldFail = true
        let publisher = AccessProxyEntryPublisher(
            provision: { generation, _ in
                if shouldFail {
                    shouldFail = false
                    throw AccessSiteSessionError.prepareFailed("boom")
                }
                return self.provision(generation: generation, port: 18_198)
            },
            shutdown: { identity in
                shutdownIdentities.append(identity)
            }
        )
        let staleID = UUID()
        do {
            _ = try await publisher.prepare(
                AccessProxyEntryPrepareRequest(operationID: staleID, deadline: .seconds(15))
            )
            XCTFail("first prepare must fail")
        } catch {
        }
        let liveID = UUID()
        let ready = try await publisher.prepare(
            AccessProxyEntryPrepareRequest(operationID: liveID, deadline: .seconds(15))
        )
        XCTAssertTrue(publisher.retain(ready.endpoint, for: AccessHostStoreKey(
            scopeID: "ordinary",
            host: try AccessSiteHost("reap.example"),
            isPrivate: false
        )))
        publisher.cancel(operationID: liveID)
        publisher.cancel(operationID: staleID)
        publisher.release(for: AccessHostStoreKey(
            scopeID: "ordinary",
            host: try AccessSiteHost("reap.example"),
            isPrivate: false
        ))
        XCTAssertEqual(shutdownIdentities, ["entry-1"])
        XCTAssertNil(publisher.currentEndpoint)
    }

    func testLastCancelledWaiterDestroysUnclaimedProvision() async throws {
        var shutdownIdentities: [String] = []
        let started = expectation(description: "provision started")
        let release = expectation(description: "release provision")
        let publisher = AccessProxyEntryPublisher(
            provision: { generation, _ in
                started.fulfill()
                await self.fulfillment(of: [release], timeout: 2)
                return self.provision(generation: generation, port: 18_199)
            },
            shutdown: { identity in
                shutdownIdentities.append(identity)
            }
        )
        let operationID = UUID()
        async let prepare = publisher.prepare(
            AccessProxyEntryPrepareRequest(operationID: operationID, deadline: .seconds(15))
        )
        await fulfillment(of: [started], timeout: 2)
        publisher.cancel(operationID: operationID)
        release.fulfill()
        do {
            _ = try await prepare
            XCTFail("cancelled waiter must not claim the entry")
        } catch is CancellationError {
        }
        XCTAssertEqual(shutdownIdentities, ["entry-1"])
        XCTAssertNil(publisher.currentEndpoint)
    }

    func testCancellingOneWaiterLeavesTheSharedPreparationReady() async throws {
        let started = expectation(description: "provision started")
        let release = expectation(description: "release provision")
        let publisher = AccessProxyEntryPublisher { generation, _ in
            started.fulfill()
            await self.fulfillment(of: [release], timeout: 2)
            return self.provision(generation: generation)
        }
        let cancelledID = UUID()
        let keptID = UUID()
        async let cancelled = publisher.prepare(
            AccessProxyEntryPrepareRequest(operationID: cancelledID, deadline: .seconds(15))
        )
        async let kept = publisher.prepare(
            AccessProxyEntryPrepareRequest(operationID: keptID, deadline: .seconds(15))
        )
        await fulfillment(of: [started], timeout: 2)
        publisher.cancel(operationID: cancelledID)
        release.fulfill()
        do {
            _ = try await cancelled
            XCTFail("取消的等待者不能拿到入口")
        } catch is CancellationError {
        }
        let ready = try await kept
        XCTAssertEqual(publisher.provisionCount, 1)
        XCTAssertEqual(publisher.currentEndpoint?.generation, ready.endpoint.generation)
        XCTAssertTrue(publisher.validateReady(ready))
    }

    func testFailClosedPublisherNeverValidates() async {
        let publisher = AccessFailClosedProxyEntryPublisher()
        do {
            _ = try await publisher.prepare(
                AccessProxyEntryPrepareRequest(operationID: UUID(), deadline: .seconds(15))
            )
            XCTFail("失败关闭必须拒绝准备")
        } catch let error as AccessSiteSessionError {
            XCTAssertEqual(error, .nodeUnavailable)
        } catch {
            XCTFail("意外错误 \(error)")
        }
        XCTAssertNil(publisher.currentEndpoint)
    }

    func testUnhealthyPublishedGenerationCannotBeReusedBeforeTheHealthPoll() async throws {
        var healthy = true
        var stopped: [String] = []
        let publisher = AccessProxyEntryPublisher(provision: { generation, _ in
            healthy = true
            return self.provision(generation: generation, identity: "entry-\(generation)")
        }, shutdown: { stopped.append($0) }, healthCheck: { healthy })
        let first = try await publisher.prepare(.init(operationID: UUID(), deadline: .seconds(15)))
        let key = AccessHostStoreKey(scopeID: "ordinary", host: try AccessSiteHost("example.invalid"), isPrivate: false)
        healthy = false
        XCTAssertNil(publisher.currentEndpoint)
        XCTAssertFalse(publisher.validateReady(first))
        XCTAssertFalse(publisher.retain(first.endpoint, for: key))
        let second = try await publisher.prepare(.init(operationID: UUID(), deadline: .seconds(15)))
        XCTAssertEqual(stopped, [first.endpoint.identity])
        XCTAssertGreaterThan(second.endpoint.generation, first.endpoint.generation)
        XCTAssertTrue(publisher.validateReady(second))
        publisher.cancel(operationID: first.operationID)
        XCTAssertEqual(publisher.currentEndpoint, second.endpoint)
        publisher.cancel(operationID: second.operationID)
        XCTAssertEqual(stopped, [first.endpoint.identity, second.endpoint.identity])
    }

    func testCancelledReplacementIsStoppedDespiteRetainedFailedGeneration() async throws {
        for reusedIdentity in [false, true] {
            let gate = AccessProvisionTestGate(entered: expectation(description: "replacement provisioned"))
            defer { gate.finish() }
            var stopped: [String] = []
            let replacement = reusedIdentity ? "old" : "replacement"
            let publisher = AccessProxyEntryPublisher(provision: { generation, _ in
                if generation > 1 { await gate.wait() }
                return self.provision(generation: generation, identity: generation == 1 ? "old" : replacement)
            }, shutdown: { stopped.append($0) })
            let firstID = UUID(), nextID = UUID()
            let first = try await publisher.prepare(.init(operationID: firstID, deadline: .seconds(15)))
            let oldHost = AccessHostStoreKey(scopeID: "ordinary", host: try AccessSiteHost("old.example"), isPrivate: false)
            XCTAssertTrue(publisher.retain(first.endpoint, for: oldHost))
            publisher.cancel(operationID: firstID)
            publisher.closeCurrentGeneration()
            XCTAssertEqual(stopped, ["old"])
            let next = Task { try await publisher.prepare(.init(operationID: nextID, deadline: .seconds(15))) }
            await fulfillment(of: [gate.entered], timeout: 2)
            publisher.cancel(operationID: nextID)
            gate.finish()
            do { _ = try await next.value; XCTFail("Cancelled replacement was claimed") }
            catch is CancellationError { }
            XCTAssertEqual(stopped, ["old", replacement], "Old failed consumers do not own the replacement transport")
            publisher.release(for: oldHost)
            publisher.release(for: oldHost)
            publisher.cancel(operationID: nextID)
            publisher.closeCurrentGeneration()
            XCTAssertEqual(stopped, ["old", replacement], "Releasing old metadata must not stop a provision twice")
            XCTAssertNil(publisher.currentEndpoint)
        }
    }

    func testMultipleCancelledReplacementWaitersStopTheirProvisionOnlyOnce() async throws {
        let gate = AccessProvisionTestGate(entered: expectation(description: "shared replacement provisioned"))
        defer { gate.finish() }
        var stopped: [String] = []
        let publisher = AccessProxyEntryPublisher(provision: { generation, _ in
            if generation > 1 { await gate.wait() }
            return self.provision(generation: generation, identity: "entry-\(generation)")
        }, shutdown: { stopped.append($0) })
        let firstID = UUID()
        let first = try await publisher.prepare(.init(operationID: firstID, deadline: .seconds(15)))
        let host = AccessHostStoreKey(scopeID: "ordinary", host: try AccessSiteHost("old.example"), isPrivate: false)
        XCTAssertTrue(publisher.retain(first.endpoint, for: host))
        publisher.cancel(operationID: firstID)
        publisher.closeCurrentGeneration()
        let firstCancelledID = UUID(), secondCancelledID = UUID()
        let firstCancelled = Task { try await publisher.prepare(.init(operationID: firstCancelledID, deadline: .seconds(15))) }
        let enteredSecond = expectation(description: "second waiter entered")
        let secondCancelled = Task {
            enteredSecond.fulfill()
            return try await publisher.prepare(.init(operationID: secondCancelledID, deadline: .seconds(15)))
        }
        await fulfillment(of: [gate.entered, enteredSecond], timeout: 2)
        publisher.cancel(operationID: firstCancelledID); publisher.cancel(operationID: secondCancelledID)
        gate.finish()
        for task in [firstCancelled, secondCancelled] {
            do { _ = try await task.value; XCTFail("Cancelled waiter was claimed") }
            catch is CancellationError { }
        }
        XCTAssertEqual(publisher.provisionCount, 2)
        XCTAssertEqual(stopped, ["entry-1", "entry-2"])
        publisher.release(for: host)
        XCTAssertEqual(stopped, ["entry-1", "entry-2"])
    }

    func testOldConsumersDoNotKeepAnUnretainedReplacementAlive() async throws {
        var stopped: [String] = []
        let publisher = AccessProxyEntryPublisher(provision: { generation, _ in
            self.provision(generation: generation, identity: "entry-\(generation)")
        }, shutdown: { stopped.append($0) })
        let firstID = UUID(), nextID = UUID()
        let first = try await publisher.prepare(.init(operationID: firstID, deadline: .seconds(15)))
        let host = AccessHostStoreKey(scopeID: "ordinary", host: try AccessSiteHost("old.example"), isPrivate: false)
        XCTAssertTrue(publisher.retain(first.endpoint, for: host))
        publisher.cancel(operationID: firstID)
        publisher.closeCurrentGeneration()
        let next = try await publisher.prepare(.init(operationID: nextID, deadline: .seconds(15)))
        XCTAssertTrue(publisher.validateReady(next))
        publisher.cancel(operationID: nextID)
        XCTAssertEqual(stopped, ["entry-1", "entry-2"])
        XCTAssertNil(publisher.currentEndpoint)
        publisher.release(for: host)
        XCTAssertEqual(stopped, ["entry-1", "entry-2"])
    }

    func testCancelledSiblingCannotStopReplacementWinnerWithReusedIdentity() async throws {
        let gate = AccessProvisionTestGate(entered: expectation(description: "replacement provisioned"))
        defer { gate.finish() }
        var stopped: [String] = []
        let publisher = AccessProxyEntryPublisher(provision: { generation, _ in
            if generation > 1 { await gate.wait() }
            return self.provision(generation: generation)
        }, shutdown: { stopped.append($0) })
        let firstID = UUID(), cancelledID = UUID(), winnerID = UUID()
        let first = try await publisher.prepare(.init(operationID: firstID, deadline: .seconds(15)))
        let old = AccessHostStoreKey(scopeID: "old", host: try AccessSiteHost("same.example"), isPrivate: false)
        let winner = AccessHostStoreKey(scopeID: "new", host: old.host, isPrivate: false)
        XCTAssertTrue(publisher.retain(first.endpoint, for: old))
        publisher.cancel(operationID: firstID); publisher.closeCurrentGeneration()
        let cancelled = Task { try await publisher.prepare(.init(operationID: cancelledID, deadline: .seconds(15))) }
        let enteredWinner = expectation(description: "winner waiter entered")
        let kept = Task {
            enteredWinner.fulfill()
            return try await publisher.prepare(.init(operationID: winnerID, deadline: .seconds(15)))
        }
        await fulfillment(of: [gate.entered, enteredWinner], timeout: 2)
        publisher.cancel(operationID: cancelledID)
        gate.finish()
        let ready = try await kept.value
        XCTAssertTrue(publisher.retain(ready.endpoint, for: winner))
        publisher.cancel(operationID: winnerID)
        do { _ = try await cancelled.value; XCTFail("Cancelled sibling was claimed") }
        catch is CancellationError { }
        publisher.release(for: old)
        XCTAssertEqual(stopped, ["entry-1"])
        XCTAssertTrue(publisher.currentEndpoint?.generation == ready.endpoint.generation)
        publisher.release(for: winner)
        XCTAssertEqual(stopped, ["entry-1", "entry-1"])
        XCTAssertNil(publisher.currentEndpoint)
    }
}

@MainActor
final class AccessProvisionTestGate {
    let entered: XCTestExpectation
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation) { self.entered = entered }
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0; entered.fulfill() }
    }
    func finish() {
        released = true
        let pending = continuation; continuation = nil
        pending?.resume()
    }
}
