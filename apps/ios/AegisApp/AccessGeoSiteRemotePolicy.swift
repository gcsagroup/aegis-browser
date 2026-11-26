import AccessKit
import CryptoKit
import Foundation

struct AccessGeoSiteRefreshPolicy {
    static let supportedDays = [1, 3, 7]
    var days = 3
    var leadHours = 24
    var retryHours = 6

    func nextCheck(after checkedAt: Date, expires: Date?) -> Date {
        let periodic = checkedAt.addingTimeInterval(Double(days) * 86_400)
        guard let expires, expires > checkedAt else { return periodic }
        let deadline = expires.addingTimeInterval(-Double(leadHours) * 3_600)
        if deadline > checkedAt { return min(periodic, deadline) }
        let retry = min(Double(retryHours) * 3_600, expires.timeIntervalSince(checkedAt) / 2)
        return min(periodic, checkedAt.addingTimeInterval(retry))
    }
}

struct AccessGeoSiteRemotePolicy: Codable, Equatable, Sendable {
    static let maximumEnvelopeBytes = 12 * 1024
    static let checkInterval: TimeInterval = 86_400

    enum Failure: Error { case envelope, signature, payload, rollback, conflict }

    struct Rules: Codable, Equatable, Sendable {
        let schema: Int
        let version: Int
        let issuedAt: TimeInterval
        let expiresAt: TimeInterval
        let defaultRefreshDays: Int?
        let expiryLeadHours: Int?
        let lateRetryHours: Int?
        let overseasPaused: Bool
        let blockedTags: [String]
        let minimumTag: String?

        var valid: Bool {
            schema == 1 && version > 0 && issuedAt.isFinite && expiresAt.isFinite
                && expiresAt > issuedAt && expiresAt - issuedAt <= 30 * 86_400
                && defaultRefreshDays.map(AccessGeoSiteRefreshPolicy.supportedDays.contains) != false
                && expiryLeadHours.map((6...72).contains) != false
                && lateRetryHours.map((1...24).contains) != false
                && blockedTags.count <= 64 && Set(blockedTags).count == blockedTags.count
                && blockedTags.allSatisfy(AccessGeoSiteAdmission.isValidReleaseTag)
                && minimumTag.map(AccessGeoSiteAdmission.isValidReleaseTag) != false
        }

        func blocks(_ tag: String) -> Bool {
            blockedTags.contains(tag) || minimumTag.map { tag < $0 } == true
        }
    }

    private struct Envelope: Decodable {
        let payload: Data
        let signature: Data
    }

    let rules: Rules
    let digest: String

    static func verify(_ bytes: Data, key: Curve25519.Signing.PublicKey, now: Date) throws -> Self {
        guard (1...maximumEnvelopeBytes).contains(bytes.count) else { throw Failure.envelope }
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: bytes)
        guard envelope.signature.count == 64, key.isValidSignature(envelope.signature, for: envelope.payload)
        else { throw Failure.signature }
        let rules = try decoder.decode(Rules.self, from: envelope.payload)
        let timestamp = now.timeIntervalSince1970
        guard rules.valid, rules.issuedAt <= timestamp + 300, rules.expiresAt > timestamp else { throw Failure.payload }
        return Self(rules: rules, digest: AccessGeoSiteAdmission.sha256(envelope.payload))
    }

    func validateSuccessor(of prior: Self?) throws {
        guard let prior else { return }
        if rules.version < prior.rules.version { throw Failure.rollback }
        if rules.version == prior.rules.version, digest != prior.digest { throw Failure.conflict }
    }

    func schedule(at date: Date) -> AccessGeoSiteRefreshPolicy {
        guard date.timeIntervalSince1970 < rules.expiresAt else { return .init() }
        return .init(days: rules.defaultRefreshDays ?? 3, leadHours: rules.expiryLeadHours ?? 24,
                     retryHours: rules.lateRetryHours ?? 6)
    }
}

struct AccessGeoSiteRemoteSource: Sendable {
    let url: URL
    let key: Curve25519.Signing.PublicKey

    static func configured(in bundle: Bundle = .main) -> Self? {
        guard let value = bundle.object(forInfoDictionaryKey: "AegisGeoSitePolicyURL") as? String,
              let url = URL(string: value), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let encoded = bundle.object(forInfoDictionaryKey: "AegisGeoSitePolicyPublicKey") as? String,
              let rawKey = Data(base64Encoded: encoded),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey) else { return nil }
        return Self(url: url, key: key)
    }

    func load(now: Date) async throws -> AccessGeoSiteRemotePolicy {
        let bytes = try await AccessGeoSiteUpdateTransport().loadPolicy(at: url, limit: AccessGeoSiteRemotePolicy.maximumEnvelopeBytes)
        return try AccessGeoSiteRemotePolicy.verify(bytes, key: key, now: now)
    }
}
