import Foundation
import Network
import XCTest
@testable import AccessKit

final class AccessHTTPTunnelBridgeTests: XCTestCase {
    func testSplitKeepsBytesThatArriveWithTheHeader() throws {
        let payload = Data("HELLO".utf8)
        var buffer = Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".utf8)
        buffer.append(payload)
        let (request, remainder) = try XCTUnwrap(try AccessHTTPConnectParser.split(buffer: buffer))
        XCTAssertEqual(request.host, "example.com")
        XCTAssertEqual(remainder, payload)
    }

    func testPreludeAndReplyCrossTheTunnel() throws {
        let port: UInt16 = 18_220
        let registration = try registration(port: port)
        let opener = RecordingOpener()
        let listener = try AccessHTTPInboundListener(registration: registration, tunnels: opener)
        try listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }

        let received = expectation(description: "origin bytes")
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let bucket = ByteBucket()
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            var payload = Data("CONNECT example.com:80 HTTP/1.1\r\nHost: example.com:80\r\n\r\n".utf8)
            payload.append(Data("PING".utf8))
            connection.send(content: payload, completion: .contentProcessed { _ in })
            Self.collect(connection, into: bucket, until: "PONG", done: received)
        }
        connection.start(queue: .global())

        let deadline = Date().addingTimeInterval(3)
        while !opener.stream.writtenSnapshot.contains(Data("PING".utf8)), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(opener.stream.writtenSnapshot.contains(Data("PING".utf8)))
        opener.stream.push(Data("PONG".utf8))
        wait(for: [received], timeout: 3)
        connection.cancel()
    }

    private static func collect(
        _ connection: NWConnection,
        into bucket: ByteBucket,
        until marker: String,
        done: XCTestExpectation
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { data, _, isComplete, _ in
            if let data { bucket.append(data) }
            if bucket.text.contains(marker) {
                done.fulfill()
                return
            }
            if !isComplete {
                collect(connection, into: bucket, until: marker, done: done)
            }
        }
    }

    func testPayloadAfterTheConnectResponseIsForwarded() throws {
        let port: UInt16 = 18_222
        let registration = try registration(port: port)
        let opener = RecordingOpener()
        let listener = try AccessHTTPInboundListener(registration: registration, tunnels: opener)
        try listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let established = expectation(description: "200")
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let headers = Data("CONNECT example.com:80 HTTP/1.1\r\nHost: example.com:80\r\n\r\n".utf8)
            connection.send(content: headers, completion: .contentProcessed { _ in })
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { data, _, _, _ in
                let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
                if text.contains("200") {
                    established.fulfill()
                    let body = Data("GET /page HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8)
                    connection.send(content: body, completion: .contentProcessed { _ in })
                }
            }
        }
        connection.start(queue: .global())
        wait(for: [established], timeout: 3)
        let deadline = Date().addingTimeInterval(3)
        while !opener.stream.writtenSnapshot.contains(Data("GET /page".utf8)), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(
            opener.stream.writtenSnapshot.contains(Data("GET /page".utf8)),
            String(data: opener.stream.writtenSnapshot, encoding: .utf8) ?? ""
        )
        connection.cancel()
    }

    func testDialFailureClosesWithoutAnotherAttempt() throws {
        let port: UInt16 = 18_221
        let registration = try registration(port: port)
        let listener = try AccessHTTPInboundListener(registration: registration, tunnels: FailingOpener())
        try listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let response = expectation(description: "200 then close")
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let payload = Data("CONNECT example.com:80 HTTP/1.1\r\n\r\n".utf8)
            connection.send(content: payload, completion: .contentProcessed { _ in })
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { data, _, _, _ in
                let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
                if text.contains("200") { response.fulfill() }
            }
        }
        connection.start(queue: .global())
        wait(for: [response], timeout: 3)
        connection.cancel()
        XCTAssertEqual(listener.establishedConnectCount, 1)
    }

    private func registration(port: UInt16) throws -> AccessRegistration {
        AccessRegistration(
            id: try AccessRegistrationID("reg-tunnel-\(port)"),
            owner: try AccessOwner(channel: 1, profile: "ordinary", partition: "default"),
            transport: .http,
            endpoint: try AccessEndpoint(host: "127.0.0.1", port: port),
            credentialSlot: try AccessCredentialSlot(id: "cred-tunnel-\(port)"),
            lease: try AccessLease(generation: 1, expiresAt: Date(timeIntervalSince1970: 1_700_000_060))
        )
    }
}

private final class ByteBucket: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }
}

private final class RecordingOpener: AccessHTTPTunnelOpening, @unchecked Sendable {
    let stream = AccessMemoryRealityStream()
    func open(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        stream
    }
}

private final class FailingOpener: AccessHTTPTunnelOpening, @unchecked Sendable {
    func open(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        throw CancellationError()
    }
}
