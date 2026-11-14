import CryptoKit
import Foundation

/// Verifies an on-disk Xray core before the runtime may launch it.
public protocol AccessXrayDigestVerifying: Sendable {
    func verify(
        fileURL: URL,
        architecture: AccessXrayArchitecture,
        outboundProfile: AccessOutboundProfile
    ) throws
}

/// Production verifier: SHA-256 the file and match F6 frozen pins.
public struct AccessXrayPinnedDigestVerifier: AccessXrayDigestVerifying {
    public init() {}

    public func verify(
        fileURL: URL,
        architecture: AccessXrayArchitecture,
        outboundProfile: AccessOutboundProfile
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw AccessXrayRuntimeError.executableMissing
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw AccessXrayRuntimeError.executableMissing
        }
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let actual = try AccessXrayAssetDigest(sha256Hex: hex)
        do {
            try AccessXrayAssetPins.verify(
                kind: .coreBinary,
                architecture: architecture,
                outboundProfile: outboundProfile,
                actualDigest: actual
            )
        } catch let error as AccessContractError {
            if case let .xrayAssetDigestMismatch(expected, actualHex) = error {
                throw AccessXrayRuntimeError.digestMismatch(expected: expected, actual: actualHex)
            }
            throw error
        }
    }
}
