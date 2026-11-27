import CryptoKit
import Foundation
import XCTest
@testable import Aegis

final class AccessGeoSiteRemotePolicyTests: XCTestCase {
    func testSignedRestrictionsSurviveExpiryAndRejectConflictingVersions() throws {
        let key = Curve25519.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 1_795_656_000)
        func policy(version: Int, paused: Bool) throws -> AccessGeoSiteRemotePolicy {
            let payload = try JSONSerialization.data(withJSONObject: [
                "schema": 1, "version": version, "issuedAt": now.timeIntervalSince1970,
                "expiresAt": now.timeIntervalSince1970 + 3600, "defaultRefreshDays": 7,
                "overseasPaused": paused, "blockedTags": []
            ], options: .sortedKeys)
            let envelope = try JSONSerialization.data(withJSONObject: [
                "payload": payload.base64EncodedString(),
                "signature": key.signature(for: payload).base64EncodedString()
            ])
            return try AccessGeoSiteRemotePolicy.verify(envelope, key: key.publicKey, now: now)
        }
        let pause = try policy(version: 2, paused: true)
        let expired = now.addingTimeInterval(3600)
        XCTAssertTrue(pause.rules.overseasPaused)
        XCTAssertEqual(pause.schedule(at: expired).days, 3)
        XCTAssertThrowsError(try policy(version: 1, paused: false).validateSuccessor(of: pause))
        XCTAssertThrowsError(try policy(version: 2, paused: false).validateSuccessor(of: pause))
        XCTAssertNoThrow(try pause.validateSuccessor(of: pause))
        XCTAssertNoThrow(try policy(version: 3, paused: false).validateSuccessor(of: pause))
    }

    func testScheduleUsesExpiryAndCapsRetryWhileRulesAreStillValid() {
        let now = Date(timeIntervalSince1970: 10_000)
        let sevenDays = AccessGeoSiteRefreshPolicy(days: 7)
        XCTAssertEqual(sevenDays.nextCheck(after: now, expires: now.addingTimeInterval(5 * 86_400)),
                       now.addingTimeInterval(4 * 86_400))
        XCTAssertEqual(sevenDays.nextCheck(after: now, expires: now.addingTimeInterval(2 * 3600)),
                       now.addingTimeInterval(3600))
        XCTAssertEqual(AccessGeoSiteRefreshPolicy().nextCheck(after: now, expires: nil),
                       now.addingTimeInterval(3 * 86_400))
    }

    func testLastCheckIsScheduledBeforeAnExpiryLessThanOneMinuteAway() {
        let checkedAt = Date(timeIntervalSince1970: 10_000)
        let expiry = checkedAt.addingTimeInterval(30)
        let next = AccessGeoSiteRefreshPolicy(days: 7).nextCheck(after: checkedAt, expires: expiry)
        XCTAssertGreaterThan(next, checkedAt)
        XCTAssertLessThan(next, expiry)
    }
}
