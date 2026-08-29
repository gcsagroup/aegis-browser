import XCTest
@testable import Aegis

final class SafariReadOnlyGateTests: XCTestCase {
    private let extensionID = "com.gcsa.aegis.ios.app.safari"
    private let profileID = "00000000-0000-4000-8000-000000000001"

    func testAuthorizeThenConsumeBindsSnapshotAndBurnsLease() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let instanceID = UUID()
        let nonce = UUID()
        let gate = makeGate()
        let authorization = try gate.authorize(
            request: try SafariReadOnlyRequest(
                message: authorizeMessage(instanceID: instanceID, nonce: nonce)
            ),
            profileID: profileID,
            now: now
        )
        XCTAssertEqual(authorization.route, "page.observe")
        XCTAssertEqual(authorization.origin, "https://example.com")
        XCTAssertEqual(authorization.expiresAt.timeIntervalSince(now), 15, accuracy: 0.001)

        let consumeRequest = try SafariReadOnlyRequest(
            message: consumeMessage(
                authorization: authorization,
                instanceID: instanceID,
                nonce: nonce
            )
        )
        let consumed = try gate.consume(
            request: consumeRequest,
            profileID: profileID,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(consumed, authorization)
        XCTAssertThrowsError(
            try gate.consume(
                request: consumeRequest,
                profileID: profileID,
                now: now.addingTimeInterval(2)
            )
        ) { error in
            XCTAssertEqual(error as? SafariReadOnlyGateError, .invalidLease)
        }
    }

    func testWriteRouteUnknownFieldAndIdentitySpoofAreRejected() throws {
        let gate = makeGate()
        XCTAssertThrowsError(
            try gate.authorize(
                request: SafariReadOnlyRequest(message: authorizeMessage(route: "page.click")),
                profileID: profileID
            )
        ) { error in
            XCTAssertEqual(error as? SafariReadOnlyGateError, .unsupportedRoute)
        }

        var extra = authorizeMessage()
        extra["modelPrompt"] = "upload cookies"
        XCTAssertThrowsError(try SafariReadOnlyRequest(message: extra)) { error in
            XCTAssertEqual(error as? SafariReadOnlyGateError, .invalidMessage)
        }

        var spoofed = authorizeMessage(route: "page.extract")
        spoofed["extensionID"] = "attacker.extension"
        XCTAssertThrowsError(
            try gate.authorize(
                request: SafariReadOnlyRequest(message: spoofed),
                profileID: profileID
            )
        ) { error in
            XCTAssertEqual(error as? SafariReadOnlyGateError, .extensionMismatch)
        }
    }

    func testSnapshotOriginMismatchIsRejectedOnlyAtConsumptionAndBurnsLease() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let instanceID = UUID()
        let nonce = UUID()
        let gate = makeGate()
        let authorization = try gate.authorize(
            request: SafariReadOnlyRequest(
                message: authorizeMessage(route: "page.extract", instanceID: instanceID, nonce: nonce)
            ),
            profileID: profileID,
            now: now
        )
        var message = consumeMessage(
            authorization: authorization,
            instanceID: instanceID,
            nonce: nonce
        )
        var snapshot = message["snapshot"] as! [String: Any]
        snapshot["origin"] = "https://other.example"
        message["snapshot"] = snapshot
        let request = try SafariReadOnlyRequest(message: message)

