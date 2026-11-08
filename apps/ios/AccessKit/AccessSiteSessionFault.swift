import Foundation

/// Product fault disposition while intent remains `allow` (P-iOS-5).
///
/// Fail-closed aborts new requests; wait holds them until recovery.
/// Neither mode admits silent DIRECT / native success as Access success.
public enum AccessSiteSessionFaultMode: String, Codable, Sendable, Equatable, Hashable {
    case none
    case failClosed = "fail-closed"
    case wait
}
