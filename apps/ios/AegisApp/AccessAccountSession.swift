import Combine
import Foundation
import Security
import Network
import BrowserKit
import AegisPolicyKit

struct AccessAccountCredential: Codable, Equatable, Sendable {
    let accountID, token, endpoint: String
    var valid: Bool {
        !accountID.isEmpty && (1...256).contains(token.utf8.count) &&
        token.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) ||
            (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
}

struct AccessAccountKeychain {
    let service: String
    init(service: String = "com.gcsa.aegis.ios.access-account.v1") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "current", kSecAttrSynchronizable as String: false]
    }

    func read() throws -> AccessAccountCredential? {
        var request = query
        request[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw AccountQueryError.invalid }
        return try JSONDecoder().decode(AccessAccountCredential.self, from: data)
    }

    func save(_ credential: AccessAccountCredential?) throws {
        guard let credential else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountQueryError.invalid }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(credential),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, value in value } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AccountQueryError.invalid }
    }
}

/// Application-wide identity with single-flight reads. Identity changes invalidate earlier responses.
@MainActor
final class AccessAccountSession: ObservableObject {
    enum State: Equatable { case signedOut, loading, unavailable, ready(AccessAccountEntitlement) }
    @Published private(set) var state: State = .signedOut
    @Published private(set) var lastSnapshot: AccessAccountEntitlement?
    /// Receipt anchor only; never a substitute for the server's measurement watermark.
    @Published private(set) var snapshotReceivedUptime: TimeInterval?
    /// Request start conservatively includes network and MainActor delivery time.
    /// Invalid or regressing timing makes freshness unavailable, never newer.
    @Published private(set) var snapshotFreshnessAnchorUptime: TimeInterval?
    @Published private(set) var isRefreshing = false
    /// Query validity only. The UI must separately age the server's freshness metadata.
    var snapshotIsStale: Bool {
        guard lastSnapshot != nil else { return false }
        if case .ready = state { return false }
        return true
    }
    var supportsAccountAuthorization: Bool { client != nil }
    private let client: AccessAccountClient?
    private let keychain: AccessAccountKeychain
    private let uptime: () -> TimeInterval
    private let fetch: @Sendable (AccessAccountClient, AccessAccountCredential) async throws -> AccessAccountEntitlement
    private var grants: [UUID: AccessTabGrant] = [:]
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var currentCredential: AccessAccountCredential?
    lazy var usageRefresh = AccessAccountUsageRefreshCoordinator(refresh: { [weak self] in
        self?.refresh()
    })

    convenience init(client: AccessAccountClient?, keychain: AccessAccountKeychain = .init(),
                     fetch: @escaping @Sendable (AccessAccountClient, AccessAccountCredential) async throws -> AccessAccountEntitlement = { try await $0.read($1) }) {
        self.init(client: client, keychain: keychain,
                  uptime: { ProcessInfo.processInfo.systemUptime }, fetch: fetch)
    }

    init(client: AccessAccountClient?, keychain: AccessAccountKeychain = .init(),
         uptime: @escaping () -> TimeInterval,
         fetch: @escaping @Sendable (AccessAccountClient, AccessAccountCredential) async throws -> AccessAccountEntitlement = { try await $0.read($1) }) {
        self.client = client
        self.keychain = keychain
        self.uptime = uptime
        self.fetch = fetch
    }

    static func product(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment,
                        keychain: AccessAccountKeychain = .init()) -> AccessAccountSession {
        let origin = bundle.object(forInfoDictionaryKey: "AegisAccountServiceOrigin") as? String ?? ""
#if DEBUG && targetEnvironment(simulator)
        if let controlledOrigin = environment["AEGIS_ACCOUNT_SIM_ORIGIN"] {
            let candidate = try? AccessAccountClient(origin: controlledOrigin, allowSimulatorLoopback: true)
            let client = candidate?.endpoint.host == "127.0.0.1" ? candidate : nil
            let session = AccessAccountSession(client: client, keychain: keychain)
            // Only a trusted local simulator launcher can supply these inputs.
            if environment["AEGIS_ACCOUNT_SIM_ACTION"] == "clear" { session.signOut() }
            if environment["AEGIS_ACCOUNT_SIM_ACTION"] == "bind" {
                do {
                    try session.stage(accountID: environment["AEGIS_ACCOUNT_SIM_ID"] ?? "",
                                      token: environment["AEGIS_ACCOUNT_SIM_TOKEN"] ?? "")
                } catch { session.signOut() }
            }
            return session
        }
#endif
        return AccessAccountSession(client: try? AccessAccountClient(origin: origin), keychain: keychain)
    }

