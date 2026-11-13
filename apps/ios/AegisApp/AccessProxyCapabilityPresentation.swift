import AccessKit
import CryptoKit
import Foundation

/// Display-only projection. Never retains credentials, a source path or a share URI.
struct AccessProxyCapabilityPresentation: Equatable, Sendable {
    enum PageRoute: Equatable, Sendable { case notAttached, localEntryReady, unavailable }
    let configuredNodeID: String?
    let pageRoute: PageRoute

    static func make(nodeID: String?, attached: Bool, entryReady: Bool) -> Self {
        Self(configuredNodeID: nodeID,
             pageRoute: !attached ? .notAttached : entryReady ? .localEntryReady : .unavailable)
    }

    /// A non-authoritative endpoint label, not a credential fingerprint or proof of connection.
    static func nodeID(address: String, port: UInt16) -> String {
        let input = Data("\(address.lowercased())\n\(port)".utf8)
        return SHA256.hash(data: input).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func configuredNodeID() -> String? {
        guard let path = AccessLocalV2RayConfigLoader.productPath(),
              let config = try? AccessLocalV2RayConfigLoader.load(path: path) else { return nil }
        return nodeID(address: config.parameters.address, port: config.parameters.port)
    }

    var routeText: LocalizedStringResource {
        switch pageRoute {
        case .notAttached: return "当前页面尚未接入代理"
        case .localEntryReady: return "本地代理入口已就绪；远端连接未验证"
        case .unavailable: return "代理入口不可用；未切回原连接"
        }
    }
}
