import Combine
import CryptoKit
import Foundation

public struct BrowserDownload: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case running, pausing, paused, completed, failed, cancelled }
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
    public var currentURL: URL {
        guard let mirrors, !mirrors.isEmpty else { return url }
        return mirrors[min(max(0, mirrorIndex ?? 0), mirrors.count - 1)]
    }
    public var progress: Double? { expected > 0 ? min(1, Double(received) / Double(expected)) : nil }
}

public enum DownloadError: LocalizedError {
    case invalidURL, invalidHash, http(Int), hashMismatch, tooLarge, missingFile
    public var errorDescription: String? {
        switch self {
        case .invalidURL: String(localized: "此下载地址无法安全使用，请输入普通 HTTP 或 HTTPS 文件链接。")
        case .invalidHash: String(localized: "SHA-256 应为 64 位十六进制字符。")
        case let .http(status): String(localized: "下载服务器返回错误（\(status)）。")
        case .hashMismatch: String(localized: "文件校验不一致，已丢弃本次文件。")
        case .tooLarge: String(localized: "文件超过当前 1 GB 下载限制，已停止下载。")
        case .missingFile: String(localized: "下载文件已不可用，请重新下载。")
        }
    }
}

/// 由系统执行传输；记录先落盘，完成文件核对后才显示完成。
@MainActor
public final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published public private(set) var items: [BrowserDownload] = []
    @Published public private(set) var storageError: String?
    public let directory: URL
    public static var backgroundCompletion: (() -> Void)?
    private var finalizingCount = 0
    private var backgroundEventsFinished = false
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
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
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    public init(directory: URL? = nil, background: Bool = true) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        self.useBackgroundSession = background
        super.init()
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: manifestURL), data.count < 2_000_000 {
                items = try JSONDecoder().decode([BrowserDownload].self, from: data)
            }
            Task { await reconnect() }
        } catch { storageError = error.localizedDescription }
    }

    private var manifestURL: URL { directory.appendingPathComponent("downloads.json") }
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
        return value.isEmpty || value == "." || value == ".." ? "download.bin" : String(value.prefix(100))
    }

    @discardableResult
    public func start(_ input: String, expectedSHA256: String = "") throws -> UUID {
        try start(DownloadPlan(urls: [try Self.validatedURL(input)], sha256: expectedSHA256))
    }

    @discardableResult
    public func start(_ plan: DownloadPlan) throws -> UUID {
        guard !plan.urls.isEmpty, plan.urls.count <= 16, Set(plan.urls).count == plan.urls.count else { throw DownloadPlanError.invalidMirrors }
        let urls = try plan.urls.map { try Self.validatedURL($0.absoluteString) }
        let hash = (plan.sha256 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hash512 = (plan.sha512 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hash.isEmpty || hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              hash512.isEmpty || hash512.range(of: "^[a-f0-9]{128}$", options: .regularExpression) != nil else { throw DownloadError.invalidHash }
        guard plan.size == nil || (0...1_000_000_000).contains(plan.size!) else { throw DownloadError.tooLarge }
        let item = BrowserDownload(id: UUID(), url: urls[0], filename: Self.safeFilename(plan.filename ?? urls[0].lastPathComponent), state: .running,
                                   expectedSHA256: hash.isEmpty ? nil : hash, mirrors: urls, mirrorIndex: 0,
                                   expectedSize: plan.size, expectedSHA512: hash512.isEmpty ? nil : hash512, plannedFilename: plan.filename)
        items.insert(item, at: 0)
        do { try persist() } catch { items.removeAll { $0.id == item.id }; throw error }
        begin(item)
        return item.id
    }

    private func begin(_ item: BrowserDownload) {
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
            }
        }
    }

    public func resume(_ id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }),
              [.paused, .failed, .cancelled].contains(items[index].state) else { return }
        _ = try Self.validatedURL(items[index].currentURL.absoluteString)
        if items[index].state != .paused {
            items[index].mirrorIndex = 0
            try? FileManager.default.removeItem(at: resumeURL(id))
        }
        items[index].state = .running
        items[index].message = nil
        try persist()
        begin(items[index])
    }

    public func cancel(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .cancelled
        try? FileManager.default.removeItem(at: resumeURL(id))
        saveOrReport()
    }

    private func reconnect() async {
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
        for index in items.indices where items[index].state == .completed {
            if !FileManager.default.fileExists(atPath: fileURL(items[index]).path) {
                items[index].state = .failed
                items[index].message = DownloadError.missingFile.localizedDescription
            }
        }
        saveOrReport()
    }

    private func persist() throws {
        try JSONEncoder().encode(items).write(to: manifestURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    private func saveOrReport() {
        do { try persist() } catch { storageError = String(localized: "下载记录保存失败：\(error.localizedDescription)") }
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
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: staged, to: target)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
                items[index].sha256 = digest
                items[index].received = Int64(length)
                items[index].state = .completed
                items[index].message = nil
                tasks[id] = nil
                try? FileManager.default.removeItem(at: resumeURL(id))
                try persist()
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
        Task { @MainActor in
            guard let name, let id = UUID(uuidString: name), tasks[id]?.taskIdentifier == identifier,
                  let index = items.firstIndex(where: { $0.id == id }) else { return }
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
            items[index].message = String(localized: "上个镜像失败，正在尝试备用镜像。")
            do { try persist(); begin(items[index]) }
            catch { items[index].state = .failed; storageError = error.localizedDescription }
        } else {
            items[index].state = .failed
            items[index].message = message
            saveOrReport()
        }
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
