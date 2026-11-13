import Foundation

/// Trusted owner identity for an Access partition.
///
/// Strings supplied by web content are not an authority source. Callers must
/// pass browser-owned channel / profile / partition identifiers.
public struct AccessOwner: Codable, Sendable, Equatable, Hashable {
    public let channel: UInt32
    public let profile: String
    public let partition: String

    public init(channel: UInt32, profile: String, partition: String) throws {
        let trimmedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPartition = partition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProfile.isEmpty else {
            throw AccessContractError.emptyOwnerField("profile")
        }
        guard !trimmedPartition.isEmpty else {
            throw AccessContractError.emptyOwnerField("partition")
        }
        guard trimmedProfile == profile, trimmedPartition == partition else {
            throw AccessContractError.ownerFieldNotCanonical
        }
        guard !trimmedProfile.contains("\0"), !trimmedPartition.contains("\0") else {
            throw AccessContractError.ownerFieldNotCanonical
        }
        self.channel = channel
        self.profile = trimmedProfile
        self.partition = trimmedPartition
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let channel = try container.decode(UInt32.self, forKey: .channel)
        let profile = try container.decode(String.self, forKey: .profile)
        let partition = try container.decode(String.self, forKey: .partition)
        try self.init(channel: channel, profile: profile, partition: partition)
    }

    private enum CodingKeys: String, CodingKey {
        case channel
        case profile
        case partition
    }
}
