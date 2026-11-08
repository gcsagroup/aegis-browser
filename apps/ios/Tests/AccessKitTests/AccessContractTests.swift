import XCTest
@testable import AccessKit

final class AccessContractTests: XCTestCase {
    func testInboundAcceptsHttpHttpsAndSocks5() throws {
        XCTAssertEqual(try AccessInboundTransport.parse(rawValue: 1), .http)
        XCTAssertEqual(try AccessInboundTransport.parse(rawValue: 2), .https)
        XCTAssertEqual(try AccessInboundTransport.parse(rawValue: 3), .socks5)
    }

    func testInboundRejectsUnknown() {
        XCTAssertThrowsError(try AccessInboundTransport.parse(rawValue: 0)) { error in
            XCTAssertEqual(error as? AccessContractError, .unknownInboundTransport(0))
        }
        XCTAssertThrowsError(try AccessInboundTransport.parse(rawValue: 99)) { error in
            XCTAssertEqual(error as? AccessContractError, .unknownInboundTransport(99))
        }
    }

    func testInboundCodableRoundTripIncludesSocks5() throws {
        let encoded = try JSONEncoder().encode(AccessInboundTransport.https)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "2")
        XCTAssertEqual(try JSONDecoder().decode(AccessInboundTransport.self, from: encoded), .https)

        let socks5 = Data("3".utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(AccessInboundTransport.self, from: socks5),
            .socks5
        )
        let roundTrip = try JSONEncoder().encode(AccessInboundTransport.socks5)
        XCTAssertEqual(String(data: roundTrip, encoding: .utf8), "3")
    }

    func testOutboundAcceptsOnlyRealityVision() throws {
        XCTAssertEqual(
            try AccessOutboundProfile.parse(rawValue: "reality_vision"),
            .realityVision
        )
        XCTAssertThrowsError(try AccessOutboundProfile.parse(rawValue: "ws_tls_compat")) { error in
            XCTAssertEqual(error as? AccessContractError, .wsTlsCompatNotAdmitted)
        }
        XCTAssertThrowsError(try AccessOutboundProfile.parse(rawValue: "direct")) { error in
            XCTAssertEqual(error as? AccessContractError, .unknownOutboundProfile("direct"))
        }
        XCTAssertThrowsError(try AccessOutboundProfile.parse(rawValue: "freedom")) { error in
            XCTAssertEqual(error as? AccessContractError, .unknownOutboundProfile("freedom"))
        }
    }

    func testOutboundCodableRejectsReservedAndUnknownPayloads() throws {
        let encoded = try JSONEncoder().encode(AccessOutboundProfile.realityVision)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), #""reality_vision""#)
        XCTAssertEqual(
            try JSONDecoder().decode(AccessOutboundProfile.self, from: encoded),
            .realityVision
        )

        for payload in [#"ws_tls_compat"#, #"freedom"#, #"direct"#] {
            let data = Data("\"\(payload)\"".utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(AccessOutboundProfile.self, from: data))
        }
    }

    func testOwnerRejectsEmptyOrPaddedFields() throws {
        let owner = try AccessOwner(channel: 1, profile: "ordinary", partition: "default")
        XCTAssertEqual(owner.profile, "ordinary")

        XCTAssertThrowsError(try AccessOwner(channel: 1, profile: "  ", partition: "default")) { error in
            XCTAssertEqual(error as? AccessContractError, .emptyOwnerField("profile"))
        }
        XCTAssertThrowsError(try AccessOwner(channel: 1, profile: "ordinary", partition: "")) { error in
            XCTAssertEqual(error as? AccessContractError, .emptyOwnerField("partition"))
        }
        XCTAssertThrowsError(try AccessOwner(channel: 1, profile: " ordinary", partition: "default")) { error in
            XCTAssertEqual(error as? AccessContractError, .ownerFieldNotCanonical)
        }
        XCTAssertThrowsError(try AccessOwner(channel: 1, profile: "ord\0inary", partition: "default")) { error in
            XCTAssertEqual(error as? AccessContractError, .ownerFieldNotCanonical)
        }
    }

    func testOwnerDecodableFailsClosed() throws {
        let json = Data(#"{"channel":1,"profile":"ordinary","partition":"default"}"#.utf8)
        let owner = try JSONDecoder().decode(AccessOwner.self, from: json)
        XCTAssertEqual(owner.channel, 1)

        let bad = Data(#"{"channel":1,"profile":"","partition":"default"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AccessOwner.self, from: bad))
    }
}
