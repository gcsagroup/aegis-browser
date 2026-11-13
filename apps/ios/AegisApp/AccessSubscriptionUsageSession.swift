import AccessKit
import Combine
import CryptoKit
import Foundation

/// Internal node quota metadata, independent of paid-account authorization.
struct AccessSubscriptionConfiguration: Decodable, Sendable {
    let subscriptionInfoURL: URL
    let allowedTestClient: String
    let expectedQuotaBytes: UInt64
    let trafficReset: String
    let nodeSHA256: String

    func validateEndpoint() throws {
        guard let parts = URLComponents(url: subscriptionInfoURL, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.queryItems == [URLQueryItem(name: "format", value: "info")],
              !subscriptionInfoURL.lastPathComponent.isEmpty, parts.path != "/",
              !allowedTestClient.isEmpty, allowedTestClient.utf8.count <= 256,
              expectedQuotaBytes == 10_000_000_000, trafficReset == "daily"
        else { throw AccessSubscriptionQueryError.invalid }
    }

    func validate(node: Data) throws {
        try validateEndpoint()
        guard nodeSHA256 == SHA256.hash(data: node).map({ String(format: "%02x", $0) }).joined()
        else { throw AccessSubscriptionQueryError.invalid }
    }
}

struct AccessSubscriptionUsage: Decodable, Equatable, Sendable {
    let sId: String
    let emails: [String]
    let uploadByte, downloadByte, totalByte: UInt64
    let expire: UInt64
    let enabled: Bool

    func validate(for configuration: AccessSubscriptionConfiguration) throws {
        let (_, overflow) = uploadByte.addingReportingOverflow(downloadByte)
        guard sId == configuration.subscriptionInfoURL.lastPathComponent,
              emails == [configuration.allowedTestClient], totalByte == configuration.expectedQuotaBytes,
              !overflow, expire <= 253_402_300_799 else { throw AccessSubscriptionQueryError.invalid }
    }

    var usedBytes: UInt64 { uploadByte + downloadByte }
    var remainingBytes: UInt64 { totalByte > usedBytes ? totalByte - usedBytes : 0 }
}

enum AccessSubscriptionQueryError: Error { case invalid, unavailable }

private final class SubscriptionRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum AccessSubscriptionClient {
    static func read(_ configuration: AccessSubscriptionConfiguration,
                     sessionConfiguration settings: URLSessionConfiguration = .ephemeral) async throws -> AccessSubscriptionUsage {
        try configuration.validateEndpoint()
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        settings.urlCredentialStorage = nil
        settings.timeoutIntervalForRequest = 10
        settings.timeoutIntervalForResource = 15
        let session = URLSession(configuration: settings, delegate: SubscriptionRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: configuration.subscriptionInfoURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Aegis-Alpha/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == configuration.subscriptionInfoURL,
              response.mimeType == "application/json" else { throw AccessSubscriptionQueryError.unavailable }
        // The info response also contains subscription URLs. Never log or persist it.
        var data = Data()
        for try await byte in bytes {
            guard data.count < 65_536 else { throw AccessSubscriptionQueryError.invalid }
            data.append(byte)
        }
        let usage = try JSONDecoder().decode(AccessSubscriptionUsage.self, from: data)
        try usage.validate(for: configuration)
        return usage
    }
}

@MainActor
final class AccessSubscriptionUsageSession: ObservableObject {
    let isSelected: Bool
    private let configuration: AccessSubscriptionConfiguration?
    private let fetch: @Sendable (AccessSubscriptionConfiguration) async throws -> AccessSubscriptionUsage
    @Published private(set) var snapshot: AccessSubscriptionUsage?
    @Published private(set) var receivedAt: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var unavailable = false
    private var active = false
    private var generation = UUID()
    private var receivedUptime: TimeInterval?
    private var task: Task<Void, Never>?
    lazy var usageRefresh = AccessAccountUsageRefreshCoordinator(refresh: { [weak self] in self?.refresh() })
    var isStale: Bool {
        guard let receivedUptime else { return true }
        let age = ProcessInfo.processInfo.systemUptime - receivedUptime
        return unavailable || age < 0 || age > 15
    }

    init(isSelected: Bool, configuration: AccessSubscriptionConfiguration?,
         fetch: @escaping @Sendable (AccessSubscriptionConfiguration) async throws -> AccessSubscriptionUsage = { try await AccessSubscriptionClient.read($0) }) {
        self.isSelected = isSelected
        self.configuration = configuration
        self.fetch = fetch
    }

    static func product(bundle: Bundle = .main) -> AccessSubscriptionUsageSession {
        let channel = bundle.object(forInfoDictionaryKey: "AegisAccessReleaseChannel") as? String
        guard ["dev", "alpha", "beta"].contains(channel ?? ""),
              let path = AccessLocalV2RayConfigLoader.productPath(bundle: bundle) else {
            return .init(isSelected: false, configuration: nil)
        }
        let config: AccessSubscriptionConfiguration?
        do {
            guard let resource = bundle.url(forResource: "AegisPrivateTestSubscription", withExtension: "json") else {
                throw AccessSubscriptionQueryError.invalid
            }
            let data = try Data(contentsOf: resource)
            guard data.count <= 8192 else { throw AccessSubscriptionQueryError.invalid }
            let decoded = try JSONDecoder().decode(AccessSubscriptionConfiguration.self, from: data)
            try decoded.validate(node: Data(contentsOf: URL(fileURLWithPath: path)))
            config = decoded
        } catch { config = nil }
        return .init(isSelected: true, configuration: config)
    }

    func setActive(_ value: Bool) {
        active = value && isSelected
        if !active {
            generation = UUID()
            task?.cancel(); task = nil
            isRefreshing = false
        }
        usageRefresh.setActive(active)
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard active else { return nil }
        if let task { return task }
        guard let configuration else { unavailable = true; return nil }
        let token = UUID(); generation = token
        let fetch = fetch
        isRefreshing = true
        task = Task { [weak self] in
            do {
                let value = try await fetch(configuration)
                try value.validate(for: configuration)
                guard let self, self.active, self.generation == token, !Task.isCancelled else { return }
                self.snapshot = value
                self.receivedAt = Date()
                self.receivedUptime = ProcessInfo.processInfo.systemUptime
                self.unavailable = false
                self.task = nil; self.isRefreshing = false
                self.usageRefresh.didComplete(succeeded: true)
            } catch {
                guard let self, self.active, self.generation == token, !Task.isCancelled else { return }
                self.unavailable = true
                self.task = nil; self.isRefreshing = false
                self.usageRefresh.didComplete(succeeded: false)
            }
        }
        return task
    }
}
