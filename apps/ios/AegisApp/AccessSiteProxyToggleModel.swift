import AccessKit
import Foundation

/// Short intent-line ids. UI localizes; never conflate with connection copy.
enum AccessSiteProxyIntentStatusId: String, Equatable, Sendable {
    case noTrustedSite
    case offBrowserDefault
    case allowNotConnected
    case allowConnected
    case blockLocalRefuse
}

/// Connection status ids kept distinct from the product switch (A1-3).
enum AccessSiteProxyConnectionStatusId: String, Equatable, Sendable {
    case idle
    case connecting
    case ready
    case unavailable
}

/// Presentation snapshot for the current-page site-proxy toggle (P-iOS-3).
struct AccessSiteProxyToggleSnapshot: Equatable, Sendable {
    var hasTrustedSite: Bool = false
    var host: AccessSiteHost?
    var intent: AccessSiteIntent = .off
    var connection: AccessSiteSessionConnectionState = .idle
    /// Checked when intent == allow. Independent of connection readiness.
    var toggleOn: Bool = false
    /// False when the committed URL is not a trusted http(s) navigation host.
    var toggleEnabled: Bool = false
    var intentStatus: AccessSiteProxyIntentStatusId = .noTrustedSite
    var connectionStatus: AccessSiteProxyConnectionStatusId = .idle
    var failureReason: String?
}

/// Pure presentation helpers for the per-site Access proxy toggle.
///
/// Binds to the current navigation host only. Switch state comes from product
/// intent; connection health is a separate line and must not claim Access
/// success merely because the switch is on.
enum AccessSiteProxyToggleModel {
    /// Resolves an exact-host product key from the current navigation URL.
    /// Only http(s) with a host are admitted — internal pages are excluded.
    static func resolveTrustedHost(from url: URL?) -> AccessSiteHost? {
        guard let url else { return nil }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return nil
        }
        guard let host = url.host, !host.isEmpty else { return nil }
        return try? AccessSiteHost.normalize(host)
    }

    static func connectionStatus(
        _ connection: AccessSiteSessionConnectionState
    ) -> AccessSiteProxyConnectionStatusId {
        switch connection {
        case .idle: return .idle
        case .connecting: return .connecting
        case .ready: return .ready
        case .unavailable: return .unavailable
        }
    }

    static func intentStatus(
        intent: AccessSiteIntent,
        connection: AccessSiteSessionConnectionState
    ) -> AccessSiteProxyIntentStatusId {
        switch intent {
        case .off:
            return .offBrowserDefault
        case .block:
            return .blockLocalRefuse
        case .allow:
            return connection == .ready ? .allowConnected : .allowNotConnected
        }
    }

    /// Builds toggle state. Intent and connection stay independent inputs so
    /// enabling the switch never implies Access connectivity by itself.
    static func buildSnapshot(
        url: URL?,
        controller: AccessSiteSessionController
    ) -> AccessSiteProxyToggleSnapshot {
        var snapshot = AccessSiteProxyToggleSnapshot()
        guard let host = resolveTrustedHost(from: url) else {
            snapshot.intentStatus = .noTrustedSite
            snapshot.connectionStatus = .idle
            return snapshot
        }

        let session = controller.snapshot(for: host)
        snapshot.hasTrustedSite = true
        snapshot.host = host
        snapshot.intent = session.intent
        snapshot.connection = session.connectionState
        snapshot.toggleEnabled = true
        snapshot.toggleOn = session.intent == .allow
        snapshot.intentStatus = intentStatus(
            intent: session.intent,
            connection: session.connectionState
        )
        snapshot.connectionStatus = connectionStatus(session.connectionState)
        snapshot.failureReason = session.failureReason
        return snapshot
    }

    /// Product toggle → allow/off via the session controller.
    ///
    /// On enable failures the controller keeps intent=`allow` with
    /// connection=`unavailable` (readable) — never silent DIRECT success.
    @discardableResult
    static func applyToggle(
        enabled: Bool,
        host: AccessSiteHost,
        controller: AccessSiteSessionController
    ) -> AccessSiteProxyToggleSnapshot {
        if enabled {
            _ = try? controller.enable(host: host)
        } else {
            _ = try? controller.disable(host: host)
        }
        return buildSnapshot(
            url: URL(string: "https://\(host.rawValue)/"),
            controller: controller
        )
    }

    // MARK: - Copy (zh-Hans source keys; catalog can absorb later)

    static func intentLine(for status: AccessSiteProxyIntentStatusId) -> String {
        switch status {
        case .noTrustedSite:
            return "当前页不是可代理的网站"
        case .offBrowserDefault:
            return "未使用本服务代理 / 使用浏览器原有连接"
        case .allowNotConnected:
            return "本站代理已开启 · 连接尚未就绪"
        case .allowConnected:
            return "本站代理已开启"
        case .blockLocalRefuse:
            return "本站代理已本地拒绝"
        }
    }

    static func connectionLine(for status: AccessSiteProxyConnectionStatusId) -> String {
        switch status {
        case .idle:
            return "连接：空闲"
        case .connecting:
            return "连接：正在连接"
        case .ready:
            return "连接：已就绪"
        case .unavailable:
            return "连接：不可用"
        }
    }
}