    func suspend() {
        usageRefresh.identityDidChange()
        for grant in grants.values { grant.invalidate(client: client) }
        generation = UUID()
        task?.cancel()
        task = nil
        isRefreshing = false
        currentCredential = nil
        lastSnapshot = nil
        snapshotReceivedUptime = nil
        snapshotFreshnessAnchorUptime = nil
        state = .signedOut
    }

    private func stage(accountID: String, token: String) throws {
        guard let client else { throw AccountQueryError.invalid }
        let credential = AccessAccountCredential(accountID: accountID, token: token, endpoint: client.endpoint.absoluteString)
        guard credential.valid else { throw AccountQueryError.invalid }
        try keychain.save(credential)
    }

    @discardableResult
    func bind(accountID: String, token: String) -> Task<Void, Never>? {
        suspend()
        do {
            try stage(accountID: accountID, token: token)
            return refresh()
        } catch {
            signOut()
            state = .unavailable
            return nil
        }
    }

    func signOut() {
        suspend()
        do { try keychain.save(nil) } catch { state = .unavailable }
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        do {
            guard let credential = try keychain.read() else {
                // Repeated signed-out quota reads do not end an independent private grant.
                if currentCredential != nil { suspend() }
                else { state = .signedOut }
                return nil
            }
            guard let client, credential.valid, client.endpoint.absoluteString == credential.endpoint else {
                throw AccountQueryError.invalid
            }
            if currentCredential != credential {
                suspend()
                currentCredential = credential
            }
            // A slow request survives repeated foreground/UI refresh triggers.
            if let task { return task }
            generation = UUID()
            let generation = generation
            let requestStartedUptime = uptime()
            state = .loading
            isRefreshing = true
            task = Task {
                defer {
                    // A cancelled old read must not clear a newer identity's in-flight task.
                    if self.generation == generation {
                        self.task = nil
                        self.isRefreshing = false
                    }
                }
                do {
                    let result = try await fetch(client, credential)
                    guard self.generation == generation else { return }
                    guard revalidateIdentity(credential) else { return }
                    try result.validate(for: credential.accountID)
                    lastSnapshot = result
                    let receivedUptime = uptime()
                    snapshotReceivedUptime = receivedUptime
                    snapshotFreshnessAnchorUptime = requestStartedUptime.isFinite && requestStartedUptime >= 0
                        && receivedUptime.isFinite && receivedUptime >= requestStartedUptime
                        ? requestStartedUptime : nil
                    state = .ready(result)
                    usageRefresh.didComplete(succeeded: true)
                } catch {
                    guard self.generation == generation else { return }
                    guard revalidateIdentity(credential) else { return }
                    if case AccountQueryError.unauthorized = error { signOut() }
                    else {
                        state = .unavailable
                        usageRefresh.didComplete(succeeded: false)
                    }
                }
            }
        } catch {
            // Unknown Keychain identity is not an HTTP outage: discard every old number.
            suspend()
            state = .unavailable
            usageRefresh.didComplete(succeeded: false)
        }
        return task
    }

    private func revalidateIdentity(_ credential: AccessAccountCredential) -> Bool {
        do {
            guard try keychain.read() == credential else {
                suspend()
                state = .unavailable
                return false
            }
            return true
        } catch {
            suspend()
            state = .unavailable
            return false
        }
    }
}

/// An explicitly selected tab/site. Only the owning native transfer receives this transport.
@MainActor
private final class AccessTabGrant {
    let mode: AccessNodeMode
    let host: String
    var privateCredential: AccessAccountCredential?
    var lease: AccessNodeLease?
    var credential: AccessAccountCredential?
    var transfer: AccessDownloadTransport?
    var expiry: Task<Void, Never>?
    var renewal: Task<Void, Never>?
    var epoch = UUID()
    var preparation: Task<AccessNodeLease, Error>?

    init(host: String, mode: AccessNodeMode, privateCredential: AccessAccountCredential?) {
        self.host = host
        self.mode = mode
        self.privateCredential = privateCredential
    }

