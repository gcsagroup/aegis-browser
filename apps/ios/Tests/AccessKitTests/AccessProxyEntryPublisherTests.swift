import XCTest
@testable import AccessKit

@MainActor
final class AccessProxyEntryPublisherTests: XCTestCase {
    private func provision(generation: UInt64, port: UInt16 = 18_081) -> AccessProxyEntryPublisher.Provision {
        AccessProxyEntryPublisher.Provision(
            endpoint: AccessManagedProxyEndpoint(
                identity: "entry-1",
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
}
