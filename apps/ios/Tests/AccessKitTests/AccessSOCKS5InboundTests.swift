import Foundation
import Network
import XCTest
import Synchronization
@testable import AccessKit

final class AccessSOCKS5InboundTests: XCTestCase {
    func testTwoPreparedSOCKSSocketsStayDistinctAndServeAfterAdoption() async throws {
        let first = try await AccessEmbeddedProxyEntrySession.reserveLoopbackSocket()
        let second = try await AccessEmbeddedProxyEntrySession.reserveLoopbackSocket()
        defer { first.cancel(); second.cancel() }
        let firstPort = try XCTUnwrap(first.port?.rawValue)
        let secondPort = try XCTUnwrap(second.port?.rawValue)
        XCTAssertNotEqual(firstPort, secondPort)
        for port in [firstPort, secondPort] { XCTAssertNotEqual(port, 0); XCTAssertNotEqual(port, 1080) }
        let rival = try AccessSOCKS5InboundListener(registration: makeRegistration(port: firstPort))
        do {
            try await rival.start()
            try? rival.stop()
            XCTFail("The assigned SOCKS port must remain held before adoption")
        } catch { }
        for (socket, port) in [(first, firstPort), (second, secondPort)] {
            let listener = try AccessSOCKS5InboundListener(registration: makeRegistration(port: port), preparedSocket: socket)
            try await listener.start(at: Date(), accepting: false)
            defer { try? listener.stop() }
            XCTAssertTrue(listener.boundSocketForTests === socket)
            XCTAssertFalse(listener.isAccepting)
            try await assertGreetingRefused(on: port)
            XCTAssertEqual(listener.acceptedConnectionCount, 0)
            XCTAssertTrue(listener.activate())
            let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            client.start(queue: .global())
            try await Self.send(Data([5, 1, 0]), to: client)
            let reply = try await Self.receive(2, from: client)
            XCTAssertEqual(reply, Data([5, 0]))
            client.cancel()
        }
    }

    func testPreparedSOCKSSocketRejectsMismatchedRegistration() async throws {
        let socket = try await AccessEmbeddedProxyEntrySession.reserveLoopbackSocket()
        defer { socket.cancel() }
        let port = try XCTUnwrap(socket.port?.rawValue)
        let listener = try AccessSOCKS5InboundListener(
            registration: makeRegistration(port: port == 65535 ? 65534 : port + 1), preparedSocket: socket)
        do {
            try await listener.start()
            XCTFail("A prepared socket cannot be relabelled with another endpoint")
        } catch { }
        XCTAssertNil(listener.boundSocketForTests)
        XCTAssertEqual(listener.acceptedConnectionCount, 0)
    }

