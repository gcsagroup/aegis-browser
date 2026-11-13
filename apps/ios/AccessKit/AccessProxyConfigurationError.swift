import Foundation

public enum AccessProxyConfigurationError: Error, Equatable, Sendable {
    case emptyRegistrationId
    case nonLoopbackHost(String)
    case invalidPort
    case socks5ProxyConfigurationNotAdmitted
    case dataStoreKindMismatch(
        expected: AccessProxyDataStoreKind,
        actual: AccessProxyDataStoreKind
    )
}
