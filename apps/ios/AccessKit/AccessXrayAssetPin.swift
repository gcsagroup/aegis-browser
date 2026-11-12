import Foundation

/// One frozen Xray asset pin bound to an admitted outbound profile.
public struct AccessXrayAssetPin: Codable, Sendable, Equatable, Hashable {
    public let kind: AccessXrayAssetKind
    public let architecture: AccessXrayArchitecture
    public let outboundProfile: AccessOutboundProfile
    public let digest: AccessXrayAssetDigest
    public let sourceCommit: String

    public init(
        kind: AccessXrayAssetKind,
        architecture: AccessXrayArchitecture,
        outboundProfile: AccessOutboundProfile,
        digest: AccessXrayAssetDigest,
        sourceCommit: String
    ) throws {
        guard outboundProfile == .realityVision else {
            throw AccessContractError.xrayAssetProfileNotAdmitted(outboundProfile.rawValue)
        }
        guard sourceCommit.count == 40,
              sourceCommit.unicodeScalars.allSatisfy({ Self.lowercaseHex.contains($0) })
        else {
            throw AccessContractError.malformedXraySourceCommit
        }
        self.kind = kind
        self.architecture = architecture
        self.outboundProfile = outboundProfile
        self.digest = digest
        self.sourceCommit = sourceCommit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(AccessXrayAssetKind.self, forKey: .kind)
        let architecture = try container.decode(AccessXrayArchitecture.self, forKey: .architecture)
        let outboundProfile = try container.decode(AccessOutboundProfile.self, forKey: .outboundProfile)
        let digest = try container.decode(AccessXrayAssetDigest.self, forKey: .digest)
        let sourceCommit = try container.decode(String.self, forKey: .sourceCommit)
        try self.init(
            kind: kind,
            architecture: architecture,
            outboundProfile: outboundProfile,
            digest: digest,
            sourceCommit: sourceCommit
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case architecture
        case outboundProfile
        case digest
        case sourceCommit
    }

    private static let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
}
