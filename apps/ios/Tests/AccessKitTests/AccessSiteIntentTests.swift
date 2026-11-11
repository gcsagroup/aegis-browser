import XCTest
@testable import AccessKit

final class AccessSiteIntentTests: XCTestCase {
    func testParsesIntents() throws {
        XCTAssertEqual(try AccessSiteIntent.parse(rawValue: "off"), .off)
        XCTAssertEqual(try AccessSiteIntent.parse(rawValue: "allow"), .allow)
        XCTAssertEqual(try AccessSiteIntent.parse(rawValue: "block"), .block)
        XCTAssertThrowsError(try AccessSiteIntent.parse(rawValue: "proxy")) { error in
            XCTAssertEqual(error as? AccessSiteIntentError, .unknownIntent("proxy"))
        }
    }

    func testNormalizesHostFromURLText() throws {
        let host = try AccessSiteHost.normalize("https://WWW.Example.COM:443/path?q=1")
        XCTAssertEqual(host.rawValue, "www.example.com")
    }

    func testRejectsNonCanonicalExactHost() {
        XCTAssertThrowsError(try AccessSiteHost("WWW.Example.COM")) { error in
            XCTAssertEqual(error as? AccessSiteIntentError, .hostNotCanonical)
        }
        XCTAssertThrowsError(try AccessSiteHost("www.example.com/path")) { error in
            XCTAssertEqual(error as? AccessSiteIntentError, .hostContainsSchemeOrPath)
        }
        XCTAssertThrowsError(try AccessSiteHost("https://www.example.com")) { error in
            XCTAssertEqual(error as? AccessSiteIntentError, .hostContainsSchemeOrPath)
        }
    }

    func testStoreDefaultsOffAndOmitsOffEntries() throws {
        var store = AccessSiteIntentStore()
        let host = try AccessSiteHost("www.example.com")
        XCTAssertEqual(store.intent(for: host), .off)

        store.setIntent(.allow, for: host)
        XCTAssertEqual(store.intent(for: host), .allow)
        XCTAssertEqual(store.allIntents()[host], .allow)

        store.setIntent(.block, for: host)
        XCTAssertEqual(store.intent(for: host), .block)

        store.setIntent(.off, for: host)
        XCTAssertEqual(store.intent(for: host), .off)
        XCTAssertNil(store.allIntents()[host])
    }
}