    func invalidate(client: AccessAccountClient?, clearAuthorization: Bool = true) {
        epoch = UUID()
        preparation = nil
        transfer?.invalidate()
        transfer = nil
        expiry?.cancel()
        expiry = nil
        renewal?.cancel()
        renewal = nil
        if let client, let credential, let lease {
            Task { try? await client.revoke(credential, lease: lease) }
        }
        lease = nil
        credential = nil
        if clearAuthorization { privateCredential = nil }
    }
}

extension AccessAccountSession {
    @discardableResult
    func selectProxy(for tab: UUID, host: String, privateMode: Bool, privateAccount: String = "",
                     privateToken: String = "") -> Task<Bool, Never> {
        closeProxy(for: tab)
        guard let host = RegisteredDomain.normalizedHost(host) else { return Task { false } }
        let grant = AccessTabGrant(host: host, mode: privateMode ? .private : .regular,
            privateCredential: privateMode ? client.map {
                AccessAccountCredential(accountID: privateAccount, token: privateToken, endpoint: $0.endpoint.absoluteString)
            } : nil)
        grants[tab] = grant
        let selectedEpoch = grant.epoch
        return Task {
            guard grants[tab] === grant, grant.epoch == selectedEpoch else { return false }
            do { _ = try await prepare(grant, tab: tab); return true }
            catch { return false }
        }
    }

    func closeProxy(for tab: UUID) { grants.removeValue(forKey: tab)?.invalidate(client: client) }

    func hasSelectedProxy(for tab: UUID, host: String) -> Bool {
        guard let host = RegisteredDomain.normalizedHost(host) else { return false }
        return grants[tab]?.host == host
    }

    private func prepare(_ grant: AccessTabGrant, tab: UUID) async throws -> AccessNodeLease {
        guard let client, grants[tab] === grant else { throw AccountQueryError.invalid }
        let account: AccessAccountCredential
        if grant.mode == .private {
            guard let supplied = grant.privateCredential, supplied.valid else { throw AccountQueryError.unauthorized }
            account = supplied
        } else {
            guard let current = try keychain.read(), current.valid else { throw AccountQueryError.unauthorized }
            account = current
        }
        if let lease = grant.lease, lease.expiresAt <= Int64(Date().timeIntervalSince1970 * 1000) || grant.credential != account {
            grant.invalidate(client: client, clearAuthorization: false)
        }
        let epoch = grant.epoch
        func current() throws -> Bool {
            guard self.grants[tab] === grant, grant.epoch == epoch else { return false }
            if grant.mode == .private { return true }
            return try keychain.read() == account
        }
        if let lease = grant.lease, grant.credential == account,
           lease.expiresAt > Int64(Date().timeIntervalSince1970 * 1000), try current() { return lease }
        if let preparation = grant.preparation { return try await preparation.value }
        let preparation = Task<AccessNodeLease, Error> {
            defer { if grant.epoch == epoch { grant.preparation = nil } }
            let entitlement = try await client.read(account)
            guard try current(), entitlement.status == .active, let period = entitlement.periodId else {
                throw AccountQueryError.unauthorized
            }
            // The server replaces grants for the same context. A late POST from
            // a previous epoch must never supersede a newer authorization.
            let lease = try await client.issue(account, contextID: epoch, mode: grant.mode, periodID: period)
            guard (try? current()) == true else {
                try? await client.revoke(account, lease: lease)
                throw AccountQueryError.unauthorized
            }
            grant.transfer?.invalidate()
            grant.transfer = nil
            grant.credential = account
            install(lease, on: grant, client: client)
            return lease
        }
        grant.preparation = preparation
        return try await preparation.value
    }

    private func install(_ lease: AccessNodeLease, on grant: AccessTabGrant, client: AccessAccountClient) {
        grant.lease = lease
        grant.expiry?.cancel()
        grant.expiry = Task { [weak grant] in
            let delay = max(0, lease.expiresAt - Int64(Date().timeIntervalSince1970 * 1000))
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let grant, grant.lease?.credentialId == lease.credentialId,
                  grant.lease?.expiresAt == lease.expiresAt else { return }
            grant.invalidate(client: client, clearAuthorization: false)
        }
    }

