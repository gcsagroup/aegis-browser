import Foundation

/// The server sends byte counts as canonical decimal strings (some exceed 2^53).
struct AccessAccountEntitlement: Decodable, Equatable, Sendable {
    enum Status: String, Decodable { case notSubscribed = "not_subscribed", active, exhausted, expired }
    enum Freshness: String, Decodable { case current, delayed, unavailable }
    let entitlementAccountId: String
    let status: Status
    let planId, periodId: String?
    let periodStart, periodEnd, expiresAt: Int64?
    let quotaBytes, uploadedBytes, downloadedBytes, usedBytes, remainingBytes: String?
    let measuredAt, receivedAt, snapshotAgeMs: Int64?
    let freshness: Freshness?
    enum QuotaSource: String, Decodable { case threeXUIAlpha = "3xui_alpha" }
    enum PanelExpiryMode: String, Decodable { case none, absolute }
    let quotaSource: QuotaSource?
    let panelExpiryMode: PanelExpiryMode?
    let panelExpiresAt: Int64?

    init(entitlementAccountId: String, status: Status, planId: String?, periodId: String?,
         periodStart: Int64?, periodEnd: Int64?, expiresAt: Int64?, quotaBytes: String?,
         uploadedBytes: String?, downloadedBytes: String?, usedBytes: String?, remainingBytes: String?,
         measuredAt: Int64?, receivedAt: Int64?, snapshotAgeMs: Int64?, freshness: Freshness?,
         quotaSource: QuotaSource? = nil, panelExpiryMode: PanelExpiryMode? = nil,
         panelExpiresAt: Int64? = nil) {
        self.entitlementAccountId = entitlementAccountId
        self.status = status
        self.planId = planId
        self.periodId = periodId
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.expiresAt = expiresAt
        self.quotaBytes = quotaBytes
        self.uploadedBytes = uploadedBytes
        self.downloadedBytes = downloadedBytes
        self.usedBytes = usedBytes
        self.remainingBytes = remainingBytes
        self.measuredAt = measuredAt
        self.receivedAt = receivedAt
        self.snapshotAgeMs = snapshotAgeMs
        self.freshness = freshness
        self.quotaSource = quotaSource
        self.panelExpiryMode = panelExpiryMode
        self.panelExpiresAt = panelExpiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case entitlementAccountId, status, planId, periodId, periodStart, periodEnd, expiresAt
        case quotaBytes, uploadedBytes, downloadedBytes, usedBytes, remainingBytes
        case measuredAt, receivedAt, snapshotAgeMs, freshness
        case quotaSource, panelExpiryMode, panelExpiresAt
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let alphaKeys: [CodingKeys] = [.quotaSource, .panelExpiryMode, .panelExpiresAt]
        let hasAlphaMetadata = alphaKeys.contains { fields.contains($0) }
        let status = try fields.decode(Status.self, forKey: .status)
        if hasAlphaMetadata {
            // Explicit null is not absence. An opt-in response must carry the whole group.
            guard alphaKeys.allSatisfy({ fields.contains($0) }), status != .notSubscribed else {
                throw AccountQueryError.invalid
            }
        }
        self.init(
            entitlementAccountId: try fields.decode(String.self, forKey: .entitlementAccountId),
            status: status,
            planId: try fields.decodeIfPresent(String.self, forKey: .planId),
            periodId: try fields.decodeIfPresent(String.self, forKey: .periodId),
            periodStart: try fields.decodeIfPresent(Int64.self, forKey: .periodStart),
            periodEnd: try fields.decodeIfPresent(Int64.self, forKey: .periodEnd),
            expiresAt: try fields.decodeIfPresent(Int64.self, forKey: .expiresAt),
            quotaBytes: try fields.decodeIfPresent(String.self, forKey: .quotaBytes),
            uploadedBytes: try fields.decodeIfPresent(String.self, forKey: .uploadedBytes),
            downloadedBytes: try fields.decodeIfPresent(String.self, forKey: .downloadedBytes),
            usedBytes: try fields.decodeIfPresent(String.self, forKey: .usedBytes),
            remainingBytes: try fields.decodeIfPresent(String.self, forKey: .remainingBytes),
            measuredAt: try fields.decodeIfPresent(Int64.self, forKey: .measuredAt),
            receivedAt: try fields.decodeIfPresent(Int64.self, forKey: .receivedAt),
            snapshotAgeMs: try fields.decodeIfPresent(Int64.self, forKey: .snapshotAgeMs),
            freshness: try fields.decodeIfPresent(Freshness.self, forKey: .freshness),
            quotaSource: hasAlphaMetadata ? try fields.decode(QuotaSource.self, forKey: .quotaSource) : nil,
            panelExpiryMode: hasAlphaMetadata ? try fields.decode(PanelExpiryMode.self, forKey: .panelExpiryMode) : nil,
            panelExpiresAt: try fields.decodeIfPresent(Int64.self, forKey: .panelExpiresAt)
        )
    }

