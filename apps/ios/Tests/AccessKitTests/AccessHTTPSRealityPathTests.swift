import Network
import XCTest
@testable import AccessKit

private final class FakeStream: AccessRealityPathStream, @unchecked Sendable {
    private(set) var isOpen = true
    func read(maxBytes: Int) async throws -> Data? { nil }
    func write(_ data: Data) async throws {}
    func close() { isOpen = false }
}

private final class FakeDialer: AccessRealityPathDialing, @unchecked Sendable {
    var lastHost: String?
    var lastPort: UInt16?
    var dialCount = 0
    var shouldFail = false
    func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        dialCount += 1
        if shouldFail { throw AccessHTTPSRealityPathError.dialFailed("forced") }
        lastHost = host
        lastPort = port
        return FakeStream()
    }
}

private final class AcceptingTLSProvider: AccessHTTPSInboundTLSProviding {
    var lastLabel: String?
    var callCount = 0
    func makeServerTLSOptions(identityLabel: String) throws -> NWProtocolTLS.Options {
        callCount += 1
        lastLabel = identityLabel
        return NWProtocolTLS.Options()
    }
}

private final class FailingTLSProvider: AccessHTTPSInboundTLSProviding {
    func makeServerTLSOptions(identityLabel: String) throws -> NWProtocolTLS.Options {
        throw AccessHTTPSInboundError.tlsIdentityUnavailable("missing:\(identityLabel)")
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

final class AccessHTTPSRealityPathTests: XCTestCase {
    private func makeRegistration(
        transport: AccessInboundTransport = .https
    ) throws -> AccessRegistration {
        AccessRegistration(
            id: try AccessRegistrationID("reg-https-reality"),
            owner: try AccessOwner(channel: 1, profile: "ordinary", partition: "default"),
            transport: transport,
            endpoint: try AccessEndpoint(host: "127.0.0.1", port: 18_443),
            credentialSlot: try AccessCredentialSlot(id: "cred-https-reality"),
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
            .appendingPathComponent("f12-xray-\(UUID().uuidString)")
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

    func testOpensRealityPathForHTTPSConnect() async throws {
        let registration = try makeRegistration()
        let (runtime, url) = try makeRunningRuntime()
        defer {
            try? runtime.stop()
            try? FileManager.default.removeItem(at: url)
        }
        let dialer = FakeDialer()
        let tls = AcceptingTLSProvider()
        let connect = try AccessHTTPConnectRequest(host: "example.com", port: 443, httpVersion: "HTTP/1.1")
        let (handle, stream) = try await AccessHTTPSRealityPath.open(
            connect: connect,
            registration: registration,
            identityLabel: "local-front",
            tlsProvider: tls,
            runtime: runtime,
            dialer: dialer,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(handle.targetHost, "example.com")
        XCTAssertEqual(handle.targetPort, 443)
        XCTAssertEqual(handle.identityLabel, "local-front")
        XCTAssertTrue(handle.streamOpen)
        XCTAssertEqual(dialer.lastHost, "example.com")
        XCTAssertEqual(dialer.lastPort, 443)
        XCTAssertEqual(dialer.dialCount, 1)
        XCTAssertEqual(tls.lastLabel, "local-front")
        XCTAssertEqual(tls.callCount, 1)
        stream.close()
        XCTAssertFalse(stream.isOpen)
    }

    func testRejectsHTTPRegistrationTransportGate() async throws {
        let http = try makeRegistration(transport: .http)
        let (runtime, url) = try makeRunningRuntime()
        defer {
            try? runtime.stop()
            try? FileManager.default.removeItem(at: url)
        }
        let dialer = FakeDialer()
        let connect = try AccessHTTPConnectRequest(host: "example.com", port: 443, httpVersion: "HTTP/1.1")
        do {
            _ = try await AccessHTTPSRealityPath.open(
                connect: connect,
                registration: http,
                identityLabel: "local-front",
                tlsProvider: AcceptingTLSProvider(),
                runtime: runtime,
                dialer: dialer,
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AccessHTTPSRealityPathError, .transportNotHTTPS(.http))
        }
        XCTAssertEqual(dialer.dialCount, 0)
    }

    func testCertificateFailureHasNoDirectBypass() async throws {
        let registration = try makeRegistration()
        let (runtime, url) = try makeRunningRuntime()
        defer {
            try? runtime.stop()
            try? FileManager.default.removeItem(at: url)
        }
        let dialer = FakeDialer()
        let connect = try AccessHTTPConnectRequest(host: "example.com", port: 443, httpVersion: "HTTP/1.1")
        do {
            _ = try await AccessHTTPSRealityPath.open(
                connect: connect,
                registration: registration,
                identityLabel: "local-front",
                tlsProvider: FailingTLSProvider(),
                runtime: runtime,
                dialer: dialer,
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(
                error as? AccessHTTPSRealityPathError,
                .tlsIdentityUnavailable("missing:local-front")
            )
        }
        // Cert failure must not dial origin DIRECT (or any path) as success.
        XCTAssertEqual(dialer.dialCount, 0)
    }

    func testRejectsStoppedRuntimeAndDirectDialFlag() async throws {
        let registration = try makeRegistration()
        let runtime = try AccessXrayRuntime(
            processController: FakeController(),
            digestVerifier: AcceptingVerifier()
        )
        let dialer = FakeDialer()
        let connect = try AccessHTTPConnectRequest(host: "example.com", port: 443, httpVersion: "HTTP/1.1")
        do {
            _ = try await AccessHTTPSRealityPath.open(
                connect: connect,
                registration: registration,
                identityLabel: "local-front",
                tlsProvider: AcceptingTLSProvider(),
                runtime: runtime,
                dialer: dialer,
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AccessHTTPSRealityPathError, .runtimeNotRunning)
        }
        XCTAssertEqual(dialer.dialCount, 0)

        let (running, url) = try makeRunningRuntime()
        defer {
            try? running.stop()
            try? FileManager.default.removeItem(at: url)
        }
        do {
            _ = try await AccessHTTPSRealityPath.open(
                connect: connect,
                registration: registration,
                identityLabel: "local-front",
                tlsProvider: AcceptingTLSProvider(),
                runtime: running,
                dialer: dialer,
                at: Date(timeIntervalSince1970: 1_700_000_000),
                allowDirectDial: true
            )
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AccessHTTPSRealityPathError, .directDialNotAdmitted)
        }
        XCTAssertEqual(dialer.dialCount, 0)
    }

    func testRejectsInactiveLease() async throws {
        let registration = try makeRegistration()
        let (runtime, url) = try makeRunningRuntime()
        defer {
            try? runtime.stop()
            try? FileManager.default.removeItem(at: url)
        }
        let dialer = FakeDialer()
        let connect = try AccessHTTPConnectRequest(host: "example.com", port: 443, httpVersion: "HTTP/1.1")
        do {
            _ = try await AccessHTTPSRealityPath.open(
                connect: connect,
                registration: registration,
                identityLabel: "local-front",
                tlsProvider: AcceptingTLSProvider(),
                runtime: runtime,
                dialer: dialer,
                at: Date(timeIntervalSince1970: 1_700_000_000 + 120)
            )
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AccessHTTPSRealityPathError, .leaseInactive)
        }
        XCTAssertEqual(dialer.dialCount, 0)
    }
}
