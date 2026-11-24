import Foundation
import Darwin
import Network
import XCTest
import os
@testable import AccessKit

final class AccessHTTPInboundListenerTests: XCTestCase {
    func testPreparedLoopbackSocketIsRetainedAcrossHTTPAdoption() async throws {
        let socket = try await AccessEmbeddedProxyEntrySession.reserveLoopbackSocket()
        defer { socket.cancel() }
        let port = try XCTUnwrap(socket.port?.rawValue)
        let registration = try makeRegistration(port: port)
        let rival = try AccessHTTPInboundListener(registration: registration, tunnels: HoldingTunnel())
        do {
            try await rival.start()
            try? rival.stop()
            XCTFail("The assigned socket must hold its port before protocol adoption")
        } catch { }
        let listener = try AccessHTTPInboundListener(registration: registration, preparedSocket: socket, tunnels: HoldingTunnel())
        try await listener.start()
        defer { try? listener.stop() }
        XCTAssertTrue(listener.boundSocketForTests === socket)
        XCTAssertEqual(listener.boundPort, port)
        XCTAssertTrue(listener.isListening)
    }

    func testRepeatedConnectsReleaseConnectionsSessionsAndBridges() async throws {
        let listener = try AccessHTTPInboundListener(registration: makeRegistration(port: 18_088), tunnels: HoldingTunnel())
        let references = OSAllocatedUnfairLock(initialState: [WeakConnection]())
        listener.acceptedConnectionObserverForTests = { connection in
            references.withLock { $0.append(WeakConnection(connection)) }
        }
        try await listener.start()
        defer { try? listener.stop() }
        var footprints = [["closedConnections": UInt64(0), "physicalFootprintBytes": try physicalFootprint()]]
        for index in 0..<60 {
            let response = expectation(description: "CONNECT response \(index)")
            let client = NWConnection(host: "127.0.0.1", port: 18_088, using: .tcp)
            client.stateUpdateHandler = { [weak client] state in
                guard case .ready = state, let client else { return }
                client.send(content: Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                client.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { _, _, _, _ in response.fulfill() }
            }
            client.start(queue: .global())
            await fulfillment(of: [response], timeout: 3)
            client.cancel()
            let deadline = Date().addingTimeInterval(3)
            while listener.retainedResourceCounts.connections > 0, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(listener.retainedResourceCounts.connections, 0)
            XCTAssertEqual(listener.retainedResourceCounts.sessions, 0)
            XCTAssertEqual(listener.retainedResourceCounts.bridges, 0)
            if (index + 1).isMultiple(of: 20) {
                footprints.append(["closedConnections": UInt64(index + 1), "physicalFootprintBytes": try physicalFootprint()])
            }
        }
        let deadline = Date().addingTimeInterval(3)
        while references.withLock({ $0.contains { $0.value != nil } }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(listener.acceptedConnectionCount, 60)
        XCTAssertEqual(references.withLock { $0.filter { $0.value != nil }.count }, 0)
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: footprints, options: [.sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "loopback-connect-memory-samples.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSuspensionKeepsPortOwnedAndRejectsNewTraffic() async throws {
        let registration = try makeRegistration(port: 18_096)
        let listener = try AccessHTTPInboundListener(registration: registration, tunnels: HoldingTunnel())
        try await listener.start()
        defer { try? listener.stop() }
        listener.suspend()
        XCTAssertTrue(listener.isListening)
        let rival = try AccessHTTPInboundListener(registration: registration, tunnels: HoldingTunnel())
        do {
            try await rival.start()
            try? rival.stop()
            XCTFail("A suspended listener must retain its port until document retirement")
        } catch { }
        let finished = expectation(description: "suspended connection closes")
        let client = NWConnection(host: "127.0.0.1", port: 18_096, using: .tcp)
        client.stateUpdateHandler = { [weak client] state in
            guard case .ready = state, let client else { return }
            client.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in finished.fulfill() }
        }
        client.start(queue: .global())
        await fulfillment(of: [finished], timeout: 3)
        client.cancel()
        XCTAssertEqual(listener.acceptedConnectionCount, 0)
    }

    func testExpiredHTTPRegistrationFencesActiveAndNewFlowsWithoutReleasingItsSocket() async throws {
        let socket = try await AccessEmbeddedProxyEntrySession.reserveLoopbackSocket()
        defer { socket.cancel() }
        let port = try XCTUnwrap(socket.port?.rawValue)
        let registration = try makeRegistration(port: port)
        let clock = OSAllocatedUnfairLock(initialState: Date())
        let tunnel = RecordingHTTPExpiryTunnel()
        let listener = try AccessHTTPInboundListener(registration: registration, tunnels: tunnel,
            maximumConnections: 4, preparedSocket: socket, now: { clock.withLock { $0 } })
        try await listener.start()
        defer { try? listener.stop() }
        XCTAssertTrue(listener.isAccepting)

        let connected = expectation(description: "HTTP CONNECT established before expiry")
        let client = try startPeer(port: port, sendConnect: true) { data, _, error in
            XCTAssertNil(error)
            XCTAssertTrue(data.map { String(decoding: $0, as: UTF8.self).hasPrefix("HTTP/1.1 200") } == true)
            connected.fulfill()
        }
        defer { client.cancel() }
        await fulfillment(of: [connected], timeout: 2)
        XCTAssertTrue(tunnel.stream.isOpen)

        clock.withLock { $0 = registration.leaseExpiry }
        let refused = expectation(description: "expired HTTP peer closes without accepting CONNECT")
        let newcomer = try startPeer(port: port, sendConnect: true) { data, complete, error in
            XCTAssertTrue(data?.isEmpty != false)
            XCTAssertTrue(complete || error != nil)
            refused.fulfill()
        }
        defer { newcomer.cancel() }
        await fulfillment(of: [refused], timeout: 2)
        XCTAssertFalse(listener.isAccepting)
        XCTAssertTrue(listener.isListening)
        XCTAssertTrue(listener.boundSocketForTests === socket)
        XCTAssertFalse(tunnel.stream.isOpen)
        XCTAssertEqual(listener.acceptedConnectionCount, 1)
        XCTAssertEqual(tunnel.dialCount, 1)
        clock.withLock { $0 = Date() }
        XCTAssertFalse(listener.isAccepting, "The fenced lease must remain closed after a clock correction")
    }

    func testLeaseExpiringAfterSocketReadinessReturnsHTTPError() async throws {
        let socket = try await AccessEmbeddedProxyEntrySession.reserveLoopbackSocket()
        defer { socket.cancel() }
        let port = try XCTUnwrap(socket.port?.rawValue)
        let registration = try makeRegistration(port: port)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let initialTime = registration.leaseExpiry.addingTimeInterval(-30)
        let listener = try AccessHTTPInboundListener(registration: registration, tunnels: HoldingTunnel(),
            maximumConnections: 4, preparedSocket: socket, now: {
                reads.withLock { count in
                    count += 1
                    return count == 1 ? initialTime : registration.leaseExpiry
                }
            })
        do {
            try await listener.start(at: initialTime)
            XCTFail("HTTP startup must fail when the lease reaches its cutoff")
        } catch {
            XCTAssertEqual(error as? AccessHTTPInboundError, .leaseInactive)
        }
        XCTAssertGreaterThanOrEqual(reads.withLock { $0 }, 2)
        XCTAssertFalse(listener.isListening)
    }

    func testHTTPConnectAdmittedBeforeExpiryCannotOpenUpstreamAfterExpiry() async throws {
        let socket = try await AccessEmbeddedProxyEntrySession.reserveLoopbackSocket()
        defer { socket.cancel() }
        let port = try XCTUnwrap(socket.port?.rawValue)
        let registration = try makeRegistration(port: port)
        let clock = OSAllocatedUnfairLock(initialState: Date())
        let tunnel = RecordingHTTPExpiryTunnel()
        let listener = try AccessHTTPInboundListener(registration: registration, tunnels: tunnel,
            maximumConnections: 4, preparedSocket: socket, now: { clock.withLock { $0 } })
        let accepted = expectation(description: "client accepted while lease is active")
        listener.acceptedConnectionObserverForTests = { _ in accepted.fulfill() }
        try await listener.start()
        defer { try? listener.stop() }
        let closed = expectation(description: "client closes when sending CONNECT after lease expiry")
        let client = try startPeer(port: port, sendConnect: false) { data, complete, error in
            XCTAssertTrue(data?.isEmpty != false)
            XCTAssertTrue(complete || error != nil)
            closed.fulfill()
        }
        defer { client.cancel() }
        await fulfillment(of: [accepted], timeout: 2)
        clock.withLock { $0 = registration.leaseExpiry }
        client.send(content: Self.connectRequest, completion: .contentProcessed { _ in })
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(tunnel.dialCount, 0)
        XCTAssertFalse(listener.isAccepting)
        XCTAssertTrue(listener.boundSocketForTests === socket)
    }

    private static let connectRequest = Data("CONNECT probe.invalid:443 HTTP/1.1\r\nHost: probe.invalid:443\r\n\r\n".utf8)

    private func startPeer(port: UInt16, sendConnect: Bool,
                           response: @escaping @Sendable (Data?, Bool, NWError?) -> Void) throws -> NWConnection {
        let endpoint = try XCTUnwrap(NWEndpoint.Port(rawValue: port))
        let client = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
        client.stateUpdateHandler = { [weak client] state in
            guard case .ready = state, let client else { return }
            if sendConnect { client.send(content: Self.connectRequest, completion: .contentProcessed { _ in }) }
            client.receive(minimumIncompleteLength: 12, maximumLength: 256) { data, _, complete, error in
                response(data, complete, error)
            }
        }
        client.start(queue: .global())
        return client
    }

    private func physicalFootprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw NSError(domain: NSMachErrorDomain, code: Int(result)) }
        return info.phys_footprint
    }

