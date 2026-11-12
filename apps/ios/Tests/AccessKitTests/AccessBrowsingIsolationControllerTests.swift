import XCTest
@testable import AccessKit

final class AccessBrowsingIsolationControllerTests: XCTestCase {
    private func makeRegistration(
        id: String,
        profile: String,
        credential: String,
        port: UInt16,
        generation: UInt64 = 1
    ) throws -> AccessRegistration {
        AccessRegistration(
            id: try AccessRegistrationID(id),
            owner: try AccessOwner(channel: 1, profile: profile, partition: "default"),
            transport: .http,
            endpoint: try AccessEndpoint(host: "127.0.0.1", port: port),
            credentialSlot: try AccessCredentialSlot(id: credential),
            lease: try AccessLease(
                generation: generation,
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
    }

    func testOrdinaryAndPrivateStateStayIndependent() throws {
        let controller = AccessBrowsingIsolationController()
        let ordinaryReg = try makeRegistration(
            id: "reg-ordinary",
            profile: "ordinary",
            credential: "cred-ordinary",
            port: 18_101
        )
        let privateReg = try makeRegistration(
            id: "reg-private",
            profile: "private",
            credential: "cred-private",
            port: 18_201
        )
        let ordinaryFixture = try AccessProxyRegistrationFixture.httpOrdinary(port: 18_101)
        let privateFixture = try AccessProxyRegistrationFixture.httpsPrivate(port: 18_443)
        let host = try AccessSiteHost("example.test")

        try controller.install(registration: ordinaryReg, into: .ordinary)
        try controller.install(registration: privateReg, into: .privateBrowsing)
        try controller.install(proxyFixture: ordinaryFixture, into: .ordinary)
        try controller.install(proxyFixture: privateFixture, into: .privateBrowsing)
        try controller.setIntent(.allow, for: host, in: .ordinary)
        try controller.setIntent(.block, for: host, in: .privateBrowsing)

        XCTAssertEqual(try controller.registration(in: .ordinary).id.rawValue, "reg-ordinary")
        XCTAssertEqual(try controller.registration(in: .privateBrowsing).id.rawValue, "reg-private")
        XCTAssertEqual(try controller.proxyFixture(in: .ordinary).port, 18_101)
        XCTAssertEqual(try controller.proxyFixture(in: .privateBrowsing).port, 18_443)
        XCTAssertEqual(try controller.intent(for: host, in: .ordinary), .allow)
        XCTAssertEqual(try controller.intent(for: host, in: .privateBrowsing), .block)

        try controller.requireRegistration(ordinaryReg.id, belongsTo: .ordinary)
        try controller.requireRegistration(privateReg.id, belongsTo: .privateBrowsing)
        try controller.requireCredentialSlot(ordinaryReg.credentialSlot, belongsTo: .ordinary)
        try controller.requireCredentialSlot(privateReg.credentialSlot, belongsTo: .privateBrowsing)
        try controller.requireProxyFixture(ordinaryFixture, belongsTo: .ordinary)
        try controller.requireProxyFixture(privateFixture, belongsTo: .privateBrowsing)
    }

    func testRejectsCrossBucketRegistrationAndCredentialReuse() throws {
        let controller = AccessBrowsingIsolationController()
        let ordinaryReg = try makeRegistration(
            id: "reg-ordinary-x",
            profile: "ordinary",
            credential: "cred-ordinary-x",
            port: 18_111
        )
        try controller.install(registration: ordinaryReg, into: .ordinary)

        XCTAssertThrowsError(
            try controller.install(registration: ordinaryReg, into: .privateBrowsing)
        ) { error in
            XCTAssertEqual(
                error as? AccessBrowsingIsolationError,
                .crossBucketReuseRejected(
                    resource: "registration:reg-ordinary-x",
                    owningBucket: .ordinary,
                    requestedBucket: .privateBrowsing
                )
            )
        }

        // Owner profile mismatch also fails closed without mutating private.
        let mismatched = try makeRegistration(
            id: "reg-mismatch",
            profile: "ordinary",
            credential: "cred-mismatch",
            port: 18_112
        )
        XCTAssertThrowsError(
            try controller.install(registration: mismatched, into: .privateBrowsing)
        ) { error in
            XCTAssertEqual(
                error as? AccessBrowsingIsolationError,
                .browsingBucketMismatch(expected: .privateBrowsing, actual: .ordinary)
            )
        }

        XCTAssertThrowsError(
            try controller.requireRegistration(ordinaryReg.id, belongsTo: .privateBrowsing)
        ) { error in
            XCTAssertEqual(
                error as? AccessBrowsingIsolationError,
                .crossBucketReuseRejected(
                    resource: "registration:reg-ordinary-x",
                    owningBucket: .ordinary,
                    requestedBucket: .privateBrowsing
                )
            )
        }

        XCTAssertThrowsError(
            try controller.requireCredentialSlot(
                ordinaryReg.credentialSlot,
                belongsTo: .privateBrowsing
            )
        ) { error in
            XCTAssertEqual(
                error as? AccessBrowsingIsolationError,
                .crossBucketReuseRejected(
                    resource: "credential:cred-ordinary-x",
                    owningBucket: .ordinary,
                    requestedBucket: .privateBrowsing
                )
            )
        }

        let ordinaryFixture = try AccessProxyRegistrationFixture.httpOrdinary(port: 18_301)
        try controller.install(proxyFixture: ordinaryFixture, into: .ordinary)
        XCTAssertThrowsError(
            try controller.requireProxyFixture(ordinaryFixture, belongsTo: .privateBrowsing)
        ) { error in
            XCTAssertEqual(
                error as? AccessBrowsingIsolationError,
                .crossBucketReuseRejected(
                    resource: "proxyFixture:fixture-http-ordinary",
                    owningBucket: .ordinary,
                    requestedBucket: .privateBrowsing
                )
            )
        }

        // Private lane must still be empty after rejected cross installs.
        XCTAssertThrowsError(try controller.registration(in: .privateBrowsing)) { error in
            XCTAssertEqual(
                error as? AccessBrowsingIsolationError,
                .registrationNotInstalled(nil)
            )
        }
    }

    func testDestroyPrivateAccessStateLeavesOrdinaryIntact() throws {
        let controller = AccessBrowsingIsolationController()
        let ordinaryReg = try makeRegistration(
            id: "reg-keep",
            profile: "ordinary",
            credential: "cred-keep",
            port: 18_401
        )
        let privateReg = try makeRegistration(
            id: "reg-wipe",
            profile: "private",
            credential: "cred-wipe",
            port: 18_402
        )
        let ordinaryFixture = try AccessProxyRegistrationFixture.httpOrdinary(
            registrationId: "keep-http",
            port: 18_401
        )
        let privateFixture = try AccessProxyRegistrationFixture.httpsPrivate(
            registrationId: "wipe-https",
            port: 18_444
        )
        let host = try AccessSiteHost("wipe.test")

        try controller.install(registration: ordinaryReg, into: .ordinary)
        try controller.install(registration: privateReg, into: .privateBrowsing)
        try controller.install(proxyFixture: ordinaryFixture, into: .ordinary)
        try controller.install(proxyFixture: privateFixture, into: .privateBrowsing)
        try controller.setIntent(.allow, for: host, in: .ordinary)
        try controller.setIntent(.allow, for: host, in: .privateBrowsing)

        controller.endPrivateBrowsingSession()
        XCTAssertTrue(controller.isPrivateAccessDestroyed())

        XCTAssertThrowsError(try controller.snapshot(for: .privateBrowsing)) { error in
            XCTAssertEqual(
                error as? AccessBrowsingIsolationError,
                .privateAccessStateDestroyed
            )
        }
        XCTAssertThrowsError(
            try controller.requireRegistration(privateReg.id, belongsTo: .privateBrowsing)
        ) { error in
            XCTAssertEqual(
                error as? AccessBrowsingIsolationError,
                .privateAccessStateDestroyed
            )
        }
        XCTAssertThrowsError(
            try controller.install(
                registration: try makeRegistration(
                    id: "reg-after-destroy",
                    profile: "private",
                    credential: "cred-after-destroy",
                    port: 18_403
                ),
                into: .privateBrowsing
            )
        ) { error in
            XCTAssertEqual(
                error as? AccessBrowsingIsolationError,
                .privateAccessStateDestroyed
            )
        }

        // Destroyed private registration/credential ids must not migrate to ordinary.
        XCTAssertThrowsError(
            try controller.install(registration: privateReg, into: .ordinary)
        ) { error in
            XCTAssertEqual(
                error as? AccessBrowsingIsolationError,
                .crossBucketReuseRejected(
                    resource: "registration:reg-wipe",
                    owningBucket: .privateBrowsing,
                    requestedBucket: .ordinary
                )
            )
        }
        XCTAssertThrowsError(
            try controller.bind(credentialSlot: privateReg.credentialSlot, into: .ordinary)
        ) { error in
            XCTAssertEqual(
                error as? AccessBrowsingIsolationError,
                .crossBucketReuseRejected(
                    resource: "credential:cred-wipe",
                    owningBucket: .privateBrowsing,
                    requestedBucket: .ordinary
                )
            )
        }

        // Ordinary Access state remains usable.
        XCTAssertEqual(try controller.registration(in: .ordinary).id.rawValue, "reg-keep")
        XCTAssertEqual(try controller.proxyFixture(in: .ordinary).registrationId, "keep-http")
        XCTAssertEqual(try controller.intent(for: host, in: .ordinary), .allow)
        try controller.requireRegistration(ordinaryReg.id, belongsTo: .ordinary)
        try controller.requireCredentialSlot(ordinaryReg.credentialSlot, belongsTo: .ordinary)
    }

    func testBeginPrivateSessionAfterDestroyStartsFreshLane() throws {
        let controller = AccessBrowsingIsolationController()
        let firstPrivate = try makeRegistration(
            id: "reg-private-1",
            profile: "private",
            credential: "cred-private-1",
            port: 18_501
        )
        try controller.install(registration: firstPrivate, into: .privateBrowsing)
        try controller.setIntent(.allow, for: try AccessSiteHost("fresh.test"), in: .privateBrowsing)

        controller.endPrivateBrowsingSession()
        XCTAssertTrue(controller.isPrivateAccessDestroyed())

        controller.beginPrivateBrowsingSession()
        XCTAssertFalse(controller.isPrivateAccessDestroyed())
        XCTAssertThrowsError(try controller.registration(in: .privateBrowsing))
        XCTAssertEqual(
            try controller.intent(for: try AccessSiteHost("fresh.test"), in: .privateBrowsing),
            .off
        )

        let secondPrivate = try makeRegistration(
            id: "reg-private-2",
            profile: "private",
            credential: "cred-private-2",
            port: 18_502
        )
        try controller.install(registration: secondPrivate, into: .privateBrowsing)
        XCTAssertEqual(try controller.registration(in: .privateBrowsing).id.rawValue, "reg-private-2")

        // Prior private registration stays retired and cannot re-enter either lane.
        XCTAssertThrowsError(
            try controller.requireRegistration(firstPrivate.id, belongsTo: .privateBrowsing)
        )
        XCTAssertThrowsError(
            try controller.install(registration: firstPrivate, into: .ordinary)
        )
    }

    func testBucketBridgesOwnerProfileAndDataStoreKind() throws {
        XCTAssertEqual(AccessBrowsingBucket.ordinary.ownerProfile, "ordinary")
        XCTAssertEqual(AccessBrowsingBucket.privateBrowsing.ownerProfile, "private")
        XCTAssertEqual(AccessBrowsingBucket.ordinary.dataStoreKind, .ordinary)
        XCTAssertEqual(AccessBrowsingBucket.privateBrowsing.dataStoreKind, .privateBrowsing)
        XCTAssertEqual(try AccessBrowsingBucket.from(ownerProfile: "private"), .privateBrowsing)
        XCTAssertEqual(
            AccessBrowsingBucket.from(dataStoreKind: .privateBrowsing),
            .privateBrowsing
        )
        XCTAssertThrowsError(try AccessBrowsingBucket.from(ownerProfile: "guest")) { error in
            XCTAssertEqual(
                error as? AccessBrowsingIsolationError,
                .unknownOwnerProfile("guest")
            )
        }
    }

    func testCredentialSlotReuseIsRejectedWithoutReplacingOwner() throws {
        let controller = AccessBrowsingIsolationController()
        let ordinaryReg = try makeRegistration(
            id: "reg-slot-owner",
            profile: "ordinary",
            credential: "cred-shared-slot",
            port: 18_601
        )
        try controller.install(registration: ordinaryReg, into: .ordinary)

        let stolen = try makeRegistration(
            id: "reg-slot-thief",
            profile: "private",
            credential: "cred-shared-slot",
            port: 18_602
        )
        XCTAssertThrowsError(
            try controller.install(registration: stolen, into: .privateBrowsing)
        ) { error in
            XCTAssertEqual(
                error as? AccessBrowsingIsolationError,
                .crossBucketReuseRejected(
                    resource: "credential:cred-shared-slot",
                    owningBucket: .ordinary,
                    requestedBucket: .privateBrowsing
                )
            )
        }

        XCTAssertEqual(try controller.registration(in: .ordinary).id.rawValue, "reg-slot-owner")
        XCTAssertThrowsError(try controller.registration(in: .privateBrowsing))
        try controller.requireCredentialSlot(ordinaryReg.credentialSlot, belongsTo: .ordinary)
        XCTAssertThrowsError(
            try controller.requireCredentialSlot(stolen.credentialSlot, belongsTo: .privateBrowsing)
        )
    }
}