    func testProductionTunnelWaitsForUpstreamAndPreservesPipelinedBytes() async throws {
        let tunnel = GatedTunnel()
        let listener = try AccessSOCKS5InboundListener(registration: makeRegistration(port: 10806), tunnels: tunnel)
        try await listener.start()
        let connection = NWConnection(host: "127.0.0.1", port: 10806, using: .tcp)
        connection.start(queue: .global())
        let deadline = Task { try? await Task.sleep(for: .seconds(5)); connection.cancel() }
        defer { deadline.cancel(); tunnel.release(); connection.cancel(); try? listener.stop() }
        try await Self.send(Data([5, 1, 0]), to: connection)
        let method = try await Self.receive(2, from: connection)
        XCTAssertEqual(method, Data([5, 0]))
        var request = Data([5, 1, 0, 3, 11])
        request.append(contentsOf: "example.com".utf8)
        request.append(contentsOf: [1, 187])
        request.append(Data("first-bytes".utf8))
        try await Self.send(request, to: connection)
        let replied = Mutex(false)
        let response = Task { () throws -> Data in
            let data = try await Self.receive(10, from: connection)
            replied.withLock { $0 = true }
            return data
        }
        let wait = Date().addingTimeInterval(2)
        while !tunnel.isWaiting, Date() < wait { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(tunnel.isWaiting)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(replied.withLock { $0 }, "SOCKS success cannot precede the authorized upstream")
        tunnel.release()
        let success = try await response.value
        XCTAssertEqual(success, AccessSOCKS5InboundParser.successReply())
        let writeDeadline = Date().addingTimeInterval(2)
        while tunnel.stream.writtenSnapshot.isEmpty, Date() < writeDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(tunnel.stream.writtenSnapshot, Data("first-bytes".utf8))
        tunnel.stream.push(Data("reply".utf8))
        let responseBytes = try await Self.receive(5, from: connection)
        XCTAssertEqual(responseBytes, Data("reply".utf8))
        listener.suspend()
        let closeDeadline = Date().addingTimeInterval(2)
        while tunnel.stream.isOpen, Date() < closeDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(tunnel.stream.isOpen)
        XCTAssertFalse(listener.isAccepting)
        try await assertGreetingRefused(on: 10806)
        XCTAssertTrue(listener.isListening, "Suspension retains the bound port until document retirement")
        let rival = try AccessSOCKS5InboundListener(registration: makeRegistration(port: 10806))
        do { try await rival.start(); try? rival.stop(); XCTFail("Port was released too early") }
        catch { }
    }

    func testExpiredSOCKSRegistrationFencesLiveAndNewFlowsWhileKeepingTheSocket() async throws {
        let socket = try await AccessEmbeddedProxyEntrySession.reserveLoopbackSocket()
        defer { socket.cancel() }
        let port = try XCTUnwrap(socket.port?.rawValue)
        let time = Date()
        let clock = Mutex(time)
        let cutoff = time.addingTimeInterval(60)
        let tunnel = GatedTunnel()
        let listener = try AccessSOCKS5InboundListener(
            registration: makeRegistration(port: port, expiresAt: cutoff),
            tunnels: tunnel, maximumConnections: 4, preparedSocket: socket, now: { clock.withLock { $0 } })
        try await listener.start(at: time)
        let connection = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: port)), using: .tcp)
        connection.start(queue: .global())
        let deadline = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { connection.cancel() }
        }
        defer { deadline.cancel(); tunnel.release(); connection.cancel(); try? listener.stop() }

        try await Self.send(Data([5, 1, 0]), to: connection)
        let method = try await Self.receive(2, from: connection)
        XCTAssertEqual(method, Data([5, 0]))
        try await Self.send(Data([5, 1, 0, 1, 192, 0, 2, 1, 1, 187]), to: connection)
        let dialDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !tunnel.isWaiting, ContinuousClock.now < dialDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(tunnel.isWaiting)
        tunnel.release()
        let reply = try await Self.receive(10, from: connection)
        XCTAssertEqual(reply, AccessSOCKS5InboundParser.successReply())
        XCTAssertTrue(tunnel.stream.isOpen)

        clock.withLock { $0 = cutoff }
        try await assertGreetingRefused(on: port)
        XCTAssertFalse(listener.isAccepting)
        XCTAssertEqual(listener.acceptedConnectionCount, 1)
        XCTAssertFalse(tunnel.stream.isOpen)
        XCTAssertTrue(listener.boundSocketForTests === socket)
        XCTAssertEqual(listener.boundPort, port)
        clock.withLock { $0 = time }
        XCTAssertFalse(listener.isAccepting, "A fenced lease must stay fenced after a clock correction")
    }

    func testHTTPLeaseExpiringDuringDialDoesNotAcknowledgeOrForward() async throws {
        try await assertLeaseExpiringDuringDial(transport: .http)
    }

    func testSOCKSLeaseExpiringDuringDialDoesNotAcknowledgeOrForward() async throws {
        try await assertLeaseExpiringDuringDial(transport: .socks5)
    }

    func testEstablishedHTTPUploadIsFencedOnWallClockExpiry() async throws {
        try await assertEstablishedLeaseExpiry(transport: .http, upload: true)
    }

    func testEstablishedHTTPDownloadIsFencedOnWallClockExpiry() async throws {
        try await assertEstablishedLeaseExpiry(transport: .http, upload: false)
    }

    func testEstablishedSOCKSUploadIsFencedOnWallClockExpiry() async throws {
        try await assertEstablishedLeaseExpiry(transport: .socks5, upload: true)
    }

    func testEstablishedSOCKSDownloadIsFencedOnWallClockExpiry() async throws {
        try await assertEstablishedLeaseExpiry(transport: .socks5, upload: false)
    }

    private func assertEstablishedLeaseExpiry(transport: AccessInboundTransport, upload: Bool) async throws {
        let socket = try await AccessEmbeddedProxyEntrySession.reserveLoopbackSocket()
        defer { socket.cancel() }
        let port = try XCTUnwrap(socket.port)
        let time = Date()
        let cutoff = time.addingTimeInterval(60)
        let clock = Mutex(time)
        let now: @Sendable () -> Date = { clock.withLock { $0 } }
        let tunnel = GatedTunnel()
        tunnel.release()
        let registration = try makeRegistration(transport: transport, port: port.rawValue, expiresAt: cutoff)
        let http = transport == .http ? try AccessHTTPInboundListener(registration: registration, tunnels: tunnel,
            maximumConnections: 4, preparedSocket: socket, now: now) : nil
        let socks = transport == .socks5 ? try AccessSOCKS5InboundListener(registration: registration, tunnels: tunnel,
            maximumConnections: 4, preparedSocket: socket, now: now) : nil
        defer { try? http?.stop(); try? socks?.stop() }
        try await http?.start(at: time)
        try await socks?.start(at: time)

        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        client.start(queue: .global())
        let deadline = Task {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { client.cancel() }
        }
        defer { deadline.cancel(); client.cancel() }
        let reply: Data
        if transport == .socks5 {
            try await Self.send(Data([5, 1, 0]), to: client)
            let greeting = try await Self.receive(2, from: client)
            XCTAssertEqual(greeting, Data([5, 0]))
            try await Self.send(Data([5, 1, 0, 1, 192, 0, 2, 1, 1, 187]), to: client)
            reply = AccessSOCKS5InboundParser.successReply()
        } else {
            try await Self.send(Data("CONNECT 192.0.2.1:443 HTTP/1.1\r\nHost: 192.0.2.1:443\r\n\r\n".utf8), to: client)
            reply = AccessHTTPConnectParser.successResponse(httpVersion: "HTTP/1.1")
        }
        let received = try await Self.receive(reply.count, from: client)
        XCTAssertEqual(received, reply)
        let readDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !tunnel.stream.hasPendingReadForTests, ContinuousClock.now < readDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard tunnel.stream.hasPendingReadForTests else { return XCTFail("The established stream never parked its remote read") }
        XCTAssertEqual(http?.establishedConnectCount ?? socks?.establishedConnectCount, 1)
        let fenced = expectation(description: "established peer closes without passing expired bytes")
        client.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, complete, error in
            XCTAssertTrue(data?.isEmpty != false)
            XCTAssertTrue(complete || error != nil)
            fenced.fulfill()
        }
        // The listener's monotonic timer is still valid; only the next forwarding
        // attempt can observe the wall-clock expiry.
        clock.withLock { $0 = cutoff }
        if upload {
            try? await Self.send(Data([42]), to: client)
        } else {
            tunnel.stream.push(Data([42]))
        }
        await fulfillment(of: [fenced], timeout: 2)
        XCTAssertTrue(tunnel.stream.writtenSnapshot.isEmpty)
        XCTAssertFalse(tunnel.stream.isOpen)
        XCTAssertTrue((http?.boundSocketForTests ?? socks?.boundSocketForTests) === socket)
        XCTAssertEqual(http?.boundPort ?? socks?.boundPort, port.rawValue)
    }

    private func assertLeaseExpiringDuringDial(transport: AccessInboundTransport) async throws {
        let socket = try await AccessEmbeddedProxyEntrySession.reserveLoopbackSocket()
        defer { socket.cancel() }
        let port = try XCTUnwrap(socket.port)
        let time = Date()
        let cutoff = time.addingTimeInterval(60)
        let clock = Mutex(time)
        let now: @Sendable () -> Date = { clock.withLock { $0 } }
        let tunnel = GatedTunnel()
        let registration = try makeRegistration(transport: transport, port: port.rawValue, expiresAt: cutoff)
        let http = transport == .http ? try AccessHTTPInboundListener(registration: registration, tunnels: tunnel,
            maximumConnections: 4, preparedSocket: socket, now: now) : nil
        let socks = transport == .socks5 ? try AccessSOCKS5InboundListener(registration: registration, tunnels: tunnel,
            maximumConnections: 4, preparedSocket: socket, now: now) : nil
        defer { tunnel.release(); try? http?.stop(); try? socks?.stop() }
        try await http?.start(at: time)
        try await socks?.start(at: time)

        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        client.start(queue: .global())
        let deadline = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { client.cancel() }
        }
        defer { deadline.cancel(); client.cancel() }
        var connect: Data
        if transport == .socks5 {
            try await Self.send(Data([5, 1, 0]), to: client)
            let greeting = try await Self.receive(2, from: client)
            XCTAssertEqual(greeting, Data([5, 0]))
            connect = Data([5, 1, 0, 1, 192, 0, 2, 1, 1, 187])
        } else {
            connect = Data("CONNECT 192.0.2.1:443 HTTP/1.1\r\nHost: 192.0.2.1:443\r\n\r\n".utf8)
        }
        connect.append(contentsOf: "buffered-synthetic-data".utf8)
        try await Self.send(connect, to: client)
        let dialDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !tunnel.isWaiting, ContinuousClock.now < dialDeadline { try await Task.sleep(for: .milliseconds(10)) }
        guard tunnel.isWaiting else { return XCTFail("The authorized opener never suspended") }
        let refused = expectation(description: "peer closed without CONNECT success")
        client.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, complete, error in
            XCTAssertTrue(data?.isEmpty != false)
            XCTAssertTrue(complete || error != nil)
            refused.fulfill()
        }
        // Only wall time advances. Querying isAccepting here would fence the
        // listener independently of the bridge and hide the regression.
        clock.withLock { $0 = cutoff }
        tunnel.release()
        await fulfillment(of: [refused], timeout: 2)
        let closeDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while tunnel.stream.isOpen, ContinuousClock.now < closeDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(tunnel.stream.isOpen)
        XCTAssertTrue(tunnel.stream.writtenSnapshot.isEmpty)
        XCTAssertEqual(http?.establishedConnectCount ?? socks?.establishedConnectCount, 0)
        XCTAssertTrue((http?.boundSocketForTests ?? socks?.boundSocketForTests) === socket)
    }

    private func assertGreetingRefused(on port: UInt16) async throws {
        let connection = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: port)), using: .tcp)
        let timedOut = Mutex(false)
        connection.start(queue: .global())
        let deadline = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { timedOut.withLock { $0 = true }; connection.cancel() }
        }
        defer { deadline.cancel(); connection.cancel() }
        do {
            try await Self.send(Data([5, 1, 0]), to: connection)
            _ = try await Self.receive(2, from: connection)
            XCTFail("A fenced listener must refuse a new greeting")
        } catch {
            XCTAssertFalse(timedOut.withLock { $0 }, "Local cancellation is not proof of a peer fence")
        }
    }

    private static func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private static func receive(_ count: Int, from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: URLError(.badServerResponse)) }
            }
        }
    }

    private final class GatedTunnel: AccessHTTPTunnelOpening, @unchecked Sendable {
        let stream = AccessMemoryRealityStream()
        let gate = Mutex((released: false, waiter: Optional<CheckedContinuation<Void, Never>>.none))
        var isWaiting: Bool { gate.withLock { $0.waiter != nil } }
        func open(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
            await withCheckedContinuation { continuation in
                let released = gate.withLock { state in
                    if state.released { return true }
                    state.waiter = continuation
                    return false
                }
                if released { continuation.resume() }
            }
            try Task.checkCancellation()
            return stream
        }
        func release() {
            let pending = gate.withLock { state in
                state.released = true
                let pending = state.waiter
                state.waiter = nil
                return pending
            }
            pending?.resume()
        }
    }

    private func makeRegistration(
        transport: AccessInboundTransport = .socks5,
        port: UInt16 = 18_805,
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) throws -> AccessRegistration {
        AccessRegistration(
            id: try AccessRegistrationID("reg-socks5-\(port)"),
            owner: try AccessOwner(channel: 1, profile: "ordinary", partition: "default"),
            transport: transport,
            endpoint: try AccessEndpoint(host: "127.0.0.1", port: port),
            credentialSlot: try AccessCredentialSlot(id: "cred-socks5"),
            lease: try AccessLease(
                generation: 1,
                expiresAt: expiresAt
            )
        )
    }

    func testLocalSOCKSPort1080CannotRestoreRotateOrStart() throws {
        let legacy = try makeRegistration(port: 1080)
        XCTAssertFalse(legacy.isActive(at: Date(timeIntervalSince1970: 1_700_000_000), observedGeneration: 1))
        XCTAssertThrowsError(try AccessSOCKS5InboundListener(registration: legacy))
        XCTAssertThrowsError(try JSONDecoder().decode(AccessRegistration.self, from: JSONEncoder().encode(legacy)))
        XCTAssertThrowsError(try AccessProxyRegistrationFixture(registrationId: "legacy", dataStoreKind: .ordinary,
            transport: .socks5, loopbackHost: "127.0.0.1", port: 1080, isActive: true))
        let admitted = try makeRegistration(port: 10806)
        XCTAssertTrue(admitted.hasAdmittedEndpoint)
        XCTAssertNoThrow(try JSONDecoder().decode(AccessRegistration.self, from: JSONEncoder().encode(admitted)))
        XCTAssertThrowsError(try admitted.rotated(id: AccessRegistrationID("next"),
            endpoint: AccessEndpoint(host: "127.0.0.1", port: 1080),
            credentialSlot: admitted.credentialSlot,
            lease: AccessLease(generation: 2, expiresAt: Date(timeIntervalSince1970: 1_700_000_120))))
        XCTAssertTrue(try makeRegistration(transport: .http, port: 1080).hasAdmittedEndpoint)
        XCTAssertNoThrow(try AccessSOCKS5ConnectRequest(address: .domain("example.com"), port: 1080))
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
        try await listener.start()

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
