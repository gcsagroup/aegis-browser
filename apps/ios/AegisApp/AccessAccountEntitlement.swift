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

    func validate(for account: String) throws {
        guard entitlementAccountId == account else { throw AccountQueryError.invalid }
        let raw = [quotaBytes, uploadedBytes, downloadedBytes, usedBytes, remainingBytes]
        if status == .notSubscribed {
            guard raw.allSatisfy({ $0 == nil }), planId == nil, periodId == nil, periodStart == nil,
                  periodEnd == nil, expiresAt == nil, receivedAt == nil, measuredAt == nil,
                  snapshotAgeMs == nil, freshness == nil else { throw AccountQueryError.invalid }
            return
        }
        guard let planId, !planId.isEmpty, let periodId, !periodId.isEmpty,
              let periodStart, let periodEnd, periodStart >= 0, periodEnd > periodStart,
              let expiresAt, expiresAt > 0, let receivedAt, receivedAt >= periodStart else {
            throw AccountQueryError.invalid
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
        guard credential.endpoint == endpoint.absoluteString, credential.valid else { throw AccountQueryError.invalid }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config, delegate: AccountRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == endpoint else { throw AccountQueryError.invalid }
        if response.statusCode == 401 { throw AccountQueryError.unauthorized }
        guard response.statusCode == 200 else { throw AccountQueryError.invalid }
        var data = Data()
        for try await byte in stream {
            guard data.count < 65536 else { throw AccountQueryError.invalid }
            data.append(byte)
        }
        let result = try JSONDecoder().decode(AccessAccountEntitlement.self, from: data)
        try result.validate(for: credential.accountID)
        return result
    }
}
