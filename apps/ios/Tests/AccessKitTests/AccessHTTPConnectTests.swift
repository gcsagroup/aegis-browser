import Foundation
import Network
import XCTest
@testable import AccessKit

final class AccessHTTPConnectTests: XCTestCase {
    func testParserAcceptsConnectAndRejectsOtherMethods() throws {
        let ok = Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".utf8)
        let request = try XCTUnwrap(try AccessHTTPConnectParser.parse(buffer: ok))
        XCTAssertEqual(request.host, "example.com")
        XCTAssertEqual(request.port, 443)
        XCTAssertEqual(request.httpVersion, "HTTP/1.1")

        let ipv6 = Data("CONNECT [::1]:8443 HTTP/1.1\r\n\r\n".utf8)
        let v6 = try XCTUnwrap(try AccessHTTPConnectParser.parse(buffer: ipv6))
        XCTAssertEqual(v6.host, "::1")
        XCTAssertEqual(v6.port, 8443)

        XCTAssertNil(try AccessHTTPConnectParser.parse(buffer: Data("CONNECT example.com:443 HTTP/1.1\r\n".utf8)))

        XCTAssertThrowsError(
            try AccessHTTPConnectParser.parse(buffer: Data("GET http://example.com/ HTTP/1.1\r\n\r\n".utf8))
        ) { error in
            XCTAssertEqual(error as? AccessHTTPConnectError, .methodNotConnect("GET"))
        }
        XCTAssertThrowsError(
            try AccessHTTPConnectParser.parse(buffer: Data("CONNECT example.com HTTP/1.1\r\n\r\n".utf8))
        ) { error in
            XCTAssertEqual(error as? AccessHTTPConnectError, .malformedTarget("example.com"))
        }
    }

    func testListenerEstablishesConnectWithoutDirectDial() async throws {
        let port: UInt16 = 18_190
        let registration = AccessRegistration(
            id: try AccessRegistrationID("reg-http-connect"),
            owner: try AccessOwner(channel: 1, profile: "ordinary", partition: "default"),
            transport: .http,
            endpoint: try AccessEndpoint(host: "127.0.0.1", port: port),
            credentialSlot: try AccessCredentialSlot(id: "cred-http-connect"),
            lease: try AccessLease(
                generation: 1,
                expiresAt: Date(timeIntervalSince1970: 1_700_000_000 + 60)
            )
        )
        let listener = try AccessHTTPInboundListener(registration: registration, tunnels: HoldingTunnel())
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await listener.start(at: now)

        let response = expectation(description: "200 connection established")
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let payload = Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".utf8)
            connection.send(content: payload, completion: .contentProcessed { _ in })
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { data, _, _, _ in
                let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
                if text.contains("200 Connection Established") {
                    response.fulfill()
                }
            }
        }
        connection.start(queue: .global())
        await fulfillment(of: [response], timeout: 3.0)
        connection.cancel()

        let deadline = Date().addingTimeInterval(1.0)
        while listener.establishedConnectCount == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(listener.acceptedConnectionCount, 1)
        XCTAssertGreaterThanOrEqual(listener.establishedConnectCount, 1)

        try listener.stop()
    }

    func testListenerRejectsNonConnectMethod() async throws {
        let port: UInt16 = 18_191
        let registration = AccessRegistration(
            id: try AccessRegistrationID("reg-http-connect-get"),
            owner: try AccessOwner(channel: 1, profile: "ordinary", partition: "default"),
            transport: .http,
            endpoint: try AccessEndpoint(host: "127.0.0.1", port: port),
            credentialSlot: try AccessCredentialSlot(id: "cred-http-connect-get"),
            lease: try AccessLease(
                generation: 1,
                expiresAt: Date(timeIntervalSince1970: 1_700_000_000 + 60)
            )
        )
        let listener = try AccessHTTPInboundListener(registration: registration, tunnels: HoldingTunnel())
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))

        let response = expectation(description: "405 method not allowed")
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let payload = Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
            connection.send(content: payload, completion: .contentProcessed { _ in })
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { data, _, _, _ in
                let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
                if text.contains("405 Method Not Allowed") {
                    response.fulfill()
                }
            }
        }
        connection.start(queue: .global())
        await fulfillment(of: [response], timeout: 3.0)
        connection.cancel()
        XCTAssertEqual(listener.establishedConnectCount, 0)
        try listener.stop()
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