    func validate(for account: String) throws {
        guard entitlementAccountId == account else { throw AccountQueryError.invalid }
        let raw = [quotaBytes, uploadedBytes, downloadedBytes, usedBytes, remainingBytes]
        if status == .notSubscribed {
            guard raw.allSatisfy({ $0 == nil }), planId == nil, periodId == nil, periodStart == nil,
                  periodEnd == nil, expiresAt == nil, receivedAt == nil, measuredAt == nil,
                  snapshotAgeMs == nil, freshness == nil, quotaSource == nil,
                  panelExpiryMode == nil, panelExpiresAt == nil else { throw AccountQueryError.invalid }
            return
        }
        guard let planId, !planId.isEmpty, let periodId, !periodId.isEmpty,
              let periodStart, let periodEnd, periodStart >= 0, periodEnd > periodStart,
              let expiresAt, expiresAt > 0, let receivedAt, receivedAt >= periodStart else {
            throw AccountQueryError.invalid
        }
        if quotaSource != nil || panelExpiryMode != nil || panelExpiresAt != nil {
            guard quotaSource == .threeXUIAlpha, let panelExpiryMode else { throw AccountQueryError.invalid }
            switch panelExpiryMode {
            case .none:
                guard panelExpiresAt == nil, expiresAt == periodEnd else { throw AccountQueryError.invalid }
            case .absolute:
                guard let panelExpiresAt, panelExpiresAt > 0,
                      expiresAt == min(periodEnd, panelExpiresAt) else { throw AccountQueryError.invalid }
            }
        }
        let bytes = try raw.map { string -> UInt64 in
            guard let string, let value = UInt64(string), String(value) == string else {
                throw AccountQueryError.invalid
            }
            return value
        }
        let (sum, overflow) = bytes[1].addingReportingOverflow(bytes[2])
        guard !overflow, bytes[3] == sum, bytes[4] == (bytes[0] > sum ? bytes[0] - sum : 0) else {
            throw AccountQueryError.invalid
        }
        if (status == .active && sum >= bytes[0]) || (status == .exhausted && sum < bytes[0]) {
            throw AccountQueryError.invalid
        }
        if let measuredAt {
            guard measuredAt >= 0, measuredAt <= receivedAt, let age = snapshotAgeMs,
                  age >= receivedAt - measuredAt,
                  freshness == (age > 15_000 ? .unavailable : age > 5_000 ? .delayed : .current)
            else { throw AccountQueryError.invalid }
        } else if snapshotAgeMs != nil || freshness != .unavailable {
            throw AccountQueryError.invalid
        }
    }
}

enum AccountQueryError: Error { case invalid, unauthorized }

private final class AccountRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct AccessAccountClient: Sendable {
    let endpoint: URL
    init(origin: String, allowSimulatorLoopback: Bool = false) throws {
        guard let c = URLComponents(string: origin), let host = c.host, !host.isEmpty,
              c.scheme == "https" || (allowSimulatorLoopback && c.scheme == "http" && host == "127.0.0.1"),
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.percentEncodedPath == "" || c.percentEncodedPath == "/", let url = c.url else {
            throw AccountQueryError.invalid
        }
        endpoint = url.appendingPathComponent("v1/me/entitlement")
    }

