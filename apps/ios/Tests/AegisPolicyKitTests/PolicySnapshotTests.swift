import XCTest
@testable import AegisPolicyKit

final class PolicySnapshotTests: XCTestCase {
    func testDecodesCurrentSnapshotVersion() throws {
        let snapshot = try PolicySnapshotLoader.decode(validSnapshot)

        XCTAssertEqual(snapshot.version, 1)
        XCTAssertEqual(snapshot.source, "@gcsa-aegis/core")
        XCTAssertEqual(snapshot.trackingQueryParams, ["utm_source"])
        XCTAssertEqual(snapshot.phishBrandKeywords, ["paypal"])
    }

    func testRejectsUnknownVersion() {
        let json = validSnapshot.replacingOccurrences(of: #""version": 1"#, with: #""version": 2"#)

        XCTAssertThrowsError(try PolicySnapshotLoader.decode(json)) { error in
            XCTAssertEqual(error as? PolicySnapshotError, .unsupportedVersion(2))
        }
    }

    func testRejectsUnknownFieldInsteadOfSilentlyIgnoringIt() {
        let json = validSnapshot.replacingOccurrences(
            of: #""phishBrandKeywords": ["paypal"]"#,
            with: #""phishBrandKeywords": ["paypal"], "futureField": true"#
        )

        XCTAssertThrowsError(try PolicySnapshotLoader.decode(json)) { error in
            XCTAssertEqual(error as? PolicySnapshotError, .unexpectedFields(["futureField"]))
        }
    }

    func testRejectsWrongSource() {
        let json = validSnapshot.replacingOccurrences(
            of: "@gcsa-aegis/core",
            with: "untrusted/source"
        )

        XCTAssertThrowsError(try PolicySnapshotLoader.decode(json)) { error in
            XCTAssertEqual(error as? PolicySnapshotError, .invalidSource("untrusted/source"))
        }
    }

    private let validSnapshot = #"""
    {
      "version": 1,
      "generatedAt": "1970-01-01T00:00:00.000Z",
      "source": "@gcsa-aegis/core",
      "trackerHosts": ["doubleclick.net"],
      "trackingQueryParams": ["utm_source"],
      "firstPartyCollectPaths": ["/g/collect"],
      "phishHosts": ["aegis-phish-demo.test"],
      "suspiciousTlds": ["tk"],
      "phishBrandKeywords": ["paypal"]
    }
    """#
}
