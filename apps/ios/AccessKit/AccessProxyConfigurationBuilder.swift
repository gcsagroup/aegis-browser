import Foundation
import Network

/// Testable plan describing how a registration becomes a WebKit proxy relay.
public struct AccessProxyEndpointPlan: Equatable, Sendable {
    public let registrationId: String
    public let host: String
    public let port: UInt16
    /// `true` when the CONNECT hop itself uses TLS (HTTPS inbound front).
    public let usesTLSToProxy: Bool

    public init(
        registrationId: String,
        host: String,
        port: UInt16,
        usesTLSToProxy: Bool
    ) {
        self.registrationId = registrationId
        self.host = host
        self.port = port
        self.usesTLSToProxy = usesTLSToProxy
    }
}

/// Builds Network `ProxyConfiguration` values from a fake registration fixture.
///
/// HTTP registrations use cleartext HTTP CONNECT. HTTPS registrations attach
/// TLS options so WebKit speaks TLS to the local inbound front. No listener or
/// REALITY runtime is started here.
public enum AccessProxyConfigurationBuilder {
    /// Returns `nil` when the fixture is inactive (caller must clear the store).
    public static func plan(
        for fixture: AccessProxyRegistrationFixture
    ) -> AccessProxyEndpointPlan? {
        guard fixture.isActive else { return nil }
        return AccessProxyEndpointPlan(
            registrationId: fixture.registrationId,
            host: fixture.loopbackHost,
            port: fixture.port,
            usesTLSToProxy: fixture.transport == .https
        )
    }

    /// Empty when inactive so an old port cannot remain selected.
    public static func makeConfigurations(
        from fixture: AccessProxyRegistrationFixture
    ) throws -> [ProxyConfiguration] {
        guard let plan = plan(for: fixture) else { return [] }
        return [try makeConfiguration(from: plan)]
    }

    public static func makeConfiguration(
        from plan: AccessProxyEndpointPlan
    ) throws -> ProxyConfiguration {
        guard plan.port != 0 else {
            throw AccessProxyConfigurationError.invalidPort
        }
        guard let nwPort = NWEndpoint.Port(rawValue: plan.port) else {
            throw AccessProxyConfigurationError.invalidPort
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(plan.host),
            port: nwPort
        )
        switch plan.usesTLSToProxy {
        case false:
            return ProxyConfiguration(httpCONNECTProxy: endpoint)
        case true:
            return ProxyConfiguration(
                httpCONNECTProxy: endpoint,
                tlsOptions: NWProtocolTLS.Options()
            )
        }
    }
}
