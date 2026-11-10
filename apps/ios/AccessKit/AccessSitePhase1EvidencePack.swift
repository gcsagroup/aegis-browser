import Foundation

/// Points operators at the product Phase 1 evidence directory (A4).
/// Artifacts under this path are what may justify `SIMULATOR_PASS`; unit
/// greens alone must not.
public enum AccessSitePhase1EvidencePack {
    public static let relativeDirectory =
        "docs/audit/evidence/ios-access-product-phase1"
    public static let validatorScript =
        "apps/browser/scripts/ios-access-phase1-evidence.mjs"
    public static let allowedProductStatus = "SIMULATOR_PASS"
    public static let deviceAndTestFlightStatus = "NOT_RUN"
}
