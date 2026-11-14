import Foundation

/// Product release channel for Access debug admission (P-iOS-4).
///
/// Mirrors macOS `version_info::Channel` with iOS Firebase channel names:
/// `dev` / `alpha` ≈ DEV / Canary; `release` ≈ Stable.
public enum AccessReleaseChannel: String, Sendable, Equatable, Hashable, CaseIterable {
    case unknown
    case dev
    case alpha
    case beta
    case release

    public static func parse(_ raw: String?) -> AccessReleaseChannel {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case AccessReleaseChannel.dev.rawValue:
            return .dev
        case AccessReleaseChannel.alpha.rawValue:
            return .alpha
        case AccessReleaseChannel.beta.rawValue:
            return .beta
        case AccessReleaseChannel.release.rawValue:
            return .release
        default:
            return .unknown
        }
    }
}

/// Whether the DEV ALLOW/BLOCK debug surface may register on this channel.
public enum AccessDevAllowBlockChannelAdmission: String, Sendable, Equatable {
    case admitted
    case notAdmitted
}

/// Explicit-host DEV panel actions. Intent-only; not a general rule editor.
public enum AccessDevAllowBlockAction: String, Sendable, Equatable {
    case allow
    case block
    case off
}

public enum AccessDevAllowBlockApplyStatus: String, Sendable, Equatable {
    case applied
    case channelNotAdmitted
    case invalidHost
}

public struct AccessDevAllowBlockApplyResult: Sendable, Equatable {
    public var status: AccessDevAllowBlockApplyStatus
    public var host: AccessSiteHost?
    public var intent: AccessSiteIntent

    public init(
        status: AccessDevAllowBlockApplyStatus,
        host: AccessSiteHost? = nil,
        intent: AccessSiteIntent = .off
    ) {
        self.status = status
        self.host = host
        self.intent = intent
    }
}

public enum AccessDevAllowBlockStatusId: String, Sendable, Equatable {
    case panelNotRegistered
    case noTrustedHost
    case off
    case allowProxyIntent
    case blockLocalRefuse
}

/// Presentation snapshot for the DEV ALLOW/BLOCK debug entry.
public struct AccessDevAllowBlockPanelSnapshot: Sendable, Equatable {
    /// False on Beta/Release — UI must not render the section.
    public var panelRegistered: Bool
    /// Always false: this feat is not a general Access rule editor.
    public var generalRuleEditorRegistered: Bool
    public var hasExplicitHost: Bool
    public var host: AccessSiteHost?
    public var intent: AccessSiteIntent
    public var statusId: AccessDevAllowBlockStatusId

    public init(
        panelRegistered: Bool = false,
        generalRuleEditorRegistered: Bool = false,
        hasExplicitHost: Bool = false,
        host: AccessSiteHost? = nil,
        intent: AccessSiteIntent = .off,
        statusId: AccessDevAllowBlockStatusId = .panelNotRegistered
    ) {
        self.panelRegistered = panelRegistered
        self.generalRuleEditorRegistered = generalRuleEditorRegistered
        self.hasExplicitHost = hasExplicitHost
        self.host = host
        self.intent = intent
        self.statusId = statusId
    }
}

/// P-iOS-4: DEV/Alpha debug entry for explicit-host ALLOW / BLOCK.
///
/// Beta/Release must not register this surface or a general Access rule editor.
/// Mutations are intent-only via `AccessSiteIntentStore` (session seams may wrap).
/// BLOCK is local refuse — never silent DIRECT success.
public enum AccessDevAllowBlockPanel {
    /// DEV / Alpha / Unknown admit; Beta / Release refuse.
    public static func admission(for channel: AccessReleaseChannel) -> AccessDevAllowBlockChannelAdmission {
        switch channel {
        case .dev, .alpha, .unknown:
            return .admitted
        case .beta, .release:
            return .notAdmitted
        }
    }

    public static func isPanelAdmitted(_ channel: AccessReleaseChannel) -> Bool {
        admission(for: channel) == .admitted
    }

    /// Hard rule: never register a general rule editor on any channel.
    public static func isGeneralAccessRuleEditorRegistered(
        _ channel: AccessReleaseChannel
    ) -> Bool {
        _ = channel
        return false
    }

    public static func intent(for action: AccessDevAllowBlockAction) -> AccessSiteIntent {
        switch action {
        case .allow: return .allow
        case .block: return .block
        case .off: return .off
        }
    }

    public static func statusId(for intent: AccessSiteIntent) -> AccessDevAllowBlockStatusId {
        switch intent {
        case .allow: return .allowProxyIntent
        case .block: return .blockLocalRefuse
        case .off: return .off
        }
    }

    /// Applies product intent for an explicit host when the channel admits the panel.
    /// Never invents DIRECT success for allow/block. Does not publish/ACK.
    public static func apply(
        store: inout AccessSiteIntentStore,
        channel: AccessReleaseChannel,
        rawHost: String,
        action: AccessDevAllowBlockAction
    ) -> AccessDevAllowBlockApplyResult {
        guard isPanelAdmitted(channel) else {
            return AccessDevAllowBlockApplyResult(status: .channelNotAdmitted)
        }

        let host: AccessSiteHost
        do {
            host = try resolveExactHost(rawHost)
        } catch {
            return AccessDevAllowBlockApplyResult(status: .invalidHost)
        }

        let next = intent(for: action)
        store.setIntent(next, for: host)
        return AccessDevAllowBlockApplyResult(status: .applied, host: host, intent: next)
    }

    /// Snapshot for a trusted http(s) navigation URL. Non-http(s) → no trusted host.
    public static func buildSnapshot(
        channel: AccessReleaseChannel,
        store: AccessSiteIntentStore,
        url: URL?
    ) -> AccessDevAllowBlockPanelSnapshot {
        let host: AccessSiteHost?
        if let url,
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           let raw = url.host,
           !raw.isEmpty {
            host = try? AccessSiteHost.normalize(raw)
        } else {
            host = nil
        }
        return snapshot(channel: channel, store: store, host: host)
    }

    /// Snapshot for an already-known raw host string (URL text or exact host).
    public static func buildSnapshot(
        channel: AccessReleaseChannel,
        store: AccessSiteIntentStore,
        rawHost: String
    ) -> AccessDevAllowBlockPanelSnapshot {
        let host = try? resolveExactHost(rawHost)
        return snapshot(channel: channel, store: store, host: host)
    }

    private static func snapshot(
        channel: AccessReleaseChannel,
        store: AccessSiteIntentStore,
        host: AccessSiteHost?
    ) -> AccessDevAllowBlockPanelSnapshot {
        var snap = AccessDevAllowBlockPanelSnapshot(
            generalRuleEditorRegistered: isGeneralAccessRuleEditorRegistered(channel)
        )
        guard isPanelAdmitted(channel) else {
            snap.panelRegistered = false
            snap.statusId = .panelNotRegistered
            return snap
        }
        snap.panelRegistered = true
        guard let host else {
            snap.statusId = .noTrustedHost
            return snap
        }
        snap.hasExplicitHost = true
        snap.host = host
        snap.intent = store.intent(for: host)
        snap.statusId = statusId(for: snap.intent)
        return snap
    }

    private static func resolveExactHost(_ rawHost: String) throws -> AccessSiteHost {
        if let normalized = try? AccessSiteHost.normalize(rawHost) {
            return normalized
        }
        return try AccessSiteHost(rawHost)
    }
}
