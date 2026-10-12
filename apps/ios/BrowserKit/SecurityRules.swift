import AegisPolicyKit
import CryptoKit
import Foundation
import WebKit

public struct SecurityRuleSnapshot: Codable, Sendable {
    public let version: Int
    public let created: TimeInterval
    public let expires: TimeInterval
    public let phishing: [String]
    public let mining: [String]
    public let fingerprinting: [String]

    /// 更新包必须完整验签后再解析；版本、数量及有效期校验失败时调用者保留现有快照。
    static func verify(_ data: Data, signature: Data, key: Data, minimumVersion: Int = 0,
                       now: Date = Date(), allowExpired: Bool = false) throws -> Self {
        guard data.count <= 8_000_000, signature.count == 64,
              try Curve25519.Signing.PublicKey(rawRepresentation: key).isValidSignature(signature, for: data)
        else { throw SecurityRuleError.invalidSnapshot }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.version > minimumVersion, result.created <= now.timeIntervalSince1970 + 86400,
              result.expires > result.created, result.expires - result.created <= 100 * 86400,
              allowExpired || result.expires > now.timeIntervalSince1970,
              !result.phishing.isEmpty, result.phishing.count <= 250_000,
              result.mining.count <= 5000, result.fingerprinting.count <= 5000,
              (result.phishing + result.mining + result.fingerprinting).allSatisfy({ host in
                  host.count <= 253 && host.contains(".") && host.utf8.allSatisfy { byte in
                      (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 46
                  } && !host.hasPrefix(".") && !host.hasSuffix(".") && !host.contains("..")
              }) else { throw SecurityRuleError.invalidSnapshot }
        return result
    }
}

enum SecurityRuleError: Error { case invalidSnapshot }

public enum LocalThreatDatabase {
    private final class ResourceAnchor: NSObject { }
    static let snapshot: SecurityRuleSnapshot? = {
        let bundle = Bundle(for: ResourceAnchor.self)
        guard let url = bundle.url(forResource: "security-rules", withExtension: "json"),
              let sig = bundle.url(forResource: "security-rules", withExtension: "sig"),
              let data = try? Data(contentsOf: url), let signature = try? Data(contentsOf: sig),
              let key = Data(base64Encoded: "ZZtvyUz9YXMk0obT7mjURE43om/wLNP1ngbXNg023Qg=") else { return nil }
        // 内置签名快照过期后继续保护，并显示过期状态；不能接受过期的新更新包。
        return try? SecurityRuleSnapshot.verify(data, signature: signature, key: key, allowExpired: true)
    }()
    private static let phishingHosts = Set(snapshot?.phishing ?? [])
    public static var version: Int? { snapshot?.version }
    public static var isExpired: Bool { (snapshot?.expires ?? 0) < Date().timeIntervalSince1970 }
    public static func contains(_ url: URL) -> Bool {
        guard let host = url.host.flatMap(RegisteredDomain.normalizedHost) else { return false }
        // 上游以完整主机登记；不将共享托管的父域扩大为整站拦截。
        return phishingHosts.contains(host)
    }
}

@MainActor
final class SecurityRuleStore {
    static let shared = SecurityRuleStore()
    private var compiled: [String: WKContentRuleList] = [:]
    private var pending: [String: Task<WKContentRuleList, Error>] = [:]
    let fixtureRules: Bool
    init(fixtureRules: Bool = false) { self.fixtureRules = fixtureRules }

    func list(category: String) async throws -> WKContentRuleList {
        if let cached = compiled[category] { return cached }
        if let task = pending[category] { return try await task.value }
        guard let snapshot = LocalThreatDatabase.snapshot else { throw SecurityRuleError.invalidSnapshot }
        let domains = category == "mining" ? snapshot.mining : snapshot.fingerprinting
        var rules: [[String: Any]] = domains.map { host in
            ["trigger": ["url-filter": "^[a-z]+://([^/]+\\.)?" + host.replacingOccurrences(of: ".", with: "\\.") + "[/:]"],
             "action": ["type": "block"]]
        }
        if fixtureRules {
            for host in ["127\\.0\\.0\\.1", "localhost"] {
                rules.append(["trigger": ["url-filter": "^http://" + host + ":8768/security-fixture/" + category + "/"], "action": ["type": "block"]])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let task = Task { @MainActor in
            try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "aegis-security-" + digest,
                encodedContentRuleList: String(decoding: data, as: UTF8.self))!
        }
        pending[category] = task
        defer { pending[category] = nil }
        let list = try await task.value
        compiled[category] = list
        return list
    }
}
