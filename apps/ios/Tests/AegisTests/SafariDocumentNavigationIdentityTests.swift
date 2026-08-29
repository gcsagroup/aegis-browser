import XCTest
@testable import Aegis

final class SafariDocumentNavigationIdentityTests: XCTestCase {
    private let extensionID = "com.gcsa.aegis.ios.app.safari"
    private let profileID = "00000000-0000-4000-8000-000000000001"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSameDocumentAndNavigationIdentityConsumesWithinLease() throws {
        let gate = makeGate()
        let authorization = try authorize(gate: gate)

        XCTAssertEqual(authorization.expiresAt.timeIntervalSince(now), 15, accuracy: 0.001)
        XCTAssertNoThrow(
            try gate.consume(
                request: SafariReadOnlyRequest(message: consumeMessage(authorization)),
                profileID: profileID,
                now: now.addingTimeInterval(1)
            )
        )
    }

    func testNewDocumentTokenFailsClosedAndBurnsLease() throws {
        let gate = makeGate()
        let authorization = try authorize(gate: gate)
        let replacementToken = UUID()
        let replacedDocument = consumeMessage(
            authorization,
            documentToken: replacementToken,
            navigationEpoch: 1
        )

        assertRejectedAndBurned(
            gate: gate,
            authorization: authorization,
            rejectedMessage: replacedDocument
        )
    }

    func testNewNavigationEpochFailsClosedAndBurnsLease() throws {
        let gate = makeGate()
        let authorization = try authorize(gate: gate, navigationEpoch: 7)
        let navigated = consumeMessage(
            authorization,
            documentToken: authorization.documentToken,
            navigationEpoch: authorization.navigationEpoch + 1
        )

        assertRejectedAndBurned(
            gate: gate,
            authorization: authorization,
            rejectedMessage: navigated
        )
    }

    func testSnapshotIdentityMismatchFailsClosedAndBurnsLease() throws {
        let gate = makeGate()
        let authorization = try authorize(gate: gate)
        var mismatchedSnapshot = consumeMessage(authorization)
        var snapshot = mismatchedSnapshot["snapshot"] as! [String: Any]
        snapshot["documentToken"] = UUID().uuidString
        snapshot["navigationEpoch"] = authorization.navigationEpoch + 1
        mismatchedSnapshot["snapshot"] = snapshot

        assertRejectedAndBurned(
            gate: gate,
            authorization: authorization,
            rejectedMessage: mismatchedSnapshot
        )
    }

    func testIdentityFieldsAreRequiredAndWhitelisted() throws {
        var missingToken = authorizeMessage()
        missingToken.removeValue(forKey: "documentToken")
        assertInvalidMessage(missingToken)

        var invalidEpoch = authorizeMessage()
        invalidEpoch["navigationEpoch"] = 0
        assertInvalidMessage(invalidEpoch)

        var unknownField = authorizeMessage()
        unknownField["navigationURL"] = "https://example.com/private"
        assertInvalidMessage(unknownField)

        let gate = makeGate()
        let authorization = try authorize(gate: gate)
        var missingSnapshotToken = consumeMessage(authorization)
        var snapshot = missingSnapshotToken["snapshot"] as! [String: Any]
        snapshot.removeValue(forKey: "documentToken")
        missingSnapshotToken["snapshot"] = snapshot
        assertInvalidMessage(missingSnapshotToken)
    }

    private func assertRejectedAndBurned(
        gate: SafariReadOnlyGate,
        authorization: SafariReadOnlyAuthorization,
        rejectedMessage: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try gate.consume(
                request: SafariReadOnlyRequest(message: rejectedMessage),
                profileID: profileID,
                now: now.addingTimeInterval(1)
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? SafariReadOnlyGateError,
                .invalidLease,
                file: file,
                line: line
            )
        }

        XCTAssertThrowsError(
            try gate.consume(
                request: SafariReadOnlyRequest(message: consumeMessage(authorization)),
                profileID: profileID,
                now: now.addingTimeInterval(2)
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? SafariReadOnlyGateError,
                .invalidLease,
                file: file,
                line: line
            )
        }
    }

    private func assertInvalidMessage(
        _ message: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try SafariReadOnlyRequest(message: message),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? SafariReadOnlyGateError,
                .invalidMessage,
                file: file,
                line: line
            )
        }
    }

    private func makeGate() -> SafariReadOnlyGate {
        SafariReadOnlyGate(expectedExtensionID: extensionID)
    }

    private func authorize(
        gate: SafariReadOnlyGate,
        documentToken: UUID = UUID(),
        navigationEpoch: Int = 1
    ) throws -> SafariReadOnlyAuthorization {
        try gate.authorize(
            request: SafariReadOnlyRequest(
                message: authorizeMessage(
                    documentToken: documentToken,
                    navigationEpoch: navigationEpoch
                )
            ),
            profileID: profileID,
            now: now
        )
    }

    private func authorizeMessage(
        documentToken: UUID = UUID(),
        navigationEpoch: Int = 1,
        extensionInstanceID: UUID = UUID(),
        gestureNonce: UUID = UUID()
    ) -> [String: Any] {
        [
            "schemaVersion": 1,
            "phase": "authorize",
            "route": "page.observe",
            "extensionID": extensionID,
            "extensionInstanceID": extensionInstanceID.uuidString,
            "gestureNonce": gestureNonce.uuidString,
            "documentToken": documentToken.uuidString,
            "navigationEpoch": navigationEpoch,
            "isPrivate": false,
            "tabID": 7,
            "frameID": 0,
            "origin": "https://example.com",
        ]
    }

    private func consumeMessage(
        _ authorization: SafariReadOnlyAuthorization,
        documentToken: UUID? = nil,
        navigationEpoch: Int? = nil
    ) -> [String: Any] {
        let documentToken = documentToken ?? authorization.documentToken
        let navigationEpoch = navigationEpoch ?? authorization.navigationEpoch
        return [
            "schemaVersion": 1,
            "phase": "consume",
            "route": authorization.route,
            "extensionID": extensionID,
            "extensionInstanceID": authorization.extensionInstanceID.uuidString,
            "gestureNonce": authorization.gestureNonce.uuidString,
            "documentToken": documentToken.uuidString,
            "navigationEpoch": navigationEpoch,
            "isPrivate": false,
            "tabID": authorization.tabID,
            "frameID": authorization.frameID,
            "origin": authorization.origin,
            "leaseID": authorization.leaseID.uuidString,
            "snapshot": [
                "schemaVersion": 1,
                "route": "\(authorization.route).result",
                "origin": authorization.origin,
                "documentToken": documentToken.uuidString,
                "navigationEpoch": navigationEpoch,
                "title": "Example",
                "language": "zh-CN",
                "headings": ["标题"],
            ],
        ]
    }
}
