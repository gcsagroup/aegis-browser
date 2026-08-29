import XCTest
@testable import AegisPolicyKit

final class PIIScannerTests: XCTestCase {
    func testDetectsAndRedactsEmailAndPhone() {
        let result = PIIScanner.scan("Contact me at alice@example.com or 13812345678")

        XCTAssertEqual(result.matches.map(\.kind), [.email, .phone])
        XCTAssertEqual(result.redacted, "Contact me at a***@example.com or 138****78")
        XCTAssertTrue(result.blocked)
    }

    func testOffsetsUseUTF16CodeUnitsLikeJavaScript() {
        let result = PIIScanner.scan("😀 Contact alice@example.com")

        XCTAssertEqual(result.matches.first?.start, 11)
        XCTAssertEqual(result.matches.first?.end, 28)
        XCTAssertEqual(result.redacted, "😀 Contact a***@example.com")
    }

    func testRedactsSecretsWithoutReturningRawPayload() {
        let input = "Authorization: Bearer abcdefghijklmnop and token=tok_live_ABC123456789"
        let result = PIIScanner.scan(input)

        XCTAssertEqual(result.matches.map(\.kind), [.secret, .secret])
        XCTAssertEqual(result.redacted, "[REDACTED_SECRET] and [REDACTED_SECRET]")
        XCTAssertFalse(result.redacted.contains("abcdefghijklmnop"))
    }

    func testCreditCardRequiresLuhn() {
        XCTAssertEqual(
            PIIScanner.scan("4111 1111 1111 1111").redacted,
            "4111 **** **** 1111"
        )
        XCTAssertFalse(PIIScanner.scan("4111 1111 1111 1112").blocked)
    }

    func testOutboundGateAlwaysUsesRedactedPayloadForPII() {
        let blocked = PIIScanner.gateOutboundText("SSN 123-45-6789", userApproved: false)
        let approved = PIIScanner.gateOutboundText("SSN 123-45-6789", userApproved: true)

        XCTAssertFalse(blocked.allowed)
        XCTAssertTrue(approved.allowed)
        XCTAssertEqual(blocked.payload, "SSN ***-**-****")
        XCTAssertEqual(approved.payload, blocked.payload)
    }
}
