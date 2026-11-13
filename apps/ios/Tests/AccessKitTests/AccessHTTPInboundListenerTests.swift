import Foundation
import Darwin
import Network
import XCTest
import os
@testable import AccessKit

final class AccessHTTPInboundListenerTests: XCTestCase {
    func testRepeatedConnectsReleaseConnectionsSessionsAndBridges() async throws {
        let listener = try AccessHTTPInboundListener(registration: makeRegistration(port: 18_088), tunnels: HoldingTunnel())
        let references = OSAllocatedUnfairLock(initialState: [WeakConnection]())
        listener.acceptedConnectionObserverForTests = { connection in
            references.withLock { $0.append(WeakConnection(connection)) }
        }
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
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
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
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
