import AccessKit
@testable import Aegis
import WebKit
import UIKit
import XCTest
@testable import BrowserKit

@MainActor final class BrowserWindowTests: XCTestCase {
    func testIndependentWindowUpdatesGroupsRestartAndPrivateIsolation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("windows.json")
        let store = BrowserWindowStore(persistenceURL: file)
        let shared = BrowserDataStore(persistenceURL: nil)
        let firstID = try store.createWindow(), secondID = try store.createWindow()
        let first = BrowserSession(dataStore: shared, windowID: firstID, windowStore: store)
        let second = BrowserSession(dataStore: shared, windowID: secondID, windowStore: store)
        let group = try first.createGroup(name: "论文")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let firstWindow = UIWindow(windowScene: scene), secondWindow = UIWindow(windowScene: scene)
        for (window, browser) in [(firstWindow, first), (secondWindow, second)] {
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
            let view = try XCTUnwrap(browser.activeTab).webView
            view.frame = window.bounds; window.addSubview(view); window.makeKeyAndVisible()
        }
        defer { firstWindow.isHidden = true; secondWindow.isHidden = true }
        first.activeTab?.load(URL(string: "http://127.0.0.1:8768/article?token=secret")!)
        second.activeTab?.load(URL(string: "http://127.0.0.1:8768/article-two")!)
        try await waitUntil { first.activeTab?.url?.path == "/article" && second.activeTab?.url?.path == "/article-two" }
        try first.renameGroup(group, to: "论文资料")
        first.persistSession(); second.persistSession()
        XCTAssertFalse(first.activeTab === second.activeTab)
        XCTAssertTrue(first.dataStore === second.dataStore)
        _ = shared.toggleBookmark(title: "跨窗口收藏", url: try XCTUnwrap(second.activeTab?.url), isPrivate: false)
        XCTAssertTrue(second.bookmarkIsActive)
        let originalSecond = try XCTUnwrap(store.snapshot(secondID))
        first.switchProfile(to: .privateMode)
        _ = try first.createGroup(name: "PRIVATE_GROUP_SENTINEL")
        first.activeTab?.load(URL(string: "http://127.0.0.1:8768/sensitive?secret=PRIVATE_URL_SENTINEL")!)
        first.persistSession()
        let bytes = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(bytes.contains("PRIVATE_GROUP_SENTINEL"))
        XCTAssertFalse(bytes.contains("PRIVATE_URL_SENTINEL"))
        XCTAssertFalse(bytes.contains("token="))
        XCTAssertEqual(store.snapshot(secondID), originalSecond)
        first.discardPrivateSession()
        XCTAssertTrue(first.privateTabs.isEmpty)
        XCTAssertTrue(first.privateGroups.isEmpty)
        let restarted = BrowserWindowStore(persistenceURL: file)
        let restored = BrowserSession(dataStore: shared, windowID: firstID, windowStore: restarted)
        XCTAssertEqual(restored.groups.map(\.name), ["论文资料"])
        XCTAssertEqual(restored.selectedGroupID, group)
        XCTAssertEqual(restored.displayedTabs.count, 1)
        XCTAssertEqual(restored.profile, .standard)
        XCTAssertTrue(restored.privateTabs.isEmpty)
        XCTAssertEqual(restarted.snapshot(secondID)?.tabs.first?.url?.path, "/article-two")
        let count = restored.standardTabs.count
        restored.removeGroup(group)
        XCTAssertEqual(restored.standardTabs.count, count)
        XCTAssertTrue(restored.standardTabs.allSatisfy { $0.groupID == nil })
        [first, second, restored].forEach { session in (session.standardTabs + session.privateTabs).forEach { $0.stop() } }
    }

    func testPrivateWebsiteDataStoreRetiresOnCloseAndDiscard() async throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        browser.switchProfile(to: .privateMode)
        let first = try XCTUnwrap(browser.activeTab)
        let firstStore = first.websiteDataStore
        XCTAssertFalse(firstStore.isPersistent)
        XCTAssertFalse(firstStore === WKWebsiteDataStore.default())

        browser.close(first.id)
        try await waitUntil { browser.retiredPrivateWebsiteDataStoreRevision == 1 }
        let closed = browser.consumeRetiredPrivateWebsiteDataStores()
        XCTAssertTrue(closed.contains { $0 === firstStore })
        let replacement = try XCTUnwrap(browser.privateTabs.first)
        XCTAssertFalse(replacement.websiteDataStore === firstStore)

        browser.discardPrivateSession()
        try await waitUntil { browser.retiredPrivateWebsiteDataStoreRevision == 2 }
        let discarded = browser.consumeRetiredPrivateWebsiteDataStores()
        XCTAssertTrue(discarded.contains { $0 === replacement.websiteDataStore })
        XCTAssertTrue(browser.privateTabs.isEmpty)
        XCTAssertEqual(browser.profile, .standard)

        let ordinary = try XCTUnwrap(browser.activeTab)
        browser.close(ordinary.id)
        XCTAssertTrue(browser.consumeRetiredPrivateWebsiteDataStores().isEmpty)
        browser.standardTabs.forEach { $0.stop() }
    }

    func testMoveCloseAndSwitchGroupDoNotAffectOtherGroups() throws {
        let store = BrowserWindowStore()
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), windowStore: store)
        let ungrouped = try XCTUnwrap(browser.activeTab)
        let one = try browser.createGroup(name: "第一组")
        let firstTab = try XCTUnwrap(browser.activeTab)
        let two = try browser.createGroup(name: "第二组")
        let secondTab = try XCTUnwrap(browser.activeTab)
        browser.moveTab(ungrouped.id, to: two)
        XCTAssertEqual(browser.displayedTabs.count, 2)
        browser.selectGroup(one)
        XCTAssertEqual(browser.displayedTabs.map(\.id), [firstTab.id])
        browser.close(firstTab.id)
        XCTAssertTrue(browser.displayedTabs.isEmpty)
        XCTAssertNil(browser.activeTab)
        browser.selectGroup(two)
        XCTAssertEqual(Set(browser.displayedTabs.map(\.id)), [ungrouped.id, secondTab.id])
        browser.switchProfile(to: .privateMode)
        XCTAssertTrue(browser.groups.isEmpty)
        browser.switchProfile(to: .standard)
        XCTAssertEqual(browser.selectedGroupID, two)
        XCTAssertTrue(browser.displayedTabs.contains { $0.id == browser.activeTabID })
    }

    func testLegacyMigrationAndCorruptFilePreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("windows.json")
        let legacy = [URL(string: "https://example.com/?q=paper&token=secret")!]
        let store = BrowserWindowStore(persistenceURL: file, legacyURLs: legacy)
        XCTAssertEqual(store.windows.count, 1)
        XCTAssertEqual(store.windows.first?.tabs.first?.url?.absoluteString, "https://example.com/?q=paper")
        let second = BrowserWindowStore(persistenceURL: file, legacyURLs: legacy)
        XCTAssertEqual(second.windows, store.windows)
        try Data("unreadable original".utf8).write(to: file)
        let corrupt = BrowserWindowStore(persistenceURL: file, legacyURLs: legacy)
        XCTAssertNotNil(corrupt.storageError)
        XCTAssertThrowsError(try corrupt.createWindow())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unreadable original")
    }

    func testOpenWindowCannotBeDeletedAndWriteFailureDoesNotPublish() throws {
        let store = BrowserWindowStore()
        let id = try store.createWindow(); store.register(id)
        XCTAssertThrowsError(try store.removeSavedWindow(id))
        store.unregister(id); try store.removeSavedWindow(id)
        XCTAssertTrue(store.windows.isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("parent is a file".utf8).write(to: directory)
        let blocked = BrowserWindowStore(persistenceURL: directory.appendingPathComponent("windows.json"))
        XCTAssertThrowsError(try blocked.createWindow())
        XCTAssertTrue(blocked.windows.isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let limit = Date().addingTimeInterval(20)
        while !condition() && Date() < limit { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(condition())
    }
}

@MainActor
final class BrowserWindowHostCleanupTests: XCTestCase {
    func testWindowOwnerReleaseUnbindsOnlyItsTabsAndAllowsIdlePruning() async throws {
        let store = BrowserWindowStore()
        let data = BrowserDataStore(persistenceURL: nil)
        let first = BrowserSession(dataStore: data, windowID: try store.createWindow(), windowStore: store)
        let second = BrowserSession(dataStore: data, windowID: try store.createWindow(), windowStore: store)
        let coordinator = AccessHostStoreCoordinator()
        first.hostCoordinator = coordinator
        second.hostCoordinator = coordinator
        store.register(first.windowID); store.register(second.windowID)
        let shared = try AccessSiteHost("shared.invalid")
        let exclusive = try AccessSiteHost("closed-only.invalid")
        let firstTab = try XCTUnwrap(first.activeTab)
        let otherTab = try XCTUnwrap(second.activeTab)
        let exclusiveTab = first.newTab()
        let sharedStore = try bind(firstTab, host: shared, coordinator: coordinator)
        XCTAssertTrue(sharedStore === (try bind(otherTab, host: shared, coordinator: coordinator)))
        _ = try bind(exclusiveTab, host: exclusive, coordinator: coordinator)
        first.persistSession()
        let ordinarySnapshot = store.snapshot(first.windowID)
        first.switchProfile(to: .privateMode)
        let privateTab = try XCTUnwrap(first.activeTab)
        let privateScope = privateTab.browsingScopeID
        _ = try bind(privateTab, host: shared, coordinator: coordinator)
        var owner: AegisWindowLifetime? = AegisWindowLifetime(browser: first)
        weak var weakOwner = owner
        XCTAssertTrue(owner?.browser === first)
        // A temporary disappearance does not release the root state owner.
        first.persistSession()
        XCTAssertNotNil(coordinator.registry.store(scopeID: "ordinary", host: exclusive, isPrivate: false))
        owner = nil
        let limit = Date().addingTimeInterval(2)
        while store.openIDs.contains(first.windowID), Date() < limit { await Task.yield() }
        XCTAssertNil(weakOwner)
        XCTAssertFalse(store.openIDs.contains(first.windowID))
        XCTAssertTrue(store.openIDs.contains(second.windowID))
        XCTAssertTrue(first.privateTabs.isEmpty)
        assertBrowsingState(store.snapshot(first.windowID), equals: ordinarySnapshot)
        await waitForCleanup { coordinator.registry.store(scopeID: privateScope, host: shared, isPrivate: true) == nil }
        XCTAssertNil(coordinator.registry.store(scopeID: privateScope, host: shared, isPrivate: true))

        first.closeWindow() // Explicit close followed by root release is harmless.
        let afterIdle = Date().addingTimeInterval(30 * 60 + 1)
        coordinator.registry.sweep(now: afterIdle)
        XCTAssertNil(coordinator.registry.store(scopeID: "ordinary", host: exclusive, isPrivate: false),
                     "closed ordinary tab must no longer pin its host store")
        XCTAssertTrue(coordinator.registry.store(scopeID: "ordinary", host: shared, isPrivate: false) === sharedStore,
                      "still-open window must retain its shared binding")
        second.closeWindow()
        await waitForCleanup {
            coordinator.registry.sweep(now: afterIdle)
            return coordinator.registry.store(scopeID: "ordinary", host: shared, isPrivate: false) == nil
        }
        coordinator.registry.sweep(now: afterIdle)
        XCTAssertNil(coordinator.registry.store(scopeID: "ordinary", host: shared, isPrivate: false),
                     "neither closed window may leave an ID in the shared store")
        assertBrowsingState(store.snapshot(first.windowID), equals: ordinarySnapshot)
    }

    func testDiscardedSceneClosesOnlyItsWindowBeforeRootStateIsReleased() async throws {
        let store = BrowserWindowStore()
        let first = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil),
                                   windowID: try store.createWindow(), windowStore: store)
        let second = BrowserSession(dataStore: first.dataStore,
                                    windowID: try store.createWindow(), windowStore: store)
        let coordinator = AccessHostStoreCoordinator()
        first.hostCoordinator = coordinator; second.hostCoordinator = coordinator
        store.register(first.windowID); store.register(second.windowID)
        let firstOwner = AegisWindowLifetime(browser: first)
        let secondOwner = AegisWindowLifetime(browser: second)
        let firstScene = UUID().uuidString, secondScene = UUID().uuidString
        firstOwner.attach(sceneID: firstScene); secondOwner.attach(sceneID: secondScene)
        let host = try AccessSiteHost("discarded.invalid")
        _ = try bind(XCTUnwrap(first.activeTab), host: host, coordinator: coordinator)
        _ = try first.createGroup(name: "Retained group")
        first.activeTab?.load(URL(string: "aegis://start")!)
        first.persistSession()
        let before = store.snapshot(first.windowID)
        let discardedTabIDs = Set(first.standardTabs.map(\.id))
        let otherWindowTabIDs = Set(second.standardTabs.map(\.id))
        let liveBefore = Set(BrowserSession.openTabs().map(\.id))
        XCTAssertTrue(discardedTabIDs.isSubset(of: liveBefore))
        XCTAssertTrue(otherWindowTabIDs.isSubset(of: liveBefore))
        weak var retainedDiscardedBrowser = first
        AegisWindowLifetime.discardScenes([firstScene])
        AegisWindowLifetime.discardScenes([firstScene])
        XCTAssertTrue(first.isWindowClosed)
        XCTAssertFalse(second.isWindowClosed)
        XCTAssertEqual(store.openIDs, [second.windowID])
        XCTAssertTrue(retainedDiscardedBrowser === firstOwner.browser)
        XCTAssertEqual(Set(first.standardTabs.map(\.id)), discardedTabIDs,
                       "ordinary tabs remain retained for the saved window")
        let liveAfter = Set(BrowserSession.openTabs().map(\.id))
        XCTAssertTrue(discardedTabIDs.isDisjoint(with: liveAfter),
                      "retained closed sessions must not enter active coordinator operations")
        XCTAssertTrue(otherWindowTabIDs.isSubset(of: liveAfter))
        assertBrowsingState(store.snapshot(first.windowID), equals: before)
        await waitForCleanup {
            coordinator.registry.sweep(now: Date().addingTimeInterval(1801))
            return coordinator.registry.store(scopeID: "ordinary", host: host, isPrivate: false) == nil
        }
        XCTAssertNil(coordinator.registry.store(scopeID: "ordinary", host: host, isPrivate: false))
        withExtendedLifetime((firstOwner, secondOwner)) {}
        second.closeWindow()
    }

    private func waitForCleanup(_ condition: @MainActor () -> Bool) async {
        let limit = Date().addingTimeInterval(5)
        while !condition(), Date() < limit { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "terminal document cleanup must finish")
    }

    private func assertBrowsingState(_ actual: BrowserWindowSnapshot?, equals expected: BrowserWindowSnapshot?,
                                     file: StaticString = #filePath, line: UInt = #line) {
        // Saving is expected to refresh updatedAt; all browsing fields must survive.
        var normalized = actual
        normalized?.updatedAt = expected?.updatedAt ?? .distantPast
        XCTAssertEqual(normalized, expected, file: file, line: line)
    }

    private func bind(_ tab: BrowserTab, host: AccessSiteHost,
                      coordinator: AccessHostStoreCoordinator) throws -> WKWebsiteDataStore {
        coordinator.registry.setEndpoint(.init(identity: "local-test", generation: 1,
            loopbackHost: "127.0.0.1", port: 18080, state: .ready),
            scopeID: tab.browsingScopeID, host: host, isPrivate: tab.profile.isPrivate)
        coordinator.setProxyEnabled(true, host: host, scopeID: tab.browsingScopeID, isPrivate: tab.profile.isPrivate)
        return try XCTUnwrap(coordinator.dataStoreForMainFrame(tab: tab, url: URL(string: "https://\(host.rawValue)/")!))
    }
}
