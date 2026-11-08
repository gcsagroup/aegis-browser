import Foundation

/// Frozen Xray asset digests for the admitted `reality_vision` path.
///
/// Digests are contract pins. Runtime lifecycle (F8) must refuse any asset whose
/// SHA-256 does not match these values. This type does not load or execute Xray.
public enum AccessXrayAssetPins {
    /// Source identity pin for the reality_vision Xray asset set.
    public static let realityVisionSourceCommit = "db72a9c96f3c3ea1b6f592d66b7bb396d1cb1ed4"

    /// Expected SHA-256 for `core_binary` / `ios-arm64` / `reality_vision`.
    public static let realityVisionCoreBinaryIOSArm64DigestHex =
        "05dbb69d777fa7c103c3dd5f75eac7e945fb3a75ba528edab8a8d7912cbc1a28"

    /// Complete frozen pin table for the admitted reality_vision path.
    public static let realityVision: [AccessXrayAssetPin] = {
        do {
            let digest = try AccessXrayAssetDigest(
                sha256Hex: realityVisionCoreBinaryIOSArm64DigestHex
            )
            let pin = try AccessXrayAssetPin(
                kind: .coreBinary,
                architecture: .iosArm64,
                outboundProfile: .realityVision,
                digest: digest,
                sourceCommit: realityVisionSourceCommit
            )
            return [pin]
        } catch {
            preconditionFailure("Frozen reality_vision Xray pins must be well-formed")
        }
    }()

    /// Look up the frozen pin for an admitted kind / architecture / profile.
    public static func pin(
        kind: AccessXrayAssetKind,
        architecture: AccessXrayArchitecture,
        outboundProfile: AccessOutboundProfile
    ) throws -> AccessXrayAssetPin {
        guard outboundProfile == .realityVision else {
            throw AccessContractError.xrayAssetProfileNotAdmitted(outboundProfile.rawValue)
        }
        guard let match = realityVision.first(where: {
            $0.kind == kind && $0.architecture == architecture && $0.outboundProfile == outboundProfile
        }) else {
            throw AccessContractError.xrayAssetPinMissing(kind.rawValue, architecture.rawValue)
        }
        return match
    }

    /// Fail closed unless `actualDigest` exactly matches the frozen pin.
    public static func verify(
        kind: AccessXrayAssetKind,
        architecture: AccessXrayArchitecture,
        outboundProfile: AccessOutboundProfile,
        actualDigest: AccessXrayAssetDigest
    ) throws {
        let expected = try pin(
            kind: kind,
            architecture: architecture,
            outboundProfile: outboundProfile
        )
        guard expected.digest == actualDigest else {
            throw AccessContractError.xrayAssetDigestMismatch(
                expected: expected.digest.sha256Hex,
                actual: actualDigest.sha256Hex
            )
        }
    }

    /// Fail closed when comparing raw hex strings (malformed actual digests reject).
    public static func verify(
        kind: AccessXrayAssetKind,
        architecture: AccessXrayArchitecture,
        outboundProfile: AccessOutboundProfile,
        actualDigestHex: String
    ) throws {
        let actual = try AccessXrayAssetDigest(sha256Hex: actualDigestHex)
        try verify(
            kind: kind,
            architecture: architecture,
            outboundProfile: outboundProfile,
            actualDigest: actual
        )
    }
}
