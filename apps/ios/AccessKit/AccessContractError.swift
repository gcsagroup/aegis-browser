import Foundation

public enum AccessContractError: Error, Equatable, Sendable {
    case unknownInboundTransport(UInt8)
    case socks5NotAdmitted
    case unknownOutboundProfile(String)
    case wsTlsCompatNotAdmitted
    case emptyOwnerField(String)
    case ownerFieldNotCanonical
}
