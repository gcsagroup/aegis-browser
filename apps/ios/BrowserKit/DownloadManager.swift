import Combine
import CryptoKit
import Foundation

public struct BrowserDownload: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case queued, running, pausing, paused, completed, failed, cancelled }
    public let id: UUID
    public let url: URL
    public var filename: String
    public var state: State
    public var received: Int64 = 0
    public var expected: Int64 = 0
    public var sha256: String?
    public var expectedSHA256: String?
    public var message: String?
    public var mirrors: [URL]?
    public var mirrorIndex: Int?
    public var expectedSize: Int64?
    public var expectedSHA512: String?
    public var sha512: String?
    public var plannedFilename: String?
    public var createdAt: Date?
    public var currentURL: URL {
        guard let mirrors, !mirrors.isEmpty else { return url }
        return mirrors[min(max(0, mirrorIndex ?? 0), mirrors.count - 1)]
    }
    public var progress: Double? { expected > 0 ? min(1, Double(received) / Double(expected)) : nil }
}

public enum DownloadError: LocalizedError {
    case invalidURL, invalidHash, http(Int), hashMismatch, tooLarge, missingFile, unreadableRecords, recordsTooLarge, insufficientSpace
    public var errorDescription: String? {
        switch self {
        case .invalidURL: String(localized: "此下载地址无法安全使用，请输入普通 HTTP 或 HTTPS 文件链接。")
        case .invalidHash: String(localized: "SHA-256 应为 64 位十六进制字符。")
        case let .http(status): String(localized: "下载服务器返回错误（\(status)）。")
        case .hashMismatch: String(localized: "文件校验不一致，已丢弃本次文件。")
        case .tooLarge: String(localized: "文件超过当前 1 GB 下载限制，已停止下载。")
        case .missingFile: String(localized: "下载文件已不可用，请重新下载。")
        case .unreadableRecords: String(localized: "下载记录无法读取，原文件已保留，暂时无法开始或更改下载。")
        case .recordsTooLarge: String(localized: "下载记录超过存储容量，未保存本次更改。")
        case .insufficientSpace: String(localized: "可用空间不足，下载已停止。请释放空间后继续。")
        }
    }
}

