import Foundation
import XCTest
@testable import BrowserKit

@MainActor
final class BookmarkTransactionJournalTests: XCTestCase {
    private struct Fixture {
        let rootURL: URL
        let dataURL: URL
    }

    func testRestartLoadsLatestTransactionAndUndoIsExactlyOnce() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let original = makeDisorderedBookmarks()
        let store = makePersistedStore(fixture, bookmarks: original)
        let receipt = try store.apply(store.makeBookmarkOrganizationPlan())
        XCTAssertEqual(store.bookmarks.count, 3)

        let restarted = BrowserDataStore(persistenceURL: fixture.dataURL)
        XCTAssertEqual(try restarted.latestUndoableBookmarkTransaction(), receipt)
        XCTAssertEqual(
            try restarted.undoBookmarkTransaction(
                transactionID: receipt.transactionID,
                expectedAfterDigest: receipt.afterDigest
            ),
            receipt
        )
        XCTAssertEqual(restarted.bookmarks, original)

        let restartedAgain = BrowserDataStore(persistenceURL: fixture.dataURL)
        XCTAssertNil(try restartedAgain.latestUndoableBookmarkTransaction())
        XCTAssertThrowsError(try restartedAgain.undoBookmarkTransaction(
            transactionID: receipt.transactionID,
            expectedAfterDigest: receipt.afterDigest
        )) { error in
            XCTAssertEqual(
                error as? BookmarkTransactionError,
                .transactionAlreadyUndone(receipt.transactionID)
            )
        }
    }

    func testRestartOnlyAllowsUndoingLatestLegalTransaction() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let store = makePersistedStore(fixture, bookmarks: makeDisorderedBookmarks())
        let first = try store.apply(store.makeBookmarkOrganizationPlan())
        let firstResult = store.bookmarks

        XCTAssertTrue(store.toggleBookmark(
            title: "稍后加入",
            url: try XCTUnwrap(URL(string: "https://middle.example/")),
            isPrivate: false
        ))
        let beforeSecond = store.bookmarks
        let second = try store.apply(store.makeBookmarkOrganizationPlan())

        let restarted = BrowserDataStore(persistenceURL: fixture.dataURL)
        XCTAssertEqual(try restarted.latestUndoableBookmarkTransaction(), second)
        XCTAssertThrowsError(try restarted.undoBookmarkTransaction(
            transactionID: first.transactionID,
            expectedAfterDigest: first.afterDigest
        )) { error in
            XCTAssertEqual(
                error as? BookmarkTransactionError,
                .transactionNotFound(first.transactionID)
            )
        }
        _ = try restarted.undoBookmarkTransaction(
            transactionID: second.transactionID,
            expectedAfterDigest: second.afterDigest
        )
        XCTAssertEqual(restarted.bookmarks, beforeSecond)
        XCTAssertNotEqual(restarted.bookmarks, firstResult)
    }

    func testPreparedApplyFailureFreezesWritesAndRestartRecoversBaseState() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let original = makeDisorderedBookmarks()
        let store = makePersistedStore(fixture, bookmarks: original)
        let plan = try store.makeBookmarkOrganizationPlan()
        let dataBefore = try Data(contentsOf: fixture.dataURL)
        store.persistenceFailureInjector = { $0 == .applyData }

        XCTAssertThrowsError(try store.apply(plan)) { error in
            XCTAssertEqual(error as? BookmarkTransactionError, .persistenceFailed)
        }
        XCTAssertEqual(store.bookmarks, original)
        XCTAssertThrowsError(try store.makeBookmarkOrganizationPlan()) { error in
            XCTAssertEqual(error as? BookmarkTransactionError, .recoveryRequired)
        }
        try assertPersistentWritesBlocked(
            store: store,
            dataURL: fixture.dataURL,
            expectedData: dataBefore
        )

        let restarted = BrowserDataStore(persistenceURL: fixture.dataURL)
        XCTAssertEqual(restarted.bookmarks, original)
        XCTAssertNil(try restarted.latestUndoableBookmarkTransaction())
        XCTAssertNoThrow(try restarted.makeBookmarkOrganizationPlan())
    }

    func testPreparedUndoFailureFreezesWritesAndRestartKeepsUndoAvailable() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let store = makePersistedStore(fixture, bookmarks: makeDisorderedBookmarks())
        let receipt = try store.apply(store.makeBookmarkOrganizationPlan())
        let applied = store.bookmarks
        let dataBefore = try Data(contentsOf: fixture.dataURL)
        store.persistenceFailureInjector = { $0 == .undoData }

        XCTAssertThrowsError(try store.undoBookmarkTransaction(
            transactionID: receipt.transactionID,
            expectedAfterDigest: receipt.afterDigest
        )) { error in
            XCTAssertEqual(error as? BookmarkTransactionError, .persistenceFailed)
        }
        XCTAssertEqual(store.bookmarks, applied)
        XCTAssertThrowsError(try store.latestUndoableBookmarkTransaction()) { error in
            XCTAssertEqual(error as? BookmarkTransactionError, .recoveryRequired)
        }
        try assertPersistentWritesBlocked(
            store: store,
            dataURL: fixture.dataURL,
            expectedData: dataBefore
        )

        let restarted = BrowserDataStore(persistenceURL: fixture.dataURL)
        XCTAssertEqual(try restarted.latestUndoableBookmarkTransaction(), receipt)
        XCTAssertNoThrow(try restarted.undoBookmarkTransaction(
            transactionID: receipt.transactionID,
            expectedAfterDigest: receipt.afterDigest
        ))
    }

    func testEncryptedEnvelopeHidesBookmarkContentAndUsesCompleteProtection() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let store = makePersistedStore(fixture, bookmarks: makeDisorderedBookmarks())
        _ = try store.apply(store.makeBookmarkOrganizationPlan())
        let journalURL = BrowserDataStore.bookmarkJournalURL(for: fixture.dataURL)
        let journalData = try Data(contentsOf: journalURL)
        let journalText = try XCTUnwrap(String(data: journalData, encoding: .utf8))

        XCTAssertFalse(journalText.contains("https://z.example"))
        XCTAssertFalse(journalText.contains("重复项"))
        XCTAssertTrue(journalText.contains("AES-256-GCM"))
        try assertCompleteProtectionIfReadable(at: fixture.dataURL)
        try assertCompleteProtectionIfReadable(at: journalURL)
    }

    func testTamperedOrUnsupportedJournalFailsClosedWithoutOverwritingData() throws {
        for mutation in [
            JournalMutation.tamperCiphertext,
            .tamperNonce,
            .tamperTag,
            .unsupportedVersion,
        ] {
            let fixture = try makeFixture()
            defer { cleanup(fixture) }
            let store = makePersistedStore(fixture, bookmarks: makeDisorderedBookmarks())
            _ = try store.apply(store.makeBookmarkOrganizationPlan())
            let dataBefore = try Data(contentsOf: fixture.dataURL)
            try mutateJournal(at: fixture.dataURL, mutation: mutation)

            let restarted = BrowserDataStore(persistenceURL: fixture.dataURL)
            let expectedError: BookmarkTransactionError = mutation == .unsupportedVersion
                ? .unsupportedJournalVersion
                : .journalCorrupted
            XCTAssertThrowsError(try restarted.latestUndoableBookmarkTransaction()) { error in
                XCTAssertEqual(error as? BookmarkTransactionError, expectedError)
            }
            try assertPersistentWritesBlocked(
                store: restarted,
                dataURL: fixture.dataURL,
                expectedData: dataBefore
            )
        }
    }

    func testMissingJournalAndABADriftBothFailClosed() throws {
        do {
            let fixture = try makeFixture()
            defer { cleanup(fixture) }
            let store = makePersistedStore(fixture, bookmarks: makeDisorderedBookmarks())
            _ = try store.apply(store.makeBookmarkOrganizationPlan())
            let dataBefore = try Data(contentsOf: fixture.dataURL)
            try FileManager.default.removeItem(
                at: BrowserDataStore.bookmarkJournalURL(for: fixture.dataURL)
            )

            let restarted = BrowserDataStore(persistenceURL: fixture.dataURL)
            XCTAssertThrowsError(try restarted.latestUndoableBookmarkTransaction()) { error in
                XCTAssertEqual(error as? BookmarkTransactionError, .journalCorrupted)
            }
            try assertPersistentWritesBlocked(
                store: restarted,
                dataURL: fixture.dataURL,
                expectedData: dataBefore
            )
        }

        do {
            let fixture = try makeFixture()
            defer { cleanup(fixture) }
            let store = makePersistedStore(fixture, bookmarks: makeDisorderedBookmarks())
            let receipt = try store.apply(store.makeBookmarkOrganizationPlan())
            let applied = store.bookmarks
            let laterURL = try XCTUnwrap(URL(string: "https://later.example/"))
            XCTAssertTrue(store.toggleBookmark(title: "临时项", url: laterURL, isPrivate: false))
            XCTAssertFalse(store.toggleBookmark(title: "临时项", url: laterURL, isPrivate: false))
            XCTAssertEqual(store.bookmarks, applied)

            XCTAssertThrowsError(try store.undoBookmarkTransaction(
                transactionID: receipt.transactionID,
                expectedAfterDigest: receipt.afterDigest
            )) { error in
                guard case BookmarkTransactionError.stateDiverged = error else {
                    return XCTFail("ABA 状态必须按漂移拒绝，实际错误：\(error)")
                }
            }
            XCTAssertEqual(store.bookmarks, applied)
        }
    }

    func testPostReplaceProtectionFailureFreezesAndRestartRecoversCommittedTarget() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let store = makePersistedStore(fixture, bookmarks: makeDisorderedBookmarks())
        _ = try store.apply(store.makeBookmarkOrganizationPlan())
        let laterURL = try XCTUnwrap(URL(string: "https://post-replace.example/"))
        let dataBefore = try Data(contentsOf: fixture.dataURL)
        store.persistenceFailureInjector = { $0 == .postReplaceFileProtection }

        XCTAssertFalse(store.toggleBookmark(
            title: "替换后故障",
            url: laterURL,
            isPrivate: false
        ))
        XCTAssertFalse(store.bookmarks.contains { $0.url == laterURL.absoluteString })
        XCTAssertThrowsError(try store.makeBookmarkOrganizationPlan()) { error in
            XCTAssertEqual(error as? BookmarkTransactionError, .recoveryRequired)
        }
        let dataAfterReplace = try Data(contentsOf: fixture.dataURL)
        XCTAssertNotEqual(dataAfterReplace, dataBefore)
        try assertPersistentWritesBlocked(
            store: store,
            dataURL: fixture.dataURL,
            expectedData: dataAfterReplace
        )

        let restarted = BrowserDataStore(persistenceURL: fixture.dataURL)
        XCTAssertTrue(restarted.bookmarks.contains { $0.url == laterURL.absoluteString })
        XCTAssertNoThrow(try restarted.makeBookmarkOrganizationPlan())
        try assertCompleteProtectionIfReadable(at: fixture.dataURL)
    }

    func testAuthenticatedHeadRejectsRestoringValidPreUndoFilePair() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let store = makePersistedStore(fixture, bookmarks: makeDisorderedBookmarks())
        let receipt = try store.apply(store.makeBookmarkOrganizationPlan())
        let journalURL = BrowserDataStore.bookmarkJournalURL(for: fixture.dataURL)
        let oldPayload = try Data(contentsOf: fixture.dataURL)
        let oldJournal = try Data(contentsOf: journalURL)

        _ = try store.undoBookmarkTransaction(
            transactionID: receipt.transactionID,
            expectedAfterDigest: receipt.afterDigest
        )
        try oldPayload.write(to: fixture.dataURL, options: .atomic)
        try oldJournal.write(to: journalURL, options: .atomic)

        let restarted = BrowserDataStore(persistenceURL: fixture.dataURL)
        XCTAssertThrowsError(try restarted.latestUndoableBookmarkTransaction()) { error in
            XCTAssertEqual(error as? BookmarkTransactionError, .journalCorrupted)
        }
        XCTAssertThrowsError(try restarted.makeBookmarkOrganizationPlan()) { error in
            XCTAssertEqual(error as? BookmarkTransactionError, .journalCorrupted)
        }
    }

    func testAuthenticatedHeadRejectsRestoringClearedHistorySnapshot() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let store = makePersistedStore(fixture, bookmarks: makeDisorderedBookmarks())
        _ = try store.apply(store.makeBookmarkOrganizationPlan())
        store.record(
            title: "已清除的敏感历史",
            url: URL(string: "https://history.example/private?token=removed")!,
            isPrivate: false
        )
        let journalURL = BrowserDataStore.bookmarkJournalURL(for: fixture.dataURL)
        let oldPayload = try Data(contentsOf: fixture.dataURL)
        let oldJournal = try Data(contentsOf: journalURL)

        store.clearHistory()
        XCTAssertTrue(store.history.isEmpty)
        try oldPayload.write(to: fixture.dataURL, options: .atomic)
        try oldJournal.write(to: journalURL, options: .atomic)

        let restarted = BrowserDataStore(persistenceURL: fixture.dataURL)
        XCTAssertTrue(restarted.history.isEmpty, "防回滚失败时不得发布旧历史")
        XCTAssertThrowsError(try restarted.makeBookmarkOrganizationPlan()) { error in
            XCTAssertEqual(error as? BookmarkTransactionError, .journalCorrupted)
        }
    }

    func testCommittedPayloadRejectsHistoricalAuthenticatedEmptyJournal() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let original = makeDisorderedBookmarks()
        let first = makePersistedStore(fixture, bookmarks: original)
        let failedPlan = try first.makeBookmarkOrganizationPlan()
        first.persistenceFailureInjector = { $0 == .applyData }
        XCTAssertThrowsError(try first.apply(failedPlan))

        let recovered = BrowserDataStore(persistenceURL: fixture.dataURL)
        XCTAssertTrue(recovered.toggleBookmark(
            title: "触发空日志落盘",
            url: URL(string: "https://empty-journal.example/")!,
            isPrivate: false
        ))
        let journalURL = BrowserDataStore.bookmarkJournalURL(for: fixture.dataURL)
        let authenticatedEmptyJournal = try Data(contentsOf: journalURL)
        _ = try recovered.apply(recovered.makeBookmarkOrganizationPlan())
        try authenticatedEmptyJournal.write(to: journalURL, options: .atomic)

        let restarted = BrowserDataStore(persistenceURL: fixture.dataURL)
        XCTAssertThrowsError(try restarted.latestUndoableBookmarkTransaction()) { error in
            XCTAssertEqual(error as? BookmarkTransactionError, .journalCorrupted)
        }
    }

    func testOversizedPayloadAndDecodedCiphertextFailClosed() throws {
        do {
            let fixture = try makeFixture()
            defer { cleanup(fixture) }
            let oversizedPayload = Data(repeating: 0x41, count: 8 * 1_024 * 1_024 + 1)
            try oversizedPayload.write(to: fixture.dataURL, options: .atomic)
            let store = BrowserDataStore(persistenceURL: fixture.dataURL)
            XCTAssertThrowsError(try store.makeBookmarkOrganizationPlan()) { error in
                XCTAssertEqual(error as? BookmarkTransactionError, .storageCorrupted)
            }
            store.clearHistory()
            XCTAssertEqual(try Data(contentsOf: fixture.dataURL), oversizedPayload)
        }

        do {
            let fixture = try makeFixture()
            defer { cleanup(fixture) }
            _ = makePersistedStore(fixture, bookmarks: makeDisorderedBookmarks())
            let dataBefore = try Data(contentsOf: fixture.dataURL)
            let oversizedCiphertext = Data(
                repeating: 0x42,
                count: 16 * 1_024 * 1_024 + 1
            ).base64EncodedString()
            let envelope: [String: Any] = [
                "schema_version": 1,
                "algorithm": "AES-256-GCM",
                "nonce": Data(repeating: 0, count: 12).base64EncodedString(),
                "ciphertext": oversizedCiphertext,
                "tag": Data(repeating: 0, count: 16).base64EncodedString(),
            ]
            try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
                .write(
                    to: BrowserDataStore.bookmarkJournalURL(for: fixture.dataURL),
                    options: .atomic
                )

            let restarted = BrowserDataStore(persistenceURL: fixture.dataURL)
            XCTAssertThrowsError(try restarted.latestUndoableBookmarkTransaction()) { error in
                XCTAssertEqual(error as? BookmarkTransactionError, .journalCorrupted)
            }
            try assertPersistentWritesBlocked(
                store: restarted,
                dataURL: fixture.dataURL,
                expectedData: dataBefore
            )
        }

        do {
            let fixture = try makeFixture()
            defer { cleanup(fixture) }
            let store = makePersistedStore(fixture, bookmarks: makeDisorderedBookmarks())
            _ = try store.apply(store.makeBookmarkOrganizationPlan())
            let dataBefore = try Data(contentsOf: fixture.dataURL)
            let oversizedEnvelope = Data(
                repeating: 0x41,
                count: 24 * 1_024 * 1_024 + 1
            )
            try oversizedEnvelope.write(
                to: BrowserDataStore.bookmarkJournalURL(for: fixture.dataURL),
                options: .atomic
            )

            let restarted = BrowserDataStore(persistenceURL: fixture.dataURL)
            XCTAssertThrowsError(try restarted.latestUndoableBookmarkTransaction()) { error in
                XCTAssertEqual(error as? BookmarkTransactionError, .journalCorrupted)
            }
            try assertPersistentWritesBlocked(
                store: restarted,
                dataURL: fixture.dataURL,
                expectedData: dataBefore
            )
        }
    }

    private enum JournalMutation: Equatable {
        case tamperCiphertext
        case tamperNonce
        case tamperTag
        case unsupportedVersion
    }

    private func makeFixture() throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "aegis-bookmark-journal-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return Fixture(
            rootURL: rootURL,
            dataURL: rootURL.appendingPathComponent("browser-data.json")
        )
    }

    private func cleanup(_ fixture: Fixture) {
        BrowserDataStore.removeBookmarkJournalEncryptionKey(for: fixture.dataURL)
        try? FileManager.default.removeItem(at: fixture.rootURL)
    }

    private func makePersistedStore(
        _ fixture: Fixture,
        bookmarks: [BrowserBookmark]
    ) -> BrowserDataStore {
        let store = BrowserDataStore(
            persistenceURL: fixture.dataURL,
            initialBookmarks: bookmarks
        )
        // 先建立 revision 0 主数据，使故障注入可以精确覆盖两文件提交窗口。
        store.record(
            title: "seed",
            url: URL(string: "https://seed.example/?token=redacted")!,
            isPrivate: false
        )
        return store
    }

    private func assertPersistentWritesBlocked(
        store: BrowserDataStore,
        dataURL: URL,
        expectedData: Data
    ) throws {
        let historyBefore = store.history
        let bookmarksBefore = store.bookmarks
        store.record(
            title: "blocked",
            url: URL(string: "https://blocked.example/?secret=1")!,
            isPrivate: false
        )
        store.clearHistory()
        if let existing = bookmarksBefore.first,
           let existingURL = URL(string: existing.url) {
            XCTAssertTrue(store.toggleBookmark(
                title: existing.title,
                url: existingURL,
                isPrivate: false
            ))
        }
        _ = store.toggleBookmark(
            title: "blocked",
            url: URL(string: "https://blocked.example/")!,
            isPrivate: false
        )
        XCTAssertEqual(store.history, historyBefore)
        XCTAssertEqual(store.bookmarks, bookmarksBefore)
        XCTAssertEqual(try Data(contentsOf: dataURL), expectedData)
    }

    private func mutateJournal(at dataURL: URL, mutation: JournalMutation) throws {
        let journalURL = BrowserDataStore.bookmarkJournalURL(for: dataURL)
        let data = try Data(contentsOf: journalURL)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        switch mutation {
        case .tamperCiphertext:
            try flipFirstByte(of: "ciphertext", in: &object)
        case .tamperNonce:
            try flipFirstByte(of: "nonce", in: &object)
        case .tamperTag:
            try flipFirstByte(of: "tag", in: &object)
        case .unsupportedVersion:
            object["schema_version"] = 2
        }
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: journalURL, options: .atomic)
    }

    private func flipFirstByte(
        of key: String,
        in object: inout [String: Any]
    ) throws {
        let encoded = try XCTUnwrap(object[key] as? String)
        var data = try XCTUnwrap(Data(base64Encoded: encoded))
        XCTAssertFalse(data.isEmpty)
        data[data.startIndex] ^= 0x01
        object[key] = data.base64EncodedString()
    }

    private func assertCompleteProtectionIfReadable(at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let protection = attributes[.protectionKey] else { return }
        if let value = protection as? FileProtectionType {
            XCTAssertEqual(value, .complete)
        } else if let value = protection as? String {
            XCTAssertEqual(value, FileProtectionType.complete.rawValue)
        } else {
            XCTFail("无法识别文件保护属性：\(protection)")
        }
    }

    private func makeDisorderedBookmarks() -> [BrowserBookmark] {
        [
            BrowserBookmark(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
                title: "Z",
                url: "https://z.example?utm_source=feed",
                createdAt: Date(timeIntervalSince1970: 300)
            ),
            BrowserBookmark(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
                title: "重复项",
                url: "https://EXAMPLE.com/item?utm_source=feed&keep=1",
                createdAt: Date(timeIntervalSince1970: 200)
            ),
            BrowserBookmark(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                title: "保留项",
                url: "https://example.com/item?keep=1",
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            BrowserBookmark(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!,
                title: "A",
                url: "https://a.example?fbclid=tracking",
                createdAt: Date(timeIntervalSince1970: 400)
            ),
        ]
    }
}
