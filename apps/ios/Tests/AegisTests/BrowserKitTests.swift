import XCTest
@testable import BrowserKit

@MainActor
final class BrowserKitTests: XCTestCase {
    private let bookmarkAID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let duplicateNewerID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let bookmarkZID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    private let bookmarkAlphaID = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!

    func testAddressNormalization() {
        XCTAssertEqual(BrowserSession.normalizedURL(from: "aegis://research")?.absoluteString, "aegis://research")
        XCTAssertEqual(BrowserSession.normalizedURL(from: "example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(
            BrowserSession.normalizedURL(from: "隐私 浏览")?.host,
            "duckduckgo.com"
        )
    }

    func testPrivateProfileUsesNonPersistentStoreAndDisablesAgent() {
        let store = BrowserDataStore(persistenceURL: nil)
        let session = BrowserSession(dataStore: store)
        XCTAssertEqual(session.activeProfileID, session.standardProfileID)
        XCTAssertTrue(session.activeTab?.webView.configuration.websiteDataStore.isPersistent == true)

        session.switchProfile(to: .privateMode)
        XCTAssertEqual(session.activeProfileID, session.privateProfileID)
        XCTAssertNotEqual(session.activeProfileID, session.standardProfileID)
        XCTAssertFalse(session.agentIsAvailable)
        XCTAssertTrue(session.activeTab?.webView.configuration.websiteDataStore.isPersistent == false)
        XCTAssertNotEqual(session.standardTabs.first?.id, session.privateTabs.first?.id)

        session.switchProfile(to: .standard)
        XCTAssertEqual(session.activeProfileID, session.standardProfileID)
    }

    func testPrivateNavigationNeverWritesHistory() async throws {
        let store = BrowserDataStore(persistenceURL: nil)
        let session = BrowserSession(dataStore: store)
        session.switchProfile(to: .privateMode)
        let tab = try XCTUnwrap(session.activeTab)
        let finished = expectation(description: "fixture finished")
        tab.onNavigation = { _ in finished.fulfill() }
        tab.load(try XCTUnwrap(URL(string: "aegis://research")))
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertTrue(store.history.isEmpty)
    }

    func testNormalHistoryRedactsQueryAndFragment() {
        let store = BrowserDataStore(persistenceURL: nil)
        store.record(
            title: "Example",
            url: URL(string: "https://example.com/path?token=secret#account")!,
            isPrivate: false
        )
        XCTAssertEqual(store.history.first?.url, "https://example.com/path")
    }

    func testBookmarkOrganizationAppliesDeterministicallyAndUndoRestoresExactSnapshot() throws {
        let original = makeDisorderedBookmarks()
        let store = BrowserDataStore(persistenceURL: nil, initialBookmarks: original)
        let secondStore = BrowserDataStore(persistenceURL: nil, initialBookmarks: original)

        let plan = try store.makeBookmarkOrganizationPlan(
            planID: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
            transactionID: UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        )
        let equivalentPlan = try secondStore.makeBookmarkOrganizationPlan(
            planID: plan.planID,
            transactionID: plan.transactionID
        )

        XCTAssertEqual(store.bookmarkRootID, secondStore.bookmarkRootID)
        XCTAssertEqual(plan.beforeDigest, equivalentPlan.beforeDigest)
        XCTAssertEqual(plan.afterDigest, equivalentPlan.afterDigest)
        XCTAssertEqual(plan.canonicalApplyParameters, equivalentPlan.canonicalApplyParameters)
        XCTAssertEqual(plan.beforeCount, 4)
        XCTAssertEqual(plan.afterCount, 3)
        XCTAssertEqual(
            plan.canonicalApplyParameters,
            "{\"after_count\":3,\"before_count\":4,\"changed_count\":3,"
                + "\"operation\":\"apply\","
                + "\"plan_id\":\"10000000-0000-4000-8000-000000000001\","
                + "\"removed_duplicate_count\":1,"
                + "\"root_id\":\"7d862e89-6cb4-4f30-a21f-a0919bb91de6\","
                + "\"transaction_id\":\"20000000-0000-4000-8000-000000000001\","
                + "\"tree_after\":\"\(plan.afterDigest)\","
                + "\"tree_before\":\"\(plan.beforeDigest)\"}"
        )
        XCTAssertNotEqual(plan.beforeDigest, plan.afterDigest)
        XCTAssertEqual(plan.removedDuplicateIDs, [duplicateNewerID])
        XCTAssertEqual(plan.proposedBookmarks.map(\.id), [bookmarkAlphaID, bookmarkAID, bookmarkZID])
        XCTAssertEqual(
            plan.proposedBookmarks.map(\.url),
            [
                "https://a.example/",
                "https://example.com/item?keep=1",
                "https://z.example/",
            ]
        )

        let receipt = try store.apply(plan)
        XCTAssertEqual(store.bookmarks, plan.proposedBookmarks)
        XCTAssertEqual(try store.bookmarkDigest(), receipt.afterDigest)

        let undoReceipt = try store.undoBookmarkTransaction(
            transactionID: receipt.transactionID,
            expectedAfterDigest: receipt.afterDigest
        )
        XCTAssertEqual(undoReceipt, receipt)
        XCTAssertEqual(store.bookmarks, original)
        XCTAssertEqual(try store.bookmarkDigest(), receipt.beforeDigest)
        XCTAssertThrowsError(try store.undoBookmarkTransaction(
            transactionID: receipt.transactionID,
            expectedAfterDigest: receipt.afterDigest
        )) { error in
            XCTAssertEqual(
                error as? BookmarkTransactionError,
                .transactionAlreadyUndone(receipt.transactionID)
            )
        }
    }

    func testBookmarkApplyRejectsStateDriftWithoutOverwritingCurrentBookmarks() throws {
        let store = BrowserDataStore(
            persistenceURL: nil,
            initialBookmarks: makeDisorderedBookmarks()
        )
        let plan = try store.makeBookmarkOrganizationPlan()
        XCTAssertTrue(store.toggleBookmark(
            title: "用户后加",
            url: URL(string: "https://later.example/")!,
            isPrivate: false
        ))
        let stateAfterUserChange = store.bookmarks

        XCTAssertThrowsError(try store.apply(plan)) { error in
            guard case BookmarkTransactionError.stateDiverged = error else {
                return XCTFail("应拒绝已过期计划，实际错误：\(error)")
            }
        }
        XCTAssertEqual(store.bookmarks, stateAfterUserChange)
    }

    func testBookmarkUndoRejectsStateDriftWithoutOverwritingCurrentBookmarks() throws {
        let store = BrowserDataStore(
            persistenceURL: nil,
            initialBookmarks: makeDisorderedBookmarks()
        )
        let receipt = try store.apply(store.makeBookmarkOrganizationPlan())
        XCTAssertTrue(store.toggleBookmark(
            title: "用户后加",
            url: URL(string: "https://later.example/")!,
            isPrivate: false
        ))
        let stateAfterUserChange = store.bookmarks

        XCTAssertThrowsError(try store.undoBookmarkTransaction(
            transactionID: receipt.transactionID,
            expectedAfterDigest: receipt.afterDigest
        )) { error in
            guard case BookmarkTransactionError.stateDiverged = error else {
                return XCTFail("应拒绝覆盖用户后续修改，实际错误：\(error)")
            }
        }
        XCTAssertEqual(store.bookmarks, stateAfterUserChange)
    }

    func testBookmarkPersistenceFailureDoesNotPublishCandidateState() throws {
        let original = makeDisorderedBookmarks()
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("aegis-bookmark-persistence-\(UUID().uuidString)", isDirectory: true)
        let directoryAtFilePath = temporaryRoot.appendingPathComponent("browser-data.json", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryAtFilePath,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let store = BrowserDataStore(
            persistenceURL: directoryAtFilePath,
            initialBookmarks: original
        )
        let plan = try store.makeBookmarkOrganizationPlan()

        XCTAssertThrowsError(try store.apply(plan)) { error in
            XCTAssertEqual(error as? BookmarkTransactionError, .persistenceFailed)
        }
        XCTAssertEqual(store.bookmarks, original)
        XCTAssertEqual(try store.bookmarkDigest(), plan.beforeDigest)
    }

    private func makeDisorderedBookmarks() -> [BrowserBookmark] {
        [
            BrowserBookmark(
                id: bookmarkZID,
                title: "Z",
                url: "https://z.example?utm_source=feed",
                createdAt: Date(timeIntervalSince1970: 300)
            ),
            BrowserBookmark(
                id: duplicateNewerID,
                title: "重复项",
                url: "https://EXAMPLE.com/item?utm_source=feed&keep=1",
                createdAt: Date(timeIntervalSince1970: 200)
            ),
            BrowserBookmark(
                id: bookmarkAID,
                title: "保留项",
                url: "https://example.com/item?keep=1",
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            BrowserBookmark(
                id: bookmarkAlphaID,
                title: "A",
                url: "https://a.example?fbclid=tracking",
                createdAt: Date(timeIntervalSince1970: 400)
            ),
        ]
    }
}