    func read(_ credential: AccessAccountCredential) async throws -> AccessAccountEntitlement {
        let data = try await request(credential, url: endpoint, method: "GET", accepted: [200])
        let result = try JSONDecoder().decode(AccessAccountEntitlement.self, from: data)
        try result.validate(for: credential.accountID)
        return result
    }

    private func request(_ credential: AccessAccountCredential, url: URL, method: String,
                         body: Data? = nil, accepted: Set<Int>) async throws -> Data {
        guard credential.endpoint == endpoint.absoluteString, credential.valid else { throw AccountQueryError.invalid }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config, delegate: AccountRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == url else { throw AccountQueryError.invalid }
        if response.statusCode == 401 { throw AccountQueryError.unauthorized }
        guard accepted.contains(response.statusCode) else { throw AccountQueryError.invalid }
        var data = Data()
        for try await byte in stream {
            guard data.count < 65536 else { throw AccountQueryError.invalid }
            data.append(byte)
        }
        return data
    }

    func issue(_ credential: AccessAccountCredential, contextID: UUID, mode: AccessNodeMode,
               periodID: String) async throws -> AccessNodeLease {
        let url = endpoint.deletingLastPathComponent().appendingPathComponent("node-credentials")
        let context = contextID.uuidString.lowercased()
        let body = try JSONEncoder().encode(["contextId": context, "mode": mode.rawValue])
        let data = try await request(credential, url: url, method: "POST", body: body, accepted: [200, 201])
        let lease = try JSONDecoder().decode(AccessNodeLease.self, from: data)
        try lease.validate(account: credential.accountID, period: periodID, context: context, mode: mode)
        return lease
    }

    func renew(_ credential: AccessAccountCredential, lease: AccessNodeLease) async throws -> AccessNodeLease {
        let url = endpoint.deletingLastPathComponent().appendingPathComponent("node-credentials")
            .appendingPathComponent(lease.credentialId).appendingPathComponent("renew")
        let body = try JSONEncoder().encode(["contextId": lease.contextId, "mode": lease.mode.rawValue])
        let data = try await request(credential, url: url, method: "POST", body: body, accepted: [200])
        return try lease.renewed(with: data)
    }

    func revoke(_ credential: AccessAccountCredential, lease: AccessNodeLease) async throws {
        let url = endpoint.deletingLastPathComponent().appendingPathComponent("node-credentials")
            .appendingPathComponent(lease.credentialId)
        _ = try await request(credential, url: url, method: "DELETE", accepted: [200, 204, 404])
    }
}

enum AccessNodeMode: String, Decodable, Sendable { case regular, `private` }

/// Native-only lease. Never serialize it into a rule, diagnostic or website-facing value.
struct AccessNodeLease: Decodable, Sendable {
    let accountId, periodId, credentialId, contextId, host, username, password: String
    let mode: AccessNodeMode
    let port: UInt16
    private(set) var expiresAt: Int64

    func renewed(with data: Data, now: Date = Date()) throws -> Self {
        struct Renewal: Decodable {
            let accountId, periodId, credentialId, contextId: String
            let mode: AccessNodeMode
            let expiresAt: Int64
        }
        let reply = try JSONDecoder().decode(Renewal.self, from: data)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        guard reply.accountId == accountId, reply.periodId == periodId, reply.credentialId == credentialId,
              reply.contextId == contextId, reply.mode == mode, reply.expiresAt > expiresAt,
              expiresAt > nowMs else { throw AccountQueryError.invalid }
        var renewed = self
        renewed.expiresAt = reply.expiresAt
        return renewed
    }

    func validate(account: String, period: String, context: String, mode expectedMode: AccessNodeMode,
                  now: Date = Date()) throws {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard accountId == account, periodId == period, contextId == context, mode == expectedMode,
              !credentialId.isEmpty, credentialId.utf8.count <= 256, credentialId == username,
              credentialId.unicodeScalars.allSatisfy(safe.contains),
              !password.isEmpty, password.utf8.count <= 512, password.utf8.allSatisfy({ (33...126).contains($0) }),
              port > 0, !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                  (48...57).contains($0) || [45, 46, 58].contains($0) }),
              expiresAt > Int64(now.timeIntervalSince1970 * 1000) else { throw AccountQueryError.invalid }
    }
}
