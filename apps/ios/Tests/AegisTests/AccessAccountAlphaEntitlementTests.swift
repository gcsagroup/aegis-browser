import XCTest
@testable import Aegis

final class AccessAccountAlphaEntitlementTests: XCTestCase {
    private var legacy: [String: Any] {
        ["entitlementAccountId": "A", "status": "active", "planId": "p", "periodId": "one",
         "periodStart": 10, "periodEnd": 100, "expiresAt": 90,
         "quotaBytes": "9007199254740993", "uploadedBytes": "2", "downloadedBytes": "3",
         "usedBytes": "5", "remainingBytes": "9007199254740988", "receivedAt": 15,
         "freshness": "unavailable"]
    }

    private var none: [String: Any] {
        legacy.merging(["quotaSource": "3xui_alpha", "panelExpiryMode": "none",
                        "panelExpiresAt": NSNull(), "expiresAt": 100]) { _, new in new }
    }

    private func validated(_ fields: [String: Any]) throws -> AccessAccountEntitlement {
        let data = try JSONSerialization.data(withJSONObject: fields)
        let result = try JSONDecoder().decode(AccessAccountEntitlement.self, from: data)
        try result.validate(for: "A")
        return result
    }

    func testLegacyWireAndLegacyConstructorRemainCompatible() throws {
        let result = try validated(legacy)
        XCTAssertNil(result.quotaSource)
        XCTAssertNil(result.panelExpiryMode)
        XCTAssertNil(result.panelExpiresAt)
        XCTAssertEqual(result.expiresAt, 90)
        let constructed = AccessAccountEntitlement(entitlementAccountId: "A", status: .active,
            planId: "p", periodId: "one", periodStart: 10, periodEnd: 100, expiresAt: 90,
            quotaBytes: "9007199254740993", uploadedBytes: "2", downloadedBytes: "3", usedBytes: "5",
            remainingBytes: "9007199254740988", measuredAt: nil, receivedAt: 15,
            snapshotAgeMs: nil, freshness: .unavailable)
        XCTAssertEqual(result, constructed)
        try constructed.validate(for: "A")
        XCTAssertEqual(try validated(["entitlementAccountId": "A", "status": "not_subscribed"]).status,
                       .notSubscribed)
    }

    func testPanelWithoutExpiryStillHasFinitePeriodAuthorization() throws {
        let result = try validated(none)
        XCTAssertEqual(result.quotaSource, .threeXUIAlpha)
        XCTAssertEqual(result.panelExpiryMode, AccessAccountEntitlement.PanelExpiryMode.none)
        XCTAssertNil(result.panelExpiresAt)
        XCTAssertEqual(result.expiresAt, result.periodEnd)
        XCTAssertEqual(result.expiresAt, 100)
        XCTAssertEqual(result.quotaBytes, "9007199254740993")
        XCTAssertNil(result.measuredAt)
        XCTAssertEqual(result.freshness, .unavailable)
        XCTAssertEqual(result.status, .active)
    }

    func testAbsolutePanelExpiryUsesEarlierPositiveBound() throws {
        for (panel, effective): (Int64, Int64) in [(1, 1), (90, 90), (100, 100), (101, 100), (.max, 100)] {
            let fields = none.merging(["panelExpiryMode": "absolute", "panelExpiresAt": panel,
                                       "expiresAt": effective]) { _, new in new }
            let result = try validated(fields)
            XCTAssertEqual(result.panelExpiryMode, .absolute)
            XCTAssertEqual(result.panelExpiresAt, panel)
            XCTAssertEqual(result.expiresAt, effective)
        }
    }

    func testNoneRejectsContradictoryAndNonpositiveExpiry() {
        for changes: [String: Any] in [
            ["panelExpiresAt": 1], ["panelExpiresAt": 0], ["panelExpiresAt": -1],
            ["expiresAt": 90], ["expiresAt": 0], ["expiresAt": -1],
            ["expiresAt": NSNull()], ["periodEnd": 0], ["panelExpiryMode": "permanent"],
            ["quotaSource": "other"], ["quotaSource": NSNull()], ["panelExpiryMode": NSNull()]
        ] {
            XCTAssertThrowsError(try validated(none.merging(changes) { _, new in new }), "\(changes)")
        }
    }

