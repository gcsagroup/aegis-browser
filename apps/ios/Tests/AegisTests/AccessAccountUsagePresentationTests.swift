import XCTest
@testable import Aegis

final class AccessAccountUsagePresentationTests: XCTestCase {
    private typealias Presentation = AccessAccountUsagePresentation

    func testByteFormattingPreservesIntegerPrecisionAndAcceptsUInt64Maximum() {
        let cases: [(String, String)] = [
            ("0", "0 B"), ("1", "1 B"), ("1023", "1023 B"),
            ("1024", "1.00 KiB"), ("1260", "1.23 KiB"), ("1048575", "1023.99 KiB"),
            ("1048576", "1.00 MiB"), ("1073741824", "1.00 GiB"),
            ("1099511627776", "1.00 TiB"), ("1125899906842624", "1.00 PiB"),
            ("9007199254740993", "8.00 PiB"),
            ("1152921504606846976", "1.00 EiB"),
            ("18446744073709551615", "15.99 EiB")
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(Presentation.formattedBytes(raw), expected, raw)
        }
        // This is below a hundredth-PiB boundary; Float conversion must not round it across.
        XCTAssertEqual(Presentation.formattedBytes("9018458253809418"), "8.00 PiB")
    }

    func testUnknownAndNoncanonicalBytesAreNotDisplayedAsZero() {
        for raw: String? in [nil, "", "00", "01", "+1", "-1", " 1", "1 ", "1.0", "1e3",
                            "18446744073709551616"] {
            XCTAssertEqual(Presentation.formattedBytes(raw), "—")
        }
    }

    func testFreshnessAgesAtExactThresholdsAndNeverUsesWallClock() {
        XCTAssertEqual(fresh(age: 0, elapsed: 5), .current)
        XCTAssertEqual(fresh(age: 0, elapsed: 5.001), .delayed)
        XCTAssertEqual(fresh(age: 0, elapsed: 15), .delayed)
        XCTAssertEqual(fresh(age: 0, elapsed: 15.001), .unavailable)
        XCTAssertEqual(fresh(age: 5_000), .current)
        XCTAssertEqual(fresh(age: 5_001), .delayed)
        XCTAssertEqual(fresh(age: 15_000), .delayed)
        XCTAssertEqual(fresh(age: 15_001), .unavailable)
        XCTAssertEqual(fresh(age: 4_000, elapsed: 1), .current)
        XCTAssertEqual(fresh(age: 4_000, elapsed: 1.001), .delayed)
        XCTAssertEqual(fresh(age: 5_000, elapsed: 0.0001), .delayed)
    }

    func testUnknownStaleInvalidAndRegressingClocksAreUnavailable() {
        let known = snapshot(age: 0)
        XCTAssertEqual(Presentation.freshness(snapshot: known, receivedUptime: nil, nowUptime: 1, stale: false), .unavailable)
        XCTAssertEqual(Presentation.freshness(snapshot: known, receivedUptime: 1, nowUptime: 1, stale: true), .unavailable)
        for (receipt, now): (TimeInterval, TimeInterval) in [
            (2, 1), (-1, 1), (.nan, 1), (.infinity, 1), (1, .nan), (1, .infinity), (1, -.infinity)
        ] {
            XCTAssertEqual(Presentation.freshness(snapshot: known, receivedUptime: receipt,
                                                   nowUptime: now, stale: false), .unavailable)
        }
        for unknown in [snapshot(age: nil), snapshot(age: 0, measuredAt: nil),
                        snapshot(age: -1), snapshot(age: 0, measuredAt: -1),
                        snapshot(age: 0, measuredAt: 11),
                        snapshot(age: 0, measuredAt: 9),
                        snapshot(age: 0, serverFreshness: .unavailable)] {
            XCTAssertEqual(Presentation.freshness(snapshot: unknown, receivedUptime: 1,
                                                   nowUptime: 1, stale: false), .unavailable)
        }
    }

    func testFreshnessSaturatesHugeElapsedAndSummedAge() {
        XCTAssertEqual(fresh(age: Int64.max), .unavailable)
        XCTAssertEqual(fresh(age: 0, elapsed: Double.greatestFiniteMagnitude), .unavailable)
        XCTAssertEqual(fresh(age: Int64.max, elapsed: Double(UInt64.max) / 1_000), .unavailable)
        XCTAssertEqual(fresh(age: Int64.max, elapsed: 10_000_000_000_000_000), .unavailable)
    }

    func testBusinessStatusIsNotReinterpretedByPresentation() {
        // Fixture expiry precedes the receipt; these helpers intentionally do not infer expiry.
        let value = snapshot(age: 0)
        XCTAssertEqual(value.status, .active)
        XCTAssertEqual(Presentation.freshness(snapshot: value, receivedUptime: 1,
                                               nowUptime: 1, stale: false), .current)
        XCTAssertEqual(value.status, .active)
        XCTAssertEqual(value.quotaBytes, "9007199254740993")
    }

    private func fresh(age: Int64, elapsed: TimeInterval = 0) -> Presentation.Freshness {
        Presentation.freshness(snapshot: snapshot(age: age), receivedUptime: 0,
                               nowUptime: elapsed, stale: false)
    }

    private func snapshot(age: Int64?, measuredAt: Int64? = 10,
                          serverFreshness: AccessAccountEntitlement.Freshness? = nil) -> AccessAccountEntitlement {
        let derived: AccessAccountEntitlement.Freshness = (age ?? Int64.max) > 15_000 ? .unavailable
            : (age ?? 0) > 5_000 ? .delayed : .current
        return AccessAccountEntitlement(entitlementAccountId: "A", status: .active,
            planId: "p", periodId: "period", periodStart: 0, periodEnd: 20, expiresAt: 5,
            quotaBytes: "9007199254740993", uploadedBytes: "0", downloadedBytes: "0",
            usedBytes: "0", remainingBytes: "9007199254740993", measuredAt: measuredAt,
            receivedAt: 10, snapshotAgeMs: age, freshness: serverFreshness ?? derived)
    }
}
