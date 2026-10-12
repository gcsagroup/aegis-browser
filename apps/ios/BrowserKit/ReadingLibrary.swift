import AegisPolicyKit
import Combine
import CryptoKit
import Foundation
import PDFKit
import Security

public struct ReadingRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public let sourceURL: URL?
    public let pdfPage: Int?
    public let text: String
    public let truncated: Bool
    public var quote = ""
    public var note = ""
    public var translation = ""
    public var translationLanguage = ""
    public var archived = false
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, sourceURL: URL?, pdfPage: Int? = nil,
                text: String, truncated: Bool = false, updatedAt: Date = Date()) {
        self.id = id; self.title = title; self.sourceURL = sourceURL; self.pdfPage = pdfPage
        self.text = text; self.truncated = truncated; self.updatedAt = updatedAt
    }
    public var report: String {
        [title, sourceURL?.absoluteString ?? "", pdfPage.map { String(localized: "PDF 第 \($0) 页") } ?? "",
         text, quote, note, translation].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

public enum ReadingLibraryError: LocalizedError {
    case unreadable, capacity, changed, invalidQuote, invalidRecord, pdfUnavailable, pdfTooLarge
    public var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "阅读资料无法解密或读取，原文件已保留。请恢复可用的钥匙串或备份后重试。")
        case .capacity: String(localized: "阅读资料已达到容量限制。最多保存 100 条、合计 8 MB；原资料保持不变。")
        case .changed: String(localized: "资料已在另一处更改，请返回列表重新打开后再保存。")
        case .invalidQuote: String(localized: "引文必须来自当前保存的原文，不能使用原文中不存在的文字。")
        case .invalidRecord: String(localized: "资料内容或来源无效，无法保存。")
        case .pdfUnavailable: String(localized: "无法读取此 PDF 页的文字层。请检查页码、密码或改用有文字层的 PDF；当前不提供 OCR。")
        case .pdfTooLarge: String(localized: "PDF 文件超过 20 MB，或页数超过 1000 页，暂不导入。")
        }
    }
}

