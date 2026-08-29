import Foundation

struct ShareEnvelope: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let nonce: UUID
    let url: URL
    let createdAt: Date
    let expiresAt: Date
}

enum ShareInboxError: Error, Equatable, LocalizedError {
    case unsupportedScheme
    case payloadTooLarge
    case invalidEnvelope
    case expired
    case unavailableContainer

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme: "只接受 HTTP(S) 链接"
        case .payloadTooLarge: "分享内容超过 8 KiB"
        case .invalidEnvelope: "分享内容格式无效"
        case .expired: "分享内容已过期"
        case .unavailableContainer: "专用 Share Inbox 不可用"
        }
    }
}

struct ShareInbox {
    static let appGroupIdentifier = "group.com.gcsa.aegis.ios.share-inbox"
    static let maximumPayloadBytes = 8 * 1_024
    static let maximumEnvelopeBytes = maximumPayloadBytes + 2 * 1_024
    static let timeToLive: TimeInterval = 60

    private static let envelopeFileName = "share-envelope-v1.json"
    private let baseURL: URL

    init(baseURL: URL? = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: ShareInbox.appGroupIdentifier
    )) throws {
        guard let baseURL else { throw ShareInboxError.unavailableContainer }
        self.baseURL = baseURL
    }

    func makeEnvelope(from input: String, now: Date = Date()) throws -> ShareEnvelope {
        let data = Data(input.utf8)
        guard data.count <= Self.maximumPayloadBytes else { throw ShareInboxError.payloadTooLarge }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil
        else { throw ShareInboxError.unsupportedScheme }
        guard Data(url.absoluteString.utf8).count <= Self.maximumPayloadBytes else {
            throw ShareInboxError.payloadTooLarge
        }
        return ShareEnvelope(
            version: ShareEnvelope.currentVersion,
            nonce: UUID(),
            url: url,
            createdAt: now,
            expiresAt: now.addingTimeInterval(Self.timeToLive)
        )
    }

    func store(_ envelope: ShareEnvelope) throws {
        guard envelope.version == ShareEnvelope.currentVersion else {
            throw ShareInboxError.invalidEnvelope
        }
        _ = try makeEnvelope(from: envelope.url.absoluteString, now: envelope.createdAt)
        guard abs(envelope.expiresAt.timeIntervalSince(envelope.createdAt) - Self.timeToLive) < 0.001 else {
            throw ShareInboxError.invalidEnvelope
        }
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maximumEnvelopeBytes else { throw ShareInboxError.payloadTooLarge }
        try data.write(
            to: baseURL.appendingPathComponent(Self.envelopeFileName),
            options: [.atomic, .completeFileProtection]
        )
    }

    func consume(now: Date = Date()) throws -> ShareEnvelope? {
        removeExpiredClaims(now: now)
        let source = baseURL.appendingPathComponent(Self.envelopeFileName)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }

        // 固定文件原子改名后再读取，多个 Scene/进程最多只有一个能取得该 envelope。
        let claimed = baseURL.appendingPathComponent(".consuming-\(UUID().uuidString)-v1.json")
        do {
            try FileManager.default.moveItem(at: source, to: claimed)
        } catch CocoaError.fileNoSuchFile {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: claimed) }

        let data = try Data(contentsOf: claimed)
        guard data.count <= Self.maximumEnvelopeBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["createdAt", "expiresAt", "nonce", "url", "version"]
        else { throw ShareInboxError.invalidEnvelope }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope = try decoder.decode(ShareEnvelope.self, from: data)
        guard envelope.version == ShareEnvelope.currentVersion else {
            throw ShareInboxError.invalidEnvelope
        }
        guard envelope.createdAt <= now,
              abs(envelope.expiresAt.timeIntervalSince(envelope.createdAt) - Self.timeToLive) < 0.001
        else { throw ShareInboxError.invalidEnvelope }
        guard now < envelope.expiresAt else { throw ShareInboxError.expired }
        _ = try makeEnvelope(from: envelope.url.absoluteString, now: envelope.createdAt)
        return envelope
    }

    private func removeExpiredClaims(now: Date) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return }
        let staleBefore = now.addingTimeInterval(-(Self.timeToLive + 5))
        for file in files where file.lastPathComponent.hasPrefix(".consuming-") {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < staleBefore
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
