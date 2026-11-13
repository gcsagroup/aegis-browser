import XCTest
@testable import AccessKit

final class AccessSitePhase1EvidenceTests: XCTestCase {
    func testStepAcceptanceIdsMatchA2() {
        XCTAssertEqual(AccessSitePhase1EvidenceStep.on.acceptanceId, "A2-1")
        XCTAssertEqual(AccessSitePhase1EvidenceStep.load.acceptanceId, "A2-2")
        XCTAssertEqual(AccessSitePhase1EvidenceStep.fault.acceptanceId, "A2-3")
        XCTAssertEqual(AccessSitePhase1EvidenceStep.recovery.acceptanceId, "A2-4")
        XCTAssertEqual(AccessSitePhase1EvidenceStep.off.acceptanceId, "A2-5")
    }

    func testFaultAndRecoveryRequirePios5Fixture() {
        XCTAssertFalse(AccessSitePhase1EvidenceStep.on.requiresFaultFixtureAPI)
        XCTAssertFalse(AccessSitePhase1EvidenceStep.load.requiresFaultFixtureAPI)
        XCTAssertTrue(AccessSitePhase1EvidenceStep.fault.requiresFaultFixtureAPI)
        XCTAssertTrue(AccessSitePhase1EvidenceStep.recovery.requiresFaultFixtureAPI)
        XCTAssertFalse(AccessSitePhase1EvidenceStep.off.requiresFaultFixtureAPI)
        XCTAssertTrue(AccessSitePhase1EvidenceFaultRequirement.isPending)
        XCTAssertEqual(AccessSitePhase1EvidenceFaultRequirement.pendingFeat, "P-iOS-5")
    }

    func testBuildCorrelationIdUsesIosPrefix() {
        let id = AccessSitePhase1EvidenceCorrelation.buildCorrelationId(
            candidateSha: "A01308C909F4503E3731320D651C9FCB4B9FE35E",
            runId: "20261108-ios-1",
            step: .load
        )
        XCTAssertEqual(id, "aegis-ios-p1/a01308c9/20261108-ios-1/load")
        XCTAssertTrue(AccessSitePhase1EvidenceCorrelation.isValid(id))
    }

    func testCorrelationRejectsMacPrefixAndBadSteps() {
        XCTAssertFalse(
            AccessSitePhase1EvidenceCorrelation.isValid("aegis-mac-p1/a01308c9/run-1/on")
        )
        XCTAssertFalse(
            AccessSitePhase1EvidenceCorrelation.isValid("aegis-ios-p1/A01308C9/run-1/on")
        )
        XCTAssertFalse(
            AccessSitePhase1EvidenceCorrelation.isValid("aegis-ios-p1/a01308c9/run-1/healthy")
        )
    }

    func testDirectSuccessMustNeverBeRecordedAsAccessSuccess() {
        // Pack rule mirror: scaffolding forbids treating DIRECT page success
        // as Access success. Product SIMULATOR_PASS still requires filled
        // same-candidate artifacts (validator), not this unit alone.
        XCTAssertEqual(AccessSitePhase1EvidenceCorrelation.prefix, "aegis-ios-p1")
        XCTAssertFalse(AccessSitePhase1EvidenceFaultRequirement.requiredCapabilities.isEmpty)
        XCTAssertEqual(
            AccessSitePhase1EvidencePack.allowedProductStatus,
            "SIMULATOR_PASS"
        )
        XCTAssertEqual(
            AccessSitePhase1EvidencePack.deviceAndTestFlightStatus,
            "NOT_RUN"
        )
    }
}