/// 只保存明确选择的正文和批注。主线程共享实例串行写入，密文摘要防止其他实例覆盖新资料。
@MainActor
public final class ReadingLibrary: ObservableObject {
    @Published public private(set) var records: [ReadingRecord] = []
    @Published public private(set) var storageError: String?
    public let fileURL: URL
    private var lastDiskHash: Data?
    private var readable = true
    private let testKey: SymmetricKey?
    private let keyAccount: String
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("reading-library-v1.aes")
    }

    public init(url: URL = ReadingLibrary.defaultURL, key: SymmetricKey? = nil, keyAccount: String = "reading-library-v1") {
        fileURL = url; testKey = key; self.keyAccount = keyAccount
        reload()
    }

    public func reload() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let encrypted = try Data(contentsOf: fileURL)
                guard encrypted.count <= 8_100_000 else { throw ReadingLibraryError.capacity }
                let data = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: encryptionKey(create: false))
                let next = try JSONDecoder().decode([ReadingRecord].self, from: data)
                guard next.count <= 100, Set(next.map(\.id)).count == next.count else { throw ReadingLibraryError.invalidRecord }
                try next.forEach(Self.validate)
                records = next; lastDiskHash = Data(SHA256.hash(data: encrypted))
            } else { records = []; lastDiskHash = nil }
            readable = true; storageError = nil
        } catch { readable = false; storageError = ReadingLibraryError.unreadable.localizedDescription }
    }

    public func save(_ record: ReadingRecord, replacing expectedDate: Date? = nil) throws {
        var value = record
        try Self.validate(value)
        if let existing = records.first(where: { $0.id == value.id }) {
            guard expectedDate == existing.updatedAt,
                  value.sourceURL == existing.sourceURL, value.text == existing.text, value.pdfPage == existing.pdfPage
            else { throw ReadingLibraryError.changed }
        } else if expectedDate != nil { throw ReadingLibraryError.changed }
        value.updatedAt = Date()
        try commit([value] + records.filter { $0.id != value.id })
    }

    public func remove(id: UUID, replacing expectedDate: Date) throws {
        guard records.first(where: { $0.id == id })?.updatedAt == expectedDate else { throw ReadingLibraryError.changed }
        try commit(records.filter { $0.id != id })
    }

    public func setArchived(_ value: Bool, id: UUID) throws {
        guard var record = records.first(where: { $0.id == id }) else { throw ReadingLibraryError.changed }
        let date = record.updatedAt
        record.archived = value
        try save(record, replacing: date)
    }

    public func search(_ query: String, archived: Bool = false) -> [ReadingRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { $0.archived == archived && (query.isEmpty || $0.report.localizedStandardContains(query)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func fromSnapshot(_ snapshot: PageSnapshot) -> ReadingRecord {
        ReadingRecord(title: snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (snapshot.url.host ?? String(localized: "阅读资料")) : snapshot.title, sourceURL: WorkspaceStore.persistableURLs([snapshot.url]).first,
                      text: snapshot.text, truncated: snapshot.truncated)
    }

    public static func pdfRecord(data: Data, name: String, page: Int) throws -> ReadingRecord {
        guard data.count <= 20_000_000 else { throw ReadingLibraryError.pdfTooLarge }
        guard let pdf = PDFDocument(data: data), !pdf.isLocked else { throw ReadingLibraryError.pdfUnavailable }
        guard pdf.pageCount <= 1000 else { throw ReadingLibraryError.pdfTooLarge }
        guard page > 0, page <= pdf.pageCount,
              let text = pdf.page(at: page - 1)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { throw ReadingLibraryError.pdfUnavailable }
        return ReadingRecord(title: String(name.prefix(300)), sourceURL: nil, pdfPage: page,
                             text: String(text.prefix(24_000)), truncated: text.count > 24_000)
    }

    private static func validate(_ record: ReadingRecord) throws {
        guard !record.title.isEmpty, record.title.count <= 300, !record.text.isEmpty, record.text.count <= 24_000,
              record.note.count <= 8_000, record.quote.count <= 4_000, record.translation.count <= 48_000,
              record.translationLanguage.count <= 80,
              record.sourceURL.map({ BrowserPreferences.origin($0) != nil }) ?? (record.pdfPage.map { $0 > 0 } ?? false)
        else { throw ReadingLibraryError.invalidRecord }
        guard record.quote.isEmpty || record.text.contains(record.quote) else { throw ReadingLibraryError.invalidQuote }
    }

    private func commit(_ next: [ReadingRecord]) throws {
        guard readable else { throw ReadingLibraryError.unreadable }
        let current = try FileManager.default.fileExists(atPath: fileURL.path) ? Data(contentsOf: fileURL) : nil
        guard current.map({ Data(SHA256.hash(data: $0)) }) == lastDiskHash else { throw ReadingLibraryError.changed }
        guard next.count <= 100 else { throw ReadingLibraryError.capacity }
        let plain = try JSONEncoder().encode(next)
        guard plain.count <= 8_000_000 else { throw ReadingLibraryError.capacity }
        let encrypted = try AES.GCM.seal(plain, using: encryptionKey(create: true)).combined!
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encrypted.write(to: fileURL, options: [.atomic, .completeFileProtection])
        lastDiskHash = Data(SHA256.hash(data: encrypted)); records = next; storageError = nil
    }

    private func encryptionKey(create: Bool) throws -> SymmetricKey {
        if let testKey { return testKey }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.gcsa.aegis.ios.reading", kSecAttrAccount as String: keyAccount]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { _, next in next } as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound, create else { throw ReadingLibraryError.unreadable }
        let key = SymmetricKey(size: .bits256)
        let statusAdded = SecItemAdd(query.merging([kSecValueData as String: key.withUnsafeBytes { Data($0) },
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { _, next in next } as CFDictionary, nil)
        guard statusAdded == errSecSuccess else { throw ReadingLibraryError.unreadable }
        return key
    }
}
