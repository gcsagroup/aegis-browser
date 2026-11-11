import Combine
import Foundation
import Security

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

/// Application-wide current identity. Every refresh, switch and sign-out invalidates earlier responses.
@MainActor
final class AccessAccountSession: ObservableObject {
    enum State: Equatable { case signedOut, loading, unavailable, ready(AccessAccountEntitlement) }
    @Published private(set) var state: State = .signedOut
    private let client: AccessAccountClient?
    private let keychain: AccessAccountKeychain
    private let fetch: @Sendable (AccessAccountClient, AccessAccountCredential) async throws -> AccessAccountEntitlement
    private var generation = UUID()
    private var task: Task<Void, Never>?

    init(client: AccessAccountClient?, keychain: AccessAccountKeychain = .init(),
         fetch: @escaping @Sendable (AccessAccountClient, AccessAccountCredential) async throws -> AccessAccountEntitlement = { try await $0.read($1) }) {
        self.client = client
        self.keychain = keychain
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
        generation = UUID()
        task?.cancel()
        task = nil
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
        suspend()
        do {
            guard let credential = try keychain.read() else { return nil }
            guard let client, credential.valid, client.endpoint.absoluteString == credential.endpoint else {
                throw AccountQueryError.invalid
            }
            let generation = generation
            state = .loading
            task = Task {
                do {
                    let result = try await fetch(client, credential)
                    guard self.generation == generation else { return }
                    guard try keychain.read() == credential else { state = .unavailable; return }
                    try result.validate(for: credential.accountID)
                    state = .ready(result)
                } catch {
                    guard self.generation == generation else { return }
                    if case AccountQueryError.unauthorized = error,
                       (try? keychain.read()) == credential { signOut() }
                    else { state = .unavailable }
                }
            }
        } catch { state = .unavailable }
        return task
    }
}
