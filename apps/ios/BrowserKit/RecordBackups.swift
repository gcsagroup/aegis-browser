import Foundation

public struct RecordBackup: Identifiable, Sendable {
    public let url: URL
    public let date: Date
    public var id: String { url.lastPathComponent }
    public var isLastGood: Bool { id == "last-good.json" }
}

/// 只管理单个记录文件的备份；恢复前先保留当前原件，不自动删除历史备份。
public enum RecordBackups {
    public static func directory(for file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".backups", isDirectory: true)
    }

    public static func read(_ file: URL, maximumBytes: Int = 2_000_000) throws -> Data {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= maximumBytes else { throw RecordRecoveryError.invalidBackup }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw RecordRecoveryError.invalidBackup }
        return data
    }

    public static func list(for file: URL) -> [RecordBackup] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory(for: file),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return RecordBackup(url: url, date: values.contentModificationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }
    }

    @discardableResult
    public static func retainOriginal(_ file: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw RecordRecoveryError.invalidBackup }
        let folder = directory(for: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.copyItem(at: file, to: target)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
        return target
    }

    public static func preserveLastGood(_ data: Data, for file: URL) throws {
        let folder = directory(for: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("last-good.json"),
                       options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    public static func readBackup(_ backup: RecordBackup, for file: URL) throws -> Data {
        guard backup.url.deletingLastPathComponent().standardizedFileURL == directory(for: file).standardizedFileURL,
              list(for: file).contains(where: { $0.url == backup.url }) else { throw RecordRecoveryError.invalidBackup }
        return try read(backup.url)
    }
}

public enum RecordRecoveryError: LocalizedError {
    case invalidBackup, busy, noFile
    public var errorDescription: String? {
        switch self {
        case .invalidBackup: String(localized: "备份无效或超出容量，当前记录未被替换。")
        case .busy: String(localized: "请先暂停或取消下载，再恢复记录。")
        case .noFile: String(localized: "没有可导出的记录文件。")
        }
    }
}
