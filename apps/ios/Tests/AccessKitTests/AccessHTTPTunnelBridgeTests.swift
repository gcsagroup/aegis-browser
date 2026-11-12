import Foundation
import Network
import os
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

    func testPreludeAndReplyCrossTheTunnel() async throws {
        let port: UInt16 = 18_220
        let registration = try registration(port: port)
        let opener = RecordingOpener()
        let listener = try AccessHTTPInboundListener(registration: registration, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
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
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(opener.stream.writtenSnapshot.contains(Data("PING".utf8)))
        opener.stream.push(Data("PONG".utf8))
        await fulfillment(of: [received], timeout: 3)
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

    func testPayloadAfterTheConnectResponseIsForwarded() async throws {
        let port: UInt16 = 18_222
        let registration = try registration(port: port)
        let opener = RecordingOpener()
        let listener = try AccessHTTPInboundListener(registration: registration, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
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
        await fulfillment(of: [established], timeout: 3)
        let deadline = Date().addingTimeInterval(3)
        while !opener.stream.writtenSnapshot.contains(Data("GET /page".utf8)), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(
            opener.stream.writtenSnapshot.contains(Data("GET /page".utf8)),
            String(data: opener.stream.writtenSnapshot, encoding: .utf8) ?? ""
        )
        connection.cancel()
    }

    func testDialFailureClosesWithoutAnotherAttempt() async throws {
        let port: UInt16 = 18_221
        let registration = try registration(port: port)
        let listener = try AccessHTTPInboundListener(registration: registration, tunnels: FailingOpener())
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
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
        await fulfillment(of: [response], timeout: 3)
        connection.cancel()
        XCTAssertEqual(listener.establishedConnectCount, 1)
    }

    func testUploadWaitsForWriteBeforeReadingAgainAndDrainsFinalBytes() async throws {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let written = OSAllocatedUnfairLock(initialState: Data())
        let writing = expectation(description: "first upstream write suspended")
        let (resume, gate) = AsyncStream<Void>.makeStream()
        let upload = Task {
            try await AccessHTTPTunnelBridge.forwardUpload(receive: {
                let count = reads.withLock { $0 += 1; return $0 }
                return (Data([UInt8(count)]), count == 2)
            }, write: { chunk in
                if chunk == Data([1]) {
                    writing.fulfill()
                    for await _ in resume { break }
                }
                written.withLock { $0.append(chunk) }
            })
        }
        await fulfillment(of: [writing], timeout: 3)
        XCTAssertEqual(reads.withLock { $0 }, 1)
        gate.yield(())
        gate.finish()
        try await upload.value
        XCTAssertEqual(reads.withLock { $0 }, 2)
        XCTAssertEqual(written.withLock { $0 }, Data([1, 2]))
    }

    func testSlowWriteStillDeliversTheChunk() async throws {
        let port: UInt16 = 18_223
        let opener = RecordingOpener()
        opener.stream.writeDelay = .milliseconds(200)
        let listener = try await makeListener(port: port, tunnels: opener)
        await sendConnect(port: port, then: Data("SLOW".utf8))
        let deadline = Date().addingTimeInterval(3)
        while !opener.stream.writtenSnapshot.contains(Data("SLOW".utf8)), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(opener.stream.writtenSnapshot.contains(Data("SLOW".utf8)))
        try? listener.stop()
    }

    func testRemoteCloseCancelsTheClientWithoutAnotherDial() async throws {
        let port: UInt16 = 18_224
        let opener = RecordingOpener()
        let listener = try await makeListener(port: port, tunnels: opener)
        let closed = expectation(description: "client closed")
        closed.assertForOverFulfill = false
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                let payload = Data("CONNECT example.com:80 HTTP/1.1\r\n\r\n".utf8)
                connection.send(content: payload, completion: .contentProcessed { _ in })
                @Sendable func watch(_ connection: NWConnection) {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { data, _, isComplete, error in
                        let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
                        if text.contains("200") {
                            connection.send(content: Data("BYE".utf8), completion: .contentProcessed { _ in })
                        }
                        if isComplete || error != nil {
                            closed.fulfill()
                            return
                        }
                        watch(connection)
                    }
                }
                watch(connection)
            }
            if case .cancelled = state { closed.fulfill() }
            if case .failed = state { closed.fulfill() }
        }
        connection.start(queue: .global())
        let deadline = Date().addingTimeInterval(3)
        while !opener.stream.writtenSnapshot.contains(Data("BYE".utf8)), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(opener.stream.writtenSnapshot.contains(Data("BYE".utf8)))
        opener.stream.close()
        await fulfillment(of: [closed], timeout: 3)
        XCTAssertFalse(opener.stream.isOpen)
        XCTAssertEqual(opener.opens, 1)
        try? listener.stop()
    }

    func testClientCancelClosesTheRemote() async throws {
        let port: UInt16 = 18_225
        let opener = RecordingOpener()
        let listener = try await makeListener(port: port, tunnels: opener)
        let established = expectation(description: "200")
        let connection = connect(port: port) { _, text in
            if text.contains("200") { established.fulfill() }
        }
        await fulfillment(of: [established], timeout: 3)
        connection.cancel()
        let deadline = Date().addingTimeInterval(3)
        while opener.stream.isOpen, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(opener.stream.isOpen)
        try? listener.stop()
    }

    func testListenerStopClosesTheRemote() async throws {
        let port: UInt16 = 18_226
        let opener = RecordingOpener()
        let listener = try await makeListener(port: port, tunnels: opener)
        let established = expectation(description: "200")
        _ = connect(port: port) { _, text in
            if text.contains("200") { established.fulfill() }
        }
        await fulfillment(of: [established], timeout: 3)
        try listener.stop()
        let deadline = Date().addingTimeInterval(3)
        while opener.stream.isOpen, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(opener.stream.isOpen)
        XCTAssertEqual(opener.opens, 1)
    }

    private func makeListener(port: UInt16, tunnels: any AccessHTTPTunnelOpening) async throws -> AccessHTTPInboundListener {
        let listener = try AccessHTTPInboundListener(registration: try registration(port: port), tunnels: tunnels)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        return listener
    }

    private func sendConnect(port: UInt16, then body: Data) async {
        let established = expectation(description: "200")
        _ = connect(port: port) { connection, text in
            guard text.contains("200") else { return }
            established.fulfill()
            connection.send(content: body, completion: .contentProcessed { _ in })
        }
        await fulfillment(of: [established], timeout: 3)
    }

    private func connect(
        port: UInt16,
        onText: @escaping (NWConnection, String) -> Void
    ) -> NWConnection {
        let handler = TextHandler(onText)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let payload = Data("CONNECT example.com:80 HTTP/1.1\r\n\r\n".utf8)
            connection.send(content: payload, completion: .contentProcessed { _ in })
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { data, _, _, _ in
                let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
                handler.call(connection, text)
            }
        }
        connection.start(queue: .global())
        return connection
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
    private let lock = OSAllocatedUnfairLock(initialState: Data())
    var text: String {
        lock.withLock { String(data: $0, encoding: .utf8) ?? "" }
    }
    func append(_ chunk: Data) {
        lock.withLock { $0.append(chunk) }
    }
}

private final class RecordingOpener: AccessHTTPTunnelOpening, @unchecked Sendable {
    let stream = AccessMemoryRealityStream()
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    var opens: Int { lock.withLock { $0 } }
    func open(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        lock.withLock { $0 += 1 }
        return stream
    }
}

private final class TextHandler: @unchecked Sendable {
    private let body: (NWConnection, String) -> Void
    init(_ body: @escaping (NWConnection, String) -> Void) { self.body = body }
    func call(_ connection: NWConnection, _ text: String) { body(connection, text) }
}

private final class FailingOpener: AccessHTTPTunnelOpening, @unchecked Sendable {
    func open(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        throw CancellationError()
    }
}
