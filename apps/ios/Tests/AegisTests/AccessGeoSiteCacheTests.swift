import AccessKit
import BrowserKit
import CryptoKit
import Foundation
import os
import Security
import XCTest
@testable import Aegis

@MainActor
final class AccessGeoSiteCacheTests: XCTestCase {
    typealias Cache = AccessGeoSiteCache
    typealias Vector = AccessGeoSiteTestVector
    private let debian = URL(string: "https://security.debian.org/")!
    private let douban = URL(string: "https://www.douban.com/")!
    private let added = URL(string: "https://sub.new-coverage.example.com/")!
    private let outside = URL(string: "https://example.net/")!
    private let smartAll = Cache.Selection(mode: .smart, categories: [.debian, .douban, .meituan])

    func testLegacyDefaultsWithoutLedgerDoNotAuthorizeNewDebianHost() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let suite = "aegis.geosite.migration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("smart", forKey: "browser.websiteAcceleration.mode")
        defaults.set(["DEBIAN"], forKey: "browser.websiteAcceleration.categories")

        let cache = fixture.cache()
        let coordinator = AccessHostStoreCoordinator(channel: .dev, locationPreferences: defaults, geoSiteCache: cache)
        for _ in 0..<100 where cache.status == .loading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(coordinator.websiteAccelerationMode, .smart)
        XCTAssertEqual(cache.match(debian), .managed)
        XCTAssertEqual(cache.match(URL(string: "https://debian.map.fastlydns.net")!), .original)

