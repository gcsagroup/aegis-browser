import Foundation

/// Persists per-host Access site intents for the current browsing scope.
///
/// This type does not start Xray, open listeners, or apply ProxyConfiguration.
public protocol AccessSiteIntentStoring: Sendable {
    func intent(for host: AccessSiteHost) -> AccessSiteIntent
    mutating func setIntent(_ intent: AccessSiteIntent, for host: AccessSiteHost)
    func allIntents() -> [AccessSiteHost: AccessSiteIntent]
}

/// In-memory store. Profile/private isolation can wrap separate instances (F13).
public struct AccessSiteIntentStore: AccessSiteIntentStoring, Sendable, Equatable {
    private var values: [AccessSiteHost: AccessSiteIntent]

    public init(values: [AccessSiteHost: AccessSiteIntent] = [:]) {
        self.values = values.filter { $0.value != .off }
    }

    public func intent(for host: AccessSiteHost) -> AccessSiteIntent {
        values[host] ?? .off
    }

    public mutating func setIntent(_ intent: AccessSiteIntent, for host: AccessSiteHost) {
        if intent == .off {
            values.removeValue(forKey: host)
        } else {
            values[host] = intent
        }
    }

    public func allIntents() -> [AccessSiteHost: AccessSiteIntent] {
        values
    }
}
