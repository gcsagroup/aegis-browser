import Network
import XCTest
@testable import AccessKit

private final class ThrowingTLSProvider: AccessHTTPSInboundTLSProviding {
    func makeServerTLSOptions(identityLabel: String) throws -> NWProtocolTLS.Options {
        throw AccessHTTPSInboundError.tlsIdentityUnavailable("missing:\(identityLabel)")
    }
}

private final class EmptyTLSProvider: AccessHTTPSInboundTLSProviding {
    func makeServerTLSOptions(identityLabel: String) throws -> NWProtocolTLS.Options {
        // Options without a local identity — enough to exercise parameter assembly.
        _ = identityLabel
        return NWProtocolTLS.Options()
    }
}

final class AccessHTTPSInboundFrontTests: XCTestCase {
    private func makeRegistration(
        transport: AccessInboundTransport,
        port: UInt16 = 18_443
    ) throws -> AccessRegistration {
        AccessRegistration(
            id: try AccessRegistrationID("reg-https-\(port)"),
            owner: try AccessOwner(channel: 1, profile: "ordinary", partition: "default"),
            transport: transport,
            endpoint: try AccessEndpoint(host: "127.0.0.1", port: port),
            credentialSlot: try AccessCredentialSlot(id: "cred-https"),
            lease: try AccessLease(
                generation: 1,
                expiresAt: Date(timeIntervalSince1970: 1_700_000_000 + 60)
            )
        )
    }

    func testPlanRejectsHTTPAndEmptyIdentity() throws {
        let http = try makeRegistration(transport: .http)
        XCTAssertThrowsError(
            try AccessHTTPSInboundFrontBuilder.plan(registration: http, identityLabel: "local-front")
        ) { error in
            XCTAssertEqual(error as? AccessHTTPSInboundError, .transportNotHTTPS(.http))
        }

        let https = try makeRegistration(transport: .https)
        XCTAssertThrowsError(
            try AccessHTTPSInboundFrontBuilder.plan(registration: https, identityLabel: "  ")
        ) { error in
            XCTAssertEqual(error as? AccessHTTPSInboundError, .emptyIdentityLabel)
        }
    }

    func testMakeParametersRequiresTLSIdentity() throws {
        let registration = try makeRegistration(transport: .https)
        let listener = try AccessHTTPSInboundListener(
            registration: registration,
            identityLabel: "local-front",
            tlsProvider: ThrowingTLSProvider()
        )
        XCTAssertThrowsError(try listener.makeParameters()) { error in
            XCTAssertEqual(
                error as? AccessHTTPSInboundError,
                .tlsIdentityUnavailable("missing:local-front")
            )
        }
    }

    func testMakeParametersAssemblesTLSLoopbackEndpoint() throws {
        let registration = try makeRegistration(transport: .https, port: 18_444)
        let listener = try AccessHTTPSInboundListener(
            registration: registration,
            identityLabel: "local-front",
            tlsProvider: EmptyTLSProvider()
        )
        let parameters = try listener.makeParameters()
        XCTAssertNotNil(parameters.defaultProtocolStack.applicationProtocols.first)
        guard case let .hostPort(host, port)? = parameters.requiredLocalEndpoint else {
            return XCTFail("expected requiredLocalEndpoint hostPort")
        }
        XCTAssertEqual("\(host)", "127.0.0.1")
        XCTAssertEqual(port.rawValue, 18_444)
    }

    func testStartRejectsInactiveLease() async throws {
        let registration = AccessRegistration(
            id: try AccessRegistrationID("reg-https-expired"),
            owner: try AccessOwner(channel: 1, profile: "ordinary", partition: "default"),
            transport: .https,
            endpoint: try AccessEndpoint(host: "127.0.0.1", port: 18_445),
            credentialSlot: try AccessCredentialSlot(id: "cred-https-expired"),
            lease: try AccessLease(
                generation: 1,
                expiresAt: Date(timeIntervalSince1970: 1_700_000_000 + 5)
            )
        )
        let listener = try AccessHTTPSInboundListener(
            registration: registration,
            identityLabel: "local-front",
            tlsProvider: EmptyTLSProvider()
        )
        let afterExpiry = Date(timeIntervalSince1970: 1_700_000_000 + 30)
        do {
            try await listener.start(at: afterExpiry)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? AccessHTTPSInboundError, .leaseInactive)
        }
    }
}
