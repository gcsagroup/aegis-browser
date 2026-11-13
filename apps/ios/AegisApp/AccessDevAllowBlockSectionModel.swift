import AccessKit
import Foundation

/// Thin AegisApp helpers for the DEV ALLOW/BLOCK debug entry (P-iOS-4).
///
/// Resolves the product channel from `AegisFirebaseChannel` and builds
/// presentation / apply calls against AccessKit + the session controller.
enum AccessDevAllowBlockSectionModel {
    static let firebaseChannelInfoKey = "AegisFirebaseChannel"

    static func resolveChannel(
        bundle: Bundle = .main
    ) -> AccessReleaseChannel {
        let raw = bundle.object(forInfoDictionaryKey: firebaseChannelInfoKey) as? String
        return AccessReleaseChannel.parse(raw)
    }

    static func buildSnapshot(
        channel: AccessReleaseChannel,
        url: URL?,
        controller: AccessSiteSessionController
    ) -> AccessDevAllowBlockPanelSnapshot {
        AccessDevAllowBlockPanel.buildSnapshot(
            channel: channel,
            store: controller.intentStoreSnapshot(),
            url: url
        )
    }

    @discardableResult
    static func apply(
        action: AccessDevAllowBlockAction,
        channel: AccessReleaseChannel,
        url: URL?,
        controller: AccessSiteSessionController
    ) -> AccessDevAllowBlockApplyResult {
        guard let host = AccessSiteProxyToggleModel.resolveTrustedHost(from: url) else {
            return AccessDevAllowBlockApplyResult(status: .invalidHost)
        }
        return controller.applyDevAllowBlock(
            channel: channel,
            rawHost: host.rawValue,
            action: action
        )
    }

    static func statusLine(for status: AccessDevAllowBlockStatusId) -> String {
        switch status {
        case .panelNotRegistered:
            return "DEV ALLOW/BLOCK 未注册"
        case .noTrustedHost:
            return "当前页不是可调试的明确 host"
        case .off:
            return "意图：关闭"
        case .allowProxyIntent:
            return "意图：ALLOW（代理）"
        case .blockLocalRefuse:
            return "意图：BLOCK（本地拒绝）"
        }
    }
}
