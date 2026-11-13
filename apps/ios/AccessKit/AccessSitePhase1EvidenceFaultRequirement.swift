import Foundation

/// Documents the P-iOS-5 surface this pack needs before fault/recovery can
/// leave `NOT_RUN`. Concrete types land with
/// `feat/ios-access-fault-no-direct-2cd7`; until then product status stays
/// scaffold-only and `SIMULATOR_PASS` is refused by the pack validator when
/// the fault fixture is absent.
public enum AccessSitePhase1EvidenceFaultRequirement {
    public static let pendingFeat = "P-iOS-5"
    public static let pendingBranch = "feat/ios-access-fault-no-direct-2cd7"

    /// Expected capabilities (names may match the landed P-iOS-5 symbols):
    /// fail-closed runtime fault that refuses silent DIRECT as Access success,
    /// plus a recoverable path back to PROXY-ready.
    public static let requiredCapabilities: [String] = [
        "fail-closed runtime fault (no silent DIRECT)",
        "recoverable PROXY-ready path without dirty-session replay",
    ]

    /// Flip to false in a follow-up once P-iOS-5 merges and the five-step
    /// drill can bind the fault API. Kept explicit so A2-3/A2-4 stay honest.
    public static var isPending: Bool { true }
}
