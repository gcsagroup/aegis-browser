import Foundation
import XCTest
@testable import Aegis

@MainActor
final class RemoteDiagnosticsControllerTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private var time = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        suite = "aegis-remote-tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        time = date
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private var preferences: FirebaseInstallPreferences {
        FirebaseInstallPreferences(defaults: defaults)
    }

    private func response(crashes: String = "true", analytics: String = "true") -> RemoteDiagnosticsResponse {
        RemoteDiagnosticsResponse(values: ["aegis_diagnostics_schema": "1", "aegis_crash_reports_allowed": crashes,
                                           "aegis_analytics_allowed": analytics], fetchedAt: time)
    }

    private func controller(_ source: ControlledRemoteDiagnosticsSource) -> RemoteDiagnosticsController {
        RemoteDiagnosticsController(preferences: preferences, source: source, now: { self.time }, schedulesExpiration: false)
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Expected asynchronous state was not reached", file: file, line: line)
    }

    func testDisabledByDefaultNeverContactsTheSource() async {
        let source = ControlledRemoteDiagnosticsSource()
        let controller = controller(source)
        controller.start()
        XCTAssertEqual(source.fetches, 0)
        XCTAssertEqual(source.deletions, 0)
        XCTAssertTrue(controller.permits(.analytics, localChoice: true))
        XCTAssertFalse(controller.permits(.analytics, localChoice: false))
    }

    func testAllowRemoteCannotEnableLocalConsentOrModifySavedChoices() async {
        let source = ControlledRemoteDiagnosticsSource()
        let controller = controller(source)
        preferences.setEnabled(false, for: .analytics)
        preferences.setEnabled(true, for: .crashes)
        controller.setEnabled(true)
        XCTAssertFalse(controller.permits(.crashes, localChoice: true))
        await waitUntil { source.fetches == 1 }
        source.finish(.success(response()))
        await waitUntil { !controller.busy }
        XCTAssertFalse(controller.permits(.analytics, localChoice: false))
        XCTAssertTrue(controller.permits(.crashes, localChoice: true))
        XCTAssertFalse(preferences.isEnabled(.analytics))
        XCTAssertTrue(preferences.isEnabled(.crashes))
        controller.setEnabled(false)
        await waitUntil { !controller.busy }
    }

    func testOffDiscardsLateResultAndDeletesOnlyAfterFetchCompletes() async {
        let source = ControlledRemoteDiagnosticsSource()
        let controller = controller(source)
        controller.setEnabled(true)
        await waitUntil { source.fetches == 1 }
        controller.setEnabled(false)
        XCTAssertEqual(source.deletions, 0)
        XCTAssertNil(controller.policy)
        source.finish(.success(response()))
        await waitUntil { !controller.busy }
        XCTAssertEqual(source.events, ["fetch", "delete"])
        XCTAssertNil(controller.policy)
        XCTAssertNil(preferences.remotePolicy)
        XCTAssertFalse(preferences.remoteInstallationUsed)
        XCTAssertFalse(preferences.remoteCleanupRequired)
    }

    func testOffOnWaitsForCleanupAndCannotUseOldAllowResponse() async {
        let source = ControlledRemoteDiagnosticsSource()
        source.suspendDeletion = true
        let controller = controller(source)
        controller.setEnabled(true)
        await waitUntil { source.fetches == 1 }
        controller.setEnabled(false)
        controller.setEnabled(true)
        source.finish(.success(response()))
        await waitUntil { source.deletions == 1 }
        XCTAssertEqual(source.fetches, 1)
        XCTAssertFalse(controller.permits(.crashes, localChoice: true))
        source.finishDeletion()
        await waitUntil { source.fetches == 2 }
        time = time.addingTimeInterval(1)
        source.finish(.success(response(crashes: "false")))
        await waitUntil { !controller.busy }
        XCTAssertFalse(controller.permits(.crashes, localChoice: true))
        XCTAssertTrue(controller.permits(.analytics, localChoice: true))
    }

    func testDeletionFailureSurvivesRestartAndBlocksNewFetchUntilRetrySucceeds() async {
        preferences.remoteInstallationUsed = true
        let first = ControlledRemoteDiagnosticsSource()
        first.deletionFails = true
        let stopped = controller(first)
        stopped.start()
        await waitUntil { !stopped.busy }
        XCTAssertEqual(stopped.state, .cleanupFailed)
        XCTAssertTrue(preferences.remoteCleanupRequired)
        XCTAssertEqual(first.fetches, 0)

        preferences.setEnabled(true, for: .remoteConfiguration)
        let second = ControlledRemoteDiagnosticsSource()
        second.deletionFails = true
        let restarted = controller(second)
        restarted.start()
        await waitUntil { !restarted.busy }
        XCTAssertEqual(second.fetches, 0)
        XCTAssertFalse(restarted.permits(.analytics, localChoice: true))
        second.deletionFails = false
        restarted.refresh()
        await waitUntil { second.fetches == 1 }
        sourcePolicyAbsent(restarted)
        time = time.addingTimeInterval(1)
        second.finish(.success(response()))
        await waitUntil { !restarted.busy }
        XCTAssertEqual(second.events, ["delete", "delete", "fetch"])
    }

    func testNetworkFailureKeepsCacheAgeButInvalidPayloadRemovesPermission() async throws {
        preferences.setEnabled(true, for: .remoteConfiguration)
        let valid = try XCTUnwrap(RemoteDiagnosticsPolicy(values: response().values, fetchedAt: date, now: date))
        preferences.saveRemotePolicy(valid)
        let source = ControlledRemoteDiagnosticsSource()
        let controller = controller(source)
        controller.start()
        await waitUntil { source.fetches == 1 }
        source.finish(.failure(ControlledRemoteDiagnosticsSource.Failure.offline))
        await waitUntil { !controller.busy }
        XCTAssertEqual(controller.policy?.fetchedAt, date)
        XCTAssertTrue(controller.permits(.analytics, localChoice: true))
        controller.refresh()
        await waitUntil { source.fetches == 2 }
        source.finish(.success(response(analytics: "YES")))
        await waitUntil { !controller.busy }
        XCTAssertNil(controller.policy)
        XCTAssertFalse(controller.permits(.analytics, localChoice: true))
    }

    func testExpirationRevokesCachedPermissionAndNotifiesCollectionOwner() throws {
        preferences.setEnabled(true, for: .remoteConfiguration)
        preferences.saveRemotePolicy(try XCTUnwrap(RemoteDiagnosticsPolicy(values: response().values, fetchedAt: date, now: date)))
        var time = date
        let controller = RemoteDiagnosticsController(preferences: preferences, source: ControlledRemoteDiagnosticsSource(),
            now: { time }, schedulesExpiration: false)
        var changes = 0
        controller.onChange = { changes += 1 }
        XCTAssertTrue(controller.permits(.analytics, localChoice: true))
        time = time.addingTimeInterval(RemoteDiagnosticsPolicy.maximumAge)
        controller.invalidateIfExpired()
        XCTAssertFalse(controller.permits(.analytics, localChoice: true))
        XCTAssertNil(preferences.remotePolicy)
        XCTAssertEqual(changes, 1)
    }

    func testPreRevocationSDKCacheCannotBeAcceptedOnReenable() async {
        preferences.setEnabled(true, for: .remoteConfiguration)
        preferences.remoteRevokedAt = date
        let source = ControlledRemoteDiagnosticsSource()
        let controller = controller(source)
        controller.start()
        await waitUntil { source.fetches == 1 }
        XCTAssertEqual(source.cutoffs, [date])
        source.finish(.success(response())) // SDK cache timestamp equals the fence.
        await waitUntil { !controller.busy }
        XCTAssertFalse(controller.permits(.analytics, localChoice: true))
        XCTAssertNotNil(preferences.remoteRevokedAt)
        time = time.addingTimeInterval(1)
        controller.refresh()
        await waitUntil { source.fetches == 2 }
        source.finish(.success(response()))
        await waitUntil { !controller.busy }
        XCTAssertTrue(controller.permits(.analytics, localChoice: true))
        XCTAssertNil(preferences.remoteRevokedAt)
    }

    func testEnableDuringStartupCleanupStartsExactlyOneNewFetch() async {
        preferences.remoteInstallationUsed = true
        let source = ControlledRemoteDiagnosticsSource()
        source.suspendDeletion = true
        let controller = controller(source)
        controller.start()
        await waitUntil { source.deletions == 1 }
        controller.setEnabled(true)
        source.finishDeletion()
        await waitUntil { source.fetches == 1 }
        time = time.addingTimeInterval(1)
        source.finish(.success(response()))
        await waitUntil { !controller.busy }
        XCTAssertEqual(source.fetches, 1)
        XCTAssertTrue(controller.permits(.analytics, localChoice: true))
    }

    func testAlreadyAbsentCleanupAllowsRecoveryAfterThrottledFetch() async {
        let source = ControlledRemoteDiagnosticsSource()
        let controller = controller(source)
        controller.setEnabled(true)
        await waitUntil { source.fetches == 1 }
        source.finish(.success(response()))
        await waitUntil { !controller.busy }
        controller.setEnabled(false)
        await waitUntil { !controller.busy }
        controller.setEnabled(true)
        await waitUntil { source.fetches == 2 }
        source.finish(.failure(ControlledRemoteDiagnosticsSource.Failure.offline))
        await waitUntil { !controller.busy }
        source.deletionError = missingInstallationError()
        controller.setEnabled(false)
        await waitUntil { !controller.busy }
        XCTAssertEqual(controller.state, .off)
        XCTAssertFalse(preferences.remoteCleanupRequired)
        controller.setEnabled(true)
        await waitUntil { source.fetches == 3 }
        time = time.addingTimeInterval(1)
        source.finish(.success(response()))
        await waitUntil { !controller.busy }
        XCTAssertTrue(controller.permits(.analytics, localChoice: true))
    }

    func testCleanupAbsenceMatcherDoesNotHideOtherErrors() {
        let missing = missingInstallationError()
        XCTAssertTrue(FirebaseInstallationCleanup.isAlreadyAbsent(missing, appID: "test-app", appName: "AegisDiagnosticsConfig"))
        let errors = [
            NSError(domain: "com.firebase.installations", code: 1, userInfo: missing.userInfo),
            NSError(domain: "com.firebase.installations", code: 2, userInfo: missing.userInfo),
            NSError(domain: "other-domain", code: 0, userInfo: missing.userInfo),
            NSError(domain: "com.firebase.installations", code: 0, userInfo: [NSLocalizedFailureReasonErrorKey: "Unknown error"]),
            NSError(domain: "com.firebase.installations", code: 0, userInfo: missing.userInfo.merging(
                [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: -1009)]) { _, new in new })
        ]
        for error in errors {
            XCTAssertFalse(FirebaseInstallationCleanup.isAlreadyAbsent(error, appID: "test-app", appName: "AegisDiagnosticsConfig"))
        }
        XCTAssertFalse(FirebaseInstallationCleanup.isAlreadyAbsent(missing, appID: "different-app", appName: "AegisDiagnosticsConfig"))
        XCTAssertFalse(FirebaseInstallationCleanup.isAlreadyAbsent(missing, appID: "test-app", appName: "__FIRAPP_DEFAULT"))
    }

    private func missingInstallationError() -> NSError {
        NSError(domain: "com.firebase.installations", code: 0, userInfo: [NSLocalizedFailureReasonErrorKey:
            "Installation for appID test-app appName AegisDiagnosticsConfig not found"])
    }

    private func sourcePolicyAbsent(_ controller: RemoteDiagnosticsController) {
        XCTAssertNil(controller.policy)
        XCTAssertNil(preferences.remotePolicy)
    }
}