        let reopened = fixture.cache()
        await reopened.restore()
        XCTAssertEqual(reopened.match(URL(string: "https://debian.map.fastlydns.net")!), .original)
    }

    func testBundledPreviewCannotValidateDomesticOnlyETagForFirstOverseasFetch() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let published = try XCTUnwrap(ISO8601DateFormatter().date(from: AccessGeoSiteCatalogue.bundled.publishedAt))
        let checked = published.addingTimeInterval(86_400)
        fixture.clock.setWall(checked)
        let cache = fixture.cache(useProductBaseline: true)
        await cache.restore(migrating: smartAll)
        let database = combined(debian: bundled(.debian), douban: bundled(.douban), meituan: bundled(.meituan))
        let candidate = try Self.candidate(1, database: database, now: checked)
        try await cache.apply(candidate, using: XCTUnwrap(cache.updateContext()),
                              refreshed: .init(etag: "\"domestic\"", checkedAt: checked))
        let domestic = await cache.conditionalReceipt(using: try XCTUnwrap(cache.updateContext()))
        XCTAssertEqual(domestic?.etag, "\"domestic\"")
        XCTAssertEqual(cache.overseasPreview?.bundled, true)
        try cache.requestOverseasPreview()
        XCTAssertNil(cache.refreshState.nextAttempt)
        let overseas = await cache.conditionalReceipt(using: try XCTUnwrap(cache.updateContext()))
        XCTAssertNil(overseas)
    }

    func testOldBundledConsentDoesNotIncludeNewDebianHost() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: smartAll)
        let route = URL(string: "https://debian.map.fastlydns.net")!
        XCTAssertEqual(cache.match(route), .managed)
        let record = try XCTUnwrap(fixture.storage.readLedger())
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any])
        legacy.removeValue(forKey: "bundledConsent")
        try fixture.storage.writeLedger(JSONSerialization.data(withJSONObject: legacy))
        let recovered = fixture.cache()
        await recovered.restore()
        XCTAssertEqual(recovered.selection, smartAll)
        XCTAssertEqual(recovered.match(route), .original)
        XCTAssertEqual(recovered.match(debian), .managed)
    }

    func testChangingSuccessfulRefreshIntervalRecalculatesDeadlineWithoutResettingBackoff() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: smartAll)
        let now = fixture.clock.wall
        let candidate = try Self.candidate(1, database: Vector.selectedProjection)
        try await cache.apply(candidate, using: XCTUnwrap(cache.updateContext()),
                              refreshed: .init(lastRequest: now, checkedAt: now))
        XCTAssertEqual(cache.refreshState.nextAttempt, now.addingTimeInterval(3 * 86_400))
        try cache.setRefreshInterval(days: 7)
        XCTAssertEqual(cache.refreshState.nextAttempt, candidate.expiresAt.addingTimeInterval(-86_400))
        try cache.setRefreshInterval(days: 1)
        XCTAssertEqual(cache.refreshState.nextAttempt, now.addingTimeInterval(86_400))
        let retry = now.addingTimeInterval(300)
        try cache.setRefreshState(.init(failureCount: 2, nextAttempt: retry), using: XCTUnwrap(cache.updateContext()))
        try cache.setRefreshInterval(days: 7)
        XCTAssertEqual(cache.refreshState.nextAttempt, retry)
    }

    func testOldOverseasWithdrawalRecoversWithNewApplicationBaseline() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: smartAll)
        try cache.requestOverseasPreview()
        let initial = try Self.overseas(1, positive: ["google.com"], excluding: [])
        try await cache.apply(initial, using: XCTUnwrap(cache.updateContext()))
        let selection = AccessOverseasSelection(enabled: true, mode: .all)
        try await cache.confirmOverseas(cache.overseasConfirmation(for: selection)) { true }
        let withdrawal = try Self.overseas(2, positive: ["google.com"], excluding: ["gemini.google.com"])
        try await cache.apply(withdrawal, using: XCTUnwrap(cache.updateContext()))
        fixture.clock.advance(by: 8 * 86_400)
        let cold = fixture.cache(useProductBaseline: true)
        await cold.restore()
        let state = cold.runtimeView().overseas
        XCTAssertEqual(cold.status, .ready)
        XCTAssertEqual(cold.highWater, withdrawal.receipt)
        XCTAssertEqual(state.selection, selection)
        XCTAssertTrue(state.usingBundledRules)
        XCTAssertEqual(state.match(URL(string: "https://gemini.google.com")!), .original)
        XCTAssertEqual(state.match(URL(string: "https://www.google.com")!), .managed)
    }

    func testBundledOverseasApprovalPersistsOfflineAndRemotePauseNeedsSignedRelease() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        fixture.clock.advance(by: 30 * 86_400)
        let cache = fixture.cache(useProductBaseline: true)
        await cache.restore()
        let target = URL(string: "https://www.google.com")!
        XCTAssertEqual(cache.runtimeView().overseas.match(target), .original)
        XCTAssertEqual(cache.overseasPreview?.bundled, true)
        let selection = AccessOverseasSelection(enabled: true, mode: .all)
        let confirmation = try await cache.overseasConfirmation(for: selection)
        XCTAssertTrue(confirmation.bundled)
        try await cache.confirmOverseas(confirmation) { true }
        let record = try XCTUnwrap(fixture.storage.readLedger())
        let ledger = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any])
        XCTAssertEqual(ledger["overseasApprovedFromBundle"] as? Bool, true)
        XCTAssertEqual(cache.runtimeView().overseas.match(target), .managed)
        XCTAssertNotNil(cache.updateContext(), "Overseas refresh applies in domestic manual mode")
        XCTAssertEqual(cache.view.refreshDays, 3)
        try cache.setRefreshInterval(days: 7)

        let key = Curve25519.Signing.PrivateKey()
        func signedPolicy(version: Int, paused: Bool, corrupt: Bool = false) throws -> AccessGeoSiteRemotePolicy {
            let issuedAt = fixture.clock.wall.timeIntervalSince1970
            let payload = try JSONSerialization.data(withJSONObject: [
                "schema": 1, "version": version, "issuedAt": issuedAt, "expiresAt": issuedAt + 3600,
                "defaultRefreshDays": 1, "overseasPaused": paused, "blockedTags": []
            ], options: .sortedKeys)
            let signature = try key.signature(for: payload)
            let envelope = try JSONSerialization.data(withJSONObject: [
                "payload": payload.base64EncodedString(),
                "signature": (corrupt ? Data(repeating: 0, count: 64) : signature).base64EncodedString()
            ])
            return try AccessGeoSiteRemotePolicy.verify(envelope, key: key.publicKey, now: fixture.clock.wall)
        }
        try cache.acceptRemotePolicy(signedPolicy(version: 2, paused: true))
        XCTAssertThrowsError(try signedPolicy(version: 3, paused: false, corrupt: true))
        fixture.clock.advance(by: 7_200)
        let reopened = fixture.cache(useProductBaseline: true)
        await reopened.restore()
        XCTAssertEqual(reopened.view.refreshDays, 7)
        XCTAssertEqual(reopened.view.overseas.selection, selection)
        XCTAssertTrue(reopened.view.overseas.remotelyPaused)
        XCTAssertEqual(reopened.runtimeView().overseas.match(target), .original)
        XCTAssertThrowsError(try reopened.acceptRemotePolicy(signedPolicy(version: 1, paused: false)))
        try reopened.acceptRemotePolicy(signedPolicy(version: 3, paused: false))
        XCTAssertEqual(reopened.runtimeView().overseas.match(target), .managed)
    }

    func testUpgradeImmediatelyNarrowsApprovalFromAnOlderBundle() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let published = try XCTUnwrap(ISO8601DateFormatter().date(from: AccessGeoSiteCatalogue.bundled.publishedAt))
        let previousInstall = published.addingTimeInterval(-2 * 86_400)
        fixture.clock.setWall(previousInstall)
        let old = fixture.cache()
        await old.restore(migrating: smartAll)
        try old.requestOverseasPreview()
        let retired = URL(string: "https://www.aegis-retired-test-domain.com")!
        let retained = URL(string: "https://www.google.com")!
        let previous = try Self.overseas(1, positive: ["google.com", "aegis-retired-test-domain.com"],
                                         excluding: [], now: previousInstall, domestic: Vector.selectedProjection)
        try await old.apply(previous, using: XCTUnwrap(old.updateContext()))
        let selection = AccessOverseasSelection(enabled: true, mode: .all)
        try await old.confirmOverseas(old.overseasConfirmation(for: selection)) { true }
        XCTAssertEqual(old.runtimeView().overseas.match(retired), .managed)
        let record = try XCTUnwrap(fixture.storage.readLedger())
        var ledger = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any])
        ledger["overseasApprovedFromBundle"] = true
        try fixture.storage.writeLedger(JSONSerialization.data(withJSONObject: ledger))

        fixture.clock.setWall(published)
        XCTAssertLessThan(fixture.clock.wall, previous.expiresAt)
        fixture.fault.withLock { $0 = .afterFileSync }
        let duringFailure = fixture.cache(useProductBaseline: true)
        await duringFailure.restore()
        XCTAssertEqual(duringFailure.status, .ready)
        XCTAssertEqual(duringFailure.match(debian), .managed)
        XCTAssertNotEqual(duringFailure.runtimeView().overseas.match(retired), .managed)
        fixture.fault.withLock { $0 = nil }

        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let downloaded = try AccessGeoSiteAdmission.admitBundled(resources: resources)
        let context = try XCTUnwrap(duringFailure.updateContext())
        let flight = try duringFailure.beginOverseasRefresh(using: context)
        do {
            defer { duringFailure.endOverseasRefresh(flight) }
            try await duringFailure.apply(downloaded, using: context)
        }
        XCTAssertEqual(duringFailure.runtimeView().overseas.match(retained), .managed)
        XCTAssertEqual(duringFailure.runtimeView().overseas.match(retired), .original)

        for _ in 0..<2 {
            let reopened = fixture.cache(useProductBaseline: true)
            await reopened.restore()
            XCTAssertEqual(reopened.runtimeView().overseas.match(retired), .original)
            XCTAssertEqual(reopened.runtimeView().overseas.match(retained), .managed)
            XCTAssertTrue(reopened.runtimeView().overseas.usingBundledRules)
            XCTAssertEqual(reopened.highWater?.tag, AccessGeoSiteCatalogue.bundled.tag)
        }
    }

    func testNewerBundleCanBeApprovedOfflineAfterOlderUnapprovedPreviewExpires() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let old = fixture.cache()
        await old.restore()
        try old.requestOverseasPreview()
        let previous = try Self.overseas(1, positive: ["google.com"], excluding: [])
        try await old.apply(previous, using: XCTUnwrap(old.updateContext()))
        XCTAssertEqual(old.overseasPreview?.release, previous.receipt.tag)
        fixture.clock.advance(by: 8 * 86_400)

        let upgraded = fixture.cache(useProductBaseline: true)
        await upgraded.restore()
        XCTAssertEqual(upgraded.overseasPreview?.release, AccessGeoSiteCatalogue.bundled.tag)
        let selection = AccessOverseasSelection(enabled: true, mode: .all)
        let confirmation = try await upgraded.overseasConfirmation(for: selection)
        XCTAssertTrue(confirmation.bundled)
        try await upgraded.confirmOverseas(confirmation) { true }
        XCTAssertEqual(upgraded.runtimeView().overseas.match(URL(string: "https://www.google.com")!), .managed)
    }

    func testConfirmingNewOverseasBundleDiscardsOlderDomesticProposal() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let published = try XCTUnwrap(ISO8601DateFormatter().date(from: AccessGeoSiteCatalogue.bundled.publishedAt))
        fixture.clock.setWall(published.addingTimeInterval(-2 * 86_400))
        let old = fixture.cache()
        await old.restore(migrating: smartAll)
        let database = combined(debian: bundled(.debian),
            douban: bundled(.douban) + [Vector.rule(2, "new-coverage.example.com")], meituan: bundled(.meituan))
        let domestic = try Self.candidate(1, database: database, now: fixture.clock.wall)
        try await old.apply(domestic, using: XCTUnwrap(old.updateContext()))
        XCTAssertEqual(old.proposal(for: .douban)?.version, domestic.receipt.tag)

        fixture.clock.setWall(published)
        let upgraded = fixture.cache(useProductBaseline: true)
        await upgraded.restore()
        XCTAssertEqual(upgraded.proposal(for: .douban)?.version, domestic.receipt.tag)
        let selection = AccessOverseasSelection(enabled: true, mode: .all)
        let confirmation = try await upgraded.overseasConfirmation(for: selection)
        XCTAssertTrue(confirmation.bundled)
        try await upgraded.confirmOverseas(confirmation) { true }
        XCTAssertEqual(upgraded.highWater?.tag, AccessGeoSiteCatalogue.bundled.tag)
        XCTAssertNil(upgraded.proposal(for: .douban))
        XCTAssertNil(upgraded.stagedFileSHA256)
        XCTAssertEqual(upgraded.match(douban), .managed)
        XCTAssertEqual(upgraded.match(added), .original)

        let reopened = fixture.cache(useProductBaseline: true)
        await reopened.restore()
        XCTAssertNil(reopened.proposal(for: .douban))
        XCTAssertNil(reopened.stagedFileSHA256)
        XCTAssertEqual(reopened.match(douban), .managed)
        XCTAssertEqual(reopened.match(added), .original)
    }

    func testAdoptingNewOverseasBundleDiscardsOlderDomesticProposal() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let published = try XCTUnwrap(ISO8601DateFormatter().date(from: AccessGeoSiteCatalogue.bundled.publishedAt))
        fixture.clock.setWall(published.addingTimeInterval(-2 * 86_400))
        let old = fixture.cache()
        await old.restore(migrating: smartAll)
        try old.requestOverseasPreview()
        let baseline = combined(debian: bundled(.debian), douban: bundled(.douban), meituan: bundled(.meituan))
        let overseas = try Self.overseas(1, positive: ["google.com"], excluding: [],
                                         now: fixture.clock.wall, domestic: baseline)
        try await old.apply(overseas, using: XCTUnwrap(old.updateContext()))
        let selection = AccessOverseasSelection(enabled: true, mode: .all)
        try await old.confirmOverseas(old.overseasConfirmation(for: selection)) { true }
        try old.disableOverseas()

        fixture.clock.advance(by: 3_600)
        let database = combined(debian: bundled(.debian),
            douban: bundled(.douban) + [Vector.rule(2, "new-coverage.example.com")], meituan: bundled(.meituan))
        let domestic = try Self.candidate(2, database: database, now: fixture.clock.wall)
        try await old.apply(domestic, using: XCTUnwrap(old.updateContext()))
        XCTAssertEqual(old.proposal(for: .douban)?.version, domestic.receipt.tag)
        // The previous app supplied its own bundled receipt.
        let record = try XCTUnwrap(fixture.storage.readLedger())
        var ledger = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any])
        ledger["overseasApprovedFromBundle"] = true
        try fixture.storage.writeLedger(JSONSerialization.data(withJSONObject: ledger))

        fixture.clock.setWall(published)
        for _ in 0..<2 {
            let upgraded = fixture.cache(useProductBaseline: true)
            await upgraded.restore()
            XCTAssertEqual(upgraded.highWater?.tag, AccessGeoSiteCatalogue.bundled.tag)
            XCTAssertNil(upgraded.proposal(for: .douban))
            XCTAssertNil(upgraded.stagedFileSHA256)
            XCTAssertEqual(upgraded.match(douban), .managed)
            XCTAssertEqual(upgraded.match(added), .original)
        }
    }

    func testAgedBundledOverseasApprovalStaysRoutedWhileApplyingUnchangedRules() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let published = try XCTUnwrap(ISO8601DateFormatter().date(from: AccessGeoSiteCatalogue.bundled.publishedAt))
        fixture.clock.setWall(published.addingTimeInterval(30 * 86_400))
        let cache = fixture.cache(useProductBaseline: true)
        await cache.restore()
        let selection = AccessOverseasSelection(enabled: true, mode: .all)
        try await cache.confirmOverseas(cache.overseasConfirmation(for: selection)) { true }
        let retained = URL(string: "https://www.google.com")!
        XCTAssertEqual(cache.runtimeView().overseas.match(retained), .managed)
        var emittedViews = 0
        cache.onChange = { view in
            emittedViews += 1
            XCTAssertEqual(view.overseas.match(retained), .managed)
        }

        let successor = try Self.overseas(1, positive: ["google.com"], excluding: [], now: fixture.clock.wall)
        try await cache.apply(successor, using: XCTUnwrap(cache.updateContext()))
        XCTAssertGreaterThan(emittedViews, 0)
        XCTAssertEqual(cache.runtimeView().overseas.match(retained), .managed)
    }

    func testDownloadedRulesMatchingBundleKeepTheirOnlineDeadline() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let resourceURL = try XCTUnwrap(Bundle.main.resourceURL)
        let downloaded = try AccessGeoSiteAdmission.admitBundled(resources: resourceURL)
        let published = try XCTUnwrap(ISO8601DateFormatter().date(from: downloaded.receipt.publishedAt))
        let checked = published.addingTimeInterval(2 * 86_400)
        fixture.clock.setWall(checked)
        let cache = fixture.cache(useProductBaseline: true)
        await cache.restore()
        try cache.setRefreshInterval(days: 7)
        try cache.requestOverseasPreview()
        try await cache.apply(downloaded, using: XCTUnwrap(cache.updateContext()),
                              refreshed: .init(checkedAt: checked))
        let selection = AccessOverseasSelection(enabled: true, mode: .all)
        let confirmation = try await cache.overseasConfirmation(for: selection)
        XCTAssertFalse(confirmation.bundled)
        try await cache.confirmOverseas(confirmation) { true }
        XCTAssertFalse(cache.runtimeView().overseas.usingBundledRules)
        XCTAssertEqual(cache.refreshState.nextAttempt, downloaded.expiresAt.addingTimeInterval(-86_400))
    }

    func testExactBundleDownloadDoesNotReplaceItsApprovalSource() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let downloaded = try AccessGeoSiteAdmission.admitBundled(resources: resources)
        let published = try XCTUnwrap(ISO8601DateFormatter().date(from: downloaded.receipt.publishedAt))
        fixture.clock.setWall(published.addingTimeInterval(86_400))
        let cache = fixture.cache(useProductBaseline: true)
        await cache.restore()
        let selection = AccessOverseasSelection(enabled: true, mode: .all)
        try await cache.confirmOverseas(cache.overseasConfirmation(for: selection)) { true }
        XCTAssertTrue(cache.runtimeView().overseas.usingBundledRules)
        try await cache.apply(downloaded, using: XCTUnwrap(cache.updateContext()))
        XCTAssertTrue(cache.runtimeView().overseas.usingBundledRules)
        let cold = fixture.cache(useProductBaseline: true)
        await cold.restore()
        XCTAssertTrue(cold.runtimeView().overseas.usingBundledRules)
    }

    func testExpiryRetainsOnlyApprovedIntersectionWithOfflineRules() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: smartAll)
        let candidate = try Self.candidate(1, database: combined(
            debian: [Vector.rule(3, "debian.org")], douban: bundled(.douban), meituan: []))
        try await cache.apply(candidate, using: XCTUnwrap(cache.updateContext()))
        fixture.clock.advance(by: 8 * 86_400)
        let cold = fixture.cache()
        await cold.restore()
        XCTAssertEqual(cold.match(URL(string: "https://debian.org")!), .managed)
        XCTAssertEqual(cold.match(debian), .original)
        XCTAssertEqual(cold.match(URL(string: "https://dotdeb.org")!), .original)
        XCTAssertEqual(cold.match(URL(string: "https://meituan.com")!), .original)
    }

    func testRejectedOverseasRulesPublishDomesticUpdateAndSuppressConditionalRefresh() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: smartAll)
        try cache.requestOverseasPreview()
        cache.cancelOverseasPreview()
        XCTAssertFalse(cache.wantsOverseasRules)
        XCTAssertNotNil(cache.updateContext())
        try cache.requestOverseasPreview()
        let initial = try Self.overseas(1, positive: ["google.com"], excluding: [])
        try await cache.apply(initial, using: XCTUnwrap(cache.updateContext()))
        let selection = AccessOverseasSelection(enabled: true, categories: [.ai])
        try await cache.confirmOverseas(cache.overseasConfirmation(for: selection)) { true }
        let gemini = URL(string: "https://gemini.google.com")!
        XCTAssertEqual(cache.runtimeView().overseas.match(gemini), .managed)

        let database = Vector.group("DEBIAN", rules: [Vector.rule(3, "debian.org")])
        let receipt = try Self.candidate(2, database: database).receipt
        let checksum = try Vector.release(database).checksum
        let candidate = try AccessGeoSiteAdmission.admit(receipt: receipt, database: database, checksum: checksum,
            now: Vector.now, includeOverseas: true, allowDomesticFallback: true)
        XCTAssertTrue(candidate.overseasRejected)
        try await cache.apply(candidate, using: XCTUnwrap(cache.updateContext()), refreshed: .init(etag: "\"domestic\""))
        let cold = fixture.cache()
        await cold.restore()
        XCTAssertEqual(cold.highWater, receipt)
        let domestic = try XCTUnwrap(cold.proposal(for: .debian))
        try await cold.confirm(domestic)
        XCTAssertEqual(cold.match(URL(string: "https://debian.org")!), .managed)
        XCTAssertTrue(cold.view.overseas.refreshFailed)
        XCTAssertNil(cold.overseasPreview)
        XCTAssertNotEqual(cold.runtimeView().overseas.match(gemini), .managed)
        let conditional = try await cold.conditionalReceipt(using: XCTUnwrap(cold.updateContext()))
        XCTAssertNil(conditional)
    }

    func testFreshOfflineBaselineHasNoCalendarExpiryAndEmptySelectionSurvives() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        fixture.clock.advance(by: 40 * 365 * 86_400)
        let cache = fixture.cache()
        await cache.restore(migrating: smartAll)
        XCTAssertEqual(cache.status, .ready)
        XCTAssertEqual(cache.match(debian), .managed)
        XCTAssertEqual(cache.match(douban), .managed)
        XCTAssertEqual(cache.match(outside), .original)
        let empty = Cache.Selection(mode: .smart, categories: [])
        try cache.setSelection(empty)
        let reopened = fixture.cache()
        await reopened.restore(migrating: smartAll)
        XCTAssertEqual(reopened.selection, empty)
        XCTAssertEqual(reopened.match(debian), .original)
        XCTAssertNil(reopened.updateContext())
        XCTAssertNil(reopened.highWater)
    }

    func testNarrowingAndWithdrawalCommitWhileWideningWaitsForCurrentConsent() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let first = fixture.cache()
        await first.restore(migrating: smartAll)
        let v1 = try Self.candidate(1, database: Vector.selectedProjection)
        try await first.apply(v1, using: XCTUnwrap(first.updateContext()))
        XCTAssertEqual(first.match(URL(string: "https://dotdeb.org/")!), .managed)
        let v2 = try Self.candidate(2, database: combined(
            debian: [Vector.rule(3, "debian.org")],
            douban: bundled(.douban) + [Vector.rule(2, "new-coverage.example.com")],
            meituan: []))
        try await first.apply(v2, using: XCTUnwrap(first.updateContext()))
        XCTAssertEqual(first.highWater, v2.receipt)
        XCTAssertNotNil(first.activeFileSHA256)
        XCTAssertNotNil(first.stagedFileSHA256)
        XCTAssertEqual(first.match(debian), .original)
        XCTAssertEqual(first.match(URL(string: "https://debian.org/")!), .managed)
        XCTAssertEqual(first.match(douban), .managed)
        XCTAssertEqual(first.match(added), .original)
        XCTAssertEqual(first.match(URL(string: "https://www.meituan.com/")!), .original)
        let oldProposal = try XCTUnwrap(first.proposal(for: .douban))
        XCTAssertEqual(oldProposal.addedRules.map(\.host), ["new-coverage.example.com"])

        let restored = fixture.cache()
        await restored.restore(migrating: Cache.Selection())
        XCTAssertEqual(restored.selection, smartAll)
        XCTAssertEqual(restored.highWater, v2.receipt)
        XCTAssertEqual(restored.match(douban), .managed)
        XCTAssertEqual(restored.match(added), .original)
        XCTAssertEqual(restored.match(URL(string: "https://www.meituan.com/")!), .original)
        await expectFailure { try await restored.confirm(oldProposal) }
        let proposal = try XCTUnwrap(restored.proposal(for: .douban))
        try await restored.confirm(proposal)
        XCTAssertEqual(restored.match(added), .managed)
        XCTAssertNil(restored.stagedFileSHA256)
        await expectFailure { try await restored.apply(v1, using: XCTUnwrap(restored.updateContext())) }

        let v3 = try Self.candidate(3, database: Vector.selectedProjection)
        try await restored.apply(v3, using: XCTUnwrap(restored.updateContext()))
        XCTAssertNotNil(restored.proposal(for: .meituan), "A withdrawn group needs new approval")
        XCTAssertEqual(restored.match(URL(string: "https://www.meituan.com/")!), .original)
        XCTAssertNotNil(restored.proposal(for: .debian), "Full to domain expands coverage")
    }

    func testNewSelectionAndCandidateInvalidateConsentAndInFlightPublication() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: smartAll)
        let more = try Self.candidate(1, database: combined(debian: bundled(.debian),
            douban: bundled(.douban) + [Vector.rule(2, "new-coverage.example.com")], meituan: bundled(.meituan)))
        try await cache.apply(more, using: XCTUnwrap(cache.updateContext()))
        let oldContext = try XCTUnwrap(cache.updateContext())
        let proposal = try XCTUnwrap(cache.proposal(for: .douban))
        try cache.setSelection(Cache.Selection(mode: .manual, categories: smartAll.categories))
        XCTAssertEqual(cache.match(douban), .original)
        XCTAssertNil(cache.updateContext())
        await expectFailure { try await cache.confirm(proposal) }
        try cache.setSelection(smartAll)
        let next = try Self.candidate(2, database: Vector.selectedProjection)
        await expectFailure { try await cache.apply(next, using: oldContext) }
        try await cache.apply(next, using: XCTUnwrap(cache.updateContext()))
        await expectFailure { try await cache.confirm(proposal) }
        XCTAssertEqual(cache.match(added), .original)
    }

    func testColdRestoreNeverWalksOldFilesAndVerifiedSameTagCanRepairItsBytes() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: smartAll)
        try await cache.apply(Self.candidate(1, database: Vector.selectedProjection), using: XCTUnwrap(cache.updateContext()))
        let oldHash = try XCTUnwrap(cache.activeFileSHA256)
        let old = try Data(contentsOf: fixture.storage.blobURL(.active, oldHash))
        let approved = try Self.candidate(2, database: combined(debian: [Vector.rule(3, "debian.org")],
            douban: bundled(.douban), meituan: bundled(.meituan)))
        try await cache.apply(approved, using: XCTUnwrap(cache.updateContext()))
        let authoritative = fixture.storage.blobURL(.active, try XCTUnwrap(cache.activeFileSHA256))
        try old.write(to: fixture.storage.blobURL(.active, oldHash))
        try old.write(to: authoritative)
        let wrong = fixture.cache()
        await wrong.restore()
        XCTAssertEqual(wrong.highWater, approved.receipt)
        XCTAssertEqual(wrong.match(debian), .indeterminate)
        XCTAssertEqual(wrong.match(outside), .indeterminate)
        try FileManager.default.removeItem(at: authoritative)
        let missing = fixture.cache()
        await missing.restore()
        XCTAssertEqual(missing.match(debian), .indeterminate)
        try await missing.apply(approved, using: XCTUnwrap(missing.updateContext()))
        XCTAssertEqual(missing.match(debian), .original)
        XCTAssertEqual(missing.match(URL(string: "https://debian.org/")!), .managed)
    }

    func testKeychainReadFailureAndInstallationMarkerNeverReinitialize() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let first = fixture.cache()
        await first.restore(migrating: smartAll)
        try first.setSelection(Cache.Selection(mode: .smart, categories: []))
        fixture.fault.withLock { $0 = .readLedger }
        let locked = fixture.cache()
        await locked.restore(migrating: smartAll)
        XCTAssertEqual(locked.status, .unavailable)
        XCTAssertEqual(locked.match(debian), .indeterminate)
        fixture.fault.withLock { $0 = nil }
        let restored = fixture.cache()
        await restored.restore(migrating: smartAll)
        XCTAssertEqual(restored.selection?.categories, [])
        XCTAssertEqual(SecItemDelete(fixture.keychainQuery as CFDictionary), errSecSuccess)
        let missing = fixture.cache()
        await missing.restore(migrating: smartAll)
        XCTAssertEqual(missing.status, .unavailable)
        XCTAssertNil(missing.selection)
        XCTAssertEqual(missing.match(debian), .indeterminate)
    }

    func testAtomicWriteFailpointsKeepAuthoritativeOldCommitAndBlockUnsavedSelection() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let first = fixture.cache()
        await first.restore(migrating: smartAll)
        let v1 = try Self.candidate(1, database: Vector.selectedProjection)
        try await first.apply(v1, using: XCTUnwrap(first.updateContext()))
        let v2 = try Self.candidate(2, database: combined(debian: [], douban: bundled(.douban), meituan: bundled(.meituan)))
        for failure in [AccessGeoSiteStorage.Step.afterFileSync, .afterRename, .afterDirectorySync, .writeLedger] {
            let context = try XCTUnwrap(first.updateContext())
            fixture.fault.withLock { $0 = failure }
            await expectFailure { try await first.apply(v2, using: context) }
            fixture.fault.withLock { $0 = nil }
            let recovered = fixture.cache()
            await recovered.restore()
            XCTAssertEqual(recovered.highWater, v1.receipt)
            XCTAssertEqual(recovered.match(debian), .managed)
        }
        fixture.fault.withLock { $0 = .writeLedger }
        XCTAssertThrowsError(try first.setSelection(.init(mode: .manual, categories: [])))
        XCTAssertEqual(first.status, .unsaved)
        XCTAssertEqual(first.match(debian), .indeterminate)
        XCTAssertNil(first.updateContext())
    }

    func testExpiryAndClockRollbackPersistWithApprovedOfflineBaseline() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let first = fixture.cache()
        await first.restore(migrating: smartAll)
        let official = try Self.candidate(1, database: Vector.selectedProjection)
        try await first.apply(official, using: XCTUnwrap(first.updateContext()))
        let state = Cache.RefreshState(failureCount: 2, nextAttempt: Vector.now.addingTimeInterval(300))
        try first.setRefreshState(state, using: XCTUnwrap(first.updateContext()))
        fixture.clock.setWall(Vector.now.addingTimeInterval(-301))
        XCTAssertEqual(first.match(debian), .indeterminate)
        XCTAssertNil(first.updateContext())
        fixture.clock.setWall(Vector.now)
        fixture.clock.advance(by: 7 * 86_400 + 1)
        XCTAssertEqual(first.match(debian), .managed)
        try first.checkpointClock()
        fixture.clock.setWall(Vector.now)
        let reboot = fixture.cache()
        await reboot.restore()
        XCTAssertEqual(reboot.refreshState, state)
        XCTAssertEqual(reboot.highWater, official.receipt)
        XCTAssertEqual(reboot.status, .clockRollback)
        XCTAssertEqual(reboot.match(debian), .indeterminate)
        fixture.clock.setWall(Vector.now.addingTimeInterval(7 * 86_400 + 2))
        try reboot.checkpointClock()
        XCTAssertEqual(reboot.match(debian), .managed)
        XCTAssertEqual(reboot.match(outside), .original)
    }

    func testUnavailableClockCheckpointCanRecoverWithoutReinitializingLedger() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: smartAll)
        let receipt = try Self.candidate(1, database: Vector.selectedProjection)
        try await cache.apply(receipt, using: XCTUnwrap(cache.updateContext()))
        fixture.clock.advance(by: 60)
        fixture.fault.withLock { $0 = .writeLedger }
        XCTAssertThrowsError(try cache.checkpointClock())
        XCTAssertEqual(cache.status, .unavailable)
        XCTAssertEqual(cache.match(debian), .indeterminate)
        fixture.fault.withLock { $0 = nil }
        try cache.checkpointClock()
        XCTAssertEqual(cache.status, .ready)
        XCTAssertEqual(cache.highWater, receipt.receipt)
        XCTAssertEqual(cache.selection, smartAll)
        XCTAssertEqual(cache.match(debian), .managed)
    }

    func testDeltaOver32RemainsStagedWithoutAnApprovalToken() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: smartAll)
        let extensionRules = (1...33).map { Vector.rule(2, "site\($0).example.net") }
        let newer = try Self.candidate(1, database: combined(debian: bundled(.debian),
            douban: bundled(.douban) + extensionRules, meituan: bundled(.meituan)))
        try await cache.apply(newer, using: XCTUnwrap(cache.updateContext()))
        XCTAssertEqual(cache.highWater, newer.receipt)
        XCTAssertNotNil(cache.stagedFileSHA256)
        XCTAssertNil(cache.proposal(for: .douban))
        XCTAssertEqual(cache.match(douban), .managed)
        XCTAssertEqual(cache.match(URL(string: "https://site1.example.net/")!), .original)
    }

    func testCancelledFileWorkAndInterveningModeChangeCannotPublish() async throws {
        let gate = WriteGate()
        let fixture = Fixture(onStep: gate.wait)
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: smartAll)
        let initial = try Self.candidate(1, database: Vector.selectedProjection)
        try await cache.apply(initial, using: XCTUnwrap(cache.updateContext()))
        let next = try Self.candidate(2, database: combined(debian: [], douban: bundled(.douban), meituan: bundled(.meituan)))
        let context = try XCTUnwrap(cache.updateContext())
        gate.arm()
        let publication = Task { try await cache.apply(next, using: context) }
        defer { gate.release.signal() }
        for _ in 0..<100 where !gate.entered { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(gate.entered)
        try cache.setSelection(.init(mode: .manual, categories: smartAll.categories))
        publication.cancel()
        gate.release.signal()
        await expectFailure { try await publication.value }
        let restored = fixture.cache()
        await restored.restore()
        XCTAssertEqual(restored.highWater, initial.receipt)
        XCTAssertEqual(restored.selection?.mode, .manual)
        XCTAssertEqual(restored.match(debian), .original)
    }

    func testCoordinatorUsesColdAuthorityAndKeepsExplicitRoutesWhenCacheIsMissing() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let first = fixture.cache()
        await first.restore(migrating: smartAll)
        try await first.apply(Self.candidate(1, database: Vector.selectedProjection), using: XCTUnwrap(first.updateContext()))
        let active = fixture.storage.blobURL(.active, try XCTUnwrap(first.activeFileSHA256))
        try FileManager.default.removeItem(at: active)
        let suite = "aegis.geosite.route-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("manual", forKey: "browser.websiteAcceleration.mode")
        defaults.set(["www.douban.com": "original", "example.net": "service"],
                     forKey: "browser.websiteAcceleration.siteChoices.v1")
        let cold = fixture.cache()
        let coordinator = AccessHostStoreCoordinator(channel: .dev, locationPreferences: defaults, geoSiteCache: cold)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        for _ in 0..<100 where cold.status == .loading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(cold.status, .ready)
        XCTAssertEqual(coordinator.websiteAccelerationMode, .smart)
        XCTAssertTrue(coordinator.isMainFrameRouteIndeterminate(tab: tab, url: debian))
        XCTAssertFalse(coordinator.canSendMainFrame(tab: tab, url: debian))
        tab.loadFromAddressBar(debian)
        XCTAssertNotNil(tab.loadingError)
        XCTAssertFalse(tab.isLoading)
        XCTAssertFalse(coordinator.isMainFrameRouteIndeterminate(tab: tab, url: douban))
        XCTAssertTrue(coordinator.canSendMainFrame(tab: tab, url: douban))
        XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: outside))
        try cold.setSelection(.init(mode: .smart, categories: []))
        XCTAssertFalse(coordinator.isMainFrameRouteIndeterminate(tab: tab, url: debian))
        XCTAssertTrue(coordinator.canSendMainFrame(tab: tab, url: debian))
        XCTAssertTrue(coordinator.requiresProxy(tab: tab, url: outside))
    }

    func testOverseasOnlyRefreshRequiresConsentAndSurvivesColdStart() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .smart, categories: []))
        XCTAssertNil(cache.updateContext())
        try cache.requestOverseasPreview()
        let source = try Self.overseas(1, positive: ["google.com", "fast.com"], excluding: ["dl.google.com"])
        try await cache.apply(source, using: XCTUnwrap(cache.updateContext()), refreshed: .init(etag: "\"overseas\""))
        let gemini = URL(string: "https://gemini.google.com")!
        let speed = URL(string: "https://fast.com")!
        XCTAssertEqual(cache.runtimeView().overseas.match(gemini), .original)
        XCTAssertNil(cache.updateContext())
        let choice = AccessOverseasSelection(enabled: true, categories: [.ai])
        let consent = try await cache.overseasConfirmation(for: choice)

        try cache.setSelection(.init(mode: .manual, categories: []))
        try cache.setSelection(.init(mode: .smart, categories: []))
        await expectFailure { try await cache.confirmOverseas(consent) { true } }
        let current = try await cache.overseasConfirmation(for: choice)
        await expectFailure { try await cache.confirmOverseas(current) { false } }
        try await cache.confirmOverseas(current) { true }
        XCTAssertEqual(cache.runtimeView().overseas.match(gemini), .managed)
        XCTAssertEqual(cache.runtimeView().overseas.route(for: gemini).grant, .categories([.ai], release: source.receipt.tag))
        XCTAssertEqual(cache.runtimeView().overseas.match(speed), .original)
        let conditional = try await cache.conditionalReceipt(using: XCTUnwrap(cache.updateContext()))
        XCTAssertEqual(conditional?.etag, "\"overseas\"")
        // A domestic choice without an accepted release must not discard the
        // overseas proof of the stored release (no full redownload).
        try cache.setSelection(.init(mode: .smart, categories: [.debian]))
        let withDomestic = try await cache.conditionalReceipt(using: XCTUnwrap(cache.updateContext()))
        XCTAssertEqual(withDomestic?.etag, "\"overseas\"")
        try cache.setSelection(.init(mode: .smart, categories: []))

        let reopened = fixture.cache()
        await reopened.restore()
        XCTAssertEqual(reopened.view.overseas.selection, choice)
        XCTAssertEqual(reopened.runtimeView().overseas.match(gemini), .managed)
        XCTAssertEqual(reopened.runtimeView().overseas.match(speed), .original)
        try reopened.disableOverseas()
        let disabled = fixture.cache()
        await disabled.restore()
        XCTAssertFalse(disabled.view.overseas.selection.enabled)
        XCTAssertEqual(disabled.view.overseas.selection.categories, [.ai])
        XCTAssertEqual(disabled.runtimeView().overseas.match(gemini), .original)
        let emptyChoice = AccessOverseasSelection(enabled: true, mode: .categories)
        try await disabled.confirmOverseas(disabled.overseasConfirmation(for: emptyChoice)) { true }
        let coldEmpty = fixture.cache()
        await coldEmpty.restore()
        XCTAssertEqual(coldEmpty.view.overseas.selection, emptyChoice)
        XCTAssertFalse(coldEmpty.wantsOverseasRules)
        XCTAssertNil(coldEmpty.updateContext())
    }

    func testMixedOverseasUpdateAppliesWithdrawalsAndNewExceptionsBeforeConsent() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .smart, categories: []))
        try cache.requestOverseasPreview()
        let v1 = try Self.overseas(1, positive: ["google.com", "fast.com"], excluding: ["dl.google.com"])
        try await cache.apply(v1, using: XCTUnwrap(cache.updateContext()))
        let all = AccessOverseasSelection(enabled: true, mode: .all, categories: [.ai])
        try await cache.confirmOverseas(cache.overseasConfirmation(for: all)) { true }
        let v2 = try Self.overseas(2, positive: ["google.com", "netflix.com"], excluding: ["fonts.google.com"])
        try await cache.apply(v2, using: XCTUnwrap(cache.updateContext()))
        let view = cache.runtimeView().overseas
        func url(_ host: String) -> URL { URL(string: "https://\(host)")! }
        XCTAssertEqual(view.match(url("fast.com")), .original)
        XCTAssertEqual(view.match(url("dl.google.com")), .original)
        XCTAssertEqual(view.match(url("fonts.google.com")), .original)
        XCTAssertEqual(view.match(url("netflix.com")), .original)
        XCTAssertEqual(view.match(url("www.google.com")), .managed)
        XCTAssertTrue(cache.view.overseas.awaitingExpansion)

        let reopened = fixture.cache()
        await reopened.restore()
        XCTAssertEqual(reopened.runtimeView().overseas, view)
        let proposal = try await reopened.overseasConfirmation(for: all)
        XCTAssertEqual(proposal.newRules.map(\.value), ["netflix.com"])
        XCTAssertEqual(proposal.removedExclusions.map(\.value), ["dl.google.com"])
        try await reopened.confirmOverseas(proposal) { true }
        XCTAssertFalse(reopened.view.overseas.awaitingExpansion)
        XCTAssertEqual(reopened.runtimeView().overseas.match(url("dl.google.com")), .managed)
        XCTAssertEqual(reopened.runtimeView().overseas.match(url("fonts.google.com")), .original)
        XCTAssertEqual(reopened.runtimeView().overseas.match(url("netflix.com")), .managed)
    }

    func testOverseasAccelerationIsIndependentOfTheDomesticMode() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .manual, categories: []))
        XCTAssertNil(cache.updateContext())
        try cache.requestOverseasPreview()
        let source = try Self.overseas(1, positive: ["google.com", "fast.com"], excluding: ["dl.google.com"])
        try await cache.apply(source, using: XCTUnwrap(cache.updateContext()))
        let gemini = URL(string: "https://gemini.google.com")!
        let choice = AccessOverseasSelection(enabled: true, categories: [.ai])
        try await cache.confirmOverseas(cache.overseasConfirmation(for: choice)) { true }
        XCTAssertEqual(cache.runtimeView().overseas.match(gemini), .managed)
        XCTAssertNotNil(cache.updateContext())
        try cache.setSelection(.init(mode: .smart, categories: []))
        XCTAssertEqual(cache.runtimeView().overseas.match(gemini), .managed)
        try cache.setSelection(.init(mode: .manual, categories: []))
        XCTAssertEqual(cache.runtimeView().overseas.match(gemini), .managed)
        XCTAssertEqual(cache.runtimeView().match(gemini), .original)

        let reopened = fixture.cache()
        await reopened.restore()
        XCTAssertEqual(reopened.runtimeView().overseas.match(gemini), .managed)
        XCTAssertNotNil(reopened.updateContext())
    }

    func testOverseasExactScopeRetainsSharedHostsWhenExclusionUnionExceedsSourceLimit() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .smart, categories: []))
        try cache.requestOverseasPreview()
        let positive = Vector.group("GFWLIST-CN", rules: [Vector.rule(3, "chatgpt.com"), Vector.rule(3, "claude.ai")])
        let openAI = Vector.group("OPENAI", rules: [Vector.rule(3, "chatgpt.com")])
        let anthropic = Vector.group("ANTHROPIC", rules: [Vector.rule(3, "claude.ai")])
        let shared = (1...511).map { Vector.rule(2, "x-\($0).example.net") }
        let oldExceptions = Vector.group("GFWLIST-CN-EXCLUDE", rules: shared + [Vector.rule(2, "old.example.net")])
        let newExceptions = Vector.group("GFWLIST-CN-EXCLUDE", rules: shared + [Vector.rule(2, "new.example.net")])
        let v1 = try Self.candidate(1, database: positive + oldExceptions + openAI, includeOverseas: true)
        let v2 = try Self.candidate(2, database: positive + newExceptions + openAI + anthropic, includeOverseas: true)
        try await cache.apply(v1, using: XCTUnwrap(cache.updateContext()))
        let ai = AccessOverseasSelection(enabled: true, categories: [.ai])
        try await cache.confirmOverseas(cache.overseasConfirmation(for: ai)) { true }
        try await cache.apply(v2, using: XCTUnwrap(cache.updateContext()))
        let cold = fixture.cache()
        await cold.restore()
        XCTAssertEqual(cold.runtimeView().overseas.match(URL(string: "https://chatgpt.com")!), .managed)
        XCTAssertEqual(cold.runtimeView().overseas.match(URL(string: "https://claude.ai")!), .original)
        let candidate = try await cold.overseasConfirmation(for: ai)
        XCTAssertEqual(candidate.newRules.map(\.value), ["claude.ai"])
    }

    func testOverseasAllScopeRetainsDomainAcrossTwoFullExceptionSets() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .smart, categories: []))
        try cache.requestOverseasPreview()
        let oldExceptions = (1...512).map { "old-\($0).example.com" }
        let newExceptions = (1...512).map { "new-\($0).example.com" }
        let old = try Self.overseas(1, positive: ["example.com"], excluding: oldExceptions)
        let newer = try Self.overseas(2, positive: ["example.com", "example.net"], excluding: newExceptions)
        try await cache.apply(old, using: XCTUnwrap(cache.updateContext()))
        let all = AccessOverseasSelection(enabled: true, mode: .all)
        try await cache.confirmOverseas(cache.overseasConfirmation(for: all)) { true }
        try await cache.apply(newer, using: XCTUnwrap(cache.updateContext()))
        let cold = fixture.cache()
        await cold.restore()
        XCTAssertTrue(cold.view.overseas.awaitingExpansion)
        XCTAssertEqual(cold.runtimeView().overseas.match(URL(string: "https://unchanged.example.com")!), .managed)
        XCTAssertEqual(cold.runtimeView().overseas.match(URL(string: "https://old-1.example.com")!), .original)
        XCTAssertEqual(cold.runtimeView().overseas.match(URL(string: "https://new-1.example.com")!), .original)
        XCTAssertEqual(cold.runtimeView().overseas.match(URL(string: "https://example.org")!), .original)
        await expectExpansionTooLarge { try await cold.overseasConfirmation(for: all) }
        let flight = try cold.beginOverseasRefresh(using: XCTUnwrap(cold.updateContext()))
        defer { cold.endOverseasRefresh(flight) }
        let interrupted = fixture.cache()
        await interrupted.restore()
        XCTAssertEqual(interrupted.runtimeView().overseas.match(URL(string: "https://example.org")!), .original)
        XCTAssertEqual(interrupted.runtimeView().overseas.match(URL(string: "https://example.net")!), .original)
        XCTAssertEqual(interrupted.runtimeView().overseas.match(URL(string: "https://unchanged.example.com")!), .indeterminate)
        fixture.clock.advance(by: 8 * 86_400)
        XCTAssertEqual(interrupted.runtimeView().overseas.match(URL(string: "https://example.org")!), .original)
        XCTAssertEqual(interrupted.runtimeView().overseas.match(URL(string: "https://example.net")!), .original)
        fixture.clock.setWall(fixture.clock.wall.addingTimeInterval(-600))
        XCTAssertEqual(interrupted.runtimeView().status, .clockRollback)
        XCTAssertEqual(interrupted.runtimeView().overseas.match(URL(string: "https://example.org")!), .original)
    }

    func testOverseasExpansionLimitSurvivesExpiryOfThePreviouslyNarrowedSnapshot() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .smart, categories: []))
        try cache.requestOverseasPreview()
        let exceptions = (1...33).map { "blocked-\($0).example.com" }
        let v1 = try Self.overseas(1, positive: ["example.com"], excluding: exceptions)
        let v2 = try Self.overseas(2, positive: ["example.com"], excluding: [])
        try await cache.apply(v1, using: XCTUnwrap(cache.updateContext()))
        let all = AccessOverseasSelection(enabled: true, mode: .all)
        try await cache.confirmOverseas(cache.overseasConfirmation(for: all)) { true }
        try await cache.apply(v2, using: XCTUnwrap(cache.updateContext()))
        await expectFailure { _ = try await cache.overseasConfirmation(for: all) }
        fixture.clock.advance(by: 8 * 86_400)
        let v3 = try Self.overseas(3, positive: ["example.com"], excluding: [], now: fixture.clock.wall)
        try await cache.apply(v3, using: XCTUnwrap(cache.updateContext()))
        XCTAssertEqual(cache.runtimeView().overseas.match(URL(string: "https://kept.example.com")!), .managed)
        XCTAssertEqual(cache.runtimeView().overseas.match(URL(string: "https://blocked-1.example.com")!), .original)
        await expectExpansionTooLarge { try await cache.overseasConfirmation(for: all) }
    }

    func testOverseasSnapshotCrashesAndCorruptionCannotPromoteUncommittedRules() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .smart, categories: []))
        try cache.requestOverseasPreview()
        let v1 = try Self.overseas(1, positive: ["google.com"], excluding: [])
        try await cache.apply(v1, using: XCTUnwrap(cache.updateContext()))
        let all = AccessOverseasSelection(enabled: true, mode: .all)
        let target = URL(string: "https://gemini.google.com")!
        let consent = try await cache.overseasConfirmation(for: all)
        for fault in [AccessGeoSiteStorage.Step.afterFileSync, .afterRename, .afterDirectorySync, .writeLedger] {
            fixture.fault.withLock { $0 = fault }
            await expectFailure { try await cache.confirmOverseas(consent) { true } }
            fixture.fault.withLock { $0 = nil }
            let reopened = fixture.cache()
            await reopened.restore()
            XCTAssertEqual(reopened.runtimeView().overseas.match(target), .original)
        }
        try await cache.confirmOverseas(consent) { true }
        func blob(approved: Bool) throws -> URL {
            let files = try FileManager.default.contentsOfDirectory(at: fixture.storage.directory, includingPropertiesForKeys: nil)
            return try XCTUnwrap(files.first { file in
                guard file.lastPathComponent.hasPrefix("overseas-"), file.pathExtension == "json",
                      let data = try? Data(contentsOf: file),
                      let content = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
                return (content["approved"] != nil) == approved
            })
        }
        try Data("damaged stage".utf8).write(to: blob(approved: false))
        let intact = fixture.cache()
        await intact.restore()
        XCTAssertEqual(intact.runtimeView().overseas.match(target), .managed)
        XCTAssertNil(intact.overseasPreview)
        await expectFailure { _ = try await intact.overseasConfirmation(for: all) }
        try Data("damaged active".utf8).write(to: blob(approved: true))
        let broken = fixture.cache()
        await broken.restore()
        XCTAssertTrue(broken.view.overseas.selection.enabled)
        XCTAssertEqual(broken.runtimeView().overseas.match(target), .indeterminate)
        XCTAssertTrue(broken.view.overseas.awaitingExpansion)
    }

    func testVerifiedOverseasWithdrawalSurvivesFailedPublicationRestartAndRelisting() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .smart, categories: []))
        try cache.requestOverseasPreview()
        let v1 = try Self.overseas(1, positive: ["google.com"], excluding: [])
        try await cache.apply(v1, using: XCTUnwrap(cache.updateContext()))
        let all = AccessOverseasSelection(enabled: true, mode: .all)
        let approved = try await cache.overseasConfirmation(for: all)
        try await cache.confirmOverseas(approved) { true }

        let target = URL(string: "https://gemini.google.com")!
        let v2 = try Self.overseas(2, positive: ["google.com"], excluding: ["gemini.google.com"])
        let relisted = try Self.overseas(3, positive: ["google.com"], excluding: [])
        fixture.fault.withLock { $0 = .writeLedger }
        await expectFailure { try await cache.apply(v2, using: XCTUnwrap(cache.updateContext())) }
        await expectFailure { try await cache.apply(relisted, using: XCTUnwrap(cache.updateContext())) }
        fixture.fault.withLock { $0 = nil }
        XCTAssertEqual(cache.runtimeView().overseas.match(target), .indeterminate)
        XCTAssertNil(cache.overseasPreview)
        await expectFailure { _ = try await cache.overseasConfirmation(for: all) }

        let reopened = fixture.cache()
        await reopened.restore()
        XCTAssertEqual(reopened.runtimeView().overseas.match(target), .indeterminate)
        XCTAssertNil(reopened.overseasPreview)
        await expectFailure { try await reopened.apply(v2, using: XCTUnwrap(reopened.updateContext())) }
        try await reopened.apply(relisted, using: XCTUnwrap(reopened.updateContext()))
        XCTAssertEqual(reopened.runtimeView().overseas.match(target), .indeterminate)
        await expectExpansionTooLarge { try await reopened.overseasConfirmation(for: all) }
        try reopened.disableOverseas()
        let newApproval = try await reopened.overseasConfirmation(for: all)
        try await reopened.confirmOverseas(newApproval) { true }
        XCTAssertEqual(reopened.runtimeView().overseas.match(target), .managed)
    }

    func testVerifiedOverseasWithdrawalSurvivesCancellationDuringDiskPublish() async throws {
        let gate = WriteGate()
        let fixture = Fixture(onStep: gate.wait)
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .smart, categories: []))
        try cache.requestOverseasPreview()
        let v1 = try Self.overseas(1, positive: ["google.com"], excluding: [])
        try await cache.apply(v1, using: XCTUnwrap(cache.updateContext()))
        let all = AccessOverseasSelection(enabled: true, mode: .all)
        try await cache.confirmOverseas(cache.overseasConfirmation(for: all)) { true }
        let target = URL(string: "https://gemini.google.com")!
        let v2 = try Self.overseas(2, positive: ["google.com"], excluding: ["gemini.google.com"])
        let context = try XCTUnwrap(cache.updateContext())
        gate.arm()
        let update = Task { try await cache.apply(v2, using: context) }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(gate.entered)
        XCTAssertEqual(cache.runtimeView().overseas.match(target), .indeterminate)
        update.cancel()
        gate.release.signal()
        await expectFailure { try await update.value }
        let reopened = fixture.cache()
        await reopened.restore()
        XCTAssertEqual(reopened.runtimeView().overseas.match(target), .indeterminate)
    }

    func testOverseasWithdrawalSurvivesMarkerFailureAndForegroundLoss() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .smart, categories: []))
        try cache.requestOverseasPreview()
        let v1 = try Self.overseas(1, positive: ["google.com"], excluding: [])
        try await cache.apply(v1, using: XCTUnwrap(cache.updateContext()))
        let all = AccessOverseasSelection(enabled: true, mode: .all)
        try await cache.confirmOverseas(cache.overseasConfirmation(for: all)) { true }
        let target = URL(string: "https://gemini.google.com")!
        let context = try XCTUnwrap(cache.updateContext())
        let flight = try cache.beginOverseasRefresh(using: context)
        let v2 = try Self.overseas(2, positive: ["google.com"], excluding: ["gemini.google.com"])
        fixture.fault.withLock { $0 = .writeOverseasWithdrawal }
        await expectFailure { try await cache.apply(v2, using: context) { false } }
        cache.endOverseasRefresh(flight)
        fixture.fault.withLock { $0 = nil }
        let offlineRetry = try cache.beginOverseasRefresh(using: context)
        cache.endOverseasRefresh(offlineRetry)
        let cold = fixture.cache()
        await cold.restore()
        XCTAssertEqual(cold.runtimeView().overseas.match(target), .indeterminate)
        XCTAssertNil(cold.overseasPreview)
        await expectFailure { try await cold.apply(v1, using: XCTUnwrap(cold.updateContext())) }
    }

    func testNewlyVerifiedOverseasReleaseInvalidatesConsentSealingAnOlderOffer() async throws {
        let gate = WriteGate()
        let fixture = Fixture(onStep: gate.wait)
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: smartAll)
        try cache.requestOverseasPreview()
        let v1 = try Self.overseas(1, positive: ["google.com"], excluding: [])
        try await cache.apply(v1, using: XCTUnwrap(cache.updateContext()))
        let all = AccessOverseasSelection(enabled: true, mode: .all)
        let pending = try await cache.overseasConfirmation(for: all)
        let context = try XCTUnwrap(cache.updateContext())
        gate.arm()
        let consent = Task { try await cache.confirmOverseas(pending) { true } }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(gate.entered)
        let v2 = try Self.candidate(2, database: Vector.selectedProjection)
        XCTAssertFalse(cache.wantsOverseasRules)
        await expectFailure { try await cache.apply(v2, using: context) }
        gate.release.signal()
        await expectFailure { try await consent.value }
        XCTAssertFalse(cache.view.overseas.selection.enabled)
        XCTAssertNil(cache.overseasPreview)
    }

    func testCorruptWithdrawalRecordPreservesLegacyRulesWhileHoldingOverseas() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: smartAll)
        try cache.requestOverseasPreview()
        let data = Vector.selectedProjection
            + Vector.group("GFWLIST-CN", rules: [Vector.rule(2, "google.com")])
            + Vector.group("GFWLIST-CN-EXCLUDE", rules: [])
        let v1 = try Self.candidate(1, database: data, includeOverseas: true)
        try await cache.apply(v1, using: XCTUnwrap(cache.updateContext()))
        let all = AccessOverseasSelection(enabled: true, mode: .all)
        try await cache.confirmOverseas(cache.overseasConfirmation(for: all)) { true }
        try fixture.storage.writeOverseasWithdrawal(Data("malformed".utf8))
        let cold = fixture.cache()
        await cold.restore()
        XCTAssertEqual(cold.match(debian), .managed)
        XCTAssertEqual(cold.runtimeView().overseas.match(URL(string: "https://www.google.com")!), .indeterminate)
        XCTAssertNil(cold.overseasPreview)
    }

    func testFirstFailedOverseasPublicationPreservesReceiptWithoutSnapshotPointers() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: smartAll)
        try cache.requestOverseasPreview()
        let newer = try Self.overseas(2, positive: [], excluding: [])
        fixture.fault.withLock { $0 = .writeLedger }
        await expectFailure { try await cache.apply(newer, using: XCTUnwrap(cache.updateContext())) }
        fixture.fault.withLock { $0 = nil }
        let cold = fixture.cache()
        await cold.restore()
        let newerLegacy = try Self.candidate(3, database: Vector.selectedProjection)
        fixture.fault.withLock { $0 = .writeLedger }
        await expectFailure { try await cold.apply(newerLegacy, using: XCTUnwrap(cold.updateContext())) }
        fixture.fault.withLock { $0 = nil }
        let retried = fixture.cache()
        await retried.restore()
        try retried.requestOverseasPreview()
        await expectFailure { try await retried.apply(newer, using: XCTUnwrap(retried.updateContext())) }
        XCTAssertNil(retried.overseasPreview)
    }

    func testFailedOverseasDisableHoldsAfterRestart() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .smart, categories: []))
        try cache.requestOverseasPreview()
        let source = try Self.overseas(1, positive: ["google.com"], excluding: [])
        try await cache.apply(source, using: XCTUnwrap(cache.updateContext()))
        let all = AccessOverseasSelection(enabled: true, mode: .all)
        try await cache.confirmOverseas(cache.overseasConfirmation(for: all)) { true }
        let target = URL(string: "https://gemini.google.com")!
        fixture.fault.withLock { $0 = .writeLedger }
        XCTAssertThrowsError(try cache.disableOverseas())
        fixture.fault.withLock { $0 = nil }
        let cold = fixture.cache()
        await cold.restore()
        XCTAssertEqual(cold.runtimeView().overseas.match(target), .indeterminate)
        try await cold.apply(source, using: XCTUnwrap(cold.updateContext()))
        XCTAssertEqual(cold.runtimeView().overseas.match(target), .indeterminate)
        try cold.disableOverseas()
        XCTAssertEqual(cold.runtimeView().overseas.match(target), .original)
    }

    func testInterruptedOverseasRefreshRestoresPriorIntersectionAfterExactReplay() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .smart, categories: []))
        try cache.requestOverseasPreview()
        let v1 = try Self.overseas(1, positive: ["google.com"], excluding: [])
        try await cache.apply(v1, using: XCTUnwrap(cache.updateContext()))
        let all = AccessOverseasSelection(enabled: true, mode: .all)
        try await cache.confirmOverseas(cache.overseasConfirmation(for: all)) { true }
        let v2 = try Self.overseas(2, positive: ["google.com", "fast.com"], excluding: [])
        try await cache.apply(v2, using: XCTUnwrap(cache.updateContext()))

        let approved = URL(string: "https://www.google.com")!
        let added = URL(string: "https://fast.com")!
        XCTAssertEqual(cache.runtimeView().overseas.match(approved), .managed)
        _ = try XCTUnwrap(cache.beginOverseasRefresh(using: XCTUnwrap(cache.updateContext())))

        let cold = fixture.cache()
        await cold.restore()
        XCTAssertEqual(cold.runtimeView().overseas.match(approved), .indeterminate)
        XCTAssertNil(cold.overseasPreview)
        let retry = try XCTUnwrap(cold.beginOverseasRefresh(using: XCTUnwrap(cold.updateContext())))
        cold.endOverseasRefresh(retry)
        let resumed = fixture.cache()
        await resumed.restore()
        XCTAssertEqual(resumed.runtimeView().overseas.match(approved), .indeterminate)
        try await resumed.apply(v2, using: XCTUnwrap(resumed.updateContext()))

        let reopened = fixture.cache()
        await reopened.restore()
        XCTAssertEqual(reopened.runtimeView().overseas.match(approved), .managed)
        XCTAssertEqual(reopened.runtimeView().overseas.match(added), .original)
        XCTAssertTrue(reopened.view.overseas.awaitingExpansion)
        let expansion = try await reopened.overseasConfirmation(for: all)
        XCTAssertEqual(expansion.newRules.map(\.value), ["fast.com"])
        XCTAssertTrue(expansion.removedExclusions.isEmpty)
    }

    func testUnreadableOverseasRefreshJournalCannotRestorePriorApprovalOnExactReplay() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .smart, categories: []))
        try cache.requestOverseasPreview()
        let v1 = try Self.overseas(1, positive: ["google.com"], excluding: [])
        try await cache.apply(v1, using: XCTUnwrap(cache.updateContext()))
        let all = AccessOverseasSelection(enabled: true, mode: .all)
        try await cache.confirmOverseas(cache.overseasConfirmation(for: all)) { true }
        _ = try XCTUnwrap(cache.beginOverseasRefresh(using: XCTUnwrap(cache.updateContext())))
        try fixture.storage.writeOverseasFlight(Data("damaged".utf8))

        let cold = fixture.cache()
        await cold.restore()
        let target = URL(string: "https://www.google.com")!
        XCTAssertEqual(cold.runtimeView().overseas.match(target), .indeterminate)
        XCTAssertNil(cold.overseasPreview)
        try await cold.apply(v1, using: XCTUnwrap(cold.updateContext()))
        XCTAssertEqual(cold.runtimeView().overseas.match(target), .indeterminate)
        await expectExpansionTooLarge { try await cold.overseasConfirmation(for: all) }
    }

    func testUnknownOverseasRecoveryHoldSurvivesFailedRetryAndCorruptJournal() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .smart, categories: []))
        try cache.requestOverseasPreview()
        let v1 = try Self.overseas(1, positive: ["google.com"], excluding: [])
        try await cache.apply(v1, using: XCTUnwrap(cache.updateContext()))
        let all = AccessOverseasSelection(enabled: true, mode: .all)
        try await cache.confirmOverseas(cache.overseasConfirmation(for: all)) { true }

        let v2 = try Self.overseas(2, positive: ["google.com"], excluding: [])
        fixture.fault.withLock { $0 = .writeLedger }
        await expectFailure { try await cache.apply(v2, using: XCTUnwrap(cache.updateContext())) }
        fixture.fault.withLock { $0 = nil }
        _ = try cache.beginOverseasRefresh(using: XCTUnwrap(cache.updateContext()))
        let cold = fixture.cache()
        await cold.restore()
        let target = URL(string: "https://gemini.google.com")!
        XCTAssertEqual(cold.runtimeView().overseas.match(target), .indeterminate)
        XCTAssertEqual(cold.runtimeView().overseas.match(URL(string: "https://example.org")!), .original)
        let newer = try Self.overseas(3, positive: ["google.com"], excluding: [])
        fixture.fault.withLock { $0 = .writeLedger }
        await expectFailure { try await cold.apply(newer, using: XCTUnwrap(cold.updateContext())) }
        fixture.fault.withLock { $0 = nil }
        let afterFailure = fixture.cache()
        await afterFailure.restore()
        let journal = fixture.storage.directory.appendingPathComponent("overseas-refresh.json")
        try Data("damaged".utf8).write(to: journal)
        let afterCorruption = fixture.cache()
        await afterCorruption.restore()
        await expectFailure { try await afterCorruption.apply(v1, using: XCTUnwrap(afterCorruption.updateContext())) }
        try await afterFailure.apply(newer, using: XCTUnwrap(afterFailure.updateContext()))
        XCTAssertEqual(afterFailure.runtimeView().overseas.match(target), .indeterminate)
    }

    func testOverseasDisableWithUnavailableJournalKeepsTheVerifiedReceiptFloor() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .smart, categories: []))
        try cache.requestOverseasPreview()
        let v1 = try Self.overseas(1, positive: ["google.com"], excluding: [])
        try await cache.apply(v1, using: XCTUnwrap(cache.updateContext()))
        let all = AccessOverseasSelection(enabled: true, mode: .all)
        try await cache.confirmOverseas(cache.overseasConfirmation(for: all)) { true }
        let v2 = try Self.overseas(2, positive: ["google.com"], excluding: ["gemini.google.com"])
        fixture.fault.withLock { $0 = .writeLedger }
        await expectFailure { try await cache.apply(v2, using: XCTUnwrap(cache.updateContext())) }
        fixture.fault.withLock { $0 = .writeOverseasJournal }
        try cache.disableOverseas()
        fixture.fault.withLock { $0 = nil }
        let cold = fixture.cache()
        await cold.restore()
        XCTAssertFalse(cold.view.overseas.selection.enabled)
        XCTAssertNil(cold.overseasPreview)
        try cold.requestOverseasPreview()
        await expectFailure { try await cold.apply(v1, using: XCTUnwrap(cold.updateContext())) }
    }

    func testLegacyRefreshAdvancesOverseasFloorAfterSuccessfulRemovalOfStagedPointer() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: smartAll)
        try cache.requestOverseasPreview()
        let v1 = try Self.overseas(1, positive: ["google.com"], excluding: [])
        try await cache.apply(v1, using: XCTUnwrap(cache.updateContext()))
        let v2 = try Self.candidate(2, database: Vector.selectedProjection)
        try await cache.apply(v2, using: XCTUnwrap(cache.updateContext()))
        XCTAssertNil(cache.overseasPreview)
        let v3 = try Self.candidate(3, database: Vector.selectedProjection)
        fixture.fault.withLock { $0 = .writeLedger }
        await expectFailure { try await cache.apply(v3, using: XCTUnwrap(cache.updateContext())) }
        fixture.fault.withLock { $0 = nil }
        let cold = fixture.cache()
        await cold.restore()
        try cold.requestOverseasPreview()
        await expectFailure { try await cold.apply(v2, using: XCTUnwrap(cold.updateContext())) }
    }

    func testMissingOverseasApprovalCannotReviveOrBypassTheExpansionLimit() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .smart, categories: []))
        try cache.requestOverseasPreview()
        let v1 = try Self.overseas(1, positive: ["fast.com"], excluding: [])
        try await cache.apply(v1, using: XCTUnwrap(cache.updateContext()))
        let all = AccessOverseasSelection(enabled: true, mode: .all)
        try await cache.confirmOverseas(cache.overseasConfirmation(for: all)) { true }
        let files = try FileManager.default.contentsOfDirectory(at: fixture.storage.directory, includingPropertiesForKeys: nil)
        let active = try XCTUnwrap(files.first { file in
            guard file.lastPathComponent.hasPrefix("overseas-"), file.pathExtension == "json",
                  let data = try? Data(contentsOf: file),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            return object["approved"] != nil
        })
        let original = try Data(contentsOf: active)
        try FileManager.default.removeItem(at: active)
        let reopened = fixture.cache()
        await reopened.restore()
        let v2 = try Self.overseas(2, positive: ["host-1.example.com"], excluding: [])
        try await reopened.apply(v2, using: XCTUnwrap(reopened.updateContext()))
        try original.write(to: active)
        let cold = fixture.cache()
        await cold.restore()
        XCTAssertEqual(cold.highWater, v2.receipt)
        XCTAssertEqual(cold.runtimeView().overseas.match(URL(string: "https://fast.com")!), .original)
        XCTAssertEqual(cold.runtimeView().overseas.match(URL(string: "https://host-1.example.com")!), .indeterminate)
        await expectExpansionTooLarge { try await cold.overseasConfirmation(for: all) }
    }

    func testOverseasBlobIndependentSizeLimit() throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let exact = Data(repeating: 0x41, count: AccessGeoSiteStorage.overseasBlobLimit)
        let digest = AccessGeoSiteAdmission.sha256(exact)
        try fixture.storage.storeOverseas(exact, digest: digest, raw: false)
        XCTAssertEqual(try fixture.storage.readOverseas(digest: digest, length: exact.count, raw: false), exact)
        fixture.fault.withLock { $0 = .afterDirectorySync }
        XCTAssertThrowsError(try fixture.storage.storeOverseas(exact, digest: digest, raw: false))
        fixture.fault.withLock { $0 = nil }
        let tooLarge = exact + Data([0x42])
        XCTAssertThrowsError(try fixture.storage.storeOverseas(tooLarge, digest: AccessGeoSiteAdmission.sha256(tooLarge), raw: false))
        XCTAssertThrowsError(try fixture.storage.readOverseas(digest: digest, length: tooLarge.count, raw: false))
        XCTAssertThrowsError(try fixture.storage.writeFile(exact, to: fixture.storage.marker))
    }

    func testOverseasColdRestoreWithExcludedApexAndDescendants() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: .init(mode: .smart, categories: []))
        try cache.requestOverseasPreview()
        let data = Vector.group("GFWLIST-CN", rules: [Vector.rule(2, "example.com"), Vector.rule(3, "example.net")])
            + Vector.group("GFWLIST-CN-EXCLUDE", rules: [Vector.rule(0, ".example.com"), Vector.rule(3, "example.com")])
        let candidate = try Self.candidate(1, database: data, includeOverseas: true)
        try await cache.apply(candidate, using: XCTUnwrap(cache.updateContext()))
        try await cache.confirmOverseas(cache.overseasConfirmation(for: .init(enabled: true, mode: .all))) { true }
        let cold = fixture.cache()
        await cold.restore()
        XCTAssertEqual(cold.runtimeView().overseas.match(URL(string: "https://example.com")!), .original)
        XCTAssertEqual(cold.runtimeView().overseas.match(URL(string: "https://example.net")!), .managed)
    }

