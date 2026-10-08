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
