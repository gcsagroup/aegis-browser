import Foundation

/// Data-store lane the WebKit applicator is allowed to write.
///
/// F13 (`AccessBrowsingIsolationController`) owns the full ordinary / private
/// Access isolation. This enum remains the applicator write-boundary key and
/// maps 1:1 to `AccessBrowsingBucket`.
public enum AccessProxyDataStoreKind: String, Codable, Sendable, Equatable, Hashable {
    case ordinary
    case privateBrowsing
}

/// Fake registration used by F9 until real registration / lease types land.
///
/// Transport uses the F1 `AccessInboundTransport` contract (`http` / `https`
/// only). This type is a WebKit-side test and applicator input only — not a
/// live listener, credential issuer, or REALITY runtime handle.
public struct AccessProxyRegistrationFixture: Codable, Sendable, Equatable, Hashable {
    public let registrationId: String
    public let dataStoreKind: AccessProxyDataStoreKind
    public let transport: AccessInboundTransport
    public let loopbackHost: String
    public let port: UInt16
    /// When false, the applicator must write an empty configuration list.
    public let isActive: Bool

    public init(
        registrationId: String,
        dataStoreKind: AccessProxyDataStoreKind,
        transport: AccessInboundTransport,
        loopbackHost: String,
        port: UInt16,
        isActive: Bool
    ) throws {
        let trimmedId = registrationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty, trimmedId == registrationId else {
            throw AccessProxyConfigurationError.emptyRegistrationId
        }
        guard Self.isNumericLoopback(loopbackHost) else {
            throw AccessProxyConfigurationError.nonLoopbackHost(loopbackHost)
        }
        guard port != 0 else {
            throw AccessProxyConfigurationError.invalidPort
        }
        self.registrationId = trimmedId
        self.dataStoreKind = dataStoreKind
        self.transport = transport
        self.loopbackHost = loopbackHost
        self.port = port
        self.isActive = isActive
    }

    /// Stable fake ordinary HTTP registration for unit tests.
    public static func httpOrdinary(
        registrationId: String = "fixture-http-ordinary",
        port: UInt16 = 18_101
    ) throws -> AccessProxyRegistrationFixture {
        try AccessProxyRegistrationFixture(
            registrationId: registrationId,
            dataStoreKind: .ordinary,
            transport: .http,
            loopbackHost: "127.0.0.1",
            port: port,
            isActive: true
        )
    }

    /// Stable fake private HTTPS registration for unit tests.
    public static func httpsPrivate(
        registrationId: String = "fixture-https-private",
        port: UInt16 = 18_443
    ) throws -> AccessProxyRegistrationFixture {
        try AccessProxyRegistrationFixture(
            registrationId: registrationId,
            dataStoreKind: .privateBrowsing,
            transport: .https,
            loopbackHost: "127.0.0.1",
            port: port,
            isActive: true
        )
    }

    public func deactivated() throws -> AccessProxyRegistrationFixture {
        try AccessProxyRegistrationFixture(
            registrationId: registrationId,
            dataStoreKind: dataStoreKind,
            transport: transport,
            loopbackHost: loopbackHost,
            port: port,
            isActive: false
        )
    }

    private static func isNumericLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1"
    }
}
