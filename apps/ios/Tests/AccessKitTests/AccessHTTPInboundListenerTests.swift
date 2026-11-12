import Foundation
import Network
import XCTest
@testable import AccessKit

final class AccessHTTPInboundListenerTests: XCTestCase {
    private func makeRegistration(
        transport: AccessInboundTransport = .http,
        port: UInt16 = 18_083,
        leaseOffset: TimeInterval = 60
    ) throws -> AccessRegistration {
        AccessRegistration(
            id: try AccessRegistrationID("reg-http-inbound-\(port)"),
            owner: try AccessOwner(channel: 1, profile: "ordinary", partition: "default"),
            transport: transport,
            endpoint: try AccessEndpoint(host: "127.0.0.1", port: port),
            credentialSlot: try AccessCredentialSlot(id: "cred-http-inbound"),
            lease: try AccessLease(
                generation: 1,
                expiresAt: Date(timeIntervalSince1970: 1_700_000_000 + leaseOffset)
            )
        )
    }

    func testRejectsHTTPSRegistration() throws {
        let registration = try makeRegistration(transport: .https, port: 18_084)
        XCTAssertThrowsError(try AccessHTTPInboundListener(registration: registration, tunnels: HoldingTunnel())) { error in
            XCTAssertEqual(
                error as? AccessHTTPInboundError,
                .transportNotHTTP(.https)
            )
        }
    }

    func testRejectsInactiveLeaseOnStart() async throws {
        let registration = try makeRegistration(port: 18_085, leaseOffset: 10)
        let listener = try AccessHTTPInboundListener(registration: registration, tunnels: HoldingTunnel())
        let afterExpiry = Date(timeIntervalSince1970: 1_700_000_000 + 30)
        do {
            try await listener.start(at: afterExpiry)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? AccessHTTPInboundError, .leaseInactive)
        }
        XCTAssertFalse(listener.isListening)
    }

    func testStartStopAndAcceptOnLoopback() async throws {
        let port: UInt16 = 18_086
        let registration = try makeRegistration(port: port)
        let listener = try AccessHTTPInboundListener(registration: registration, tunnels: HoldingTunnel())
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try await listener.start(at: now)
        XCTAssertTrue(listener.isListening)
        do {
            try await listener.start(at: now)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? AccessHTTPInboundError, .alreadyListening)
        }

        let connected = expectation(description: "tcp connected")
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connected.fulfill()
            }
        }
        connection.start(queue: .global())
        await fulfillment(of: [connected], timeout: 2.0)
        connection.cancel()

        // Accept handler is asynchronous; allow a brief settle.
        let deadline = Date().addingTimeInterval(1.0)
        while listener.acceptedConnectionCount == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(listener.acceptedConnectionCount, 1)

        try listener.stop()
        XCTAssertFalse(listener.isListening)
        XCTAssertThrowsError(try listener.stop()) { error in
            XCTAssertEqual(error as? AccessHTTPInboundError, .notListening)
        }
    }

    func testPermanentStateObserverRevokesHealthAfterReadyFailure() async throws {
        let listener = try AccessHTTPInboundListener(
            registration: makeRegistration(port: 18_087), tunnels: HoldingTunnel()
        )
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        XCTAssertTrue(listener.isListening)
        let observer = try XCTUnwrap(listener.listenerStateObserverForTests)
        observer(.failed(.posix(.ECONNABORTED)))
        XCTAssertFalse(listener.isListening)
        observer(.cancelled)
        XCTAssertFalse(listener.isListening)
    }
}

private final class HoldingStream: AccessRealityPathStream, @unchecked Sendable {
    private(set) var isOpen = true
    func read(maxBytes: Int) async throws -> Data? { nil }
    func write(_ data: Data) async throws {}
    func close() { isOpen = false }
}

private final class HoldingTunnel: AccessHTTPTunnelOpening, @unchecked Sendable {
    func open(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        HoldingStream()
    }
}
