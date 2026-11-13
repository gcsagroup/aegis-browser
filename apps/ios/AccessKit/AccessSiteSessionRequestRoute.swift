import Foundation

/// Route a new request would take under the current session/fault snapshot.
///
/// Mirrors macOS `PlanSiteProxySessionRequestRoute` without the Chromium
/// planner: when intent is `allow`, the action is `useProxy` / `wait` /
/// `fail` — never `preserveNative` (DIRECT).
public enum AccessSiteSessionRequestRouteAction: String, Codable, Sendable, Equatable, Hashable {
    case preserveNative = "preserve-native"
    case useProxy = "use-proxy"
    case wait
    case fail
}

/// Proof plan for a new request under one session snapshot.
public struct AccessSiteSessionRequestRoutePlan: Sendable, Equatable {
    public let action: AccessSiteSessionRequestRouteAction
    public let intent: AccessSiteIntent
    /// True when the allow path must reject DIRECT / native success.
    public let forbidDirect: Bool

    public init(
        action: AccessSiteSessionRequestRouteAction,
        intent: AccessSiteIntent,
        forbidDirect: Bool
    ) {
        self.action = action
        self.intent = intent
        self.forbidDirect = forbidDirect
    }
}

/// Plans the route a new request would take for a session snapshot.
public enum AccessSiteSessionRequestRoute {
    public static func plan(
        for snapshot: AccessSiteSessionSnapshot
    ) -> AccessSiteSessionRequestRoutePlan {
        switch snapshot.intent {
        case .off:
            return AccessSiteSessionRequestRoutePlan(
                action: .preserveNative,
                intent: .off,
                forbidDirect: false
            )
        case .block:
            // Local refuse: fail closed; never claim Access/DIRECT success.
            return AccessSiteSessionRequestRoutePlan(
                action: .fail,
                intent: .block,
                forbidDirect: true
            )
        case .allow:
            return planAllow(snapshot)
        }
    }

    private static func planAllow(
        _ snapshot: AccessSiteSessionSnapshot
    ) -> AccessSiteSessionRequestRoutePlan {
        let action: AccessSiteSessionRequestRouteAction
        switch snapshot.faultMode {
        case .wait:
            action = .wait
        case .failClosed:
            action = .fail
        case .none:
            if snapshot.phase == .unavailable
                || snapshot.connectionState == .unavailable
            {
                action = .fail
            } else if snapshot.phase == .ready,
                      snapshot.connectionState == .ready
            {
                action = .useProxy
            } else {
                // Connecting / preparing without an explicit wait fault still waits.
                action = .wait
            }
        }
        // Secondary guard: allow-path plans must never preserve native DIRECT.
        let safeAction = action == .preserveNative ? AccessSiteSessionRequestRouteAction.fail : action
        return AccessSiteSessionRequestRoutePlan(
            action: safeAction,
            intent: .allow,
            forbidDirect: true
        )
    }
}
