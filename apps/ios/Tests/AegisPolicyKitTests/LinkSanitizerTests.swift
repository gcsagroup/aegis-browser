import XCTest
@testable import AegisPolicyKit

final class LinkSanitizerTests: XCTestCase {
    func testRemovesTrackingParametersAndPreservesOrdinaryQuery() {
        let result = LinkSanitizer.sanitize(
            "https://news.example/a?utm_source=x&fbclid=123&keep=1"
        )

        XCTAssertEqual(result.cleaned, "https://news.example/a?keep=1")
        XCTAssertEqual(result.removed, ["utm_source", "fbclid"])
        XCTAssertTrue(result.changed)
    }

    func testMatchesCoreCaseDuplicatesHashAndFormEncoding() {
        let result = LinkSanitizer.sanitize(
            "https://EXAMPLE.com?UTM_Source=x&utm_source=y&keep=%2F#utm_test"
        )

        XCTAssertEqual(result.cleaned, "https://example.com/?keep=%2F")
        XCTAssertEqual(result.removed, ["UTM_Source", "utm_source", "#tracking-hash"])
    }

    func testNormalizesAbsoluteHTTPURLLikeJavaScriptURL() {
        let result = LinkSanitizer.sanitize("https://example.com")

        XCTAssertEqual(result.cleaned, "https://example.com/")
        XCTAssertTrue(result.changed)
    }

    func testRejectsFoundationRelativeURLAsInvalidPortableURL() {
        let result = LinkSanitizer.sanitize("not a valid URL")

        XCTAssertEqual(result.cleaned, "not a valid URL")
        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.removed.isEmpty)
    }

    func testSupportsCaseInsensitiveExtraParameters() {
        let result = LinkSanitizer.sanitize(
            "https://example.com/?foo=x&FOO=y&keep=1",
            extraParameters: ["Foo"]
        )

        XCTAssertEqual(result.cleaned, "https://example.com/?keep=1")
        XCTAssertEqual(result.removed, ["foo", "FOO"])
    }
}
