import AegisPolicyKit
import BrowserKit
import Combine
import CryptoKit
import Foundation
import Security

public struct AssistantTaskRecord: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case running, completed, interrupted, failed }
    public let id: UUID
    public var goal: String
    public var sources: [URL]
    public var state: State
    public var updatedAt: Date
    public var savedReport: String?
}

/// 正文不自动保存。记录与用户主动保存的报告均使用本机钥匙串密钥加密。
@MainActor
public final class AssistantTaskStore: ObservableObject {
    @Published public private(set) var records: [AssistantTaskRecord] = []
    @Published public private(set) var storageError: String?
    private let url: URL
    private let testKey: SymmetricKey?
    private let keyAccount: String
    private var readable = true
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("assistant-tasks-v1.aes")
    }
    public init(url: URL = AssistantTaskStore.defaultURL, key: SymmetricKey? = nil, keyAccount: String = "assistant-tasks-v1") {
        self.url = url; self.testKey = key; self.keyAccount = keyAccount
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 8_000_000 else { throw CocoaError(.fileReadTooLarge) }
                let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: encryptionKey(create: false))
                records = try JSONDecoder().decode([AssistantTaskRecord].self, from: plain)
                for index in records.indices where records[index].state == .running { records[index].state = .interrupted }
            } catch { readable = false; storageError = error.localizedDescription }
        }
    }
    @discardableResult public func begin(goal: String, sources: [URL]) throws -> UUID {
        let scan = PIIScanner.scan(goal)
        guard !scan.blocked else { throw ModelClientError.sensitiveData }
        let value = AssistantTaskRecord(id: UUID(), goal: String(scan.redacted.prefix(4000)),
            sources: WorkspaceStore.persistableURLs(sources), state: .running, updatedAt: Date())
        try commit(Array(([value] + records).prefix(100)))
        return value.id
    }
    public func finish(_ id: UUID, state: AssistantTaskRecord.State) throws {
        var next = records
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].state = state; next[index].updatedAt = Date()
        try commit(next)
    }
    public func saveReport(_ report: String, for id: UUID) throws {
        guard report.utf8.count <= 200_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        var next = records
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].savedReport = report
        try commit(next)
    }
    public func remove(_ id: UUID) throws { try commit(records.filter { $0.id != id }) }
    private func commit(_ next: [AssistantTaskRecord]) throws {
        guard readable else { throw CocoaError(.fileReadCorruptFile) }
        let data = try JSONEncoder().encode(next)
        guard data.count <= 7_500_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        let encrypted = try AES.GCM.seal(data, using: encryptionKey(create: true)).combined!
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encrypted.write(to: url, options: [.atomic, .completeFileProtection])
        records = next; storageError = nil
    }
    private func encryptionKey(create: Bool) throws -> SymmetricKey {
        if let testKey { return testKey }
        // App 更新或系统恢复可能改变沙盒绝对路径，密钥身份必须保持固定。
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.gcsa.aegis.ios.assistant-history", kSecAttrAccount as String: keyAccount]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new } as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound, create else { throw ModelClientError.keychain(status) }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let added = SecItemAdd(query.merging([kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { _, new in new } as CFDictionary, nil)
        guard added == errSecSuccess else { throw ModelClientError.keychain(added) }
        return key
    }
}
