import Foundation

/// Reads the frozen Access core lock. A source candidate is not a verified binary.
public struct AccessEmbeddedCoreManifest: Equatable, Sendable {
    public enum Status: String, Sendable {
        case sourceCandidate = "source_candidate"
        case verifiedBuild = "verified_build"
    }

    public var status: Status
    public var xrayCommit: String
    public var xrayTag: String
    public var libXrayCommit: String?
    public var iosArm64Sha256: String?
    public var iosArm64SimulatorSha256: String?

    public var mayLink: Bool {
        status == .verifiedBuild
            && !(iosArm64Sha256 ?? "").isEmpty
            && !(iosArm64SimulatorSha256 ?? "").isEmpty
    }

    public static func load(from data: Data) throws -> AccessEmbeddedCoreManifest {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw AccessEmbeddedCoreError.invalidLock
        }
        guard let statusRaw = root["status"] as? String,
              let status = Status(rawValue: statusRaw) else {
            throw AccessEmbeddedCoreError.invalidLock
        }
        guard let xray = root["xrayCore"] as? [String: Any],
              let commit = xray["commit"] as? String, commit.count == 40,
              let tag = xray["tag"] as? String, !tag.isEmpty else {
            throw AccessEmbeddedCoreError.invalidLock
        }
        let lib = root["libXray"] as? [String: Any]
        let artifacts = root["artifacts"] as? [String: Any] ?? [:]
        return AccessEmbeddedCoreManifest(
            status: status,
            xrayCommit: commit,
            xrayTag: tag,
            libXrayCommit: lib?["commit"] as? String,
            iosArm64Sha256: artifacts["iosArm64Sha256"] as? String,
            iosArm64SimulatorSha256: artifacts["iosArm64SimulatorSha256"] as? String
        )
    }
}

public enum AccessEmbeddedCoreError: Error, Equatable {
    case invalidLock
    case unverifiedAsset
}