    private func renewWhileDownloading(_ grant: AccessTabGrant, tab: UUID) {
        guard let client, grant.renewal == nil, let account = grant.credential else { return }
        let epoch = grant.epoch
        func ownsCredential() throws -> Bool {
            if grant.mode == .private { return grant.privateCredential == account }
            return try keychain.read() == account
        }
        grant.renewal = Task { [weak self, weak grant] in
            guard let self, let grant else { return }
            defer { if grant.epoch == epoch { grant.renewal = nil } }
            while let lease = grant.lease, grant.epoch == epoch, grants[tab] === grant {
                let remaining = lease.expiresAt - Int64(Date().timeIntervalSince1970 * 1000)
                guard remaining > 0 else { return }
                do {
                    try await Task.sleep(for: .milliseconds(remaining / 2))
                    guard grant.transfer?.needsLease == true, grant.epoch == epoch,
                          try ownsCredential() else { return }
                    let renewed = try await client.renew(account, lease: lease)
                    guard !Task.isCancelled, grant.transfer?.needsLease == true,
                          grants[tab] === grant, grant.epoch == epoch,
                          grant.lease?.credentialId == lease.credentialId,
                          lease.expiresAt > Int64(Date().timeIntervalSince1970 * 1000),
                          try ownsCredential() else { return }
                    install(renewed, on: grant, client: client)
                } catch { return } // The independent expiry timer still closes the transport.
            }
        }
    }

    func startDownload(_ plan: DownloadPlan, captured: BrowserAccessDownload?,
                       browser: BrowserSession, downloads: DownloadManager) async throws -> UUID {
        if let captured {
            return try await startProtectedDownload(plan, context: captured, browser: browser, downloads: downloads)
        }
        return try downloads.start(plan)
    }

    @discardableResult
    func startProtectedDownload(_ plan: DownloadPlan, context: BrowserAccessDownload,
                                browser: BrowserSession, downloads: DownloadManager) async throws -> UUID {
        guard browser.ownsAccessDownload(context), plan.urls.count == 1, let requested = plan.urls.first,
              context.target.scheme?.lowercased() == "https", context.target.user == nil, context.target.password == nil,
              BrowserAccessDownload.canonicalHost(of: context.target) == context.host,
              requested.scheme?.lowercased() == "https", requested.user == nil, requested.password == nil,
              (requested.port ?? 443) == (context.target.port ?? 443),
              BrowserAccessDownload.canonicalHost(of: requested) == context.host,
              var components = URLComponents(url: requested, resolvingAgainstBaseURL: false) else {
            throw AccountQueryError.invalid
        }
        components.host = context.host
        guard let url = components.url else { throw AccountQueryError.invalid }
        let route = try await downloadSession(for: context.tab, privateMode: context.privateMode,
                                              target: url, downloadDelegate: downloads)
        guard browser.ownsAccessDownload(context) else { throw AccountQueryError.invalid }
        var normalized = plan
        normalized.urls = [url]
        return try downloads.start(normalized, accessSession: route)
    }

    /// Used only for a browser-originated same-site download. The ephemeral
    /// transfer's delegate refuses redirects before another destination is fetched.
    func downloadSession(for tab: UUID, privateMode: Bool, target: URL, downloadDelegate: DownloadManager)
        async throws -> AccessDownloadTransport {
        guard target.scheme == "https", target.user == nil, target.password == nil,
              let grant = grants[tab], BrowserAccessDownload.canonicalHost(of: target) == grant.host,
              grant.mode == (privateMode ? .private : .regular) else { throw AccountQueryError.invalid }
        let lease = try await prepare(grant, tab: tab)
        guard grants[tab] === grant, grant.lease?.credentialId == lease.credentialId else { throw AccountQueryError.invalid }
        if let transfer = grant.transfer { return transfer }
        guard let port = NWEndpoint.Port(rawValue: lease.port) else { throw AccountQueryError.invalid }
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .init(lease.host), port: port),
                                       tlsOptions: NWProtocolTLS.Options())
        proxy.allowFailover = false
        proxy.applyCredential(username: lease.username, password: lease.password)
        let config = URLSessionConfiguration.ephemeral
        config.proxyConfigurations = [proxy]
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.waitsForConnectivity = false
        let session = AccessDownloadTransport(configuration: config, targetHost: grant.host, downloads: downloadDelegate) { [weak self, weak grant] in
            if let grant { self?.renewWhileDownloading(grant, tab: tab) }
        }
        grant.transfer = session
        return session
    }
}
