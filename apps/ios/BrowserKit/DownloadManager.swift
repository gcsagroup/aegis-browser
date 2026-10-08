import Combine
import CryptoKit
import Foundation
import UIKit

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
    public var transferID: UUID?
    var inferredInterruption: Bool?
    var userStopState: State?
    var resumeDataUsable: Bool?
    public var currentURL: URL {
        guard let mirrors, !mirrors.isEmpty else { return url }
        return mirrors[min(max(0, mirrorIndex ?? 0), mirrors.count - 1)]
    }
    public var progress: Double? { expected > 0 ? min(1, Double(received) / Double(expected)) : nil }
}

public enum DownloadError: LocalizedError {
    case invalidURL, invalidHash, http(Int), hashMismatch, tooLarge, missingFile, storageNotReady, invalidManifest
    public var errorDescription: String? {
        switch self {
        case .storageNotReady: String(localized: "下载记录尚未恢复，请稍后重试。")
        case .invalidManifest: String(localized: "下载记录无法读取，原始记录已保留。")
        case .invalidURL: String(localized: "此下载地址无法安全使用，请输入普通 HTTP 或 HTTPS 文件链接。")
        case .invalidHash: String(localized: "SHA-256 应为 64 位十六进制字符。")
        case let .http(status): String(localized: "下载服务器返回错误（\(status)）。")
        case .hashMismatch: String(localized: "文件校验不一致，已丢弃本次文件。")
        case .tooLarge: String(localized: "文件超过当前 1 GB 下载限制，已停止下载。")
        case .missingFile: String(localized: "下载文件已不可用，请重新下载。")
        }
    }
}

