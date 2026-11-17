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
              expectedQuotaBytes > 0, expectedQuotaBytes <= UInt64(Int64.max),
              ["daily", "never"].contains(trafficReset)
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
    var permitsConnection: Bool {
        enabled && remainingBytes > 0 && (expire == 0 || TimeInterval(expire) > Date.now.timeIntervalSince1970)
    }
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
    /// Only the signed private descriptor chooses the origin. Ignore URLs in the info reply.
    static func nodes(_ configuration: AccessSubscriptionConfiguration, userID: String,
                      sessionConfiguration settings: URLSessionConfiguration = .ephemeral) async throws -> [AccessRealityVisionParameters] {
        try configuration.validateEndpoint()
        guard var parts = URLComponents(url: configuration.subscriptionInfoURL, resolvingAgainstBaseURL: false) else {
            throw AccessSubscriptionQueryError.invalid
        }
        parts.query = nil
        guard let url = parts.url else { throw AccessSubscriptionQueryError.invalid }
        let data = try await request(url, accept: "text/plain", settings: settings)
        return try parseNodes(data, userID: userID)
    }

    static func parseNodes(_ data: Data, userID: String) throws -> [AccessRealityVisionParameters] {
        guard data.count <= 65_536, UUID(uuidString: userID) != nil else { throw AccessSubscriptionQueryError.invalid }
        let compact = data.filter { ![9, 10, 13, 32].contains($0) }
        let decoded = Data(base64Encoded: compact) ?? data
        guard let text = String(data: decoded, encoding: .utf8) else { throw AccessSubscriptionQueryError.invalid }
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count <= 128 else { throw AccessSubscriptionQueryError.invalid }
        var nodes: [AccessRealityVisionParameters] = []
        for line in lines {
            // The existing iOS core admits Reality/Vision only. Other protocols are not candidates.
            guard line.lowercased().hasPrefix("vless://"),
                  let node = try? AccessLocalV2RayConfigLoader.parseShareURI(String(line)),
                  node.userID == userID.lowercased() else { continue }
            if !nodes.contains(node) { nodes.append(node) }
        }
        guard !nodes.isEmpty else { throw AccessSubscriptionQueryError.unavailable }
        return nodes
    }

    static func read(_ configuration: AccessSubscriptionConfiguration,
                     sessionConfiguration settings: URLSessionConfiguration = .ephemeral) async throws -> AccessSubscriptionUsage {
        try configuration.validateEndpoint()
        let data = try await request(configuration.subscriptionInfoURL, accept: "application/json", settings: settings)
        let usage = try JSONDecoder().decode(AccessSubscriptionUsage.self, from: data)
        try usage.validate(for: configuration)
        return usage
    }

    private static func request(_ url: URL, accept: String, settings: URLSessionConfiguration) async throws -> Data {
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        settings.urlCredentialStorage = nil
        settings.timeoutIntervalForRequest = 10
        settings.timeoutIntervalForResource = 15
        let session = URLSession(configuration: settings, delegate: SubscriptionRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Aegis-Alpha/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == url,
              accept != "application/json" || response.mimeType == "application/json" else { throw AccessSubscriptionQueryError.unavailable }
        // The info response also contains subscription URLs. Never log or persist it.
        var data = Data()
        for try await byte in bytes {
            guard data.count < 65_536 else { throw AccessSubscriptionQueryError.invalid }
            data.append(byte)
        }
        return data
    }
}

@MainActor
final class AccessSubscriptionUsageSession: ObservableObject {
    let isSelected: Bool
    let managesConnections: Bool
    private let configuration: AccessSubscriptionConfiguration?
    private let nodeUserID: String?
    private let fetchNodes: @Sendable (AccessSubscriptionConfiguration, String) async throws -> [AccessRealityVisionParameters]
    private var nodes: [AccessRealityVisionParameters] = []
    private var selectedNode: AccessRealityVisionParameters?
    @Published private(set) var availableConnectionCount = 0
    @Published private(set) var connectionsUnavailable = false
    private let fetch: @Sendable (AccessSubscriptionConfiguration) async throws -> AccessSubscriptionUsage
    @Published private(set) var snapshot: AccessSubscriptionUsage?
    @Published private(set) var receivedAt: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var unavailable = false
    private var active = false
    private var generation = UUID()
    private var successfulGeneration: UUID?
    private var receivedUptime: TimeInterval?
    private var task: Task<Void, Never>?
    lazy var usageRefresh = AccessAccountUsageRefreshCoordinator(refresh: { [weak self] in self?.refresh() })
    var isStale: Bool {
        guard let receivedUptime else { return true }
        let age = ProcessInfo.processInfo.systemUptime - receivedUptime
        return unavailable || age < 0 || age > 15
    }

