import XCTest
@testable import AccessKit

final class AccessRegistrationLeaseTests: XCTestCase {
    private func makeOwner() throws -> AccessOwner {
        try AccessOwner(channel: 1, profile: "ordinary", partition: "default")
    }

    private func makeLease(generation: UInt64 = 1, offset: TimeInterval = 60) throws -> AccessLease {
        try AccessLease(generation: generation, expiresAt: Date(timeIntervalSince1970: 1_700_000_000 + offset))
    }

    func testEndpointAcceptsLoopbackOnly() throws {
        let endpoint = try AccessEndpoint(host: "127.0.0.1", port: 18080)
        XCTAssertEqual(endpoint.host, AccessEndpoint.loopbackHost)
        XCTAssertEqual(endpoint.port, 18080)

        XCTAssertThrowsError(try AccessEndpoint(host: "0.0.0.0", port: 18080)) { error in
            XCTAssertEqual(error as? AccessContractError, .nonLoopbackEndpoint("0.0.0.0"))
        }
        XCTAssertThrowsError(try AccessEndpoint(host: "192.168.1.10", port: 18080)) { error in
            XCTAssertEqual(error as? AccessContractError, .nonLoopbackEndpoint("192.168.1.10"))
        }
        XCTAssertThrowsError(try AccessEndpoint(host: "127.0.0.1", port: 0)) { error in
            XCTAssertEqual(error as? AccessContractError, .invalidEndpointPort(0))
        }
    }

    func testLeaseRejectsZeroGenerationAndExpiryRules() throws {
        XCTAssertThrowsError(try AccessLease(generation: 0, expiresAt: Date())) { error in
            XCTAssertEqual(error as? AccessContractError, .invalidLeaseGeneration(0))
        }

        let lease = try makeLease(generation: 3, offset: 30)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(lease.isActive(at: now, observedGeneration: 3))
        XCTAssertFalse(lease.isActive(at: now, observedGeneration: 2))
        XCTAssertFalse(lease.isActive(at: now.addingTimeInterval(60), observedGeneration: 3))

        let renewed = try lease.renewed(expiresAt: now.addingTimeInterval(120))
        XCTAssertEqual(renewed.generation, 4)
        XCTAssertTrue(renewed.isActive(at: now, observedGeneration: 4))
        XCTAssertFalse(lease.isActive(at: now, observedGeneration: 4), "prior generation stays inactive")
    }

    func testRegistrationIDIsOneShotAcrossRotation() throws {
        let owner = try makeOwner()
        let id1 = try AccessRegistrationID("reg-1")
        let endpoint1 = try AccessEndpoint(host: "127.0.0.1", port: 18081)
        let slot1 = try AccessCredentialSlot(id: "cred-1")
        let lease1 = try makeLease(generation: 1)

        let registration = AccessRegistration(
            id: id1,
            owner: owner,
            transport: .http,
            endpoint: endpoint1,
            credentialSlot: slot1,
            lease: lease1
        )

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(registration.isActive(at: now, observedGeneration: 1))

        XCTAssertThrowsError(
            try registration.rotated(
                id: id1,
                endpoint: try AccessEndpoint(host: "127.0.0.1", port: 18082),
                credentialSlot: try AccessCredentialSlot(id: "cred-2"),
                lease: try makeLease(generation: 2)
            )
        ) { error in
            XCTAssertEqual(error as? AccessContractError, .registrationIDReused)
        }

        XCTAssertThrowsError(
            try registration.rotated(
                id: try AccessRegistrationID("reg-2"),
                endpoint: try AccessEndpoint(host: "127.0.0.1", port: 18082),
                credentialSlot: try AccessCredentialSlot(id: "cred-2"),
                lease: try makeLease(generation: 1)
            )
        ) { error in
            XCTAssertEqual(error as? AccessContractError, .staleLeaseGeneration(1))
        }

        let rotated = try registration.rotated(
            id: try AccessRegistrationID("reg-2"),
            endpoint: try AccessEndpoint(host: "127.0.0.1", port: 18082),
            credentialSlot: try AccessCredentialSlot(id: "cred-2"),
            lease: try makeLease(generation: 2)
        )
        XCTAssertEqual(rotated.id.rawValue, "reg-2")
        XCTAssertEqual(rotated.endpoint.port, 18082)
        XCTAssertEqual(rotated.generation, 2)
        XCTAssertFalse(registration.isActive(at: now, observedGeneration: 2))
        XCTAssertTrue(rotated.isActive(at: now, observedGeneration: 2))
    }

    func testCredentialSlotAndRegistrationIDRejectEmpty() {
        XCTAssertThrowsError(try AccessCredentialSlot(id: " ")) { error in
            XCTAssertEqual(error as? AccessContractError, .emptyCredentialSlot)
        }
        XCTAssertThrowsError(try AccessRegistrationID("")) { error in
            XCTAssertEqual(error as? AccessContractError, .emptyRegistrationID)
        }
    }

    func testRegistrationCodableRoundTrip() throws {
        let registration = AccessRegistration(
            id: try AccessRegistrationID("reg-json"),
            owner: try makeOwner(),
            transport: .https,
            endpoint: try AccessEndpoint(host: "127.0.0.1", port: 8443),
            credentialSlot: try AccessCredentialSlot(id: "slot-a"),
            lease: try makeLease(generation: 7, offset: 90)
        )
        let data = try JSONEncoder().encode(registration)
        let decoded = try JSONDecoder().decode(AccessRegistration.self, from: data)
        XCTAssertEqual(decoded, registration)
        XCTAssertEqual(decoded.transport, .https)
        XCTAssertEqual(decoded.leaseExpiry, registration.lease.expiresAt)
    }
}
