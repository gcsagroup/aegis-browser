import XCTest
@testable import BrowserKit

@MainActor final class RecordRecoveryTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let limit = Date().addingTimeInterval(20)
        while !condition(), Date() < limit { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "操作未达到预期状态")
    }

    func testWorkspaceResetPreservesDamagedOriginalAndRestoresLastGood() throws {
        let file = try temporaryDirectory().appendingPathComponent("records.json")
        let store = WorkspaceStore(persistenceURL: file)
        let saved = try store.save(name: "保留资料", urls: [URL(string: "https://example.com")!])
        try store.saveSession(urls: saved.urls)
        let backup = try XCTUnwrap(store.backups.first { $0.isLastGood })
        let original = Data("损坏的原始记录".utf8)
        try original.write(to: file)
        let restarted = WorkspaceStore(persistenceURL: file)
        XCTAssertNotNil(restarted.storageError)
        try restarted.resetRecords()
        XCTAssertTrue(restarted.backups.contains { (try? Data(contentsOf: $0.url)) == original })
        try restarted.restoreBackup(backup)
        XCTAssertEqual(restarted.workspaces.first, saved)
        let invalid = try XCTUnwrap(restarted.backups.first { (try? Data(contentsOf: $0.url)) == original })
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try restarted.restoreBackup(invalid))
        XCTAssertEqual(try Data(contentsOf: file), before)
        try restarted.rename(saved.id, to: "恢复后可写")
        XCTAssertNil(restarted.storageError)
    }

    func testDownloadQueuePauseLowSpaceAndReconnect() async throws {
        let directory = try temporaryDirectory()
        let manager = DownloadManager(directory: directory, background: false, maximumConcurrentDownloads: 1)
        try await waitUntil { !manager.hasActiveDownloads }
        let first = try manager.start("http://127.0.0.1:8768/slow.bin")
        let second = try manager.start("http://127.0.0.1:8768/download.bin")
        XCTAssertEqual(manager.items.first { $0.id == second }?.state, .queued)
        try await waitUntil { manager.items.first { $0.id == first }!.received > 0 }
        manager.pause(first)
        try await waitUntil { manager.items.first { $0.id == second }?.state == .completed }
        XCTAssertEqual(manager.items.first { $0.id == first }?.state, .paused)
        let low = DownloadManager(directory: try temporaryDirectory(), background: false, availableBytes: { _ in 1 })
        try await waitUntil { !low.hasActiveDownloads }
        let before = try Data(contentsOf: low.recordFileURL)
        XCTAssertThrowsError(try low.start("http://127.0.0.1:8768/download.bin"))
        XCTAssertEqual(try Data(contentsOf: low.recordFileURL), before)
        XCTAssertTrue(low.items.isEmpty)
        manager.cancel(first)
    }

    func testCompletedReceiptRecoversAfterManifestWriteFailureAndRemovalIsReversible() async throws {
        let directory = try temporaryDirectory()
        let manager = DownloadManager(directory: directory, background: false)
        try await waitUntil { !manager.hasActiveDownloads }
        let id = try manager.start("http://127.0.0.1:8768/slow.bin")
        try await waitUntil { manager.items.first?.received ?? 0 > 0 }
        let beforeCompletion = try Data(contentsOf: manager.recordFileURL)
        // 用目录占住清单路径，模拟文件已完成但清单无法原子写入。
        try FileManager.default.removeItem(at: manager.recordFileURL)
        try FileManager.default.createDirectory(at: manager.recordFileURL, withIntermediateDirectories: false)
        try await waitUntil { manager.items.first?.state == .completed }
        XCTAssertNotNil(manager.storageError)
        try FileManager.default.removeItem(at: manager.recordFileURL)
        try beforeCompletion.write(to: manager.recordFileURL)
        let restarted = DownloadManager(directory: directory, background: false)
        try await waitUntil { !restarted.hasActiveDownloads }
        let completed = try XCTUnwrap(restarted.items.first)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(try DownloadManager.hashFile(restarted.fileURL(completed)), completed.sha256)
        try restarted.removeDownloads([id], includingFiles: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restarted.fileURL(completed).path))
        let removed = DownloadManager(directory: directory, background: false)
        try await waitUntil { !removed.hasActiveDownloads }
        XCTAssertTrue(removed.items.isEmpty)
        let recovered = try await removed.recoverCompletedFiles()
        XCTAssertEqual(recovered, 1)
        try removed.removeDownloads([id], includingFiles: true)
        XCTAssertGreaterThan(removed.recycleBinBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.fileURL(completed).path))
        let restored = try await removed.restoreRecycledFiles()
        XCTAssertEqual(restored, 1)
        try removed.emptyRecycleBin()
        XCTAssertEqual(try DownloadManager.hashFile(removed.fileURL(completed)), completed.sha256)
    }

    func testPausedDownloadRestoresFromTrashAndContinues() async throws {
        let manager = DownloadManager(directory: try temporaryDirectory(), background: false)
        let id = try manager.start("http://127.0.0.1:8768/slow.bin")
        try await waitUntil { (manager.items.first?.received ?? 0) > 0 }
        manager.pause(id)
        try await waitUntil { manager.items.first?.state == .paused }
        try manager.removeDownloads([id], includingFiles: true)
        XCTAssertTrue(manager.items.isEmpty)
        let count = try await manager.restoreRecycledFiles()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(manager.items.first?.id, id)
        XCTAssertEqual(manager.items.first?.state, .paused)
        try manager.resume(id)
        try await waitUntil { manager.items.first?.state == .completed }
        let item = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(try DownloadManager.hashFile(manager.fileURL(item)), item.sha256)
    }

    func testInterruptedHTTPDownloadCanResumeWithMatchingFile() async throws {
        let manager = DownloadManager(directory: try temporaryDirectory(), background: false)
        let id = try manager.start("http://127.0.0.1:8768/drop.bin?case=\(UUID())")
        try await waitUntil { [.paused, .completed].contains(manager.items.first { $0.id == id }!.state) }
        if manager.items.first?.state == .paused { try manager.resume(id) }
        try await waitUntil { manager.items.first?.state == .completed }
        let item = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(item.received, Int64("GCSA Aegis simulator download verification\n".utf8.count * 1024 * 32))
        XCTAssertEqual(try DownloadManager.hashFile(manager.fileURL(item)), item.sha256)
    }
}