    convenience init(isSelected: Bool, configuration: AccessSubscriptionConfiguration?,
                     fetch: @escaping @Sendable (AccessSubscriptionConfiguration) async throws -> AccessSubscriptionUsage = { try await AccessSubscriptionClient.read($0) }) {
        self.init(isSelected: isSelected, configuration: configuration, managesConnections: false, fetch: fetch)
    }

    init(isSelected: Bool, configuration: AccessSubscriptionConfiguration?, managesConnections: Bool,
         nodeUserID: String? = nil,
         fetchNodes: @escaping @Sendable (AccessSubscriptionConfiguration, String) async throws -> [AccessRealityVisionParameters] = { try await AccessSubscriptionClient.nodes($0, userID: $1) },
         fetch: @escaping @Sendable (AccessSubscriptionConfiguration) async throws -> AccessSubscriptionUsage = { try await AccessSubscriptionClient.read($0) }) {
        self.isSelected = isSelected
        self.configuration = configuration
        self.managesConnections = managesConnections
        self.nodeUserID = nodeUserID
        self.fetchNodes = fetchNodes
        self.fetch = fetch
    }

    static func product(bundle: Bundle = .main) -> AccessSubscriptionUsageSession {
        let channel = bundle.object(forInfoDictionaryKey: "AegisAccessReleaseChannel") as? String
        guard ["dev", "alpha", "beta"].contains(channel ?? ""),
              let path = AccessLocalV2RayConfigLoader.productPath(bundle: bundle) else {
            return .init(isSelected: false, configuration: nil)
        }
        let config: AccessSubscriptionConfiguration?
        var userID: String?
        do {
            guard let resource = bundle.url(forResource: "AegisPrivateTestSubscription", withExtension: "json") else {
                throw AccessSubscriptionQueryError.invalid
            }
            let data = try Data(contentsOf: resource)
            guard data.count <= 8192 else { throw AccessSubscriptionQueryError.invalid }
            let decoded = try JSONDecoder().decode(AccessSubscriptionConfiguration.self, from: data)
            try decoded.validate(node: Data(contentsOf: URL(fileURLWithPath: path)))
            userID = try AccessLocalV2RayConfigLoader.load(path: path).parameters.userID
            config = decoded
        } catch { config = nil }
        return .init(isSelected: true, configuration: config, managesConnections: true, nodeUserID: userID)
    }

    /// No static-node fallback: the account's current allowance and subscription must both succeed.
    func connectionParameters() async throws -> AccessRealityVisionParameters {
        guard active, managesConnections else { throw AccessSubscriptionQueryError.unavailable }
        guard let request = refresh() else { throw AccessSubscriptionQueryError.unavailable }
        let requestedGeneration = generation
        await request.value
        try Task.checkCancellation()
        guard generation == requestedGeneration, successfulGeneration == requestedGeneration,
              active, !unavailable, let usage = snapshot, usage.permitsConnection,
              let node = nodes.first else { throw AccessSubscriptionQueryError.unavailable }
        selectedNode = node
        return node
    }

    var permitsExistingConnection: Bool {
        !unavailable && selectedNode.map(nodes.contains) == true && snapshot?.permitsConnection == true
    }

    func setActive(_ value: Bool) {
        active = value && isSelected
        if !active {
            generation = UUID()
            task?.cancel(); task = nil
            isRefreshing = false
            // Suspending polling (including transient scene inactivity) is not revocation.
            // Keep the last validated connection; expiry and the next active read still apply.
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
                var candidates: [AccessRealityVisionParameters] = []
                if self?.managesConnections == true, value.permitsConnection, let userID = self?.nodeUserID {
                    // Node failure leaves valid counters visible but never reuses an old connection list.
                    candidates = (try? await self?.fetchNodes(configuration, userID)) ?? []
                    candidates = candidates.filter { $0.userID == userID.lowercased() }
                }
                guard let self, self.active, self.generation == token, !Task.isCancelled else { return }
                self.nodes = candidates
                self.availableConnectionCount = candidates.count
                self.connectionsUnavailable = self.managesConnections && value.permitsConnection && candidates.isEmpty
                self.snapshot = value
                self.receivedAt = Date()
                self.receivedUptime = ProcessInfo.processInfo.systemUptime
                self.unavailable = false
                self.successfulGeneration = token
                self.task = nil; self.isRefreshing = false
                self.usageRefresh.didComplete(succeeded: true)
            } catch {
                guard let self, self.active, self.generation == token, !Task.isCancelled else { return }
                self.unavailable = true
                self.nodes = []
                self.availableConnectionCount = 0
                self.connectionsUnavailable = true
                self.task = nil; self.isRefreshing = false
                self.usageRefresh.didComplete(succeeded: false)
            }
        }
        return task
    }
}
