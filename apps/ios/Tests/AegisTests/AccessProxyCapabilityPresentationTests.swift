import XCTest
@testable import Aegis

final class AccessProxyCapabilityPresentationTests: XCTestCase {
    func testConfiguredNodeDoesNotImplyPageAttachment() {
        let value = AccessProxyCapabilityPresentation.make(nodeID: "example", attached: false, entryReady: true)
        XCTAssertEqual(value.configuredNodeID, "example")
        XCTAssertEqual(value.pageRoute, .notAttached)
    }

    func testPageRouteReflectsAttachmentNotConfigAvailability() {
        XCTAssertEqual(AccessProxyCapabilityPresentation.make(nodeID: nil, attached: true, entryReady: true).pageRoute,
                       .localEntryReady)
        XCTAssertEqual(AccessProxyCapabilityPresentation.make(nodeID: "node", attached: true, entryReady: false).pageRoute,
                       .unavailable)
        XCTAssertEqual(AccessProxyCapabilityPresentation.make(nodeID: nil, attached: false, entryReady: false).pageRoute,
                       .notAttached)
    }

    func testEndpointSummaryIsStableAndSeparatesEndpointsWithoutPrintingInputs() {
        let a = AccessProxyCapabilityPresentation.nodeID(address: "SECRET.example", port: 443)
        XCTAssertEqual(a, AccessProxyCapabilityPresentation.nodeID(address: "secret.example", port: 443))
        XCTAssertNotEqual(a, AccessProxyCapabilityPresentation.nodeID(address: "secret.example", port: 8443))
        XCTAssertNotEqual(a, AccessProxyCapabilityPresentation.nodeID(address: "other.example", port: 443))
        XCTAssertEqual(a.count, 12)
        XCTAssertTrue(a.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertFalse(a.contains("secret"))
    }

    func testUntrustedEndpointTextCannotLeakURIOrCredentialToSummary() {
        let hostile = "vless://01234567-89ab-cdef-0123-456789abcdef@node.invalid/?token=secret\n/path/private"
        let label = AccessProxyCapabilityPresentation.nodeID(address: hostile, port: 443)
        XCTAssertEqual(label.count, 12)
        for sensitive in ["vless", "01234567", "token", "secret", "private", "node.invalid", "\n", "/"] {
            XCTAssertFalse(label.contains(sensitive))
        }
    }
}
