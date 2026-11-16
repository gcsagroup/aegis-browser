import AccessKit
import BrowserKit
import Foundation
import Darwin

enum AccessLocalSite {
    case loopback, localNetwork

    /// Classify literal addresses and local names without resolving the destination.
    static func classify(_ rawHost: String) -> Self? {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host == "localhost" || host.hasSuffix(".localhost") { return .loopback }
        if host.hasSuffix(".local") || host == "home.arpa" || host.hasSuffix(".home.arpa") { return .localNetwork }
        var v4 = in_addr()
        if inet_aton(host, &v4) == 1 { return ipv4Scope(UInt32(bigEndian: v4.s_addr)) }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return host.contains(".") ? nil : .localNetwork }
        return withUnsafeBytes(of: v6) { bytes in
            if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 { return .loopback }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
                return ipv4Scope(bytes.suffix(4).reduce(0) { ($0 << 8) | UInt32($1) })
            }
            if bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) {
                return .localNetwork
            }
            return nil
        }
    }

    private static func ipv4Scope(_ address: UInt32) -> Self? {
        if address >> 24 == 127 { return .loopback }
        if address >> 24 == 10 || address >> 20 == 0xac1 ||
            address >> 16 == 0xc0a8 || address >> 16 == 0xa9fe { return .localNetwork }
        return nil
    }

}

enum AccessSiteDisplayName {
    static func localLabel(for rawHost: String) -> LocalizedStringResource? {
        switch AccessLocalSite.classify(rawHost) {
        case .loopback: return "本机页面"
        case .localNetwork: return "局域网网站"
        case nil: return nil
        }
    }

    static func title(_ host: String?) -> String {
        guard let host, !host.isEmpty else { return AegisLocalization.string("当前网站") }
        return localLabel(for: host).map { AegisLocalization.string($0) } ?? host
    }
}

/// Short intent-line ids. UI localizes; never conflate with connection copy.
enum AccessSiteProxyIntentStatusId: String, Equatable, Sendable {
    case noTrustedSite
    case offBrowserDefault
    case automaticConnected
    case automaticUnavailable
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
    var attachment: AccessProxyAttachment = .notAttached
    /// 「本站打不开时自动重试」. Distinct from the explicit whole-page proxy intent.
    var autoRecoveryEnabled: Bool = false
    var autoRecoveryLine: String?
    /// DEV/Alpha read-only exact-host members. Empty on Beta/Release.
    var debugMemberHosts: [String] = []
    /// DEV/Alpha probe suggestion lines. Never auto-expands authorization.
    var probeSuggestionLines: [String] = []
    var probeBusy: Bool = false
    var showsDebugSiteGroupDetails: Bool = false
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
        guard let host = BrowserAccessDownload.canonicalHost(of: url) else { return nil }
        return try? AccessSiteHost(host)
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
        connection: AccessSiteSessionConnectionState,
        attachment: AccessProxyAttachment = .notAttached
    ) -> AccessSiteProxyIntentStatusId {
        switch intent {
        case .off:
            switch attachment {
            case .ready: return .automaticConnected
            case .attachedUnavailable: return .automaticUnavailable
            case .notAttached: return .offBrowserDefault
            }
        case .block:
            return .blockLocalRefuse
        case .allow:
            // Allow intent stays distinct from connection health (incl. P-iOS-5
            // fault: unavailable / connecting must not read as Access ready).
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

    // MARK: - Localized copy (zh-Hans source keys)

    static func intentLine(for status: AccessSiteProxyIntentStatusId) -> String {
        switch status {
        case .noTrustedSite:
            return "此页面暂不支持"
        case .offBrowserDefault:
            return "使用浏览器原有连接"
        case .automaticConnected:
            return "自动重试已连接"
        case .automaticUnavailable:
            return "自动重试连接不可用"
        case .allowNotConnected:
            return "已开启，等待连接"
        case .allowConnected:
            return "已为本站开启"
        case .blockLocalRefuse:
            return "已在本机停用"
        }
    }

    static func connectionLine(for status: AccessSiteProxyConnectionStatusId) -> String {
        switch status {
        case .idle:
            return "使用浏览器原有连接"
        case .connecting:
            return "正在准备连接"
        case .ready:
            return "服务连接已就绪"
        case .unavailable:
            return "连接暂不可用"
        }
    }

    static func attachmentLine(for attachment: AccessProxyAttachment, intent: AccessSiteIntent) -> String? {
        switch attachment {
        case .notAttached:
            guard intent == .allow else { return nil }
            return "当前页面仍使用原连接"
        case .attachedUnavailable:
            // Bound auto-recovery may have no manual allow intent; still explain the fault.
            return "连接失败，未切回原连接"
        case .ready:
            return nil
        }
    }
}
