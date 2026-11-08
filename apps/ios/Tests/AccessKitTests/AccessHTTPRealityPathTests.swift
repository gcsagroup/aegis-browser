import XCTest
@testable import AccessKit

private final class FakeStream: AccessRealityPathStream {
    private(set) var isOpen = true
    func close() { isOpen = false }
}

private final class FakeDialer: AccessRealityPathDialing {
    var lastHost: String?
    var lastPort: UInt16?
    var shouldFail = false
    func dial(host: String, port: UInt16) throws -> AccessRealityPathStream {
        if shouldFail { throw AccessHTTPRealityPathError.dialFailed("forced") }
        lastHost = host
        lastPort = port
        return FakeStream()
    }
}

private final class FakeHandle: AccessXrayProcessHandle {
    var isRunning = true
    func terminate() { isRunning = false }
}

private final class FakeController: AccessXrayProcessControlling {
    func launch(executableURL: URL, configData: Data) throws -> AccessXrayProcessHandle {
        _ = executableURL; _ = configData
        return FakeHandle()
    }
}

private struct AcceptingVerifier: AccessXrayDigestVerifying {
    func verify(
        fileURL: URL,
        architecture: AccessXrayArchitecture,
        outboundProfile: AccessOutboundProfile
    ) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AccessXrayRuntimeError.executableMissing
        }
    }
}

final class AccessHTTPRealityPathTests: XCTestCase {
    private func makeRegistration(
        transport: AccessInboundTransport = .http
    ) throws -> AccessRegistration {
        AccessRegistration(
            id: try AccessRegistrationID("reg-http-reality"),
            owner: try AccessOwner(channel: 1, profile: "ordinary", partition: "default"),
            transport: transport,
            endpoint: try AccessEndpoint(host: "127.0.0.1", port: 18_201),
            credentialSlot: try AccessCredentialSlot(id: "cred-http-reality"),
            lease: try AccessLease(
                generation: 1,
                expiresAt: Date(timeIntervalSince1970: 1_700_000_000 + 60)
            )
        )
    }

    private func makeRunningRuntime() throws -> (AccessXrayRuntime, URL) {
        let runtime = try AccessXrayRuntime(
            processController: FakeController(),
            digestVerifier: AcceptingVerifier()
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("f11-xray-\(UUID().uuidString)")
        try Data("stub".utf8).write(to: url)
        let parameters = try AccessRealityVisionParameters(
            address: "198.51.100.40",
            port: 443,
            userID: "550e8400-e29b-41d4-a716-446655440000",
            serverName: "www.example.com",
            publicKey: "abcdefghijklmnopqrstuvwxyzABCDEFG",
            shortID: "abcd1234"
        )
        try runtime.start(
            executableURL: url,
            config: try AccessRealityVisionOutboundConfigBuilder.build(parameters: parameters)
        )
        return (runtime, url)
    }

    func testOpensRealityPathForHTTPConnect() throws {
        let registration = try makeRegistration()
        let (runtime, url) = try makeRunningRuntime()
        defer {
            try? runtime.stop()
            try? FileManager.default.removeItem(at: url)
        }
        let dialer = FakeDialer()
        let connect = try AccessHTTPConnectRequest(host: "example.com", port: 443, httpVersion: "HTTP/1.1")
        let (handle, stream) = try AccessHTTPRealityPath.open(
            connect: connect,
            registration: registration,
            runtime: runtime,
            dialer: dialer,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(handle.targetHost, "example.com")
        XCTAssertEqual(handle.targetPort, 443)
        XCTAssertTrue(handle.streamOpen)
        XCTAssertEqual(dialer.lastHost, "example.com")
        XCTAssertEqual(dialer.lastPort, 443)
        stream.close()
        XCTAssertFalse(stream.isOpen)
    }

    func testRejectsNonHTTPRegistrationAndInactiveLease() throws {
        let https = try makeRegistration(transport: .https)
        let (runtime, url) = try makeRunningRuntime()
        defer {
            try? runtime.stop()
            try? FileManager.default.removeItem(at: url)
        }
        let connect = try AccessHTTPConnectRequest(host: "example.com", port: 443, httpVersion: "HTTP/1.1")
        XCTAssertThrowsError(
            try AccessHTTPRealityPath.open(
                connect: connect,
                registration: https,
                runtime: runtime,
                dialer: FakeDialer(),
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ) { error in
            XCTAssertEqual(error as? AccessHTTPRealityPathError, .transportNotHTTP(.https))
        }

        let http = try makeRegistration()
        XCTAssertThrowsError(
            try AccessHTTPRealityPath.open(
                connect: connect,
                registration: http,
                runtime: runtime,
                dialer: FakeDialer(),
                at: Date(timeIntervalSince1970: 1_700_000_000 + 120)
            )
        ) { error in
            XCTAssertEqual(error as? AccessHTTPRealityPathError, .leaseInactive)
        }
    }

    func testRejectsStoppedRuntimeAndDirectDialFlag() throws {
        let registration = try makeRegistration()
        let runtime = try AccessXrayRuntime(
            processController: FakeController(),
            digestVerifier: AcceptingVerifier()
        )
        let connect = try AccessHTTPConnectRequest(host: "example.com", port: 443, httpVersion: "HTTP/1.1")
        XCTAssertThrowsError(
            try AccessHTTPRealityPath.open(
                connect: connect,
                registration: registration,
                runtime: runtime,
                dialer: FakeDialer()
            )
        ) { error in
            XCTAssertEqual(error as? AccessHTTPRealityPathError, .runtimeNotRunning)
        }

        let (running, url) = try makeRunningRuntime()
        defer {
            try? running.stop()
            try? FileManager.default.removeItem(at: url)
        }
        XCTAssertThrowsError(
            try AccessHTTPRealityPath.open(
                connect: connect,
                registration: registration,
                runtime: running,
                dialer: FakeDialer(),
                at: Date(timeIntervalSince1970: 1_700_000_000),
                allowDirectDial: true
            )
        ) { error in
            XCTAssertEqual(error as? AccessHTTPRealityPathError, .directDialNotAdmitted)
        }
    }
}
