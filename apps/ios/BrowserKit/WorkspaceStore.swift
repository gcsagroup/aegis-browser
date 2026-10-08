import AegisPolicyKit
import Combine
import Foundation

public struct SavedWorkspace: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let urls: [URL]
    public let savedAt: Date
}

/// 仅持久化普通标签的网址；私密标签永远不进入此存储。
@MainActor
public final class WorkspaceStore: ObservableObject {
    @Published public private(set) var workspaces: [SavedWorkspace] = []
    @Published public private(set) var sessionURLs: [URL] = []
    @Published public private(set) var storageError: String?
    private let persistenceURL: URL?
    private var unreadable = false

    private struct Payload: Codable {
        var workspaces: [SavedWorkspace]
        var sessionURLs: [URL]
    }

    public init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL
        do { try reloadRecords() } catch { }
    }

    public var recordFileURL: URL? { persistenceURL }
    public var backups: [RecordBackup] { persistenceURL.map { RecordBackups.list(for: $0) } ?? [] }

    public func reloadRecords() throws {
        guard let persistenceURL else { return }
        do {
            let value = try Self.decode(RecordBackups.read(persistenceURL))
            workspaces = value.workspaces
            sessionURLs = value.sessionURLs
            unreadable = false; storageError = nil
        } catch CocoaError.fileReadNoSuchFile {
            workspaces = []; sessionURLs = []; unreadable = false; storageError = nil
        } catch {
            unreadable = true
            storageError = WorkspaceError.unreadableRecords.localizedDescription
            throw WorkspaceError.unreadableRecords
        }
    }

    private static func decode(_ data: Data) throws -> Payload {
        guard data.count <= 2_000_000 else { throw WorkspaceError.unreadableRecords }
        let value = try JSONDecoder().decode(Payload.self, from: data)
        guard value.workspaces.count <= 100, Set(value.workspaces.map(\.id)).count == value.workspaces.count else {
            throw WorkspaceError.unreadableRecords
        }
        return Payload(workspaces: value.workspaces.map {
            SavedWorkspace(id: $0.id, name: String($0.name.prefix(80)),
                           urls: Self.persistableURLs($0.urls), savedAt: $0.savedAt)
        }, sessionURLs: Self.persistableURLs(value.sessionURLs))
    }

    public func restoreBackup(_ backup: RecordBackup) throws {
        guard let persistenceURL else { throw RecordRecoveryError.noFile }
        let data = try RecordBackups.readBackup(backup, for: persistenceURL)
        let value = try Self.decode(data)
        try replaceRecords(value)
    }

    public func resetRecords() throws {
        try replaceRecords(Payload(workspaces: [], sessionURLs: []))
    }

    private func replaceRecords(_ value: Payload) throws {
        guard let persistenceURL else { throw RecordRecoveryError.noFile }
        let data = try JSONEncoder().encode(value)
        try RecordBackups.retainOriginal(persistenceURL)
        try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: persistenceURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        workspaces = value.workspaces; sessionURLs = value.sessionURLs
        unreadable = false; storageError = nil
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("workspaces-v1.json")
    }

    @discardableResult
    public func save(name: String, urls: [URL]) throws -> SavedWorkspace {
        guard workspaces.count < 100 else { throw WorkspaceError.capacity }
        let urls = Self.persistableURLs(urls)
        guard !urls.isEmpty else { throw WorkspaceError.noPages }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = SavedWorkspace(id: UUID(), name: String((trimmed.isEmpty ? "工作区" : trimmed).prefix(80)),
                                   urls: urls, savedAt: Date())
        let next = [value] + workspaces
        try persist(workspaces: next, sessionURLs: sessionURLs)
        workspaces = next
        return value
    }

    public func saveSession(urls: [URL]) throws {
        let next = Self.persistableURLs(urls)
        try persist(workspaces: workspaces, sessionURLs: next)
        sessionURLs = next
    }

    public func remove(_ id: UUID) throws {
        let next = workspaces.filter { $0.id != id }
        try persist(workspaces: next, sessionURLs: sessionURLs)
        workspaces = next
    }

    public func rename(_ id: UUID, to name: String) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw WorkspaceError.invalidImport }
        let next = workspaces.map { value in
            value.id == id ? SavedWorkspace(id: value.id, name: String(title.prefix(80)), urls: value.urls, savedAt: value.savedAt) : value
        }
        try persist(workspaces: next, sessionURLs: sessionURLs)
        workspaces = next
    }

    public func exportData() throws -> Data {
        try JSONEncoder().encode(workspaces)
    }

    public static func previewImport(_ data: Data) throws -> [SavedWorkspace] {
        guard data.count <= 2_000_000 else { throw WorkspaceError.invalidImport }
        let incoming = try JSONDecoder().decode([SavedWorkspace].self, from: data)
        guard !incoming.isEmpty, incoming.count <= 100,
              incoming.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.urls.isEmpty && $0.urls.count <= 50 }) else { throw WorkspaceError.invalidImport }
        let values = incoming.map { SavedWorkspace(id: UUID(), name: String($0.name.prefix(80)),
                                                   urls: persistableURLs($0.urls), savedAt: Date()) }
        guard values.allSatisfy({ !$0.urls.isEmpty }) else { throw WorkspaceError.invalidImport }
        return values
    }

    public func importWorkspaces(_ values: [SavedWorkspace]) throws {
        guard !values.isEmpty, values.count + workspaces.count <= 100 else { throw WorkspaceError.invalidImport }
        // 即使调用方未使用预览入口，也重新校验并分配本地身份。
        let next = try Self.previewImport(JSONEncoder().encode(values)) + workspaces
        try persist(workspaces: next, sessionURLs: sessionURLs)
        workspaces = next
    }

    public static func persistableURLs(_ urls: [URL]) -> [URL] {
        urls.prefix(50).compactMap { url in
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil,
                  var parts = URLComponents(string: LinkSanitizer.sanitize(url.absoluteString).cleaned) else { return nil }
            parts.fragment = nil
            // 会话文件不保存网址里的登录票据或个人信息。
            parts.queryItems = parts.queryItems?.filter {
                let sensitive = ["token", "key", "secret", "auth", "password", "code", "session", "email", "phone"]
                return !sensitive.contains(where: $0.name.lowercased().contains)
                    && !PIIScanner.scan($0.value ?? "").blocked
            }
            if parts.queryItems?.isEmpty == true { parts.query = nil }
            return parts.url
        }
    }

    private func persist(workspaces: [SavedWorkspace], sessionURLs: [URL]) throws {
        guard !unreadable else { throw WorkspaceError.unreadableRecords }
        guard let persistenceURL else { return }
        let data = try JSONEncoder().encode(Payload(workspaces: workspaces, sessionURLs: sessionURLs))
        guard data.count <= 2_000_000 else { throw WorkspaceError.capacity }
        try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: persistenceURL.path) {
            let previous = try RecordBackups.read(persistenceURL)
            _ = try Self.decode(previous)
            try RecordBackups.preserveLastGood(previous, for: persistenceURL)
        }
        try data.write(to: persistenceURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

public enum WorkspaceError: LocalizedError {
    case noPages, invalidImport, unreadableRecords, capacity
    public var errorDescription: String? {
        switch self {
        case .noPages: String(localized: "请先打开普通网页，再保存工作区。")
        case .invalidImport: String(localized: "工作区文件无效或超出容量：最多 100 个工作区，每组 50 个页面。")
        case .unreadableRecords: String(localized: "工作区记录无法读取，原文件已保留，暂时无法保存更改。")
        case .capacity: String(localized: "工作区存储已满，请先导出并删除不需要的工作区，或减少页面数量。")
        }
    }
}
