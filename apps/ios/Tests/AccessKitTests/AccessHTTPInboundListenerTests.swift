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
        XCTAssertThrowsError(try AccessHTTPInboundListener(registration: registration)) { error in
            XCTAssertEqual(
                error as? AccessHTTPInboundError,
                .transportNotHTTP(.https)
            )
        }
    }

    func testRejectsInactiveLeaseOnStart() throws {
        let registration = try makeRegistration(port: 18_085, leaseOffset: 10)
        let listener = try AccessHTTPInboundListener(registration: registration)
        let afterExpiry = Date(timeIntervalSince1970: 1_700_000_000 + 30)
        XCTAssertThrowsError(try listener.start(at: afterExpiry)) { error in
            XCTAssertEqual(error as? AccessHTTPInboundError, .leaseInactive)
        }
        XCTAssertFalse(listener.isListening)
    }

    func testStartStopAndAcceptOnLoopback() throws {
        let port: UInt16 = 18_086
        let registration = try makeRegistration(port: port)
        let listener = try AccessHTTPInboundListener(registration: registration)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try listener.start(at: now)
        XCTAssertTrue(listener.isListening)
        XCTAssertThrowsError(try listener.start(at: now)) { error in
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
        wait(for: [connected], timeout: 2.0)
        connection.cancel()

        // Accept handler is asynchronous; allow a brief settle.
        let deadline = Date().addingTimeInterval(1.0)
        while listener.acceptedConnectionCount == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertGreaterThanOrEqual(listener.acceptedConnectionCount, 1)

        try listener.stop()
        XCTAssertFalse(listener.isListening)
        XCTAssertThrowsError(try listener.stop()) { error in
            XCTAssertEqual(error as? AccessHTTPInboundError, .notListening)
        }
    }
}