#if DEBUG
    func testPrepareOverseasSettingsFixture() async throws {
        guard ProcessInfo.processInfo.environment["AEGIS_OVERSEAS_UI_SEED"] == "1" else {
            throw XCTSkip("Run this test explicitly to prepare the Settings fixture")
        }
        let storage = try AccessGeoSiteStorage.overseasUITest(keep: false)
        let cache = AccessGeoSiteCache(storage: storage)
        await cache.restore(migrating: .init(mode: .manual, categories: [.debian]))
        try cache.requestOverseasPreview()
        let preview = try Self.overseas(1, positive: ["google.com", "fast.com"], excluding: ["dl.google.com"], now: Date())
        try await cache.apply(preview, using: XCTUnwrap(cache.updateContext()))
        XCTAssertNotNil(cache.overseasPreview)
        XCTAssertFalse(cache.view.overseas.selection.enabled)
    }
#endif

    private func expectExpansionTooLarge(_ operation: () async throws -> Cache.OverseasConfirmation,
                                         file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await operation()
            XCTFail("Expected an over-limit expansion", file: file, line: line)
        } catch Cache.Failure.expansionTooLarge {
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func expectFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected operation to fail", file: file, line: line)
        } catch {}
    }

    static func overseas(_ sequence: Int, positive: [String], excluding: [String],
                          now: Date? = nil, domestic: Data = Data()) throws -> AccessGeoSiteAdmission.Candidate {
        let data = domestic + Vector.group("GFWLIST-CN", rules: positive.map { Vector.rule(2, $0) })
            + Vector.group("GFWLIST-CN-EXCLUDE", rules: excluding.map { Vector.rule(2, $0) })
            + Vector.group("GOOGLE-GEMINI", rules: [Vector.rule(3, "gemini.google.com")])
        return try Self.candidate(sequence, database: data, includeOverseas: true, now: now)
    }

    private static func candidate(_ sequence: Int, database: Data, includeOverseas: Bool = false,
                           now: Date? = nil) throws -> AccessGeoSiteAdmission.Candidate {
        let publishedAt = now.map { ISO8601DateFormatter().string(from: $0.addingTimeInterval(-60)) }
        let input = try Vector.release(database) { release in
            let tag = publishedAt.map { $0.filter(\.isNumber) } ?? "2026112023522\(sequence)"
            let id = 453302649 + sequence
            release["id"] = id
            release["tag_name"] = tag
            release["published_at"] = publishedAt ?? "2026-11-20T23:53:0\(sequence)Z"
            release["url"] = "https://api.github.com/repos/XTLS/Xray-rules-dat/releases/\(id)"
            release["html_url"] = "https://github.com/XTLS/Xray-rules-dat/releases/tag/\(tag)"
            var assets = try XCTUnwrap(release["assets"] as? [[String: Any]], "Expected release asset dictionaries")
            for index in assets.indices {
                let name = try XCTUnwrap(assets[index]["name"] as? String, "Expected a name for release asset \(index)")
                assets[index]["browser_download_url"] = "https://github.com/XTLS/Xray-rules-dat/releases/download/\(tag)/\(name)"
            }
            release["assets"] = assets
        }
        return try AccessGeoSiteAdmission.admit(metadata: input.metadata, database: database, checksum: input.checksum,
                                                now: now ?? Vector.now, includeOverseas: includeOverseas)
    }

    private func bundled(_ category: AccessGeoSiteCategory) -> [Data] {
        AccessGeoSiteCatalogue.bundled.groups[category]!.rules.map {
            Vector.rule($0.kind == .domain ? 2 : 3, $0.host)
        }
    }

    private func combined(debian: [Data], douban: [Data], meituan: [Data]) -> Data {
        Vector.group("DEBIAN", rules: debian) + Vector.group("DOUBAN", rules: douban) + Vector.group("MEITUAN", rules: meituan)
    }

    final class Fixture: Sendable {
        let storage: AccessGeoSiteStorage
        let fault: OSAllocatedUnfairLock<AccessGeoSiteStorage.Step?>
        let clock = Clock()

        init(onStep: @escaping @Sendable (AccessGeoSiteStorage.Step) -> Void = { _ in }) {
            let identifier = UUID().uuidString
            let fault = OSAllocatedUnfairLock<AccessGeoSiteStorage.Step?>(initialState: nil)
            self.fault = fault
            storage = AccessGeoSiteStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent(identifier),
                                          service: "aegis.geosite.test." + identifier) { step in
                onStep(step)
                if fault.withLock({ $0 == step }) { throw CocoaError(.fileWriteUnknown) }
            }
        }

        var keychainQuery: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: storage.service,
             kSecAttrAccount as String: "ledger", kSecAttrSynchronizable as String: false]
        }

        @MainActor
        func cache(useProductBaseline: Bool = false) -> Cache {
            Cache(storage: storage, time: .init(wall: { self.clock.wall }, uptime: { self.clock.uptime }),
                  useProductBaseline: useProductBaseline)
        }

        func clean() {
            var query = keychainQuery
            query[kSecAttrAccount as String] = nil
            SecItemDelete(query as CFDictionary)
            try? FileManager.default.removeItem(at: storage.directory)
        }
    }

    final class Clock: Sendable {
        private let values = OSAllocatedUnfairLock(initialState: (Vector.now, TimeInterval(1_000_000)))
        var wall: Date { values.withLock { $0.0 } }
        var uptime: TimeInterval { values.withLock { $0.1 } }
        func setWall(_ date: Date) { values.withLock { $0.0 = date } }
        func advance(by seconds: TimeInterval) {
            values.withLock { $0 = ($0.0.addingTimeInterval(seconds), $0.1 + seconds) }
        }
    }

    final class WriteGate: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (armed: false, entered: false))
        let release = DispatchSemaphore(value: 0)
        var entered: Bool { state.withLock { $0.entered } }

        func arm() { state.withLock { $0.armed = true } }

        func wait(_ step: AccessGeoSiteStorage.Step) {
            guard step == .afterDirectorySync else { return }
            let pause = state.withLock {
                guard $0.armed else { return false }
                $0.armed = false
                $0.entered = true
                return true
            }
            if pause { _ = release.wait(timeout: .now() + 5) }
        }
    }
}
