import Foundation

public enum AccessContractError: Error, Equatable, Sendable {
    case unknownInboundTransport(UInt8)
    case socks5NotAdmitted
    case unknownOutboundProfile(String)
    case wsTlsCompatNotAdmitted
    case emptyOwnerField(String)
    case ownerFieldNotCanonical
    case emptyRegistrationID
    case registrationIDNotCanonical
    case registrationIDReused
    case emptyCredentialSlot
    case credentialSlotNotCanonical
    case endpointNotCanonical
    case nonLoopbackEndpoint(String)
    case invalidEndpointPort(UInt16)
    case invalidLeaseGeneration(UInt64)
    case staleLeaseGeneration(UInt64)
    case leaseGenerationOverflow
}
