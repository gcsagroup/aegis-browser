import XCTest
@testable import BrowserKit

final class NavigationPolicyIntegrationTests: XCTestCase {
    func testHTTPNavigationIsSanitizedBeforeLoad() throws {
        let decision = BrowserNavigationPolicy.evaluate(try XCTUnwrap(URL(
            string: "https://Example.com/item?utm_source=feed&keep=1#utm_campaign"
        )))

        XCTAssertEqual(decision.kind, .sanitized)
        XCTAssertEqual(decision.effectiveURL, "https://example.com/item?keep=1")
        XCTAssertEqual(decision.removedQueryParameters, ["utm_source", "#tracking-hash"])
        XCTAssertFalse(decision.reasonCodes.contains("invalid_url"))
    }

    func testHighRiskNavigationIsBlockedBeforeNetwork() throws {
        let decision = BrowserNavigationPolicy.evaluate(try XCTUnwrap(URL(
            string: "http://paypal.example.top/login/paypal?utm_source=message"
        )))

        XCTAssertEqual(decision.kind, .blocked)
        XCTAssertGreaterThanOrEqual(decision.phishingScore, 55)
        XCTAssertTrue(decision.reasonCodes.contains("brand_spoof_host"))
        XCTAssertTrue(decision.reasonCodes.contains("suspicious_tld"))
        XCTAssertEqual(
            decision.effectiveURL,
            "http://paypal.example.top/login/paypal"
        )
    }

    func testInternalFixtureIsAllowedWithoutRewriting() throws {
        let url = try XCTUnwrap(URL(string: "aegis://injection"))
        let decision = BrowserNavigationPolicy.evaluate(url)

        XCTAssertEqual(decision.kind, .allow)
        XCTAssertEqual(decision.effectiveURL, url.absoluteString)
        XCTAssertEqual(decision.phishingScore, 0)
    }

    func testUnsupportedTopLevelSchemesFailClosed() throws {
        for rawURL in ["javascript:alert(1)", "file:///private/data.txt", "data:text/plain,secret"] {
            let decision = BrowserNavigationPolicy.evaluate(try XCTUnwrap(URL(string: rawURL)))
            XCTAssertEqual(decision.kind, .blocked, rawURL)
            XCTAssertTrue(decision.reasonCodes.contains("unsupported_top_level_scheme"), rawURL)
        }
        XCTAssertEqual(
            BrowserNavigationPolicy.evaluate(try XCTUnwrap(URL(string: "about:blank"))).kind,
            .allow
        )
    }

    func testCredentialedHTTPURLFailsClosed() throws {
        let decision = BrowserNavigationPolicy.evaluate(try XCTUnwrap(URL(
            string: "https://paypal.com@evil.example/login"
        )))

        XCTAssertEqual(decision.kind, .blocked)
        XCTAssertTrue(decision.reasonCodes.contains("credentialed_url"))
    }

    func testSanitizationRequiredForPOSTFailsClosed() throws {
        let decision = BrowserNavigationPolicy.evaluate(
            try XCTUnwrap(URL(string: "https://example.com/submit?utm_source=form&keep=1")),
            httpMethod: "POST"
        )

        XCTAssertEqual(decision.kind, .blocked)
        XCTAssertTrue(decision.reasonCodes.contains("unsafe_sanitization_method"))
        XCTAssertEqual(decision.effectiveURL, "https://example.com/submit?keep=1")
    }

    func testCanonicalizationWithoutTrackingDoesNotRewriteOrBlock() throws {
        let rawURL = "https://EXAMPLE.com"
        let url = try XCTUnwrap(URL(string: rawURL))

        for method in ["GET", "POST"] {
            let decision = BrowserNavigationPolicy.evaluate(url, httpMethod: method)
            XCTAssertEqual(decision.kind, .allow, method)
            XCTAssertEqual(decision.effectiveURL, rawURL, method)
            XCTAssertTrue(decision.removedQueryParameters.isEmpty, method)
        }
    }
}
