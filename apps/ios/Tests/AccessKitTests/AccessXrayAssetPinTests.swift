import XCTest
@testable import AccessKit

final class AccessXrayAssetPinTests: XCTestCase {
    func testRealityVisionPinsAreFrozenAndCanonical() throws {
        XCTAssertEqual(AccessXrayAssetPins.realityVision.count, 1)
        let pin = try AccessXrayAssetPins.pin(
            kind: .coreBinary,
            architecture: .iosArm64,
            outboundProfile: .realityVision
        )
        XCTAssertEqual(pin.kind, .coreBinary)
        XCTAssertEqual(pin.architecture, .iosArm64)
        XCTAssertEqual(pin.outboundProfile, .realityVision)
        XCTAssertEqual(
            pin.digest.sha256Hex,
            AccessXrayAssetPins.realityVisionCoreBinaryIOSArm64DigestHex
        )
        XCTAssertEqual(pin.sourceCommit, AccessXrayAssetPins.realityVisionSourceCommit)
        XCTAssertEqual(pin.sourceCommit.count, 40)
        XCTAssertEqual(pin.digest.sha256Hex.count, 64)
    }

    func testVerifyAcceptsExactPinnedDigest() throws {
        try AccessXrayAssetPins.verify(
            kind: .coreBinary,
            architecture: .iosArm64,
            outboundProfile: .realityVision,
            actualDigestHex: AccessXrayAssetPins.realityVisionCoreBinaryIOSArm64DigestHex
        )
    }

    func testVerifyRejectsDigestMismatch() {
        let wrong = String(repeating: "0", count: 64)
        XCTAssertThrowsError(
            try AccessXrayAssetPins.verify(
                kind: .coreBinary,
                architecture: .iosArm64,
                outboundProfile: .realityVision,
                actualDigestHex: wrong
            )
        ) { error in
            XCTAssertEqual(
                error as? AccessContractError,
                .xrayAssetDigestMismatch(
                    expected: AccessXrayAssetPins.realityVisionCoreBinaryIOSArm64DigestHex,
                    actual: wrong
                )
            )
        }
    }

    func testDigestRejectsMalformedHex() {
        XCTAssertThrowsError(try AccessXrayAssetDigest(sha256Hex: "abc")) { error in
            XCTAssertEqual(error as? AccessContractError, .malformedAssetDigest)
        }
        XCTAssertThrowsError(
            try AccessXrayAssetDigest(sha256Hex: String(repeating: "A", count: 64))
        ) { error in
            XCTAssertEqual(error as? AccessContractError, .malformedAssetDigest)
        }
        XCTAssertThrowsError(
            try AccessXrayAssetDigest(sha256Hex: String(repeating: "g", count: 64))
        ) { error in
            XCTAssertEqual(error as? AccessContractError, .malformedAssetDigest)
        }
        XCTAssertThrowsError(
            try AccessXrayAssetPins.verify(
                kind: .coreBinary,
                architecture: .iosArm64,
                outboundProfile: .realityVision,
                actualDigestHex: "not-a-digest"
            )
        ) { error in
            XCTAssertEqual(error as? AccessContractError, .malformedAssetDigest)
        }
    }

    func testKindAndArchitectureFailClosed() {
        XCTAssertThrowsError(try AccessXrayAssetKind.parse(rawValue: "geoip")) { error in
            XCTAssertEqual(error as? AccessContractError, .unknownXrayAssetKind("geoip"))
        }
        XCTAssertThrowsError(try AccessXrayArchitecture.parse(rawValue: "ios-x86_64")) { error in
            XCTAssertEqual(error as? AccessContractError, .unknownXrayArchitecture("ios-x86_64"))
        }
        XCTAssertThrowsError(try AccessXrayArchitecture.parse(rawValue: "android-arm64")) { error in
            XCTAssertEqual(error as? AccessContractError, .unknownXrayArchitecture("android-arm64"))
        }
    }

    func testPinCodableRoundTripAndRejectsBadPayload() throws {
        let pin = AccessXrayAssetPins.realityVision[0]
        let encoded = try JSONEncoder().encode(pin)
        let decoded = try JSONDecoder().decode(AccessXrayAssetPin.self, from: encoded)
        XCTAssertEqual(decoded, pin)

        let badDigest = Data(
            #"{"kind":"core_binary","architecture":"ios-arm64","outboundProfile":"reality_vision","digest":"ZZ","sourceCommit":"\#(AccessXrayAssetPins.realityVisionSourceCommit)"}"#.utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(AccessXrayAssetPin.self, from: badDigest))

        let badCommit = Data(
            #"{"kind":"core_binary","architecture":"ios-arm64","outboundProfile":"reality_vision","digest":"\#(AccessXrayAssetPins.realityVisionCoreBinaryIOSArm64DigestHex)","sourceCommit":"notacommit"}"#.utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(AccessXrayAssetPin.self, from: badCommit))
    }

    func testSourceCommitMustBeLowercaseHex() throws {
        let digest = try AccessXrayAssetDigest(
            sha256Hex: AccessXrayAssetPins.realityVisionCoreBinaryIOSArm64DigestHex
        )
        XCTAssertThrowsError(
            try AccessXrayAssetPin(
                kind: .coreBinary,
                architecture: .iosArm64,
                outboundProfile: .realityVision,
                digest: digest,
                sourceCommit: String(repeating: "A", count: 40)
            )
        ) { error in
            XCTAssertEqual(error as? AccessContractError, .malformedXraySourceCommit)
        }
    }
}