    func testCapacityAndStopBoundAcceptedConnectionOwnership() async throws {
        let listener = try AccessHTTPInboundListener(registration: makeRegistration(port: 18_089),
                                                    tunnels: HoldingTunnel(), maximumConnections: 2)
        try await listener.start()
        var clients: [NWConnection] = []
        defer { clients.forEach { $0.cancel() }; try? listener.stop() }
        for _ in 0..<3 {
            let client = NWConnection(host: "127.0.0.1", port: 18_089, using: .tcp)
            clients.append(client)
            client.start(queue: .global())
        }
        let deadline = Date().addingTimeInterval(3)
        while listener.acceptedConnectionCount < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(listener.acceptedConnectionCount, 2)
        XCTAssertEqual(listener.retainedResourceCounts.connections, 2)
        try listener.stop()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(listener.retainedResourceCounts.connections, 0)
        XCTAssertEqual(listener.retainedResourceCounts.sessions, 0)
        XCTAssertEqual(listener.retainedResourceCounts.bridges, 0)
    }

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
                expiresAt: Date().addingTimeInterval(leaseOffset)
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
        let afterExpiry = registration.leaseExpiry.addingTimeInterval(1)
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
        let now = Date()

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
        try await listener.start()
        defer { try? listener.stop() }
        XCTAssertTrue(listener.isListening)
        let observer = try XCTUnwrap(listener.listenerStateObserverForTests)
        observer(.failed(.posix(.ECONNABORTED)))
        XCTAssertFalse(listener.isListening)
        observer(.cancelled)
        XCTAssertFalse(listener.isListening)
    }
}

private final class WeakConnection: @unchecked Sendable {
    weak var value: NWConnection?
    init(_ connection: NWConnection) { value = connection }
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

private final class RecordingHTTPExpiryTunnel: AccessHTTPTunnelOpening {
    let stream = AccessMemoryRealityStream()
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var dialCount: Int { count.withLock { $0 } }

    func open(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        count.withLock { $0 += 1 }
        return stream
    }
}