/// 由系统执行传输；记录先落盘，完成文件核对后才显示完成。
@MainActor
public final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published public private(set) var items: [BrowserDownload] = []
    @Published public private(set) var storageError: String?
    @Published public private(set) var maximumConcurrentDownloads: Int
    @Published public private(set) var storedBytes: Int64 = 0
    @Published public private(set) var recycleBinBytes: Int64 = 0
    @Published public private(set) var availableBytes: Int64?
    @Published public private(set) var isRecovering = false
    public let directory: URL
    public static var backgroundCompletion: (() -> Void)?
    private var finalizingCount = 0
    private var backgroundEventsFinished = false
    private var unreadable = false
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var reconnecting = true
    private var recordGeneration = UUID()
    private var progressDates: [UUID: Date] = [:]
    private var capacityCheckDates: [UUID: Date] = [:]
    private let capacity: @Sendable (URL) -> Int64?
    private let useBackgroundSession: Bool
    private lazy var session: URLSession = {
        let config = useBackgroundSession
            ? URLSessionConfiguration.background(withIdentifier: "com.gcsa.aegis.ios.downloads.v1")
            : URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 3600
        // 前台连接失败要及时进入暂停或备用镜像，不能一直等系统恢复连接。
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    public init(directory: URL? = nil, background: Bool = true, maximumConcurrentDownloads: Int? = nil,
                availableBytes: (@Sendable (URL) -> Int64?)? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        self.useBackgroundSession = background
        let savedLimit = background ? UserDefaults.standard.integer(forKey: "downloads.concurrentLimit") : 2
        self.maximumConcurrentDownloads = min(4, max(1, maximumConcurrentDownloads ?? (savedLimit > 0 ? savedLimit : 2)))
        self.capacity = availableBytes ?? Self.freeCapacity
        super.init()
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            do {
                items = try Self.decodeRecords(RecordBackups.read(manifestURL))
            } catch CocoaError.fileReadNoSuchFile {
                // 新安装尚无清单；其他读取错误必须保留原文件。
            }
            Task { await reconnect() }
        } catch {
            unreadable = true; reconnecting = false
            storageError = DownloadError.unreadableRecords.localizedDescription
        }
        refreshStorageUsage()
    }

    private var manifestURL: URL { directory.appendingPathComponent("downloads.json") }
    public var recordFileURL: URL { manifestURL }
    public var backups: [RecordBackup] { RecordBackups.list(for: manifestURL) }
    public var hasActiveDownloads: Bool { reconnecting || items.contains { [.queued, .running, .pausing].contains($0.state) } }
    private var recycleDirectory: URL { directory.appendingPathComponent("Removed", isDirectory: true) }
    private func resumeURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id).resume") }
    public func fileURL(_ item: BrowserDownload) -> URL {
        let legacy = directory.appendingPathComponent("\(item.id)-\(item.filename)")
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return directory.appendingPathComponent(item.id.uuidString, isDirectory: true).appendingPathComponent(item.filename)
    }

    public static func validatedURL(_ input: String) throws -> URL {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { throw DownloadError.invalidURL }
        let decision = BrowserNavigationPolicy.evaluate(url)
        guard decision.kind != .blocked, let clean = URL(string: decision.effectiveURL) else { throw DownloadError.invalidURL }
        return clean
    }

    public static func safeFilename(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        let safe = last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" && $0 != "\\" }
        let value = String(String.UnicodeScalarView(safe)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "." || value == ".." || value.lowercased() == "download-record.json" ? "download.bin" : String(value.prefix(100))
    }

    @discardableResult
    public func start(_ input: String, expectedSHA256: String = "") throws -> UUID {
        try start(DownloadPlan(urls: [try Self.validatedURL(input)], sha256: expectedSHA256))
    }

    @discardableResult
    public func start(_ plan: DownloadPlan) throws -> UUID {
        guard !unreadable else { throw DownloadError.unreadableRecords }
        guard !plan.urls.isEmpty, plan.urls.count <= 16, Set(plan.urls).count == plan.urls.count else { throw DownloadPlanError.invalidMirrors }
        let urls = try plan.urls.map { try Self.validatedURL($0.absoluteString) }
        let hash = (plan.sha256 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hash512 = (plan.sha512 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hash.isEmpty || hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              hash512.isEmpty || hash512.range(of: "^[a-f0-9]{128}$", options: .regularExpression) != nil else { throw DownloadError.invalidHash }
        guard plan.size == nil || (0...1_000_000_000).contains(plan.size!) else { throw DownloadError.tooLarge }
        try checkCapacity(required: plan.size ?? 0)
        let item = BrowserDownload(id: UUID(), url: urls[0], filename: Self.safeFilename(plan.filename ?? urls[0].lastPathComponent), state: .queued,
                                   expectedSHA256: hash.isEmpty ? nil : hash, mirrors: urls, mirrorIndex: 0,
                                   expectedSize: plan.size, expectedSHA512: hash512.isEmpty ? nil : hash512, plannedFilename: plan.filename, createdAt: Date())
        items.insert(item, at: 0)
        do { try persist() } catch { items.removeAll { $0.id == item.id }; throw error }
        scheduleQueuedDownloads()
        return item.id
    }

    private func begin(_ item: BrowserDownload) throws {
        try checkCapacity(required: max(0, (item.expectedSize ?? item.expected) - item.received))
        let receipt = receiptURL(item.id)
        if FileManager.default.fileExists(atPath: receipt.path) { try FileManager.default.removeItem(at: receipt) }
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeURL(item.id)) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: item.currentURL)
        }
        task.taskDescription = item.id.uuidString
        tasks[item.id] = task
        task.resume()
    }

    public func pause(_ id: UUID) {
        if let index = items.firstIndex(where: { $0.id == id && $0.state == .queued }) {
            items[index].state = .paused; saveOrReport(); return
        }
        guard let task = tasks.removeValue(forKey: id), let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .pausing
        saveOrReport()
        let target = resumeURL(id)
        task.cancel { data in
            Task { @MainActor in
                guard let index = self.items.firstIndex(where: { $0.id == id }), self.items[index].state == .pausing else { return }
                do {
                    // 完成恢复数据写入后才允许继续，避免旧回调覆盖新任务。
                    if let data { try data.write(to: target, options: [.atomic, .completeFileProtectionUnlessOpen]) }
                    self.items[index].state = .paused
                } catch {
                    self.items[index].state = .failed
                    self.items[index].message = error.localizedDescription
                }
                self.saveOrReport()
                self.scheduleQueuedDownloads()
            }
        }
    }

    public func resume(_ id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }),
              [.paused, .failed, .cancelled].contains(items[index].state) else { return }
        _ = try Self.validatedURL(items[index].currentURL.absoluteString)
        let previous = items[index]
        if items[index].state != .paused {
            items[index].mirrorIndex = 0
        }
        try checkCapacity(required: max(0, (items[index].expectedSize ?? items[index].expected) - items[index].received))
        items[index].state = .queued
        items[index].message = nil
        do { try persist() }
        catch {
            items[index] = previous
            storageError = String(localized: "下载记录保存失败：\(error.localizedDescription)")
            throw error
        }
        if previous.state != .paused { try? FileManager.default.removeItem(at: resumeURL(id)) }
        scheduleQueuedDownloads()
    }

    public func cancel(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .cancelled
        try? FileManager.default.removeItem(at: resumeURL(id))
        saveOrReport()
        scheduleQueuedDownloads()
    }

    private func reconnect() async {
        reconnecting = true
        defer { reconnecting = false; scheduleQueuedDownloads(); refreshStorageUsage() }
        let existing = await session.allTasks
        for task in existing {
            guard let name = task.taskDescription, let id = UUID(uuidString: name),
                  let task = task as? URLSessionDownloadTask,
                  items.contains(where: { $0.id == id && $0.state == .running }) else { task.cancel(); continue }
            tasks[id] = task
        }
        for index in items.indices where [.running, .pausing].contains(items[index].state) && tasks[items[index].id] == nil {
            items[index].state = .paused
            items[index].message = String(localized: "上次下载已中断，可继续或重新下载。")
        }
        do { _ = try await recoverCompletedFiles(includeUnlisted: false) }
        catch { storageError = error.localizedDescription }
        for index in items.indices where items[index].state == .completed {
            if !FileManager.default.fileExists(atPath: fileURL(items[index]).path) {
                items[index].state = .failed
                items[index].message = DownloadError.missingFile.localizedDescription
            } else if !FileManager.default.fileExists(atPath: receiptURL(items[index].id).path) {
                do { try writeReceipt(items[index]) } catch { storageError = error.localizedDescription }
            }
        }
        saveOrReport()
    }

    private func persist() throws {
        guard !unreadable else { throw DownloadError.unreadableRecords }
        let data = try JSONEncoder().encode(items)
        guard data.count <= 2_000_000 else { throw DownloadError.recordsTooLarge }
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let previous = try RecordBackups.read(manifestURL)
            _ = try Self.decodeRecords(previous)
            try RecordBackups.preserveLastGood(previous, for: manifestURL)
        }
        try data.write(to: manifestURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        storageError = nil
    }
    private func saveOrReport() {
        do { try persist() } catch { storageError = String(localized: "下载记录保存失败：\(error.localizedDescription)") }
    }

    public func setConcurrencyLimit(_ value: Int) {
        maximumConcurrentDownloads = min(4, max(1, value))
        if useBackgroundSession { UserDefaults.standard.set(maximumConcurrentDownloads, forKey: "downloads.concurrentLimit") }
        scheduleQueuedDownloads()
    }

    private func scheduleQueuedDownloads() {
        guard !reconnecting, !unreadable, !isRecovering else { return }
        for id in items.reversed().filter({ $0.state == .queued }).map(\.id) {
            guard tasks.count < maximumConcurrentDownloads,
                  let index = items.firstIndex(where: { $0.id == id }) else { break }
            items[index].state = .running
            do {
                try persist()
                try begin(items[index])
            } catch {
                items[index].state = .failed
                items[index].message = error.localizedDescription
                saveOrReport()
            }
        }
    }

    nonisolated private static func freeCapacity(_ directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
    }

    private func checkCapacity(required: Int64) throws {
        availableBytes = capacity(directory)
        if let availableBytes, availableBytes < max(0, required) + 32_000_000 { throw DownloadError.insufficientSpace }
    }

    public func refreshStorageUsage() {
        availableBytes = capacity(directory)
        var total: Int64 = 0, removed: Int64 = 0
        if let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) {
            for case let url as URL in files {
                guard let value = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      value.isRegularFile == true, value.isSymbolicLink != true else { continue }
                let bytes = Int64(value.fileSize ?? 0)
                total += bytes
                if url.path.hasPrefix(recycleDirectory.path + "/") { removed += bytes }
            }
        }
        storedBytes = total; recycleBinBytes = removed
    }

    private static func decodeRecords(_ data: Data) throws -> [BrowserDownload] {
        guard data.count <= 2_000_000 else { throw DownloadError.recordsTooLarge }
        let values = try JSONDecoder().decode([BrowserDownload].self, from: data)
        guard Set(values.map(\.id)).count == values.count,
              values.allSatisfy({ $0.filename == Self.safeFilename($0.filename) }) else { throw DownloadError.unreadableRecords }
        return values
    }

    public func reloadRecords() async throws {
        guard !hasActiveDownloads, !isRecovering else { throw RecordRecoveryError.busy }
        do {
            items = try Self.decodeRecords(RecordBackups.read(manifestURL))
            recordGeneration = UUID(); unreadable = false; storageError = nil
            await reconnect()
        } catch {
            unreadable = true; storageError = DownloadError.unreadableRecords.localizedDescription
            throw error
        }
    }

    public func restoreBackup(_ backup: RecordBackup) async throws {
        guard !hasActiveDownloads, !isRecovering else { throw RecordRecoveryError.busy }
        let values = try Self.decodeRecords(RecordBackups.readBackup(backup, for: manifestURL))
        try replaceRecords(values)
        await reconnect()
    }

    public func resetRecords() async throws {
        guard !hasActiveDownloads, !isRecovering else { throw RecordRecoveryError.busy }
        try replaceRecords([])
        await reconnect()
    }

    private func replaceRecords(_ values: [BrowserDownload]) throws {
        let next = values.map { item in
            var item = item
            if [.running, .queued, .pausing].contains(item.state) {
                item.state = .paused
                item.message = String(localized: "记录已恢复，请确认后继续下载。")
            }
            return item
        }
        let data = try JSONEncoder().encode(next)
        guard data.count <= 2_000_000 else { throw DownloadError.recordsTooLarge }
        try RecordBackups.retainOriginal(manifestURL)
        try data.write(to: manifestURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        recordGeneration = UUID(); items = next; unreadable = false; storageError = nil
    }

    private func receiptURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("download-record.json")
    }

    private func writeReceipt(_ item: BrowserDownload) throws {
        let file = receiptURL(item.id)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(item).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    @discardableResult
    public func recoverCompletedFiles() async throws -> Int {
        guard !hasActiveDownloads, !isRecovering else { throw RecordRecoveryError.busy }
        guard !unreadable else { throw DownloadError.unreadableRecords }
        isRecovering = true
        defer { isRecovering = false; refreshStorageUsage(); scheduleQueuedDownloads() }
        return try await recoverCompletedFiles(includeUnlisted: true)
    }

    /// 自动恢复仅修复清单里仍存在的任务；主动移除的记录不会在重启后自行出现。
    private func recoverCompletedFiles(includeUnlisted: Bool) async throws -> Int {
        let generation = recordGeneration
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
        var recovered: [BrowserDownload] = []
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent), tasks[id] == nil,
                  (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            let existing = items.first { $0.id == id }
            guard existing?.state != .completed, includeUnlisted || existing != nil else { continue }
            guard let data = try? RecordBackups.read(receiptURL(id)),
                  var item = try? JSONDecoder().decode(BrowserDownload.self, from: data),
                  item.id == id, item.state == .completed, item.filename == Self.safeFilename(item.filename),
                  let hash = item.sha256, (try? Self.validatedURL(item.url.absoluteString)) != nil else { continue }
            let file = fileURL(item)
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 1_000_000_000 else { continue }
            let expected512 = item.sha512
            let valid = try await Task.detached(priority: .utility) {
                guard try Self.hashFile(file) == hash else { return false }
                if let expected512 { return try Self.hashFile(file, sha512: true) == expected512 }
                return true
            }.value
            try Task.checkCancellation()
            guard generation == recordGeneration else { throw RecordRecoveryError.busy }
            if valid, tasks[id] == nil {
                item.received = Int64(values.fileSize ?? 0)
                item.message = String(localized: "已按文件校验值恢复记录。")
                recovered.append(item)
            }
        }
        guard !recovered.isEmpty else { return 0 }
        let previous = items
        for item in recovered {
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
            else { items.append(item) }
        }
        do { try persist() } catch { items = previous; throw error }
        return recovered.count
    }

    public func removeDownloads(_ ids: Set<UUID>, includingFiles: Bool) throws {
        guard !unreadable else { throw DownloadError.unreadableRecords }
        guard !isRecovering, !reconnecting else { throw RecordRecoveryError.busy }
        let selected = items.filter { ids.contains($0.id) }
        guard selected.allSatisfy({ ![.running, .queued, .pausing].contains($0.state) }) else { throw RecordRecoveryError.busy }
        guard !selected.isEmpty else { return }
        try RecordBackups.retainOriginal(manifestURL)
        let previous = items
        items.removeAll { ids.contains($0.id) }
        do { try persist() } catch { items = previous; throw error }
        recordGeneration = UUID()
        defer { refreshStorageUsage() }
        guard includingFiles else { return }
        // 清单移除成功后才移动文件。后续失败时，文件仍保留在原位置或回收站。
        let operation = recycleDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: operation, withIntermediateDirectories: true)
        try JSONEncoder().encode(selected).write(to: operation.appendingPathComponent("records.json"),
                                                 options: [.atomic, .completeFileProtectionUnlessOpen])
        for item in selected {
            for original in [directory.appendingPathComponent(item.id.uuidString),
                             directory.appendingPathComponent("\(item.id)-\(item.filename)"), resumeURL(item.id)] {
                if FileManager.default.fileExists(atPath: original.path) {
                    try FileManager.default.moveItem(at: original, to: operation.appendingPathComponent(original.lastPathComponent))
                }
            }
        }
    }

    @discardableResult
    public func restoreRecycledFiles() async throws -> Int {
        guard !hasActiveDownloads, !isRecovering else { throw RecordRecoveryError.busy }
        guard !unreadable else { throw DownloadError.unreadableRecords }
        let operations = (try? FileManager.default.contentsOfDirectory(at: recycleDirectory, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        var restoredRecords: [BrowserDownload] = []
        for operation in operations {
            guard UUID(uuidString: operation.lastPathComponent) != nil,
                  (try? operation.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            let records = try Self.decodeRecords(RecordBackups.read(operation.appendingPathComponent("records.json")))
            for item in records {
                for name in [item.id.uuidString, "\(item.id)-\(item.filename)", "\(item.id).resume"] {
                    let original = operation.appendingPathComponent(name)
                    let target = directory.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: original.path), !FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.moveItem(at: original, to: target)
                    }
                }
                if item.state != .completed,
                   !items.contains(where: { $0.id == item.id }),
                   !restoredRecords.contains(where: { $0.id == item.id }) {
                    var restored = item
                    if [.queued, .running, .pausing].contains(restored.state) { restored.state = .paused }
                    restoredRecords.append(restored)
                }
            }
        }
        if !restoredRecords.isEmpty {
            let previous = items
            items.append(contentsOf: restoredRecords)
            do { try persist() } catch { items = previous; throw error }
            recordGeneration = UUID()
        }
        // 未完成任务要连同续传记录一起恢复；完成文件仍须通过哈希核对。
        return restoredRecords.count + (try await recoverCompletedFiles())
    }

    public func emptyRecycleBin() throws {
        guard !isRecovering else { throw RecordRecoveryError.busy }
        if FileManager.default.fileExists(atPath: recycleDirectory.path) {
            try FileManager.default.removeItem(at: recycleDirectory)
        }
        refreshStorageUsage()
    }

    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                       didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                       totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > 1_000_000_000 || totalBytesExpectedToWrite > 1_000_000_000 { downloadTask.cancel() }
        let identifier = downloadTask.taskIdentifier
        let name = downloadTask.taskDescription
        Task { @MainActor in
            guard let name, let id = UUID(uuidString: name), tasks[id]?.taskIdentifier == identifier,
                  let index = items.firstIndex(where: { $0.id == id }) else { return }
            let now = Date()
            if now.timeIntervalSince(capacityCheckDates[id] ?? .distantPast) >= 1 {
                capacityCheckDates[id] = now
                do { try checkCapacity(required: 0) }
                catch {
                    tasks.removeValue(forKey: id)?.cancel()
                    items[index].state = .failed; items[index].message = error.localizedDescription
                    saveOrReport(); scheduleQueuedDownloads(); return
                }
            }
            guard now.timeIntervalSince(progressDates[id] ?? .distantPast) >= 0.1 || totalBytesWritten == totalBytesExpectedToWrite else { return }
            progressDates[id] = now
            items[index].received = totalBytesWritten
            items[index].expected = totalBytesExpectedToWrite
        }
    }

    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                       didFinishDownloadingTo location: URL) {
        // 系统临时文件只在此回调有效，先转移，再交给主执行器更新可观察状态。
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = Result { try FileManager.default.moveItem(at: location, to: staged); return staged }
        let response = downloadTask.response as? HTTPURLResponse
        let identifier = downloadTask.taskIdentifier
        let name = downloadTask.taskDescription
        Task { @MainActor in
            finalizingCount += 1
            defer {
                try? FileManager.default.removeItem(at: staged)
                finalizingCount -= 1
                finishBackgroundEventsIfReady()
            }
            guard let name, let id = UUID(uuidString: name), tasks[id]?.taskIdentifier == identifier,
                  var index = items.firstIndex(where: { $0.id == id }), items[index].state == .running else { return }
            do {
                _ = try result.get()
                guard let response, (200..<300).contains(response.statusCode) else { throw DownloadError.http(response?.statusCode ?? 0) }
                guard let finalURL = response.url else { throw DownloadError.invalidURL }
                _ = try Self.validatedURL(finalURL.absoluteString)
                let length = try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard length <= 1_000_000_000 else { throw DownloadError.tooLarge }
                if let expected = items[index].expectedSize, expected != Int64(length) { throw DownloadPlanError.sizeMismatch }
                let digests = try await Task.detached(priority: .utility) { (try Self.hashFile(staged), try Self.hashFile(staged, sha512: true)) }.value
                let digest = digests.0
                guard let currentIndex = items.firstIndex(where: { $0.id == id }), tasks[id]?.taskIdentifier == identifier, items[currentIndex].state == .running else { return }
                index = currentIndex
                if let expected = items[index].expectedSHA256, expected != digest { throw DownloadError.hashMismatch }
                if let expected = items[index].expectedSHA512, expected != digests.1 { throw DownloadError.hashMismatch }
                items[index].sha512 = digests.1
                items[index].filename = Self.safeFilename(items[index].plannedFilename ?? response.suggestedFilename ?? items[index].filename)
                let target = fileURL(items[index])
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                var completed = items[index]
                completed.sha256 = digest; completed.received = Int64(length); completed.state = .completed; completed.message = nil
                // 单文件收据先落盘；清单失败后可按哈希重新识别已完成文件。
                try writeReceipt(completed)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: staged, to: target)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
                items[index].sha256 = digest
                items[index].received = Int64(length)
                items[index].state = .completed
                items[index].message = nil
                tasks[id] = nil
                try? FileManager.default.removeItem(at: resumeURL(id))
                saveOrReport()
                refreshStorageUsage()
                scheduleQueuedDownloads()
            } catch {
                guard let index = items.firstIndex(where: { $0.id == id }), tasks[id]?.taskIdentifier == identifier else { return }
                failOrAdvance(index: index, message: error.localizedDescription)
            }
        }
    }

    nonisolated public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            backgroundEventsFinished = true
            finishBackgroundEventsIfReady()
        }
    }

    private func finishBackgroundEventsIfReady() {
        guard backgroundEventsFinished, finalizingCount == 0 else { return }
        backgroundEventsFinished = false
        Self.backgroundCompletion?()
        Self.backgroundCompletion = nil
    }

    nonisolated public static func hashFile(_ url: URL, sha512: Bool = false) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var hash512 = SHA512()
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
            if sha512 { hash512.update(data: chunk) } else { hash.update(data: chunk) }
        }
        return (sha512 ? Array(hash512.finalize()) : Array(hash.finalize())).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask,
                                       didCompleteWithError error: (any Error)?) {
        guard let error else { return }
        let name = task.taskDescription
        let identifier = task.taskIdentifier
        let message = error.localizedDescription
        let code = (error as NSError).code
        let resumeData = (error as NSError).userInfo["NSURLSessionDownloadTaskResumeData"] as? Data
        Task { @MainActor in
            guard let name, let id = UUID(uuidString: name), tasks[id]?.taskIdentifier == identifier,
                  let index = items.firstIndex(where: { $0.id == id }) else { return }
            if (error as NSError).domain == NSURLErrorDomain,
               [NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut].contains(code) {
                tasks[id] = nil
                do {
                    if let resumeData { try resumeData.write(to: resumeURL(id), options: [.atomic, .completeFileProtectionUnlessOpen]) }
                    items[index].state = .paused
                    items[index].message = String(localized: "网络连接中断。连接恢复后可继续下载。")
                } catch { items[index].state = .failed; items[index].message = error.localizedDescription }
                saveOrReport(); scheduleQueuedDownloads(); return
            }
            failOrAdvance(index: index, message: message)
        }
    }

    private func failOrAdvance(index: Int, message: String) {
        let id = items[index].id
        tasks[id] = nil
        try? FileManager.default.removeItem(at: resumeURL(id))
        let next = (items[index].mirrorIndex ?? 0) + 1
        if let mirrors = items[index].mirrors, next < mirrors.count {
            items[index].mirrorIndex = next
            items[index].received = 0; items[index].expected = 0
            items[index].state = .queued
            items[index].message = String(localized: "上个镜像失败，正在尝试备用镜像。")
            do { try persist() }
            catch { items[index].state = .failed; storageError = error.localizedDescription }
        } else {
            items[index].state = .failed
            items[index].message = message
            saveOrReport()
        }
        scheduleQueuedDownloads()
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask,
                                       willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                                       completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // 后台传输由系统管理重定向；前台测试和普通会话仍在每跳检查。
        Task { @MainActor in
            guard let url = request.url, let cleaned = try? Self.validatedURL(url.absoluteString),
                  !(response.url?.scheme == "https" && cleaned.scheme != "https") else { completionHandler(nil); return }
            var next = request
            next.url = cleaned
            completionHandler(next)
        }
    }
}
