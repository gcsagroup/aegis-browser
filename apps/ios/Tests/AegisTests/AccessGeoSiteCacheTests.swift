import AccessKit
import BrowserKit
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
        let v1 = try candidate(1, database: Vector.selectedProjection)
        try await first.apply(v1, using: XCTUnwrap(first.updateContext()))
        XCTAssertEqual(first.match(URL(string: "https://dotdeb.org/")!), .managed)
        let v2 = try candidate(2, database: combined(
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

        let v3 = try candidate(3, database: Vector.selectedProjection)
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
        let more = try candidate(1, database: combined(debian: bundled(.debian),
            douban: bundled(.douban) + [Vector.rule(2, "new-coverage.example.com")], meituan: bundled(.meituan)))
        try await cache.apply(more, using: XCTUnwrap(cache.updateContext()))
        let oldContext = try XCTUnwrap(cache.updateContext())
        let proposal = try XCTUnwrap(cache.proposal(for: .douban))
        try cache.setSelection(Cache.Selection(mode: .manual, categories: smartAll.categories))
        XCTAssertEqual(cache.match(douban), .original)
        XCTAssertNil(cache.updateContext())
        await expectFailure { try await cache.confirm(proposal) }
        try cache.setSelection(smartAll)
        let next = try candidate(2, database: Vector.selectedProjection)
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
        try await cache.apply(candidate(1, database: Vector.selectedProjection), using: XCTUnwrap(cache.updateContext()))
        let oldHash = try XCTUnwrap(cache.activeFileSHA256)
        let old = try Data(contentsOf: fixture.storage.blobURL(.active, oldHash))
        let approved = try candidate(2, database: combined(debian: [Vector.rule(3, "debian.org")],
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
        let v1 = try candidate(1, database: Vector.selectedProjection)
        try await first.apply(v1, using: XCTUnwrap(first.updateContext()))
        let v2 = try candidate(2, database: combined(debian: [], douban: bundled(.douban), meituan: bundled(.meituan)))
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

    func testExpiryAndClockRollbackPersistWithoutRevivingOfflineBaseline() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let first = fixture.cache()
        await first.restore(migrating: smartAll)
        let official = try candidate(1, database: Vector.selectedProjection)
        try await first.apply(official, using: XCTUnwrap(first.updateContext()))
        let state = Cache.RefreshState(failureCount: 2, nextAttempt: Vector.now.addingTimeInterval(300))
        try first.setRefreshState(state, using: XCTUnwrap(first.updateContext()))
        fixture.clock.setWall(Vector.now.addingTimeInterval(-301))
        XCTAssertEqual(first.match(debian), .indeterminate)
        XCTAssertNil(first.updateContext())
        fixture.clock.setWall(Vector.now)
        fixture.clock.advance(by: 7 * 86_400 + 1)
        XCTAssertEqual(first.match(debian), .indeterminate)
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
        XCTAssertEqual(reboot.match(debian), .indeterminate)
        XCTAssertEqual(reboot.match(outside), .original)
    }

    func testUnavailableClockCheckpointCanRecoverWithoutReinitializingLedger() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let cache = fixture.cache()
        await cache.restore(migrating: smartAll)
        let receipt = try candidate(1, database: Vector.selectedProjection)
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
        let newer = try candidate(1, database: combined(debian: bundled(.debian),
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
        let initial = try candidate(1, database: Vector.selectedProjection)
        try await cache.apply(initial, using: XCTUnwrap(cache.updateContext()))
        let next = try candidate(2, database: combined(debian: [], douban: bundled(.douban), meituan: bundled(.meituan)))
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
        try await first.apply(candidate(1, database: Vector.selectedProjection), using: XCTUnwrap(first.updateContext()))
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

    private func expectFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected operation to fail", file: file, line: line)
        } catch {}
    }

    private func candidate(_ sequence: Int, database: Data) throws -> AccessGeoSiteAdmission.Candidate {
        let input = try Vector.release(database) { release in
            let tag = "2026112023522\(sequence)"
            let id = 453302649 + sequence
            release["id"] = id
            release["tag_name"] = tag
            release["published_at"] = "2026-11-20T23:53:0\(sequence)Z"
            release["url"] = "https://api.github.com/repos/XTLS/Xray-rules-dat/releases/\(id)"
            release["html_url"] = "https://github.com/XTLS/Xray-rules-dat/releases/tag/\(tag)"
            var assets = release["assets"] as! [[String: Any]]
            for index in assets.indices {
                let name = assets[index]["name"] as! String
                assets[index]["browser_download_url"] = "https://github.com/XTLS/Xray-rules-dat/releases/download/\(tag)/\(name)"
            }
            release["assets"] = assets
        }
        return try AccessGeoSiteAdmission.admit(metadata: input.metadata, database: database, checksum: input.checksum, now: Vector.now)
    }

    private func bundled(_ category: AccessGeoSiteCategory) -> [Data] {
        AccessGeoSiteCatalogue.bundled.groups[category]!.rules.map {
            Vector.rule($0.kind == .domain ? 2 : 3, $0.host)
        }
    }

    private func combined(debian: [Data], douban: [Data], meituan: [Data]) -> Data {
        Vector.group("DEBIAN", rules: debian) + Vector.group("DOUBAN", rules: douban) + Vector.group("MEITUAN", rules: meituan)
    }

    private final class Fixture: Sendable {
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
        func cache() -> Cache {
            Cache(storage: storage, time: .init(wall: { self.clock.wall }, uptime: { self.clock.uptime }))
        }

        func clean() {
            SecItemDelete(keychainQuery as CFDictionary)
            try? FileManager.default.removeItem(at: storage.directory)
        }
    }

    private final class Clock: Sendable {
        private let values = OSAllocatedUnfairLock(initialState: (Vector.now, TimeInterval(1_000_000)))
        var wall: Date { values.withLock { $0.0 } }
        var uptime: TimeInterval { values.withLock { $0.1 } }
        func setWall(_ date: Date) { values.withLock { $0.0 = date } }
        func advance(by seconds: TimeInterval) {
            values.withLock { $0 = ($0.0.addingTimeInterval(seconds), $0.1 + seconds) }
        }
    }

    private final class WriteGate: Sendable {
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
