import Foundation

public enum AccessProxyConfigurationError: Error, Equatable, Sendable {
    case emptyRegistrationId
    case nonLoopbackHost(String)
    case invalidPort
    case dataStoreKindMismatch(
        expected: AccessProxyDataStoreKind,
        actual: AccessProxyDataStoreKind
    )
}