    func testAbsoluteRejectsMissingInvalidAndInconsistentPanelBound() {
        let absolute = none.merging(["panelExpiryMode": "absolute", "panelExpiresAt": 90,
                                     "expiresAt": 90]) { _, new in new }
        for changes: [String: Any] in [
            ["panelExpiresAt": NSNull()], ["panelExpiresAt": 0], ["panelExpiresAt": -1],
            ["panelExpiresAt": "90"], ["panelExpiresAt": 90.5],
            ["panelExpiresAt": UInt64.max], ["expiresAt": 100],
            ["panelExpiresAt": 101, "expiresAt": 101]
        ] {
            XCTAssertThrowsError(try validated(absolute.merging(changes) { _, new in new }), "\(changes)")
        }
    }

    func testPartialMetadataAndNullDisguiseAreRejected() {
        let keys = ["quotaSource", "panelExpiryMode", "panelExpiresAt"]
        for mask in 1..<7 {
            var partial = legacy
            for (index, key) in keys.enumerated() where mask & (1 << index) != 0 {
                partial[key] = none[key]
            }
            XCTAssertThrowsError(try validated(partial), "metadata mask \(mask)")
        }
        XCTAssertThrowsError(try validated(legacy.merging([
            "quotaSource": NSNull(), "panelExpiryMode": NSNull(), "panelExpiresAt": NSNull()
        ]) { _, new in new }))
    }

    func testNotSubscribedCannotCarryAnyAlphaMetadata() {
        let unsubscribed: [String: Any] = ["entitlementAccountId": "A", "status": "not_subscribed"]
        for key in ["quotaSource", "panelExpiryMode", "panelExpiresAt"] {
            XCTAssertThrowsError(try validated(unsubscribed.merging([key: NSNull()]) { _, new in new }))
        }
        XCTAssertThrowsError(try validated(unsubscribed.merging([
            "quotaSource": "3xui_alpha", "panelExpiryMode": "none", "panelExpiresAt": NSNull()
        ]) { _, new in new }))
        let constructed = AccessAccountEntitlement(entitlementAccountId: "A", status: .notSubscribed,
            planId: nil, periodId: nil, periodStart: nil, periodEnd: nil, expiresAt: nil,
            quotaBytes: nil, uploadedBytes: nil, downloadedBytes: nil, usedBytes: nil,
            remainingBytes: nil, measuredAt: nil, receivedAt: nil, snapshotAgeMs: nil,
            freshness: nil, quotaSource: .threeXUIAlpha)
        XCTAssertThrowsError(try constructed.validate(for: "A"))
    }

    func testNativeConstructionCannotBypassAlphaGroupValidation() {
        for (source, mode, panel): (AccessAccountEntitlement.QuotaSource?, AccessAccountEntitlement.PanelExpiryMode?, Int64?) in [
            (.threeXUIAlpha, nil, nil), (nil, .some(.none), nil), (nil, nil, 90),
            (.threeXUIAlpha, .absolute, nil), (.threeXUIAlpha, .some(.none), 100)
        ] {
            let result = AccessAccountEntitlement(entitlementAccountId: "A", status: .active,
                planId: "p", periodId: "one", periodStart: 10, periodEnd: 100, expiresAt: 100,
                quotaBytes: "10", uploadedBytes: "2", downloadedBytes: "3", usedBytes: "5",
                remainingBytes: "5", measuredAt: nil, receivedAt: 15, snapshotAgeMs: nil,
                freshness: .unavailable, quotaSource: source, panelExpiryMode: mode, panelExpiresAt: panel)
            XCTAssertThrowsError(try result.validate(for: "A"))
        }
    }
}
