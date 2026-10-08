import CryptoKit
import Security
import XCTest
@testable import AgentKit

@MainActor final class AssistantTaskStoreTests: XCTestCase {
    func testExplicitPrivateReportSaveIsAtomicAndEncrypted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("tasks.aes"), key = SymmetricKey(size: .bits256)
        let store = AssistantTaskStore(url: file, key: key)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let id = try store.saveCompletedReport(goal: "用户确认保存", sources: [URL(string: "https://example.com/private?token=secret")!], report: "主动保留的私密分析")
        let restored = AssistantTaskStore(url: file, key: key)
        XCTAssertEqual(restored.records.count, 1)
        XCTAssertEqual(restored.records.first?.id, id)
        XCTAssertEqual(restored.records.first?.state, .completed)
        XCTAssertEqual(restored.records.first?.savedReport, "主动保留的私密分析")
        XCTAssertEqual(restored.records.first?.sources.first?.absoluteString, "https://example.com/private")
        let before = try Data(contentsOf: file)
        XCTAssertNil(before.range(of: Data("主动保留的私密分析".utf8)))
        XCTAssertThrowsError(try store.saveCompletedReport(goal: "超出范围", sources: [], report: String(repeating: "x", count: 200_001)))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testKeyIdentitySurvivesChangedContainerPath() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let account = "aegis-task-key-test-" + UUID().uuidString
        defer {
            try? FileManager.default.removeItem(at: folder)
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.gcsa.aegis.ios.assistant-history",
                kSecAttrAccount as String: account] as CFDictionary)
        }
        let first = folder.appendingPathComponent("before/tasks.aes")
        let second = folder.appendingPathComponent("after/tasks.aes")
        let store = AssistantTaskStore(url: first, keyAccount: account)
        let id = try store.begin(goal: "更新后继续研究", sources: [URL(string: "https://example.com")!])
        try store.saveReport("保留的研究结果", for: id)
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: first, to: second)
        let migrated = AssistantTaskStore(url: second, keyAccount: account)
        XCTAssertNil(migrated.storageError)
        XCTAssertEqual(migrated.records.first?.savedReport, "保留的研究结果")
    }

    func testEncryptedHistoryRestartAndExplicitReport() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("tasks.aes"), key = SymmetricKey(size: .bits256)
        let store = AssistantTaskStore(url: url, key: key)
        let id = try store.begin(goal: "比较不同论文", sources: [URL(string: "https://example.com/p?token=secret&q=research")!])
        XCTAssertNil(store.records.first?.savedReport)
        XCTAssertEqual(store.records.first?.sources.first?.absoluteString, "https://example.com/p?q=research")
        let restarted = AssistantTaskStore(url: url, key: key)
        XCTAssertEqual(restarted.records.first?.state, .interrupted)
        try restarted.finish(id, state: .completed)
        try restarted.saveReport("明确保存的研究结果", for: id)
        let bytes = try Data(contentsOf: url)
        XCTAssertNil(bytes.range(of: Data("明确保存的研究结果".utf8)))
        XCTAssertEqual(AssistantTaskStore(url: url, key: key).records.first?.savedReport, "明确保存的研究结果")
        let badKey = AssistantTaskStore(url: url, key: SymmetricKey(size: .bits256))
        XCTAssertNotNil(badKey.storageError)
        XCTAssertThrowsError(try badKey.begin(goal: "不能覆盖旧记录", sources: []))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        try restarted.remove(id)
        XCTAssertTrue(AssistantTaskStore(url: url, key: key).records.isEmpty)
    }
}
