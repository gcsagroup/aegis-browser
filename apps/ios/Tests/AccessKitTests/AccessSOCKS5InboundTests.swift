import Foundation
import Network
import XCTest
@testable import AccessKit

final class AccessSOCKS5InboundTests: XCTestCase {
    private func makeRegistration(
        transport: AccessInboundTransport = .socks5,
        port: UInt16 = 18_805
    ) throws -> AccessRegistration {
        AccessRegistration(
            id: try AccessRegistrationID("reg-socks5-\(port)"),
            owner: try AccessOwner(channel: 1, profile: "ordinary", partition: "default"),
            transport: transport,
            endpoint: try AccessEndpoint(host: "127.0.0.1", port: port),
            credentialSlot: try AccessCredentialSlot(id: "cred-socks5"),
            lease: try AccessLease(
                generation: 1,
                expiresAt: Date(timeIntervalSince1970: 1_700_000_000 + 60)
            )
        )
    }

    func testParserNoAuthGreetingAndConnect() throws {
        let greeting = Data([0x05, 0x01, 0x00])
        let methodReply = try XCTUnwrap(try AccessSOCKS5InboundParser.parseGreeting(buffer: greeting))
        XCTAssertEqual(methodReply, Data([0x05, 0x00]))

        // CONNECT example.com:443 via domain ATYP
        var request = Data([0x05, 0x01, 0x00, 0x03, 0x0b])
        request.append(contentsOf: "example.com".utf8)
        request.append(contentsOf: [0x01, 0xbb]) // 443
        let parsed = try XCTUnwrap(try AccessSOCKS5InboundParser.parseConnectRequest(buffer: request))
        XCTAssertEqual(parsed.0.host, "example.com")
        XCTAssertEqual(parsed.0.port, 443)
    }

    func testParserRejectsUsernamePasswordOnlyGreeting() {
        let greeting = Data([0x05, 0x01, 0x02])
        XCTAssertThrowsError(try AccessSOCKS5InboundParser.parseGreeting(buffer: greeting)) { error in
            XCTAssertEqual(error as? AccessSOCKS5InboundError, .usernamePasswordNotAdmitted)
        }
    }

    func testParserRejectsBindCommand() {
        let request = Data([0x05, 0x02, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x50])
        XCTAssertThrowsError(try AccessSOCKS5InboundParser.parseConnectRequest(buffer: request)) { error in
            XCTAssertEqual(error as? AccessSOCKS5InboundError, .unsupportedCommand(0x02))
        }
    }

    func testListenerRejectsNonSOCKS5Registration() throws {
        let http = try makeRegistration(transport: .http, port: 18_806)
        XCTAssertThrowsError(try AccessSOCKS5InboundListener(registration: http)) { error in
            XCTAssertEqual(error as? AccessSOCKS5InboundError, .transportNotSOCKS5(.http))
        }
    }

    func testListenerEstablishesNoAuthConnect() async throws {
        let port: UInt16 = 18_807
        let listener = try AccessSOCKS5InboundListener(registration: try makeRegistration(port: port))
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))

        let gotReply = expectation(description: "socks5 success reply")
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            // greeting: no-auth + CONNECT 127.0.0.1:80
            var payload = Data([0x05, 0x01, 0x00])
            payload.append(contentsOf: [0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x50])
            connection.send(content: payload, completion: .contentProcessed { _ in })
            connection.receive(minimumIncompleteLength: 2, maximumLength: 64) { data, _, _, _ in
                guard let data, data.count >= 2 else { return }
                // First reply is method selection; may arrive with success reply coalesced.
                if data.count >= 2, data[0] == 0x05, data[1] == 0x00 {
                    if data.count >= 10 {
                        // greeting + success coalesced
                        XCTAssertEqual(data[2], 0x05)
                        XCTAssertEqual(data[3], 0x00)
                        gotReply.fulfill()
                    } else {
                        connection.receive(minimumIncompleteLength: 10, maximumLength: 64) { second, _, _, _ in
                            guard let second, second.count >= 2 else { return }
                            XCTAssertEqual(second[0], 0x05)
                            XCTAssertEqual(second[1], 0x00)
                            gotReply.fulfill()
                        }
                    }
                }
            }
        }
        connection.start(queue: .global())
        await fulfillment(of: [gotReply], timeout: 3.0)
        connection.cancel()

        let deadline = Date().addingTimeInterval(1.0)
        while listener.establishedConnectCount == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(listener.establishedConnectCount, 1)
        try listener.stop()
    }
}