// Narrow injectable manifest I/O seam. Pending files use the actual private filesystem.
struct DownloadManifestStorage {
    var read: (URL) throws -> Data = { try Data(contentsOf: $0) }
    var write: ([BrowserDownload], URL) throws -> Void = {
        try JSONEncoder().encode($0).write(to: $1, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

struct PendingDownloadReceipt: Codable {
    enum Kind: String, Codable { case stop, resume }
    var taskDescription: String
    var status: Int?
    var finalURL: URL?
    var suggestedFilename: String?
    var error: String?
    var completed: BrowserDownload?
    var payloadStaged: Bool?
    var userStopState: BrowserDownload.State?
    var kind: Kind?
    var resumeDataAvailable: Bool?
}

/// Manifest readiness is a barrier: unavailable storage cannot imply an empty task list.
@MainActor
public final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published public private(set) var items: [BrowserDownload] = []
    @Published public private(set) var storageError: String?
    @Published public private(set) var isReady = false
    public nonisolated let directory: URL
    static weak var backgroundManager: DownloadManager?
    public static var backgroundCompletion: (() -> Void)? {
        didSet { backgroundManager?.finishBackgroundEventsIfReady() }
    }
    private var backgroundEventsFinished = false
    private var manifestLoaded = false
    private var recovering = false
    private var recoveryRequested = false
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var pausingTransfers: Set<String> = []
    private struct NativePause {
        enum Phase: Equatable { case registered, returned, disposed }
        let taskIdentifier: Int
        let taskIdentity: ObjectIdentifier
        var phase: Phase
    }
    private var nativePauses: [String: NativePause] = [:]
    private struct NativeStop {
        let task: URLSessionTask
        let name: String?
        let pause: Bool
    }
    private var userStoppedTransfers: [String: BrowserDownload.State] = [:]
    private var pendingReceiptWrites: [URL: PendingDownloadReceipt] = [:]
    private var pendingResumeWrites: [URL: Data] = [:]
    private var pendingPauseCallbacks: Set<String> = []
    private var persistedStates: [String: BrowserDownload.State] = [:]
    private var ingressRevision = 0
    private var recoveryScheduled = false
    typealias RecoveryWork = @MainActor @Sendable () async -> Void
    typealias PauseCompletion = @Sendable (Data?) -> Void
    private let recoveryScheduler: (@escaping RecoveryWork) -> Void
    private let cancelForResume: (URLSessionDownloadTask, @escaping PauseCompletion) -> Void
    private let payloadHashes: (URL) async throws -> (String, String)
    private let finalHash: (URL) async throws -> String
    private let downloadResponse: (URLSessionDownloadTask) -> HTTPURLResponse?
    private let startTransfer: (URLSessionDownloadTask) -> Void
    private let removeReceiptMetadata: (URL) throws -> Void
    private let useBackgroundSession: Bool
    private let storage: DownloadManifestStorage
    private let enumerateTasks: ((URLSession) async -> [URLSessionTask])?
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
        // Delegate ingress is serial on MainActor; event-end cannot overtake a
        // completion that has not yet staged its bytes or counted its work.
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    public convenience init(directory: URL? = nil, background: Bool = true) {
        self.init(directory: directory, background: background, storage: DownloadManifestStorage())
    }

    init(directory: URL?, background: Bool, storage: DownloadManifestStorage,
         enumerateTasks: ((URLSession) async -> [URLSessionTask])? = nil,
         automaticallyRecover: Bool = true,
         registersBackgroundEvents: Bool? = nil,
         recoveryScheduler: @escaping (@escaping RecoveryWork) -> Void = { work in Task { await work() } },
         cancelForResume: @escaping (URLSessionDownloadTask, @escaping PauseCompletion) -> Void = { task, callback in task.cancel(byProducingResumeData: callback) },
         payloadHashes: @escaping (URL) async throws -> (String, String) = { url in
             try await Task.detached(priority: .utility) { (try DownloadManager.hashFile(url), try DownloadManager.hashFile(url, sha512: true)) }.value
         },
         finalHash: @escaping (URL) async throws -> String = { url in
             try await Task.detached(priority: .utility) { try DownloadManager.hashFile(url) }.value
         },
         downloadResponse: @escaping (URLSessionDownloadTask) -> HTTPURLResponse? = { $0.response as? HTTPURLResponse },
         startTransfer: @escaping (URLSessionDownloadTask) -> Void = { $0.resume() },
         removeReceiptMetadata: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        self.useBackgroundSession = background
        self.storage = storage
        self.enumerateTasks = enumerateTasks
        self.recoveryScheduler = recoveryScheduler
        self.cancelForResume = cancelForResume
        self.payloadHashes = payloadHashes
        self.finalHash = finalHash
        self.downloadResponse = downloadResponse
        self.startTransfer = startTransfer
        self.removeReceiptMetadata = removeReceiptMetadata
        super.init()
        if registersBackgroundEvents ?? background { Self.backgroundManager = self }
        // Attach even while the protected manifest is inaccessible.
        _ = session
        NotificationCenter.default.addObserver(self, selector: #selector(storageMayBeAvailable),
                                               name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(storageMayBeAvailable),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        if automaticallyRecover { requestRecovery() }
    }

    @objc private func storageMayBeAvailable() { requestRecovery() }

    private func requestRecovery() {
        if recovering { recoveryRequested = true; return }
        guard !recoveryScheduled else { return }
        recoveryScheduled = true
        recoveryScheduler { [self] in
            recoveryScheduled = false
            await retryStorage()
        }
    }

    private func flushPendingEvents() throws {
        for (url, bytes) in pendingResumeWrites {
            try bytes.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            pendingResumeWrites[url] = nil
        }
        for (url, receipt) in pendingReceiptWrites {
            try writeReceipt(receipt, to: url)
            pendingReceiptWrites[url] = nil
        }
    }
    private var manifestURL: URL { directory.appendingPathComponent("downloads.json") }
    private var pendingDirectory: URL { directory.appendingPathComponent("Pending", isDirectory: true) }
    private func resumeURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id).resume") }
    private func description(_ item: BrowserDownload) -> String {
        item.id.uuidString + (item.transferID.map { "|" + $0.uuidString } ?? "")
    }
    private func itemIndex(_ taskDescription: String) -> Int? {
        items.firstIndex { description($0) == taskDescription }
    }
    public func fileURL(_ item: BrowserDownload) -> URL {
        let legacy = directory.appendingPathComponent("\(item.id)-\(item.filename)")
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return directory.appendingPathComponent(item.id.uuidString, isDirectory: true).appendingPathComponent(item.filename)
    }

    public func retryStorage() async {
        if recovering { recoveryRequested = true; return }
        recovering = true
        isReady = false
        defer {
            recovering = false
            finishBackgroundEventsIfReady()
            if recoveryRequested {
                recoveryRequested = false
                requestRecovery()
            }
        }
        do {
            var storageFailure: (any Error)?
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
            } catch { storageFailure = error }
            do { try flushPendingEvents() } catch { storageFailure = storageFailure ?? error }
            if !manifestLoaded {
                do {
                    let data = try storage.read(manifestURL)
                    guard data.count < 2_000_000 else { throw DownloadError.invalidManifest }
                    let loaded = try JSONDecoder().decode([BrowserDownload].self, from: data)
                    guard Set(loaded.map(\.id)).count == loaded.count else { throw DownloadError.invalidManifest }
                    items = loaded
                    persistedStates = Dictionary(uniqueKeysWithValues: loaded.map { (description($0), $0.state) })
                } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                    items = [] // Only a definite missing-file error means a new manifest.
                }
                manifestLoaded = true
            }
            // Obtain authoritative controls before native discovery, then reread
            // after the await to include stops accepted while discovery was pending.
            let beforeDiscovery = pendingReceipts()
            storageFailure = storageFailure ?? beforeDiscovery.error
            let existing: [URLSessionTask]
            if let enumerateTasks { existing = await enumerateTasks(session) }
            else { existing = await session.allTasks }
            do { try flushPendingEvents() } catch { storageFailure = storageFailure ?? error }
            let afterDiscovery = pendingReceipts()
            storageFailure = storageFailure ?? afterDiscovery.error
            let decoded = afterDiscovery.receipts
            let controlsReadable = storageFailure == nil
            // Known accepted stops still reach native tasks when a write/read fails.
            // Unreadable controls never authorize orphan cleanup or result decisions.
            let stable: Bool
            do {
                stable = try mergeStopIntents(beforeDiscovery.receipts.map { $0.1 } + decoded.map { $0.1 },
                                              discoveredTasks: existing, disposeUnknown: controlsReadable)
            } catch { throw storageFailure ?? error }
            if let storageFailure { throw storageFailure }
            guard stable else { recoveryRequested = true; return }
            func priority(_ receipt: PendingDownloadReceipt) -> Int {
                if receipt.kind == .resume { return 1 }
                if receipt.kind == .stop { return 3 }
                return receipt.error == nil ? 0 : 2
            }
            let ordered = decoded.sorted { priority($0.1) < priority($1.1) }
            let revision = ingressRevision
            for (receipt, _) in ordered {
                try await finishPending(receipt, revision: revision)
                if ingressRevision != revision { recoveryRequested = true; return }
            }
            // Delegate callbacks can arrive while enumeration or hashing awaits.
            // Drain their receipts in another pass before publishing readiness.
            if recoveryRequested || !pendingReceiptWrites.isEmpty {
                recoveryRequested = true
                return
            }
            for index in items.indices where [.running, .pausing].contains(items[index].state) && tasks[items[index].id] == nil && !pausingTransfers.contains(description(items[index])) {
                items[index].inferredInterruption = items[index].state == .running ? true : nil
                items[index].state = .paused
                items[index].message = String(localized: "上次下载已中断，可继续或重新下载。")
            }
            for index in items.indices where items[index].state == .completed {
                if !FileManager.default.fileExists(atPath: fileURL(items[index]).path) {
                    items[index].state = .failed
                    items[index].message = DownloadError.missingFile.localizedDescription
                }
            }
            var preservedUnresolvedFile = false
            let pending = try FileManager.default.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil)
            for payload in pending where payload.pathExtension == "bin" && !FileManager.default.fileExists(atPath: payload.deletingPathExtension().appendingPathExtension("json").path) {
                // New payload names retain their exact transfer identity even if
                // metadata could not be written. Preserve older anonymous bytes too.
                let name = payload.deletingPathExtension().lastPathComponent.components(separatedBy: "--").first ?? ""
                if let index = itemIndex(name), [.running, .pausing].contains(items[index].state) {
                    items[index].state = .paused
                    items[index].inferredInterruption = true
                    items[index].message = String(localized: "完成回执未保存，文件已保留，请重试下载。")
                }
                let unresolved = directory.appendingPathComponent("Unresolved", isDirectory: true)
                try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: payload, to: unresolved.appendingPathComponent(payload.lastPathComponent))
                preservedUnresolvedFile = true
            }
            try persist(items)
            storageError = preservedUnresolvedFile ? String(localized: "有下载文件缺少完成回执，原始文件已保留。") : nil
            isReady = true
        } catch { reportStorage(error) }
    }

    private func persist(_ candidate: [BrowserDownload]) throws {
        guard manifestLoaded else { throw DownloadError.storageNotReady }
        try storage.write(candidate, manifestURL)
        persistedStates = Dictionary(uniqueKeysWithValues: candidate.map { (description($0), $0.state) })
        // A committed record also durably disposes its pure stop event; do not
        // make background ACK depend on writing redundant control metadata.
        for (url, receipt) in pendingReceiptWrites where receipt.kind == .stop {
            if candidate.contains(where: { description($0) == receipt.taskDescription && $0.userStopState == receipt.userStopState }) {
                pendingReceiptWrites[url] = nil
            }
        }
    }

    private func pendingReceipts() -> (receipts: [(URL, PendingDownloadReceipt)], error: (any Error)?) {
        var receipts: [(URL, PendingDownloadReceipt)] = []
        var firstFailure: (any Error)?
        do {
            let files = try FileManager.default.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil)
            for url in files where url.pathExtension == "json" {
                do {
                    receipts.append((url, try JSONDecoder().decode(PendingDownloadReceipt.self, from: Data(contentsOf: url))))
                } catch { firstFailure = firstFailure ?? error }
            }
        } catch { firstFailure = error }
        // Readable controls retain their authority independently of a bad sibling.
        // The error keeps the receipt set incomplete, forbidding result/orphan work.
        return (receipts, firstFailure)
    }

    private func mergeStopIntents(_ receipts: [PendingDownloadReceipt],
                                 discoveredTasks: [URLSessionTask]? = nil,
                                 disposeUnknown: Bool = true) throws -> Bool {
        let revision = ingressRevision
        var stops = userStoppedTransfers
        func merge(_ name: String, _ stop: BrowserDownload.State?) {
            guard let stop, [.paused, .cancelled].contains(stop) else { return }
            if stops[name] != .cancelled { stops[name] = stop }
        }
        for item in items { merge(description(item), item.userStopState) }
        for receipt in receipts { merge(receipt.taskDescription, receipt.userStopState) }
        for receipt in pendingReceiptWrites.values { merge(receipt.taskDescription, receipt.userStopState) }
        var candidate = items
        var needsCommit = false
        for index in candidate.indices {
            let name = description(candidate[index])
            guard let stop = stops[name],
                  !(candidate[index].state == .completed && persistedStates[name] == .completed) else { continue }
            needsCommit = true
            userStoppedTransfers[name] = stop
            if candidate[index].userStopState == nil { candidate[index].resumeDataUsable = false }
            candidate[index].userStopState = stop
            candidate[index].inferredInterruption = nil
            if stop == .cancelled {
                candidate[index].state = .cancelled
                candidate[index].resumeDataUsable = false
            } else if [.running, .pausing, .paused, .completed].contains(candidate[index].state) {
                candidate[index].state = pausingTransfers.contains(name) ? .pausing : .paused
            }
        }
        let native = discoveredTasks ?? Array(tasks.values)
        if discoveredTasks != nil { tasks.removeAll() }
        var actions: [NativeStop] = []
        // Prepare ALL owners and candidate states before persistence or any API.
        for task in native {
            guard let name = task.taskDescription,
                  let index = candidate.firstIndex(where: { description($0) == name }),
                  let download = task as? URLSessionDownloadTask else {
                if disposeUnknown { actions.append(NativeStop(task: task, name: nil, pause: false)) }
                continue
            }
            let terminal = [.completed, .cancelled, .failed].contains(candidate[index].state) &&
                persistedStates[name] == candidate[index].state
            if stops[name] == .paused && !terminal {
                tasks[candidate[index].id] = nil
                if let owner = nativePauses[name] {
                    // A stopped generation does not gain another callback when
                    // a stale snapshot returns the same task after disposition.
                    if owner.taskIdentifier != task.taskIdentifier {
                        actions.append(NativeStop(task: task, name: name, pause: false))
                    }
                } else if [.running, .suspended].contains(task.state) {
                    nativePauses[name] = NativePause(taskIdentifier: task.taskIdentifier,
                                                    taskIdentity: ObjectIdentifier(task), phase: .registered)
                    pausingTransfers.insert(name)
                    pendingPauseCallbacks.insert(name)
                    candidate[index].state = .pausing
                    candidate[index].resumeDataUsable = false
                    needsCommit = true
                    actions.append(NativeStop(task: download, name: name, pause: true))
                }
            } else if stops[name] == .cancelled {
                // A known accepted cancellation is independent of orphan disposal.
                tasks[candidate[index].id] = nil
                actions.append(NativeStop(task: task, name: name, pause: false))
            } else if candidate[index].state == .running && stops[name] == nil {
                if [.running, .suspended].contains(task.state) { tasks[candidate[index].id] = download }
            } else if disposeUnknown {
                tasks[candidate[index].id] = nil
                actions.append(NativeStop(task: task, name: name, pause: false))
            }
        }
        var storageFailure: (any Error)?
        if needsCommit {
            do { try flushPendingEvents() } catch { storageFailure = error }
            do { try persist(candidate) } catch { storageFailure = storageFailure ?? error }
            // Stops may be visible before their manifest can be saved, but only
            // persist() updates durable evidence. Synchronous reentry wins.
            if ingressRevision == revision { items = candidate }
            else { recoveryRequested = true }
        }
        executeNativeStops(actions)
        if let storageFailure { throw storageFailure }
        return ingressRevision == revision
    }

    private func executeNativeStops(_ actions: [NativeStop]) {
        for action in actions {
            let task = action.task
            guard task.state != .canceling && task.state != .completed else {
                if action.pause, let name = action.name, nativePauses[name]?.phase == .registered {
                    // The real task finished before its prepared API could run.
                    releasePause(name)
                    if let index = itemIndex(name), items[index].state == .pausing { items[index].state = .paused }
                }
                continue
            }
            guard action.pause, let name = action.name, let download = task as? URLSessionDownloadTask else {
                // Reentry can accept a pause after this plain-stop action was
                // prepared. Preserve its real callback authority unless cancel won.
                if let name = action.name, stopState(name) == .paused,
                   !durablyTerminal(name), nativePauses[name]?.taskIdentifier == task.taskIdentifier { continue }
                task.cancel()
                continue
            }
            guard itemIndex(name) != nil else { task.cancel(); releasePause(name); continue }
            if stopState(name) == .cancelled || durablyTerminal(name) {
                task.cancel()
                releasePause(name)
                continue
            }
            guard let owner = nativePauses[name], owner.phase == .registered,
                  owner.taskIdentifier == task.taskIdentifier, owner.taskIdentity == ObjectIdentifier(task) else { continue }
            guard stopState(name) == .paused else { releasePause(name); continue }
            let taskIdentifier = owner.taskIdentifier
            let taskIdentity = owner.taskIdentity
            cancelForResume(download) { data in
                Task { @MainActor in
                    self.stagePauseData(name, taskIdentifier: taskIdentifier, taskIdentity: taskIdentity, data: data)
                }
            }
        }
    }

    private func recordStop(_ name: String, state: BrowserDownload.State) {
        ingressRevision += 1
        if userStoppedTransfers[name] != .cancelled { userStoppedTransfers[name] = state }
        let url = pendingDirectory.appendingPathComponent(name + "--stop.json")
        pendingReceiptWrites[url] = PendingDownloadReceipt(taskDescription: name, userStopState: state, kind: .stop)
        do {
            try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
            try flushPendingEvents()
        } catch { reportStorage(error) }
        if recovering { recoveryRequested = true }
    }

    private func stopState(_ name: String) -> BrowserDownload.State? {
        userStoppedTransfers[name] ?? itemIndex(name).flatMap { items[$0].userStopState }
    }

    private func releasePause(_ name: String) {
        pausingTransfers.remove(name)
        pendingPauseCallbacks.remove(name)
        nativePauses[name]?.phase = .disposed
        finishBackgroundEventsIfReady()
    }

    private func durablyTerminal(_ name: String) -> Bool {
        guard let index = itemIndex(name), persistedStates[name] == items[index].state else { return false }
        return [.completed, .cancelled, .failed].contains(items[index].state)
    }
    private func reportStorage(_ error: any Error) {
        isReady = false
        storageError = String(localized: "下载记录保存或恢复失败：\(error.localizedDescription)")
    }
    private func saveOrReport() {
        do { try persist(items) } catch { reportStorage(error) }
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
        guard isReady else { throw DownloadError.storageNotReady }
        guard !plan.urls.isEmpty, plan.urls.count <= 16, Set(plan.urls).count == plan.urls.count else { throw DownloadPlanError.invalidMirrors }
        let urls = try plan.urls.map { try Self.validatedURL($0.absoluteString) }
        let hash = (plan.sha256 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hash512 = (plan.sha512 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hash.isEmpty || hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              hash512.isEmpty || hash512.range(of: "^[a-f0-9]{128}$", options: .regularExpression) != nil else { throw DownloadError.invalidHash }
        guard plan.size == nil || (0...1_000_000_000).contains(plan.size!) else { throw DownloadError.tooLarge }
        let item = BrowserDownload(id: UUID(), url: urls[0], filename: Self.safeFilename(plan.filename ?? urls[0].lastPathComponent), state: .running,
                                   expectedSHA256: hash.isEmpty ? nil : hash, mirrors: urls, mirrorIndex: 0,
                                   expectedSize: plan.size, expectedSHA512: hash512.isEmpty ? nil : hash512,
                                   plannedFilename: plan.filename, transferID: UUID(), resumeDataUsable: false)
        var candidate = items
        candidate.insert(item, at: 0)
        do { try persist(candidate) } catch { reportStorage(error); throw error }
        items = candidate
        begin(item, useResumeData: false)
        return item.id
    }

    private func begin(_ item: BrowserDownload, useResumeData: Bool) {
        let task: URLSessionDownloadTask
        if useResumeData, let data = try? Data(contentsOf: resumeURL(item.id)) {
            task = session.downloadTask(withResumeData: data)
            try? FileManager.default.removeItem(at: resumeURL(item.id))
        } else {
            task = session.downloadTask(with: item.currentURL)
        }
        task.taskDescription = description(item)
        tasks[item.id] = task
        startTransfer(task)
    }

    public func pause(_ id: UUID) {
        guard manifestLoaded, let index = items.firstIndex(where: { $0.id == id }), items[index].state == .running,
              persistedStates[description(items[index])] != .completed else { return }
        let name = description(items[index])
        items[index].inferredInterruption = nil
        items[index].userStopState = .paused
        items[index].resumeDataUsable = false
        items[index].state = .paused
        recordStop(name, state: .paused)
        do { _ = try mergeStopIntents([]) } catch { reportStorage(error) }
        if !pausingTransfers.contains(name) { requestRecovery() }
    }

    private func stagePauseData(_ name: String, taskIdentifier: Int, taskIdentity: ObjectIdentifier, data: Data?) {
        guard let owner = nativePauses[name], owner.phase == .registered,
              owner.taskIdentifier == taskIdentifier, owner.taskIdentity == taskIdentity,
              pausingTransfers.contains(name), pendingPauseCallbacks.contains(name) else { return }
        nativePauses[name]?.phase = .returned
        ingressRevision += 1
        pendingPauseCallbacks.remove(name)
        guard let index = itemIndex(name), stopState(name) == .paused,
              !durablyTerminal(name), items[index].state != .cancelled else {
            releasePause(name)
            return
        }
        let url = pendingDirectory.appendingPathComponent(name + "--resume-" + UUID().uuidString + ".json")
        let payload = url.deletingPathExtension().appendingPathExtension("resume")
        pendingReceiptWrites[url] = PendingDownloadReceipt(taskDescription: name, userStopState: .paused,
                                                          kind: .resume, resumeDataAvailable: data != nil)
        if let data { pendingResumeWrites[payload] = data }
        do {
            try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
            try flushPendingEvents()
            requestRecovery()
        } catch {
            reportStorage(error)
            if recovering { recoveryRequested = true }
        }
        finishBackgroundEventsIfReady()
    }

    public func resume(_ id: UUID) throws {
        guard isReady else { throw DownloadError.storageNotReady }
        guard let index = items.firstIndex(where: { $0.id == id }),
              [.paused, .failed, .cancelled].contains(items[index].state),
              !pausingTransfers.contains(description(items[index])) else { return }
        _ = try Self.validatedURL(items[index].currentURL.absoluteString)
        let useResumeData = items[index].state == .paused && items[index].resumeDataUsable != false
        var candidate = items
        if !useResumeData { candidate[index].mirrorIndex = 0 }
        candidate[index].state = .running
        candidate[index].inferredInterruption = nil
        candidate[index].userStopState = nil
        candidate[index].resumeDataUsable = false
        candidate[index].message = nil
        candidate[index].transferID = UUID()
        do { try persist(candidate) } catch { reportStorage(error); throw error }
        userStoppedTransfers[description(items[index])] = nil
        releasePause(description(items[index]))
        nativePauses[description(items[index])] = nil // The committed new generation retires this tombstone.
        items = candidate
        if !useResumeData { try? FileManager.default.removeItem(at: resumeURL(id)) }
        begin(items[index], useResumeData: useResumeData)
    }

    public func cancel(_ id: UUID) {
        guard manifestLoaded, let index = items.firstIndex(where: { $0.id == id }), items[index].state != .cancelled,
              persistedStates[description(items[index])] != .completed else { return }
        let name = description(items[index])
        items[index].inferredInterruption = nil
        items[index].userStopState = .cancelled
        items[index].resumeDataUsable = false
        items[index].state = .cancelled
        recordStop(name, state: .cancelled)
        saveOrReport()
        tasks.removeValue(forKey: id)?.cancel()
        try? FileManager.default.removeItem(at: resumeURL(id))
        releasePause(name)
        requestRecovery()
    }

    private func writeReceipt(_ receipt: PendingDownloadReceipt, to url: URL) throws {
        // Metadata retains the manifest's protection policy. Verified payloads
        // use the same first-unlock policy as existing completed downloads.
        try JSONEncoder().encode(receipt).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func stageCompletion(_ task: URLSessionDownloadTask, location: URL) {
        guard let name = task.taskDescription,
              (1...2).contains(name.split(separator: "|").count),
              name.split(separator: "|").allSatisfy({ UUID(uuidString: String($0)) != nil }) else { return }
        if manifestLoaded && itemIndex(name) == nil { return }
        if durablyTerminal(name) { return }
        ingressRevision += 1
        let receiptURL = pendingDirectory.appendingPathComponent(name + "--" + UUID().uuidString + ".json")
        let staged = receiptURL.deletingPathExtension().appendingPathExtension("bin")
        let response = downloadResponse(task)
        var receipt = PendingDownloadReceipt(taskDescription: name, status: response?.statusCode,
                                             finalURL: response?.url, suggestedFilename: response?.suggestedFilename,
                                             payloadStaged: false, userStopState: stopState(name))
        pendingReceiptWrites[receiptURL] = receipt
        do {
            try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
            // Persist identity and response before moving. A crash at either side
            // of the move can be replayed without anonymous-file ambiguity.
            try writeReceipt(receipt, to: receiptURL)
            try FileManager.default.moveItem(at: location, to: staged)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staged.path)
            receipt.payloadStaged = true
            pendingReceiptWrites[receiptURL] = receipt
            try writeReceipt(receipt, to: receiptURL)
            pendingReceiptWrites[receiptURL] = nil
            requestRecovery()
        } catch {
            // If metadata was unavailable but bytes can be moved, their filename
            // still identifies the transfer. Recovery preserves, never trusts,
            // a payload whose response metadata is missing.
            if FileManager.default.fileExists(atPath: location.path) && !FileManager.default.fileExists(atPath: staged.path) {
                try? FileManager.default.moveItem(at: location, to: staged)
            }
            reportStorage(error)
            if recovering { recoveryRequested = true }
        }
        finishBackgroundEventsIfReady()
    }

    private func discardReceipt(_ url: URL, receipt: PendingDownloadReceipt, removeFinal: Bool = false) throws {
        if receipt.kind == .resume {
            // Keep replay dependencies until the control record is safely gone.
            try removeReceiptMetadata(url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("resume"))
            return
        }
        if removeFinal, let completed = receipt.completed, description(completed) == receipt.taskDescription,
           completed.filename == Self.safeFilename(completed.filename) {
            try? FileManager.default.removeItem(at: fileURL(completed))
        }
        try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("bin"))
        try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("resume"))
        try removeReceiptMetadata(url)
    }

    private func finishPending(_ url: URL, revision: Int) async throws {
        var receipt = try JSONDecoder().decode(PendingDownloadReceipt.self, from: Data(contentsOf: url))
        let staged = url.deletingPathExtension().appendingPathExtension("bin")
        guard let index = itemIndex(receipt.taskDescription) else {
            try discardReceipt(url, receipt: receipt)
            return
        }
        if items[index].state == .cancelled {
            // A volatile cancellation alone never licenses receipt deletion.
            try persist(items)
            releasePause(receipt.taskDescription)
            try discardReceipt(url, receipt: receipt, removeFinal: true)
            return
        }
        if receipt.kind == .stop {
            // mergeStopIntents committed this exact-generation intent first.
            try discardReceipt(url, receipt: receipt)
            return
        }
        if receipt.kind == .resume {
            if durablyTerminal(receipt.taskDescription) {
                releasePause(receipt.taskDescription)
                try discardReceipt(url, receipt: receipt)
                return
            }
            guard stopState(receipt.taskDescription) == .paused,
                  let available = receipt.resumeDataAvailable else { throw DownloadError.invalidManifest }
            var candidate = items
            let alreadyCommitted = persistedStates[receipt.taskDescription] == .paused &&
                candidate[index].state == .paused && candidate[index].userStopState == .paused &&
                candidate[index].resumeDataUsable == available &&
                (!available || FileManager.default.fileExists(atPath: resumeURL(candidate[index].id).path))
            if available && !alreadyCommitted {
                let bytes = try Data(contentsOf: url.deletingPathExtension().appendingPathExtension("resume"))
                try bytes.write(to: resumeURL(candidate[index].id), options: [.atomic, .completeFileProtectionUnlessOpen])
            }
            candidate[index].state = .paused
            candidate[index].userStopState = .paused
            candidate[index].resumeDataUsable = available
            candidate[index].inferredInterruption = nil
            if !alreadyCommitted {
                try persist(candidate)
                items = candidate
            }
            if !available { try? FileManager.default.removeItem(at: resumeURL(candidate[index].id)) }
            releasePause(receipt.taskDescription)
            try discardReceipt(url, receipt: receipt)
            return
        }
        if items[index].state == .failed && persistedStates[receipt.taskDescription] == .failed {
            releasePause(receipt.taskDescription)
            try discardReceipt(url, receipt: receipt)
            return
        }
        if let error = receipt.error {
            if stopState(receipt.taskDescription) == nil &&
                (items[index].state == .running || (items[index].state == .paused && items[index].inferredInterruption == true)) {
                try failOrAdvance(index: index, message: error)
            }
            try FileManager.default.removeItem(at: url)
            return
        }
        if receipt.completed == nil && items[index].state == .completed {
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.removeItem(at: url)
            return
        }
        if receipt.completed == nil && receipt.payloadStaged != true && !FileManager.default.fileExists(atPath: staged.path) {
            // Identity was committed, but the callback payload did not survive.
            // Preserve a retryable record rather than permanently blocking storage.
            if [.running, .pausing].contains(items[index].state) && !pausingTransfers.contains(receipt.taskDescription) {
                items[index].inferredInterruption = items[index].state == .running ? true : nil
                items[index].state = .paused
                items[index].message = String(localized: "下载文件保存被中断，可重试下载。")
            }
            try persist(items)
            try FileManager.default.removeItem(at: url)
            return
        }
        if receipt.completed == nil {
            do {
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staged.path)
                guard let status = receipt.status, (200..<300).contains(status) else { throw DownloadError.http(receipt.status ?? 0) }
                guard let finalURL = receipt.finalURL else { throw DownloadError.invalidURL }
                _ = try Self.validatedURL(finalURL.absoluteString)
                let length = try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard length <= 1_000_000_000 else { throw DownloadError.tooLarge }
                if let expected = items[index].expectedSize, expected != Int64(length) { throw DownloadPlanError.sizeMismatch }
                let hashes = try await payloadHashes(staged)
                guard ingressRevision == revision else { recoveryRequested = true; return }
                guard let current = itemIndex(receipt.taskDescription), [.running, .pausing, .paused].contains(items[current].state) else { return }
                var completed = items[current]
                if let expected = completed.expectedSHA256, expected != hashes.0 { throw DownloadError.hashMismatch }
                if let expected = completed.expectedSHA512, expected != hashes.1 { throw DownloadError.hashMismatch }
                completed.sha256 = hashes.0; completed.sha512 = hashes.1
                completed.received = Int64(length)
                completed.filename = Self.safeFilename(completed.plannedFilename ?? receipt.suggestedFilename ?? completed.filename)
                completed.state = .completed; completed.message = nil
                completed.inferredInterruption = nil
                completed.userStopState = nil
                completed.resumeDataUsable = false
                receipt.completed = completed
                try writeReceipt(receipt, to: url)
                // Full verified bytes and their receipt durably dispose a
                // pending pause even if the final manifest must await unlock.
                pendingPauseCallbacks.remove(receipt.taskDescription)
                nativePauses[receipt.taskDescription]?.phase = .disposed
                finishBackgroundEventsIfReady()
            } catch let error as DownloadError {
                guard ingressRevision == revision else { recoveryRequested = true; return }
                try failOrAdvance(index: index, message: error.localizedDescription)
                try? FileManager.default.removeItem(at: staged)
                try FileManager.default.removeItem(at: url)
                return
            } catch let error as DownloadPlanError {
                guard ingressRevision == revision else { recoveryRequested = true; return }
                try failOrAdvance(index: index, message: error.localizedDescription)
                try? FileManager.default.removeItem(at: staged)
                try FileManager.default.removeItem(at: url)
                return
            }
        }
        guard ingressRevision == revision else { recoveryRequested = true; return }
        guard let completed = receipt.completed, completed.id == items[index].id,
              description(completed) == receipt.taskDescription,
              completed.filename == Self.safeFilename(completed.filename),
              completed.state == .completed else { throw DownloadError.invalidManifest }
        let target = fileURL(completed)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: staged.path) {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: staged, to: target)
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
        let digest = try await finalHash(target)
        guard ingressRevision == revision else { recoveryRequested = true; return }
        guard digest == completed.sha256 else { throw DownloadError.invalidManifest }
        guard itemIndex(receipt.taskDescription) == index else { throw DownloadError.invalidManifest }
        var candidate = items
        candidate[index] = completed
        // Storage commit is outside transport-validation catches. Its failure
        // keeps both the final file and this replayable receipt, never a mirror retry.
        try persist(candidate)
        items = candidate
        tasks[completed.id] = nil
        releasePause(receipt.taskDescription)
        try? FileManager.default.removeItem(at: resumeURL(completed.id))
        try FileManager.default.removeItem(at: url)
    }

    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                       didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                       totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            if totalBytesWritten > 1_000_000_000 || totalBytesExpectedToWrite > 1_000_000_000 { downloadTask.cancel() }
            guard let name = downloadTask.taskDescription, let index = itemIndex(name),
                  tasks[items[index].id]?.taskIdentifier == downloadTask.taskIdentifier else { return }
            items[index].received = totalBytesWritten
            items[index].expected = totalBytesExpectedToWrite
        }
    }

    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                       didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated { stageCompletion(downloadTask, location: location) }
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask,
                                       didCompleteWithError error: (any Error)?) {
        guard let error else { return }
        MainActor.assumeIsolated {
            guard let name = task.taskDescription else { return }
            if manifestLoaded && itemIndex(name) == nil { return }
            if durablyTerminal(name) { return }
            ingressRevision += 1
            let receiptURL = pendingDirectory.appendingPathComponent(UUID().uuidString + ".json")
            let receipt = PendingDownloadReceipt(taskDescription: name, error: error.localizedDescription, userStopState: stopState(name))
            pendingReceiptWrites[receiptURL] = receipt
            do {
                try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
                try writeReceipt(receipt, to: receiptURL)
                pendingReceiptWrites[receiptURL] = nil
                requestRecovery()
            } catch {
                reportStorage(error)
                if recovering { recoveryRequested = true }
            }
            finishBackgroundEventsIfReady()
        }
    }

    nonisolated public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            backgroundEventsFinished = true
            finishBackgroundEventsIfReady()
        }
    }

    private func finishBackgroundEventsIfReady() {
        guard backgroundEventsFinished, pendingPauseCallbacks.isEmpty,
              pendingReceiptWrites.isEmpty, pendingResumeWrites.isEmpty,
              let completion = Self.backgroundCompletion else { return }
        backgroundEventsFinished = false
        Self.backgroundCompletion = nil
        completion()
    }

    private func failOrAdvance(index: Int, message: String) throws {
        let id = items[index].id
        let name = description(items[index])
        let next = (items[index].mirrorIndex ?? 0) + 1
        var candidate = items
        candidate[index].inferredInterruption = nil
        candidate[index].resumeDataUsable = false
        let mayRetryMirror = stopState(description(items[index])) == nil &&
            (items[index].state == .running || (items[index].state == .paused && items[index].inferredInterruption == true))
        if mayRetryMirror, let mirrors = items[index].mirrors, next < mirrors.count {
            candidate[index].mirrorIndex = next
            candidate[index].received = 0; candidate[index].expected = 0
            candidate[index].transferID = UUID()
            candidate[index].state = .running
            candidate[index].message = String(localized: "上个镜像失败，正在尝试备用镜像。")
            try persist(candidate)
            items = candidate
            releasePause(name)
            nativePauses[name] = nil
            tasks[id] = nil
            try? FileManager.default.removeItem(at: resumeURL(id))
            begin(items[index], useResumeData: false)
        } else {
            candidate[index].state = .failed
            candidate[index].message = message
            try persist(candidate)
            items = candidate
            releasePause(name)
            tasks[id] = nil
        }
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
