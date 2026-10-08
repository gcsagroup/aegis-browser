import XCTest
@testable import Aegis

final class ExternalPageLinkTests: XCTestCase {
    func testOnlyExplicitWebURLIsAccepted() {
        XCTAssertEqual(ExternalPageLink.destination(URL(string: "gcsa-aegis://open?url=https%3A%2F%2Fexample.com%2Fa")!)?.absoluteString, "https://example.com/a")
        for value in ["gcsa-aegis://open?url=javascript%3Aalert(1)", "gcsa-aegis://open?url=https%3A%2F%2Fu%3Ap%40example.com", "gcsa-aegis://open?url=https://example.com&run=agent", "gcsa-aegis://open?url=https://example.com&url=https://other.example"] {
            XCTAssertNil(ExternalPageLink.destination(URL(string: value)!))
        }
    }
}
