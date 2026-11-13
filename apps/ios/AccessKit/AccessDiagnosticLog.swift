import Darwin
import Foundation

/// Bounded diagnostics. Xray writes into a private FIFO; only filtered records
/// reach the app's private, size-limited history file.
public final class AccessDiagnosticLog: @unchecked Sendable {
    struct Capture: Sendable {
        let id: UUID
        let path: String
    }
    public static let shared: AccessDiagnosticLog = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AccessDiagnostics", isDirectory: true)
        return AccessDiagnosticLog(storageDirectory: directory, initialLevel: selectedLevel())
    }()
    public static let preferenceKey = "access.diagnostics.logLevel"
    private let queue = DispatchQueue(label: "aegis.access.diagnostics")
    private let limit: Int
    private let pollInterval: DispatchTimeInterval
    private var lines: [String] = []
    private var byteCount = 0
    private var pending = Data()
    private var discardingLine = false
    private var discardingBuffered = false
    private var enabled = false
    private var failed = false
    private var secrets: [String] = []
    private var reader: DispatchSourceTimer?
    private var readerFD: Int32?
    private var directory: URL?
    private var captureID: UUID?
    private var minimumRank = 2
    private let storage: AccessDiagnosticLogStorage?
    private var storageReady: Bool
    private var storageGeneration: UInt64 = 0
    private var storageFailed = false
    private var clearingStorage = false
    private var dirty = false
    private var saveWork: DispatchWorkItem?
    private var saveWorkID: UUID?
    private var saveInFlight: UUID?
    private var flushWaiters: [@Sendable (Result<Void, Error>) -> Void] = []

    init(capacity: Int = 256 * 1024, storageDirectory: URL? = nil,
         initialLevel: AccessLogLevel = .warning,
         pollInterval: DispatchTimeInterval = .milliseconds(100),
         storageQueue: DispatchQueue? = nil) {
        limit = max(256, capacity)
        self.pollInterval = pollInterval
        storage = storageDirectory.map {
            if let storageQueue { return AccessDiagnosticLogStorage(directory: $0, queue: storageQueue) }
            return AccessDiagnosticLogStorage(directory: $0)
        }
        storageReady = storageDirectory == nil || initialLevel == .none
        minimumRank = Self.rank(initialLevel)
        if let storage {
            if initialLevel == .none {
                queue.async { self.clearLocked(disable: true, completion: nil) }
            } else {
                storage.load { [weak self] result in
                    guard let self else { return }
                    self.queue.async {
                        self.storageReady = true
                        if self.storageGeneration == 0 {
                            switch result {
                            case .success(let restored):
                                let safe = restored.compactMap(self.restoredLine)
                                if safe.count != restored.count { self.storageFailed = true }
                                self.dirty = self.dirty || safe != restored
                                self.lines = safe + self.lines
                                self.trimLocked()
                            case .failure:
                                self.storageFailed = true
                            }
                        }
                        if self.dirty { self.scheduleSaveLocked() }
                        let waiters = self.flushWaiters
                        self.flushWaiters.removeAll()
                        for waiter in waiters { self.flushLocked(completion: waiter) }
                    }
                }
            }
        }
    }

    public static func defaultLevel(for channel: AccessReleaseChannel) -> AccessLogLevel {
        switch channel {
        case .dev: .debug
        case .alpha: .info
        case .beta, .release, .unknown: .warning
        }
    }

    public static var defaultLevel: AccessLogLevel {
        let raw = Bundle.main.object(forInfoDictionaryKey: "AegisAccessReleaseChannel") as? String
        return defaultLevel(for: AccessReleaseChannel.parse(raw))
    }

    public static func selectedLevel(defaults: UserDefaults = .standard,
                                     channel: AccessReleaseChannel? = nil) -> AccessLogLevel {
        if let stored = defaults.string(forKey: preferenceKey).flatMap(AccessLogLevel.init(rawValue:)) {
            return stored
        }
        return channel.map { defaultLevel(for: $0) } ?? defaultLevel
    }

    /// Creates the reader before Xray opens the FIFO, preventing an open from
    /// blocking. A failure leaves logging disabled; the proxy can still work.
    func start(level: AccessLogLevel, secrets: [String]) throws -> Capture? {
        guard stop() else { throw POSIXError(.EIO) }
        guard level != .none else { clear(); return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aegis-access-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let fifo = dir.appendingPathComponent("events.fifo")
        guard mkfifo(fifo.path, 0o600) == 0 else {
            try? FileManager.default.removeItem(at: dir)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let fd = open(fifo.path, O_RDWR | O_NONBLOCK)
        guard fd >= 0 else {
            try? FileManager.default.removeItem(at: dir)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let capture = Capture(id: UUID(), path: fifo.path)
        queue.sync {
            self.secrets = secrets.filter { !$0.isEmpty }
            let sanitized = lines.compactMap(restoredLine)
            if sanitized != lines {
                lines = sanitized
                trimLocked()
                dirty = true
                scheduleSaveLocked()
            }
            enabled = true
            failed = false
            directory = dir
            captureID = capture.id
            minimumRank = Self.rank(level)
            pending.removeAll()
            discardingLine = false
            discardingBuffered = false
            let source = DispatchSource.makeTimerSource(queue: queue)
            // A bounded poll also handles Darwin FIFO writers whose large
            // write does not trigger another readability edge.
            source.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(20))
            source.setEventHandler { [weak self] in self?.drain(fd: fd) }
            source.setCancelHandler { close(fd) }
            reader = source
            readerFD = fd
            source.resume()
        }
        return capture
    }

    @discardableResult
    func stop() -> Bool {
        stop(ifID: nil)
    }

    @discardableResult
    func stop(capture: Capture) -> Bool {
        stop(ifID: capture.id)
    }

    private func stop(ifID: UUID?) -> Bool {
        let result: (Bool, URL?) = queue.sync {
            if let ifID, captureID != ifID { return (true, nil) }
            // The core has stopped, but its final complete records may still
            // be in the FIFO before the next poll. Keep clear/none's discard
            // state while draining a bounded amount of nonblocking input.
            if let readerFD { drain(fd: readerFD, maximumReads: 64) }
            enabled = false
            var retired: URL?
            if let directory {
                retired = Self.retireDirectory(directory)
                // Keep a discarded-output reader alive if the configured
                // pathname could not be retired. A new capture must not
                // overwrite it and strand a lazy blocking writer.
                if retired == nil && errno != ENOENT {
                    pending.removeAll()
                    failed = true
                    return (false, nil)
                }
            }
            // The configured pathname is now gone, while its reader was
            // still open throughout the rename.
            reader?.cancel()
            reader = nil
            readerFD = nil
            secrets.removeAll()
            pending.removeAll()
            directory = nil
            captureID = nil
            return (true, retired)
        }
        if let retired = result.1 {
            try? FileManager.default.removeItem(at: retired)
        }
        return result.0
    }

    /// Make the configured parent disappear atomically before recursive
    /// deletion. Xray's lazy O_CREAT writer must never replace the FIFO with
    /// a regular file while its parent is being removed.
    static func retireDirectory(_ directory: URL) -> URL? {
        let retired = directory.deletingLastPathComponent()
            .appendingPathComponent("aegis-access-retired-\(UUID().uuidString)", isDirectory: true)
        guard rename(directory.path, retired.path) == 0 else { return nil }
        return retired
    }

    /// The off choice takes effect immediately even while a core is running.
    public func disableAndClear() {
        queue.sync { clearLocked(disable: true, completion: nil) }
    }

    public func clear() {
        queue.sync { clearLocked(disable: false, completion: nil) }
    }

    public func clearStoredLogs() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { self.clearLocked(disable: false) { continuation.resume(with: $0) } }
        }
    }

    /// Flush before backgrounding; normal ingestion coalesces writes.
    public func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                let complete: @Sendable (Result<Void, Error>) -> Void = { continuation.resume(with: $0) }
                if self.storageReady { self.flushLocked(completion: complete) }
                else { self.flushWaiters.append(complete) }
            }
        }
    }

    public func snapshot() -> String { queue.sync { lines.joined(separator: "\n") } }
    public var unavailable: Bool { queue.sync { failed } }
    public var persistenceUnavailable: Bool { queue.sync { storage == nil || storageFailed } }
    public var isClearingStorage: Bool { queue.sync { clearingStorage } }

    func markUnavailable() { queue.sync { failed = true } }

    private func drain(fd: Int32, maximumReads: Int = 4) {
        var bytes = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<maximumReads {
            let count = read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                    enabled = false; failed = true
                } else {
                    discardingBuffered = false
                }
                return
            }
            if discardingBuffered {
                discardingLine = bytes[count - 1] != 10
                continue
            }
            for byte in bytes.prefix(count) {
                if byte == 10 {
                    if enabled && !discardingLine && !pending.isEmpty {
                        append(String(decoding: pending, as: UTF8.self))
                    }
                    pending.removeAll(keepingCapacity: true)
                    discardingLine = false
                } else if !discardingLine {
                    pending.append(byte)
                    if pending.count > 16 * 1024 { pending.removeAll(); discardingLine = true }
                }
            }
        }
    }

    private func append(_ raw: String) {
        let event = #"^(\d{4}/\d\d/\d\d \d\d:\d\d:\d\d(?:\.\d+)?) (.*)$"#
        guard let timestamp = Self.firstMatch(event, in: raw, group: 1),
              let body = Self.firstMatch(event, in: raw, group: 2) else { return }
        var severity = "Access"
        var severityRank = 1
        var detail: String
        let access = #"^from \S+ (accepted|rejected) (\S+)(?: .*)?$"#
        if let action = Self.firstMatch(access, in: body, group: 1),
           let target = Self.firstMatch(access, in: body, group: 2) {
            detail = "\(action) \(safeTarget(target))"
        } else {
            let general = #"^\[(Debug|Info|Warning|Error)\] (?:\[[0-9]+\] )?([a-zA-Z0-9_/]+): (.*)$"#
            guard let parsedSeverity = Self.firstMatch(general, in: body, group: 1),
                  let module = Self.firstMatch(general, in: body, group: 2),
                  let message = Self.firstMatch(general, in: body, group: 3) else { return }
            severity = parsedSeverity
            severityRank = ["Debug": 0, "Info": 1, "Warning": 2, "Error": 3][severity] ?? 1
            let tunnel = #"^tunneling request to (\S+) via (\S+)$"#
            if module == "proxy/vless/outbound",
               let target = Self.firstMatch(tunnel, in: message, group: 1),
               let via = Self.firstMatch(tunnel, in: message, group: 2) {
                detail = "tunneling request to \(safeTarget(target)) via \(safeTarget(via))"
            } else if module == "core", message == "Xray 26.11.9 started" {
                // The admitted core version is fixed; never retain an
                // arbitrary numeric payload from a forged event.
                detail = "core: Xray 26.11.9 started"
            } else {
                // Never copy unconstrained nested errors, URLs or node input.
                let modules = ["core", "app/log", "proxy/vless/outbound", "app/dispatcher",
                               "transport/internet/tcp", "transport/internet/reality"]
                let messages = ["pre-connect failed", "failed to create mux server worker",
                                "failed to pick route", "REALITY: received real certificate",
                                "default outbound handler not exist", "Reader is not timeout reader"]
                detail = modules.contains(module)
                    ? (messages.first(where: { message == $0 || message.hasPrefix($0 + " ") }) ?? "details withheld")
                    : "details withheld"
            }
        }
        guard severityRank >= minimumRank else { return }
        let text = redactedLine(timestamp + " [\(severity)] " + detail)
        let size = text.utf8.count + 1
        guard size <= limit else { return }
        lines.append(text)
        byteCount += size
        while byteCount > limit || lines.count > AccessDiagnosticLogStorage.maximumRecords {
            byteCount -= lines.removeFirst().utf8.count + 1
        }
        dirty = true
        scheduleSaveLocked()
    }

    private func trimLocked() {
        byteCount = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        while byteCount > limit || lines.count > AccessDiagnosticLogStorage.maximumRecords {
            byteCount -= lines.removeFirst().utf8.count + 1
        }
    }

    private func restoredLine(_ raw: String) -> String? {
        canonicalLine(raw).map(redactedLine)
    }

    private func redactedLine(_ safe: String) -> String {
        var text = safe
        for secret in secrets {
            text = text.replacingOccurrences(of: secret, with: "[redacted]", options: .caseInsensitive)
        }
        // Short secrets can also match timestamps or fixed event grammar.
        // Both live and restored records must retain a readable safe form.
        return canonicalLine(text) == text ? text : "[redacted]"
    }

    private func canonicalLine(_ raw: String) -> String? {
        if raw == "[redacted]" { return raw }
        let event = #"^(\d{4}/\d\d/\d\d \d\d:\d\d:\d\d(?:\.\d+)?) \[(Debug|Info|Warning|Error|Access)\] (.*)$"#
        guard let timestamp = Self.firstMatch(event, in: raw, group: 1),
              let severity = Self.firstMatch(event, in: raw, group: 2),
              let message = Self.firstMatch(event, in: raw, group: 3) else { return nil }
        let access = #"^(accepted|rejected) (\S+)$"#
        let tunnel = #"^tunneling request to (\S+) via (\S+)$"#
        let detail: String
        if let action = Self.firstMatch(access, in: message, group: 1),
           let target = Self.firstMatch(access, in: message, group: 2) {
            detail = "\(action) \(safeTarget(target))"
        } else if let target = Self.firstMatch(tunnel, in: message, group: 1),
                  let via = Self.firstMatch(tunnel, in: message, group: 2) {
            detail = "tunneling request to \(safeTarget(target)) via \(safeTarget(via))"
        } else {
            let known = ["core: Xray 26.11.9 started", "details withheld", "pre-connect failed",
                         "failed to create mux server worker", "failed to pick route",
                         "REALITY: received real certificate", "default outbound handler not exist",
                         "Reader is not timeout reader"]
            guard known.contains(message) else { return nil }
            detail = message
        }
        return timestamp + " [\(severity)] " + detail
    }

    private func scheduleSaveLocked() {
        guard storage != nil, storageReady, dirty, saveWork == nil, saveInFlight == nil else { return }
        let generation = storageGeneration
        let workID = UUID()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.storageGeneration == generation, self.saveWorkID == workID else { return }
            self.saveWork = nil
            self.saveWorkID = nil
            guard self.dirty, let storage = self.storage else { return }
            self.dirty = false
            let id = UUID()
            self.saveInFlight = id
            storage.save(self.lines) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    if self.saveInFlight == id { self.saveInFlight = nil }
                    if self.storageGeneration == generation { self.storageFailed = result.isFailure }
                    if self.dirty { self.scheduleSaveLocked() }
                }
            }
        }
        saveWork = work
        saveWorkID = workID
        queue.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func clearLocked(disable: Bool, completion: (@Sendable (Result<Void, Error>) -> Void)?) {
        if disable { enabled = false; failed = false }
        lines.removeAll(); byteCount = 0
        discardingLine = discardingLine || !pending.isEmpty
        pending.removeAll()
        if let fd = readerFD {
            // Discard through the first nonblocking empty read. The bounded
            // drain can finish on later ticks under sustained output; until
            // then none of the pre-clear pipe contents can be admitted.
            discardingBuffered = true
            drain(fd: fd)
        }
        storageGeneration &+= 1
        let generation = storageGeneration
        dirty = false
        saveWork?.cancel(); saveWork = nil; saveWorkID = nil
        guard let storage else { completion?(.success(())); return }
        clearingStorage = true
        storage.clear { [weak self] result in
            guard let self else { completion?(result); return }
            self.queue.async {
                if self.storageGeneration == generation {
                    self.clearingStorage = false
                    self.storageFailed = result.isFailure
                }
                completion?(result)
            }
        }
    }

    private func flushLocked(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        guard let storage else { completion(.success(())); return }
        saveWork?.cancel(); saveWork = nil; saveWorkID = nil
        dirty = false
        let generation = storageGeneration
        let finished: @Sendable (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self else { completion(result); return }
            self.queue.async {
                if self.storageGeneration == generation { self.storageFailed = result.isFailure }
                completion(result)
            }
        }
        if lines.isEmpty { storage.clear(finished) }
        else { storage.save(lines, completion: finished) }
    }

    private func safeTarget(_ raw: String) -> String {
        guard !raw.contains("@") else { return "[redacted]" }
        var target = raw
        if target.hasPrefix("http://") || target.hasPrefix("https://") || target.hasPrefix("//") {
            let https = target.hasPrefix("https://")
            target = String(target.dropFirst(target.hasPrefix("//") ? 2 : (https ? 8 : 7)))
            target = String(target.prefix(while: { !"/?#".contains($0) }))
            if !target.contains(":") || target.hasSuffix("]") { target += https ? ":443" : ":80" }
        }
        let endpoint = target.hasPrefix("tcp:") || target.hasPrefix("udp:") ? String(target.dropFirst(4)) : target
        guard endpoint.utf8.count <= 265, let colon = endpoint.lastIndex(of: ":") else { return "[redacted]" }
        let host = String(endpoint[..<colon])
        let port = String(endpoint[endpoint.index(after: colon)...])
        guard !host.isEmpty, !port.isEmpty, port.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let number = UInt16(port), number > 0 else { return "[redacted]" }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            let address = host.dropFirst().dropLast()
            guard address.contains(":"), address.allSatisfy({ "0123456789abcdefABCDEF:.".contains($0) }) else { return "[redacted]" }
        } else {
            guard !host.hasPrefix("."), !host.hasSuffix("."), !host.contains(".."),
                  host.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }) else { return "[redacted]" }
        }
        guard !secrets.contains(where: { target.range(of: $0, options: .caseInsensitive) != nil }) else { return "[redacted]" }
        return target
    }

    private static func firstMatch(_ pattern: String, in text: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    private static func rank(_ level: AccessLogLevel) -> Int {
        AccessLogLevel.allCases.firstIndex(of: level) ?? 2
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
