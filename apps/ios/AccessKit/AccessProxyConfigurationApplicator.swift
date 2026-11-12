import Foundation
import WebKit

/// Writes registration-derived `ProxyConfiguration` values onto a
/// `WKWebsiteDataStore` (iOS 18.4+ deployment target).
///
/// Ordinary and private browsing stores are separate call sites. Closing or
/// deactivating always assigns an empty configuration list so a previous port
/// is not reused.
@MainActor
public struct AccessProxyConfigurationApplicator: Sendable {
    public init() {}

    /// Applies or clears according to `fixture.isActive`.
    public func apply(
        _ fixture: AccessProxyRegistrationFixture,
        to dataStore: WKWebsiteDataStore
    ) throws {
        dataStore.proxyConfigurations = try AccessProxyConfigurationBuilder
            .makeConfigurations(from: fixture)
    }

    /// Explicit clear path used when Access is turned off.
    public func clear(dataStore: WKWebsiteDataStore) {
        dataStore.proxyConfigurations = []
    }

    public func applyToOrdinaryStore(
        _ fixture: AccessProxyRegistrationFixture,
        dataStore: WKWebsiteDataStore
    ) throws {
        try ensureKind(fixture, matches: .ordinary)
        try apply(fixture, to: dataStore)
    }

    public func applyToPrivateStore(
        _ fixture: AccessProxyRegistrationFixture,
        dataStore: WKWebsiteDataStore
    ) throws {
        try ensureKind(fixture, matches: .privateBrowsing)
        try apply(fixture, to: dataStore)
    }

    public func clearOrdinaryStore(_ dataStore: WKWebsiteDataStore) {
        clear(dataStore: dataStore)
    }

    public func clearPrivateStore(_ dataStore: WKWebsiteDataStore) {
        clear(dataStore: dataStore)
    }

    private func ensureKind(
        _ fixture: AccessProxyRegistrationFixture,
        matches expected: AccessProxyDataStoreKind
    ) throws {
        guard fixture.dataStoreKind == expected else {
            throw AccessProxyConfigurationError.dataStoreKindMismatch(
                expected: expected,
                actual: fixture.dataStoreKind
            )
        }
    }
}
