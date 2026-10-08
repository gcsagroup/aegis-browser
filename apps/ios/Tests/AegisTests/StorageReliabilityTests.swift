import XCTest
@testable import BrowserKit

@MainActor
final class StorageReliabilityTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testUnreadableWorkspacesAreNeverOverwritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("workspaces.json")
        let valid = WorkspaceStore()
        let workspace = try valid.save(name: "新工作区", urls: [URL(string: "https://example.com")!])
        let oversized = Data("{\"workspaces\":[],\"sessionURLs\":[]}".utf8) + Data(repeating: 32, count: 2_000_001)
        for original in [Data("损坏的原始记录".utf8), oversized] {
            try original.write(to: file)
            let store = WorkspaceStore(persistenceURL: file)
            XCTAssertNotNil(store.storageError)
            XCTAssertThrowsError(try store.save(name: "新资料", urls: workspace.urls))
            XCTAssertThrowsError(try store.saveSession(urls: workspace.urls))
            XCTAssertThrowsError(try store.importWorkspaces([workspace]))
            XCTAssertThrowsError(try store.remove(UUID()))
            XCTAssertThrowsError(try store.rename(UUID(), to: "改名"))
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertTrue(store.workspaces.isEmpty)
        }
    }

    func testWorkspaceCapacityKeepsOldestSavedWorkspace() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("workspaces.json")
        let store = WorkspaceStore(persistenceURL: file)
        for index in 0..<100 {
            try store.save(name: "工作区 \(index)", urls: [URL(string: "https://example.com/\(index)")!])
        }
        let original = try Data(contentsOf: file)
        XCTAssertThrowsError(try store.save(name: "第 101 个", urls: [URL(string: "https://example.com/new")!]))
        XCTAssertEqual(store.workspaces.count, 100)
        XCTAssertEqual(store.workspaces.last?.name, "工作区 0")
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(WorkspaceStore(persistenceURL: file).workspaces, store.workspaces)
    }

    func testOversizedWorkspaceWriteKeepsPreviousData() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("workspaces.json")
        let store = WorkspaceStore(persistenceURL: file)
        let saved = try store.save(name: "保留", urls: [URL(string: "https://example.com")!])
        let original = try Data(contentsOf: file)
        let longURL = URL(string: "https://example.com/" + String(repeating: "a", count: 50_000))!
        XCTAssertThrowsError(try store.save(name: "过大", urls: Array(repeating: longURL, count: 50)))
        XCTAssertEqual(store.workspaces, [saved])
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testDuplicateWorkspaceIdentitiesPreserveOriginalFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("workspaces.json")
        let store = WorkspaceStore(persistenceURL: file)
        try store.save(name: "保留", urls: [URL(string: "https://example.com")!])
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let values = try XCTUnwrap(payload["workspaces"] as? [[String: Any]])
        payload["workspaces"] = values + values
        let original = try JSONSerialization.data(withJSONObject: payload)
        try original.write(to: file)
        let restarted = WorkspaceStore(persistenceURL: file)
        XCTAssertNotNil(restarted.storageError)
        XCTAssertThrowsError(try restarted.saveSession(urls: []))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testUnreadableDownloadsAreNeverOverwritten() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("downloads.json")
        let item = BrowserDownload(id: UUID(), url: URL(string: "https://example.com/file")!, filename: "file", state: .paused)
        var invalidName = item
        invalidName.filename = "../../file"
        let cases = [Data("损坏的下载记录".utf8), Data("[]".utf8) + Data(repeating: 32, count: 2_000_001),
                     try JSONEncoder().encode([item, item]), try JSONEncoder().encode([invalidName])]
        for original in cases {
            try original.write(to: file)
            let manager = DownloadManager(directory: directory, background: false)
            await manager.retryStorage()
            XCTAssertNotNil(manager.storageError)
            XCTAssertThrowsError(try manager.start("http://127.0.0.1:8768/download.bin"))
            await Task.yield()
            XCTAssertTrue(manager.items.isEmpty)
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testResumeWriteFailureKeepsPausedStateAndCanRetry() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("downloads.json")
        let item = BrowserDownload(id: UUID(), url: URL(string: "http://127.0.0.1:8768/download.bin")!, filename: "download.bin", state: .paused, received: 123)
        let original = try JSONEncoder().encode([item])
        try original.write(to: file)
        let manager = DownloadManager(directory: directory, background: false)
        await manager.retryStorage()
        try await waitUntil { manager.isReady }
        // 在测试专用清单位置放置目录，模拟无法原子写入；不修改真实用户目录。
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try manager.resume(item.id))
        XCTAssertEqual(manager.items.first, item)
        XCTAssertNotNil(manager.storageError)
        try FileManager.default.removeItem(at: file)
        try original.write(to: file)
        await manager.retryStorage()
        try await waitUntil { manager.isReady }
        try manager.resume(item.id)
        try await waitUntil { manager.items.first?.state == .completed }
        XCTAssertNil(manager.storageError)
        let completed = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(try DownloadManager.hashFile(manager.fileURL(completed)), completed.sha256)
        let persisted = try JSONDecoder().decode([BrowserDownload].self, from: Data(contentsOf: file))
        XCTAssertEqual(persisted.first?.state, .completed)
    }

    func testCompletedFileRemainsAvailableWhenManifestWriteFails() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("downloads.json")
        let manager = DownloadManager(directory: directory, background: false)
        await manager.retryStorage()
        try await waitUntil { manager.isReady }
        let id = try manager.start("http://127.0.0.1:8768/slow.bin")
        try await waitUntil { (manager.items.first?.received ?? 0) > 0 }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        try await waitUntil { manager.storageError != nil }
        let receiptURL = directory.appendingPathComponent(id.uuidString).appendingPathComponent("download-record.json")
        try await waitUntil { FileManager.default.fileExists(atPath: receiptURL.path) }
        let receipt = try JSONDecoder().decode(BrowserDownload.self, from: Data(contentsOf: receiptURL))
        XCTAssertEqual(receipt.state, .completed)
        XCTAssertEqual(try DownloadManager.hashFile(manager.fileURL(receipt)), receipt.sha256)
        XCTAssertNotEqual(manager.items.first?.state, .completed)
        XCTAssertFalse(manager.isReady)
        XCTAssertEqual(receipt.id, id)
    }

    func testFailedRetryWriteFailureKeepsMirrorAndRecoveryData() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("downloads.json")
        let urls = [URL(string: "http://127.0.0.1:8768/missing")!, URL(string: "http://127.0.0.1:8768/download.bin")!]
        let item = BrowserDownload(id: UUID(), url: urls[0], filename: "file", state: .failed,
                                   message: "保留上次错误", mirrors: urls, mirrorIndex: 1)
        try JSONEncoder().encode([item]).write(to: file)
        let resumeFile = directory.appendingPathComponent("\(item.id).resume")
        let recovery = Data("保留恢复资料".utf8)
        try recovery.write(to: resumeFile)
        let manager = DownloadManager(directory: directory, background: false)
        await manager.retryStorage()
        try await waitUntil { manager.isReady }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try manager.resume(item.id))
        XCTAssertEqual(manager.items.first, item)
        XCTAssertEqual(try Data(contentsOf: resumeFile), recovery)
    }

    func testOversizedDownloadWriteKeepsExistingRecords() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("downloads.json")
        let item = BrowserDownload(id: UUID(), url: URL(string: "https://example.com/file")!, filename: "file", state: .paused)
        let original = try JSONEncoder().encode([item])
        try original.write(to: file)
        let manager = DownloadManager(directory: directory, background: false)
        await manager.retryStorage()
        try await waitUntil { manager.isReady }
        let plan = DownloadPlan(urls: [URL(string: "http://127.0.0.1:8768/download.bin")!], filename: String(repeating: "a", count: 2_000_001))
        XCTAssertThrowsError(try manager.start(plan))
        XCTAssertEqual(manager.items, [item])
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(predicate(), "下载未在 20 秒内达到预期状态")
    }
}