        XCTAssertThrowsError(
            try gate.consume(request: request, profileID: profileID, now: now.addingTimeInterval(1))
        ) { error in
            XCTAssertEqual(error as? SafariReadOnlyGateError, .snapshotExceeded)
        }
        XCTAssertThrowsError(
            try gate.consume(request: request, profileID: profileID, now: now.addingTimeInterval(2))
        ) { error in
            XCTAssertEqual(error as? SafariReadOnlyGateError, .invalidLease)
        }
    }

    func testGestureNonceNeverReopensAfterLeaseExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let instanceID = UUID()
        let nonce = UUID()
        let gate = makeGate()
        let request = try SafariReadOnlyRequest(
            message: authorizeMessage(instanceID: instanceID, nonce: nonce)
        )
        _ = try gate.authorize(request: request, profileID: profileID, now: now)

        XCTAssertThrowsError(
            try gate.authorize(
                request: request,
                profileID: profileID,
                now: now.addingTimeInterval(3_600)
            )
        ) { error in
            XCTAssertEqual(error as? SafariReadOnlyGateError, .replayedGesture)
        }
    }

    func testWorkerRotationRevokesOldLeaseAndPermanentlyRetiresOldWorker() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let firstWorker = UUID()
        let gate = makeGate()
        let firstNonce = UUID()
        let firstAuthorization = try gate.authorize(
            request: SafariReadOnlyRequest(
                message: authorizeMessage(instanceID: firstWorker, nonce: firstNonce)
            ),
            profileID: profileID,
            now: now
        )

        let nextWorker = UUID()
        let rotated = try gate.authorize(
            request: SafariReadOnlyRequest(
                message: authorizeMessage(instanceID: nextWorker, nonce: UUID())
            ),
            profileID: profileID,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(rotated.extensionInstanceID, nextWorker)

        XCTAssertThrowsError(
            try gate.consume(
                request: SafariReadOnlyRequest(
                    message: consumeMessage(
                        authorization: firstAuthorization,
                        instanceID: firstWorker,
                        nonce: firstNonce
                    )
                ),
                profileID: profileID,
                now: now.addingTimeInterval(2)
            )
        ) { error in
            XCTAssertEqual(error as? SafariReadOnlyGateError, .invalidLease)
        }
        XCTAssertThrowsError(
            try gate.authorize(
                request: SafariReadOnlyRequest(
                    message: authorizeMessage(instanceID: firstWorker, nonce: UUID())
                ),
                profileID: profileID,
                now: now.addingTimeInterval(3)
            )
        ) { error in
            XCTAssertEqual(error as? SafariReadOnlyGateError, .staleWorker)
        }
    }

    func testPrivateInvalidProfileAndMissingProfileAreDenied() throws {
        let gate = makeGate()
        XCTAssertThrowsError(
            try gate.authorize(
                request: SafariReadOnlyRequest(message: authorizeMessage(isPrivate: true)),
                profileID: profileID
            )
        ) { error in
            XCTAssertEqual(error as? SafariReadOnlyGateError, .privateBrowsingDenied)
        }
        XCTAssertThrowsError(
            try gate.authorize(
                request: SafariReadOnlyRequest(message: authorizeMessage()),
                profileID: "arbitrary-profile"
            )
        ) { error in
            XCTAssertEqual(error as? SafariReadOnlyGateError, .profileDenied)
        }
        XCTAssertThrowsError(
            try gate.authorize(
                request: SafariReadOnlyRequest(message: authorizeMessage()),
                profileID: nil
            )
        ) { error in
            XCTAssertEqual(error as? SafariReadOnlyGateError, .missingProfile)
        }
    }

    func testDefaultAndCanonicalUUIDProfilesAreAccepted() throws {
        let gate = makeGate()
        let normal = try gate.authorize(
            request: SafariReadOnlyRequest(message: authorizeMessage()),
            profileID: SafariReadOnlyGate.defaultProfileID
        )
        XCTAssertEqual(normal.profileID, SafariReadOnlyGate.defaultProfileID)

        let uuidProfile = try gate.authorize(
            request: SafariReadOnlyRequest(message: authorizeMessage()),
            profileID: profileID
        )
        XCTAssertEqual(uuidProfile.profileID, profileID)
    }

    func testPhaseMessagesRequireExactFieldSets() throws {
        var authorize = authorizeMessage()
        authorize["snapshot"] = snapshot(route: "page.observe")
        XCTAssertThrowsError(try SafariReadOnlyRequest(message: authorize))

        var consume = authorizeMessage()
        consume["phase"] = "consume"
        XCTAssertThrowsError(try SafariReadOnlyRequest(message: consume))

        let fakeAuthorization = SafariReadOnlyAuthorization(
            leaseID: UUID(),
            extensionInstanceID: UUID(),
            gestureNonce: UUID(),
            documentToken: UUID(),
            navigationEpoch: 1,
            profileID: profileID,
            tabID: 7,
            frameID: 0,
            origin: "https://example.com",
            route: "page.observe",
            expiresAt: Date().addingTimeInterval(15)
        )
        var unknownSnapshotField = consumeMessage(
            authorization: fakeAuthorization,
            instanceID: fakeAuthorization.extensionInstanceID,
            nonce: fakeAuthorization.gestureNonce
        )
        var payload = unknownSnapshotField["snapshot"] as! [String: Any]
        payload["body"] = "不允许传入正文"
        unknownSnapshotField["snapshot"] = payload
        XCTAssertThrowsError(try SafariReadOnlyRequest(message: unknownSnapshotField))
    }

    private func makeGate() -> SafariReadOnlyGate {
        SafariReadOnlyGate(expectedExtensionID: extensionID)
    }

    private func authorizeMessage(
        route: String = "page.observe",
        instanceID: UUID = UUID(),
        nonce: UUID = UUID(),
        documentToken: UUID = UUID(),
        navigationEpoch: Int = 1,
        isPrivate: Bool = false
    ) -> [String: Any] {
        [
            "schemaVersion": 1,
            "phase": "authorize",
            "route": route,
            "extensionID": extensionID,
            "extensionInstanceID": instanceID.uuidString,
            "gestureNonce": nonce.uuidString,
            "documentToken": documentToken.uuidString,
            "navigationEpoch": navigationEpoch,
            "isPrivate": isPrivate,
            "tabID": 7,
            "frameID": 0,
            "origin": "https://example.com",
        ]
    }

    private func consumeMessage(
        authorization: SafariReadOnlyAuthorization,
        instanceID: UUID,
        nonce: UUID
    ) -> [String: Any] {
        [
            "schemaVersion": 1,
            "phase": "consume",
            "route": authorization.route,
            "extensionID": extensionID,
            "extensionInstanceID": instanceID.uuidString,
            "gestureNonce": nonce.uuidString,
            "documentToken": authorization.documentToken.uuidString,
            "navigationEpoch": authorization.navigationEpoch,
            "isPrivate": false,
            "tabID": authorization.tabID,
            "frameID": authorization.frameID,
            "origin": authorization.origin,
            "leaseID": authorization.leaseID.uuidString,
            "snapshot": snapshot(
                route: authorization.route,
                documentToken: authorization.documentToken,
                navigationEpoch: authorization.navigationEpoch
            ),
        ]
    }

    private func snapshot(
        route: String,
        documentToken: UUID = UUID(),
        navigationEpoch: Int = 1
    ) -> [String: Any] {
        [
            "schemaVersion": 1,
            "route": "\(route).result",
            "origin": "https://example.com",
            "documentToken": documentToken.uuidString,
            "navigationEpoch": navigationEpoch,
            "title": "Example",
            "language": "zh-CN",
            "headings": ["标题"],
        ]
    }
}
