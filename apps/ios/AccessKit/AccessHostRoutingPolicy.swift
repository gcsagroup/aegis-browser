import Foundation

/// Product intent for one exact host. Distinct from endpoint health and the
/// tab's current data-store binding.
public enum AccessProxyIntentState: String, Sendable, Equatable, Codable {
    case off
    case on
}

/// Readiness of the app-managed proxy entry. A non-zero port is not ready.
public enum AccessProxyEndpointState: String, Sendable, Equatable, Codable {
    case unavailable
    case preparing
    case ready
    case failed
}

/// Where a tab is actually loading from.
public enum AccessHostBindingKind: String, Sendable, Equatable, Codable {
    case original
    case hostStore
}

public struct AccessHostRoutingRequest: Sendable, Equatable {
    public var intent: AccessProxyIntentState
    public var endpoint: AccessProxyEndpointState
    /// Exact host of the navigation that is about to commit. Nil for non-web URLs.
    public var targetHost: AccessSiteHost?
    /// Host of the dedicated store this tab is already bound to.
    public var boundHost: AccessSiteHost?

    public init(
        intent: AccessProxyIntentState,
        endpoint: AccessProxyEndpointState,
        targetHost: AccessSiteHost?,
        boundHost: AccessSiteHost?
    ) {
        self.intent = intent
        self.endpoint = endpoint
        self.targetHost = targetHost
        self.boundHost = boundHost
    }
}

public enum AccessHostRoutingDecision: Sendable, Equatable {
    /// Use the tab's original store. Do not create a dedicated store.
    case originalStore
    /// Stay on the dedicated store already bound to this exact host.
    case keepBoundHostStore
    /// Use the dedicated store for this exact host. Caller creates it only when absent.
    case useHostStore(AccessSiteHost)
}

/// Chooses original vs dedicated storage after the navigation policy has allowed the URL.
public enum AccessHostRoutingPolicy {
    public static func decide(_ request: AccessHostRoutingRequest) -> AccessHostRoutingDecision {
        guard request.intent == .on, let target = request.targetHost else {
            return .originalStore
        }
        let boundToTarget = request.boundHost == target
        switch request.endpoint {
        case .ready:
            return .useHostStore(target)
        case .failed, .unavailable, .preparing:
            // A page already attached to this host stays there when the entry drops.
            // A tab that has not attached yet stays on its original store.
            return boundToTarget ? .keepBoundHostStore : .originalStore
        }
    }
}
