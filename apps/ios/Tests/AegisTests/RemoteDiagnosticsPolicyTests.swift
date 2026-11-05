import Foundation
import XCTest
@testable import Aegis

final class RemoteDiagnosticsPolicyTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let values = ["aegis_diagnostics_schema": "1", "aegis_crash_reports_allowed": "true", "aegis_analytics_allowed": "false"]

    func testRemotePermissionCannotOverrideLocalRefusal() throws {
        let policy = try XCTUnwrap(RemoteDiagnosticsPolicy(values: values, fetchedAt: date, now: date))
        XCTAssertFalse(policy.permits(.crashes, localChoice: false, now: date))
        XCTAssertTrue(policy.permits(.crashes, localChoice: true, now: date))
        XCTAssertFalse(policy.permits(.analytics, localChoice: true, now: date))
        XCTAssertFalse(policy.permits(.remoteConfiguration, localChoice: true, now: date))
    }

    func testMissingMalformedAndFutureSchemaAreRejectedAtomically() {
        for key in RemoteDiagnosticsPolicy.keys {
            var missing = values
            missing.removeValue(forKey: key)
            XCTAssertNil(RemoteDiagnosticsPolicy(values: missing, fetchedAt: date, now: date))
            for bad in ["", "TRUE", "1", "yes", " true", "null", "2"] where key != RemoteDiagnosticsPolicy.keys[0] || bad != "1" {
                var malformed = values
                malformed[key] = bad
                XCTAssertNil(RemoteDiagnosticsPolicy(values: malformed, fetchedAt: date, now: date))
            }
        }
    }

    func testUnknownParametersCannotExpandTheScope() throws {
        var extra = values
        extra["enable_analytics_without_consent"] = "true"
        extra["disable_protection"] = "true"
        let policy = try XCTUnwrap(RemoteDiagnosticsPolicy(values: extra, fetchedAt: date, now: date))
        XCTAssertFalse(policy.permits(.analytics, localChoice: false, now: date))
        XCTAssertEqual(policy, RemoteDiagnosticsPolicy(values: values, fetchedAt: date, now: date))
    }

    func testAgeBoundaryAndClockRollbackSuspendReporting() throws {
        let policy = try XCTUnwrap(RemoteDiagnosticsPolicy(values: values, fetchedAt: date, now: date))
        XCTAssertTrue(policy.isValid(at: date.addingTimeInterval(RemoteDiagnosticsPolicy.maximumAge - 1)))
        XCTAssertFalse(policy.isValid(at: date.addingTimeInterval(RemoteDiagnosticsPolicy.maximumAge)))
        XCTAssertFalse(policy.isValid(at: date.addingTimeInterval(-1)))
        XCTAssertNil(RemoteDiagnosticsPolicy(values: values, fetchedAt: date.addingTimeInterval(1), now: date))
        let restored = try JSONDecoder().decode(RemoteDiagnosticsPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertFalse(restored.permits(.crashes, localChoice: true, now: date.addingTimeInterval(RemoteDiagnosticsPolicy.maximumAge)))
    }

    func testCrashDecisionWaitsForStartupPolicyAndIsIrreversible() {
        var denied = DiagnosticsLaunchDecision()
        XCTAssertNil(denied.resolve(allowed: true, policySettled: false))
        XCTAssertEqual(denied.resolve(allowed: false, policySettled: true), .delete)
        XCTAssertNil(denied.resolve(allowed: true, policySettled: true))

        var authorized = DiagnosticsLaunchDecision()
        XCTAssertEqual(authorized.resolve(allowed: true, policySettled: true), .send)
        XCTAssertNil(authorized.resolve(allowed: false, policySettled: true))
    }
}
