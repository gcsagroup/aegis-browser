import Foundation

public struct AegisPolicySnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let generatedAt: String
    public let source: String
    public let trackerHosts: [String]
    public let trackingQueryParams: [String]
    public let firstPartyCollectPaths: [String]
    public let phishHosts: [String]
    public let suspiciousTlds: [String]
    public let phishBrandKeywords: [String]

    public init(
        version: Int,
        generatedAt: String,
        source: String,
        trackerHosts: [String],
        trackingQueryParams: [String],
        firstPartyCollectPaths: [String],
        phishHosts: [String],
        suspiciousTlds: [String],
        phishBrandKeywords: [String]
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.source = source
        self.trackerHosts = trackerHosts
        self.trackingQueryParams = trackingQueryParams
        self.firstPartyCollectPaths = firstPartyCollectPaths
        self.phishHosts = phishHosts
        self.suspiciousTlds = suspiciousTlds
        self.phishBrandKeywords = phishBrandKeywords
    }
}

public enum PolicySnapshotError: Error, Equatable, LocalizedError {
    case malformedJSON
    case missingFields([String])
    case unexpectedFields([String])
    case unsupportedVersion(Int)
    case invalidSource(String)
    case invalidGeneratedAt(String)

    public var errorDescription: String? {
        switch self {
        case .malformedJSON:
            return "策略快照不是有效的 JSON 对象"
        case let .missingFields(fields):
            return "策略快照缺少字段：\(fields.joined(separator: ", "))"
        case let .unexpectedFields(fields):
            return "策略快照包含未知字段：\(fields.joined(separator: ", "))"
        case let .unsupportedVersion(version):
            return "不支持的策略快照版本：\(version)"
        case let .invalidSource(source):
            return "策略快照来源无效：\(source)"
        case let .invalidGeneratedAt(value):
            return "策略快照生成时间无效：\(value)"
        }
    }
}

public enum PolicySnapshotLoader {
    public static let supportedVersion = 1
    public static let expectedSource = "@gcsa-aegis/core"

    public static func decode(_ data: Data) throws -> AegisPolicySnapshot {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw PolicySnapshotError.malformedJSON
        }

        let actualKeys = Set(dictionary.keys)
        let missing = requiredKeys.subtracting(actualKeys).sorted()
        if !missing.isEmpty {
            throw PolicySnapshotError.missingFields(missing)
        }
        let unexpected = actualKeys.subtracting(requiredKeys).sorted()
        if !unexpected.isEmpty {
            throw PolicySnapshotError.unexpectedFields(unexpected)
        }

        guard let version = dictionary["version"] as? Int else {
            throw PolicySnapshotError.malformedJSON
        }
        guard version == supportedVersion else {
            throw PolicySnapshotError.unsupportedVersion(version)
        }

        guard let snapshot = try? JSONDecoder().decode(AegisPolicySnapshot.self, from: data) else {
            throw PolicySnapshotError.malformedJSON
        }
        guard snapshot.source == expectedSource else {
            throw PolicySnapshotError.invalidSource(snapshot.source)
        }
        guard parseTimestamp(snapshot.generatedAt) != nil else {
            throw PolicySnapshotError.invalidGeneratedAt(snapshot.generatedAt)
        }
        return snapshot
    }

    public static func decode(_ json: String) throws -> AegisPolicySnapshot {
        guard let data = json.data(using: .utf8) else {
            throw PolicySnapshotError.malformedJSON
        }
        return try decode(data)
    }

    private static let requiredKeys: Set<String> = [
        "version",
        "generatedAt",
        "source",
        "trackerHosts",
        "trackingQueryParams",
        "firstPartyCollectPaths",
        "phishHosts",
        "suspiciousTlds",
        "phishBrandKeywords",
    ]

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