@MainActor
private final class ControlledRemoteDiagnosticsSource: RemoteDiagnosticsSource {
    enum Failure: Error { case offline }
    var fetches = 0
    var deletions = 0
    var events: [String] = []
    var cutoffs: [Date?] = []
    var deletionFails = false
    var deletionError: Error?
    var suspendDeletion = false
    private var pending: CheckedContinuation<RemoteDiagnosticsResponse, Error>?
    private var pendingDeletion: CheckedContinuation<Void, Never>?

    func fetch(after revocation: Date?) async throws -> RemoteDiagnosticsResponse {
        fetches += 1
        cutoffs.append(revocation)
        events.append("fetch")
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    func deleteInstallation() async throws {
        deletions += 1
        events.append("delete")
        if deletionFails { throw Failure.offline }
        if let deletionError, !FirebaseInstallationCleanup.isAlreadyAbsent(deletionError, appID: "test-app", appName: "AegisDiagnosticsConfig") {
            throw deletionError
        }
        if suspendDeletion { await withCheckedContinuation { pendingDeletion = $0 } }
    }

    func finish(_ result: Result<RemoteDiagnosticsResponse, Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }

    func finishDeletion() {
        let continuation = pendingDeletion
        pendingDeletion = nil
        continuation?.resume()
    }
}
