import AccessKit
import Combine
import CryptoKit
import Foundation

/// A private Alpha package may provide a bounded list of preconfigured test
/// routes. The UI receives only ordinal and protocol; URI data stays here.
@MainActor
final class AccessAlphaNodeCatalogue: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id: Int
        let protocolName: String
        /// Routes may share a protocol; the nonsecret ordinal tells them apart without exposing the relay.
        var displayName: String { "\(id + 1) · \(protocolName)" }
    }

    private static let fingerprintKey = "access.alpha.nodes.fingerprint.v1"
    private static let selectionKey = "access.alpha.nodes.selection.v1"
    static let shared = product()

    let isConfigured: Bool
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var selectedIndex: Int?
    private let defaults: UserDefaults
    private var candidates: [AccessInternalTestNode] = []
    private var fingerprint = ""
    private var revision = UUID()
    private var activeRevision: UUID?
    fileprivate var selectionDidChange: (() -> Void)?

    var enablesWebsiteAcceleration: Bool { isConfigured && !entries.isEmpty }
    var routes: [AccessInternalTestNode] { candidates }

    static func product(bundle: Bundle = .main, defaults: UserDefaults = .standard) -> AccessAlphaNodeCatalogue {
        let channel = bundle.object(forInfoDictionaryKey: "AegisAccessReleaseChannel") as? String
        let profile = bundle.object(forInfoDictionaryKey: "AegisReleaseProfile") as? String
        let resource = bundle.url(forResource: "AegisAlphaTestNodes", withExtension: "json")
        // A present but unreadable resource remains configured and fails closed.
        let data = resource.map { (try? Data(contentsOf: $0, options: .mappedIfSafe)) ?? Data() }
        return .init(channel: channel, profile: profile, bundleID: bundle.bundleIdentifier, data: data, defaults: defaults)
    }

    init(channel: String?, profile: String?, bundleID: String?, data: Data?, defaults: UserDefaults) {
        self.defaults = defaults
        isConfigured = channel == "alpha" && profile == "alpha"
            && ["com.gcsa.aegis", "com.gcsa.aegis.alpha.internal"].contains(bundleID ?? "") && data != nil
        guard isConfigured, let data, data.count <= 131_500,
              let links = try? JSONDecoder().decode([String].self, from: data),
              (1...16).contains(links.count) else { return }
        var loaded: [AccessInternalTestNode] = []
        var identities = Set<UUID>()
        var displayed: [Entry] = []
        for (index, link) in links.enumerated() {
            guard link.utf8.count <= 8_192,
                  let node = try? AccessInternalTestNode.parseSingleShareURI(link),
                  let user = node.testSubscriptionIdentity,
                  !loaded.contains(where: { $0.isWireIdentical(to: node) }) else { return }
            if node.kind == .vless,
               Self.protocolName(URLComponents(string: link)?.queryItems ?? []) == nil { return }
            loaded.append(node)
            identities.insert(user)
            displayed.append(Entry(id: index, protocolName: node.protocolDisplayName))
        }
        // One quota descriptor cannot authorize unrelated test identities.
        guard identities.count == 1 else { return }
        fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        candidates = loaded
        entries = displayed
        if defaults.string(forKey: Self.fingerprintKey) == fingerprint,
           let stored = defaults.object(forKey: Self.selectionKey) as? Int, loaded.indices.contains(stored) {
            selectedIndex = stored
        } else {
            selectedIndex = 0
        }
    }

    private static func protocolName(_ items: [URLQueryItem]) -> String? {
        let type = items.first { $0.name == "type" }?.value
        let security = items.first { $0.name == "security" }?.value
        let flow = items.first { $0.name == "flow" }?.value
        switch (type, security, flow) {
        case ("tcp", "tls", "xtls-rprx-vision"): return "VLESS / TCP / TLS / Vision"
        case ("tcp", "reality", "xtls-rprx-vision"): return "VLESS / TCP / REALITY / Vision"
        case ("ws", "tls", nil): return "VLESS / WS / TLS"
        case ("grpc", "reality", nil): return "VLESS / gRPC / REALITY"
        default: return nil
        }
    }

    func select(_ index: Int) {
        guard candidates.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        revision = UUID()
        activeRevision = nil
        selectionDidChange?()
        defaults.set(fingerprint, forKey: Self.fingerprintKey)
        defaults.set(index, forKey: Self.selectionKey)
    }

    fileprivate func selected() throws -> (node: AccessInternalTestNode, revision: UUID) {
        guard let index = selectedIndex, candidates.indices.contains(index) else { throw AccessSubscriptionQueryError.unavailable }
        return (candidates[index], revision)
    }

    fileprivate func activate(_ expected: UUID) -> Bool {
        guard expected == revision else { return false }
        activeRevision = expected
        return true
    }

    fileprivate var isActiveSelection: Bool { activeRevision == revision }
}

/// The current product uses one signed 3X-UI subscription for both webpages and
/// usage. Alpha's selected test route still requires that same live allowance.
@MainActor
enum AccessThreeXUIWebEntry {
    static func makePublisher(
        for usage: AccessSubscriptionUsageSession,
        alphaNodes: AccessAlphaNodeCatalogue? = nil,
        lockData: Data? = nil,
        verifiedCore: (any AccessEmbeddedCoreControlling)? = nil,
        retireDocuments: @escaping @MainActor (String, @escaping @MainActor () -> Void) -> Void
    ) -> any AccessProxyEntryPublishing {
        guard usage.isSelected, usage.managesConnections else { return AccessFailClosedProxyEntryPublisher() }
        if let alphaNodes, alphaNodes.isConfigured {
            guard alphaNodes.enablesWebsiteAcceleration,
                  let core = verifiedCore ?? (try? AccessGoEmbeddedCore()) else {
                return AccessFailClosedProxyEntryPublisher()
            }
            let publisher = AccessEmbeddedProxyEntryFactory.makeInternalTestPublisher(
                lockData: lockData, verifiedCore: core,
                node: {
                    let candidate = try alphaNodes.selected()
                    try await usage.authorizeAlphaNode(candidate.node)
                    try Task.checkCancellation()
                    guard alphaNodes.activate(candidate.revision) else { throw AccessSubscriptionQueryError.unavailable }
                    return candidate.node
                },
                connectionAllowed: { alphaNodes.isActiveSelection && usage.permitsExistingConnection },
                retireDocuments: retireDocuments, transport: .http
            )
            if let publisher = publisher as? AccessProxyEntryPublisher {
                alphaNodes.selectionDidChange = { [weak publisher] in publisher?.closeCurrentGeneration() }
            }
            return publisher
        }
        return AccessEmbeddedProxyEntryFactory.makeProductPublisher(
            lockData: lockData,
            configPath: nil,
            verifiedCore: verifiedCore,
            parameters: { try await usage.connectionParameters() },
            connectionAllowed: { usage.permitsExistingConnection },
            retireDocuments: retireDocuments
        )
    }
}
