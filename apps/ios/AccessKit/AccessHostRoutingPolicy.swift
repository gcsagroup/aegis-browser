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

public enum AccessWebsiteAccelerationMode: String, Codable, Sendable {
    case manual
    case smart
}

public enum AccessWebsiteRouteChoice: String, Sendable {
    case original
    case service
}

/// A category match authorizes the top-level navigation. Its store remains
/// isolated by exact host.
public struct AccessWebsiteRoutePolicy: Sendable {
    public let catalogue: AccessGeoSiteCatalogue
    private let fixtureSuffix: String

    public init(catalogue: AccessGeoSiteCatalogue = .bundled) {
        self.catalogue = catalogue
        fixtureSuffix = ""
    }

    #if DEBUG
    /// Closed fixture projection of the same records. No configurable rules.
    public static let geositeFixture = Self(fixtureSuffix: ".geosite.invalid")

    private init(fixtureSuffix: String) {
        catalogue = .bundled
        self.fixtureSuffix = fixtureSuffix
    }
    #endif

    public func matches(_ url: URL, categories: Set<AccessGeoSiteCategory> = [.debian]) -> Bool {
        guard !categories.isEmpty, var host = Self.websiteHost(url)?.rawValue else { return false }
        if !fixtureSuffix.isEmpty {
            guard host.hasSuffix(fixtureSuffix) else { return false }
            host.removeLast(fixtureSuffix.count)
        }
        return categories.contains { catalogue.groups[$0]?.rules.contains { $0.matches(host) } == true }
    }

    /// Use the parsed navigation host and canonicalize a single DNS root dot.
    /// Validate DNS labels before the more permissive legacy site normalizer.
    public static func websiteHost(_ url: URL) -> AccessSiteHost? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        if !host.utf8.allSatisfy({ $0 < 128 }) {
            // Foundation can expose a percent-encoded IDN as decoded Unicode.
            // Reparse only that host component to obtain the DNS representation.
            guard host.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:@?#[]%").union(.whitespacesAndNewlines)) == nil,
                  let normalized = URL(string: "https://\(host)/")?.host else { return nil }
            host = normalized.lowercased()
        }
        if host.hasSuffix(".") { host.removeLast() }
        guard host.utf8.count <= 253,
              !host.hasSuffix(".localhost"), !host.hasSuffix(".local"),
              host != "home.arpa", !host.hasSuffix(".home.arpa") else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.last?.utf8.contains(where: { (97...122).contains($0) }) == true,
              labels.allSatisfy({ label in
                  (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                      && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { return nil }
        return try? AccessSiteHost(host)
    }
}
