import XCTest
@testable import Aegis

/// Opt-in read-only test through the entitlement service; never receives panel credentials.
@MainActor
final class AccessAccountAlphaLiveTests: XCTestCase {
    func testTestClientQuotaThroughNativeSessionAndRelay() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let origin = env["AEGIS_ALPHA_ORIGIN"],
              let account = env["AEGIS_ALPHA_ACCOUNT"],
              let token = env["AEGIS_ALPHA_TOKEN"] else {
            throw XCTSkip("Run with the private Alpha entitlement runner")
        }
        let keychain = AccessAccountKeychain(service: "test.access.alpha." + UUID().uuidString)
        defer { try? keychain.save(nil) }
        #if targetEnvironment(simulator)
        let session = AccessAccountSession.product(environment: [
            "AEGIS_ACCOUNT_SIM_ORIGIN": origin,
            "AEGIS_ACCOUNT_SIM_ACTION": "bind",
            "AEGIS_ACCOUNT_SIM_ID": account,
            "AEGIS_ACCOUNT_SIM_TOKEN": token
        ], keychain: keychain)
        await session.refresh()?.value
        #else
        // A trusted native test launcher supplies the temporary Aegis session.
        // Physical devices retain the signed HTTPS origin and normal bind path.
        guard Bundle.main.object(forInfoDictionaryKey: "AegisAccountServiceOrigin") as? String == origin else {
            XCTFail("Signed service origin differs from the authorized test origin")
            return
        }
        let session = AccessAccountSession.product(keychain: keychain)
        await session.bind(accountID: account, token: token)?.value
        #endif
        guard case let .ready(value) = session.state else {
            XCTFail("Authorized TEST quota could not be read through the relay")
            return
        }
        XCTAssertEqual(value.entitlementAccountId, account)
        XCTAssertEqual(value.quotaSource, .threeXUIAlpha)
        XCTAssertEqual(value.panelExpiryMode, AccessAccountEntitlement.PanelExpiryMode.none)
        XCTAssertNil(value.panelExpiresAt)
        XCTAssertEqual(value.expiresAt, value.periodEnd)
        let expectedQuota: UInt64 = 10_000_000_000
        XCTAssertEqual(value.quotaBytes, String(expectedQuota))
        XCTAssertEqual(value.freshness, .unavailable)
        XCTAssertNil(value.measuredAt)
        XCTAssertNil(value.snapshotAgeMs)
        let up = try XCTUnwrap(value.uploadedBytes.flatMap(UInt64.init))
        let down = try XCTUnwrap(value.downloadedBytes.flatMap(UInt64.init))
        let used = try XCTUnwrap(value.usedBytes.flatMap(UInt64.init))
        let remaining = try XCTUnwrap(value.remainingBytes.flatMap(UInt64.init))
        XCTAssertEqual(used, up + down)
        XCTAssertEqual(remaining, used < expectedQuota ? expectedQuota - used : 0)
        XCTAssertNotNil(session.snapshotReceivedUptime)
        XCTAssertFalse(session.snapshotIsStale)
        session.signOut()
        XCTAssertNil(session.lastSnapshot)
        XCTAssertNil(try keychain.read())
    }
}
