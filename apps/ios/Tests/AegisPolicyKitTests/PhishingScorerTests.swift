import XCTest
@testable import AegisPolicyKit

final class PhishingScorerTests: XCTestCase {
    func testBlocksBrandAndSuspiciousTLDOnURLFeatures() {
        let result = PhishingScorer.scoreURL("http://paypal-secure-login.tk/signin")

        XCTAssertEqual(result.score, 70)
        XCTAssertEqual(result.severity, .high)
        XCTAssertTrue(result.shouldBlock)
        XCTAssertEqual(
            result.reasons.map(\.code),
            ["insecure_http", "suspicious_tld", "brand_spoof_host", "credential_path"]
        )
    }

    func testKeepsOrdinaryHTTPSURLLowRisk() {
        let result = PhishingScorer.scoreURL("https://example.com/docs")

        XCTAssertEqual(result.score, 0)
        XCTAssertEqual(result.severity, .low)
        XCTAssertFalse(result.shouldBlock)
        XCTAssertTrue(result.reasons.isEmpty)
    }

    func testDetectsDigitSubstitutionLookalike() {
        let result = PhishingScorer.scoreURL("https://micros0ft.com/")

        XCTAssertEqual(result.score, 40)
        XCTAssertEqual(result.reasons.first?.code, "brand_lookalike_host")
        XCTAssertEqual(result.reasons.first?.detail, "microsoft")
    }

    func testTreatsShortenerAsContextOnly() {
        let result = PhishingScorer.scoreURL("https://bit.ly/example")

        XCTAssertEqual(result.score, 15)
        XCTAssertFalse(result.shouldBlock)
        XCTAssertEqual(result.reasons.first?.code, "shortened_url")
    }

    func testInvalidPortableURLFailsClosed() {
        let result = PhishingScorer.scoreURL("not a valid URL")

        XCTAssertEqual(result.score, 100)
        XCTAssertEqual(result.severity, .critical)
        XCTAssertTrue(result.shouldBlock)
        XCTAssertEqual(result.reasons.first?.code, "invalid_url")
    }

    func testKeepsASCIIPunycodeHostForRiskDetection() {
        let result = PhishingScorer.scoreURL("http://xn--80ak6aa92e.tk/")

        XCTAssertEqual(result.score, 55)
        XCTAssertTrue(result.shouldBlock)
        XCTAssertTrue(result.reasons.contains { $0.code == "punycode_host" })
    }

    func testAllowlistCoversExactHostAndSubdomains() {
        let result = PhishingScorer.scoreURL(
            "http://login.safe.example/signin",
            allowlist: ["safe.example"]
        )

        XCTAssertEqual(result.score, 0)
        XCTAssertFalse(result.shouldBlock)
        XCTAssertEqual(result.reasons.first?.code, "allowlisted")
    }

    func testCrossSiteCredentialSubmissionBlocksCleanLookingPage() {
        let result = PhishingScorer.assess(
            PolicyPageSnapshot(
                url: "https://example.com/login",
                title: "Account login",
                textSample: "Enter your password",
                forms: 1,
                passwordFields: 1,
                crossSiteFormActions: 1
            )
        )

        XCTAssertEqual(result.score, 55)
        XCTAssertTrue(result.shouldBlock)
        XCTAssertEqual(
            result.reasons.map(\.code),
            ["credential_path", "cross_site_credential_submit"]
        )
    }

    func testLocalSafeFeedbackDampensScore() {
        let original = PhishingScorer.assess(
            PolicyPageSnapshot(
                url: "http://evil.tk/login",
                title: "Login",
                textSample: "verify your account",
                passwordFields: 1
            )
        )
        let adjusted = PhishingScorer.applyLocalFeedback(
            original,
            feedbackHosts: ["evil.tk": .safe]
        )

        XCTAssertLessThan(adjusted.score, original.score)
        XCTAssertEqual(adjusted.reasons.last?.code, "local_feedback_safe")
    }
}
