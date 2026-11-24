import AccessKit
import AegisPolicyKit
import Darwin
import Foundation
import Security

struct AccessGeoSiteStorage: Sendable {
    enum Step: Equatable, Sendable {
        case readLedger, afterFileSync, afterRename, afterDirectorySync, writeLedger
    }

    enum BlobKind: String, Sendable {
        case active, staged
    }

    static let ledgerLimit = 16 * 1024
    static let blobLimit = 128 * 1024
    let directory: URL
    let service: String
    let failpoint: @Sendable (Step) throws -> Void

    init(directory: URL, service: String, failpoint: @escaping @Sendable (Step) throws -> Void = { _ in }) {
        self.directory = directory
        self.service = service
        self.failpoint = failpoint
    }

    static func product() -> Self {
        let support = URL.applicationSupportDirectory.appendingPathComponent("GeoSite", isDirectory: true)
        return Self(directory: support, service: "com.gcsa.aegis.ios.geosite.v1")
    }

#if DEBUG
    static func uiTest(keep: Bool) throws -> Self {
        try Self(directory: FileManager.default.temporaryDirectory.appendingPathComponent("GeoSite-UITest"),
                 service: "com.gcsa.aegis.ios.geosite.ui-testing").preparedForUITest(keep: keep)
    }

#if targetEnvironment(simulator)
    static func consentUITest(keep: Bool) throws -> Self {
        // The hosted fixture test and the XCUI app share this simulator app container.
        try Self(directory: FileManager.default.temporaryDirectory.appendingPathComponent("GeoSite-Consent-UITest"),
                 service: "com.gcsa.aegis.ios.geosite.ui-testing.consent").preparedForUITest(keep: keep)
    }
#endif

    private func preparedForUITest(keep: Bool) throws -> Self {
        if !keep {
            let status = SecItemDelete(key as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AccessGeoSiteCache.Failure.unavailable }
            do { try FileManager.default.removeItem(at: directory) }
            catch let error as CocoaError where error.code == .fileNoSuchFile {}
        }
        return self
    }
#endif

    private var key: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "ledger", kSecAttrSynchronizable as String: false]
    }

    var marker: URL { directory.appendingPathComponent("installed") }

    func blobURL(_ kind: BlobKind, _ sha256: String) -> URL {
        directory.appendingPathComponent("\(kind.rawValue)-\(sha256).json")
    }

    func readLedger() throws -> Data? {
        try failpoint(.readLedger)
        var request = key
        request[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = value as? Data, (1...Self.ledgerLimit).contains(bytes.count)
        else { throw AccessGeoSiteCache.Failure.unavailable }
        return bytes
    }

    func writeLedger(_ bytes: Data, creating: Bool = false) throws {
        guard (1...Self.ledgerLimit).contains(bytes.count) else { throw AccessGeoSiteCache.Failure.unavailable }
        try failpoint(.writeLedger)
        let attribute = [kSecValueData as String: bytes]
        let status: OSStatus
        if creating {
            var item = key
            item[kSecValueData as String] = bytes
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        } else {
            status = SecItemUpdate(key as CFDictionary, attribute as CFDictionary)
        }
        guard status == errSecSuccess else { throw AccessGeoSiteCache.Failure.unavailable }
    }

    func readBlob(_ kind: BlobKind, digest: String) throws -> Data {
        guard AccessGeoSiteAdmission.isSHA256(digest),
              let bytes = try readFile(blobURL(kind, digest), maximum: Self.blobLimit),
              AccessGeoSiteAdmission.sha256(bytes) == digest else { throw AccessGeoSiteCache.Failure.unavailable }
        return bytes
    }

    func readMarker() throws -> Data? { try readFile(marker, maximum: 36) }

    private func readFile(_ url: URL, maximum: Int) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 && errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw AccessGeoSiteCache.Failure.unavailable }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= off_t(maximum)
        else { throw AccessGeoSiteCache.Failure.unavailable }
        var output = Data()
        while let bytes = try file.read(upToCount: maximum + 1 - output.count), !bytes.isEmpty {
            output.append(bytes)
            guard output.count <= maximum else { throw AccessGeoSiteCache.Failure.unavailable }
        }
        return output
    }

    func writeFile(_ bytes: Data, to destination: URL) throws {
        guard (1...Self.blobLimit).contains(bytes.count) else { throw AccessGeoSiteCache.Failure.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
        var url = directory
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        try url.setResourceValues(resource)

        let temporary = directory.appendingPathComponent(".geosite-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw AccessGeoSiteCache.Failure.unavailable }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? file.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: temporary.path)
        try file.write(contentsOf: bytes)
        try synchronize(descriptor)
        try failpoint(.afterFileSync)
        try file.close()
        guard rename(temporary.path, destination.path) == 0 else { throw AccessGeoSiteCache.Failure.unavailable }
        try failpoint(.afterRename)
        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else { throw AccessGeoSiteCache.Failure.unavailable }
        defer { _ = close(directoryDescriptor) }
        try synchronize(directoryDescriptor)
        try failpoint(.afterDirectorySync)
    }

    private func synchronize(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            guard errno == EINTR else { throw AccessGeoSiteCache.Failure.unavailable }
        }
    }

    /// Deletes only our obsolete generated files after selecting the exact
    /// committed digests. Directory contents never participate in recovery.
    func prune(keep: Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where !keep.contains(name) {
            let isTemporary = name.hasPrefix(".geosite-") && UUID(uuidString: String(name.dropFirst(9))) != nil
            let isBlob = ["active-", "staged-"].contains { prefix in
                name.hasPrefix(prefix) && name.hasSuffix(".json")
                    && AccessGeoSiteAdmission.isSHA256(String(name.dropFirst(prefix.count).dropLast(5)))
            }
            if isTemporary || isBlob {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }
}

@MainActor
final class AccessGeoSiteCache {
    struct Selection: Codable, Equatable, Sendable {
        var mode: AccessWebsiteAccelerationMode = .manual
        var categories: Set<AccessGeoSiteCategory> = [.debian]
    }

    struct TimeSource: Sendable {
        var wall: @Sendable () -> Date = Date.init
        var uptime: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    }

    struct RefreshState: Codable, Equatable, Sendable {
        var failureCount = 0
        var nextAttempt: Date?
        var lastRequest: Date?
        var etag: String?
    }

    struct ConditionalReceipt: Equatable, Sendable {
        let etag: String
        let receipt: AccessGeoSiteAdmission.Receipt
        fileprivate let activeFile: String?
        fileprivate let stagedFile: String?
    }

    enum Status: Equatable, Sendable { case loading, ready, unavailable, clockRollback, unsaved }
    enum Match: Equatable, Sendable { case original, managed, indeterminate }
    enum Failure: Error { case unavailable, stale, ineligible }

    struct Context: Equatable, Sendable {
        let owner: UUID
        let revision: UInt64
        fileprivate let session: UUID
    }

    struct Proposal: Equatable, Sendable {
        let owner: UUID
        let category: AccessGeoSiteCategory
        let revision: UInt64
        let version: String
        let group: AccessGeoSiteCatalogue.Group
        let addedRules: [AccessGeoSiteCatalogue.Rule]
        fileprivate let session: UUID
        fileprivate let candidate: AccessGeoSiteAdmission.Receipt
        fileprivate let oldScope: Scope
        fileprivate let deltaDigest: String
    }

    struct Version: Codable, Equatable, Sendable {
        let release: AccessGeoSiteAdmission.Receipt
        let scope: String
        let expiry: Date
    }

    enum Scope: Equatable, Sendable {
        case available(AccessGeoSiteCatalogue.Group, Version?)
        case withdrawn(String)
        case expired(AccessGeoSiteCatalogue.Group?, Version)
        case unavailable
    }

    struct StagedScope: Equatable, Sendable {
        let release: AccessGeoSiteAdmission.Receipt
        let expiry: Date
        let group: AccessGeoSiteCatalogue.Group
        let addedRules: [AccessGeoSiteCatalogue.Rule]
    }

    struct View: Equatable, Sendable {
        let status: Status
        let selection: Selection?
        let groups: [AccessGeoSiteCategory: Scope]
        var staged: [AccessGeoSiteCategory: StagedScope] = [:]

        func match(_ url: URL) -> Match {
            guard let host = AccessWebsiteRoutePolicy.websiteHost(url)?.rawValue else { return .original }
            guard let selection, status != .unsaved else { return .indeterminate }
            guard selection.mode == .smart, !selection.categories.isEmpty else { return .original }
            guard status == .ready else { return .indeterminate }
            var unresolved = false
            for category in selection.categories {
                switch groups[category] {
                case .available(let group, _):
                    if group.rules.contains(where: { $0.matches(host) }) { return .managed }
                case .expired(let group, _):
                    if group?.rules.contains(where: { $0.matches(host) }) != false { unresolved = true }
                case .withdrawn:
                    break
                case .unavailable, nil:
                    unresolved = true
                }
            }
            return unresolved ? .indeterminate : .original
        }
    }

    private enum GroupDecision: Codable, Equatable, Sendable {
        case bundled
        case accepted(Version)
        case expired(Version)
        case withdrawn(String)

        var version: Version? {
            switch self {
            case .accepted(let version), .expired(let version): version
            case .bundled, .withdrawn: nil
            }
        }
    }

    private struct Ledger: Codable, Equatable, Sendable {
        let schema: Int
        let owner: UUID
        var selection: Selection
        var clockFloor: Date
        var decisions: [String: GroupDecision]
        var highWater: AccessGeoSiteAdmission.Receipt?
        var activeFile: String?
        var stagedFile: String?
        var refresh = RefreshState()

        static func initial(selection: Selection, time: Date) -> Self {
            Self(schema: 1, owner: UUID(), selection: selection, clockFloor: time,
                 decisions: Dictionary(uniqueKeysWithValues: AccessGeoSiteCategory.allCases.map { ($0.rawValue, .bundled) }))
        }

        var files: Set<String> {
            Set([activeFile.map { "active-\($0).json" }, stagedFile.map { "staged-\($0).json" }].compactMap { $0 })
        }
    }

    private struct Blob: Codable, Sendable {
        let admissionVersion: Int
        let suffixListSHA256: String
        let groups: [String: AccessGeoSiteCatalogue.Group]

        init(_ groups: [String: AccessGeoSiteCatalogue.Group], suffixListSHA256: String) {
            admissionVersion = AccessGeoSiteAdmission.formatVersion
            self.suffixListSHA256 = suffixListSHA256
            self.groups = groups
        }
    }

    private struct Snapshot: Sendable {
        var ledger: Ledger
        var active: [String: AccessGeoSiteCatalogue.Group]
        var staged: [String: AccessGeoSiteCatalogue.Group]
    }

    private let storage: AccessGeoSiteStorage
    private let time: TimeSource
    private let session = UUID()
    private var revision: UInt64 = 0
    private var current: Snapshot?
    private var observed: (date: Date, uptime: TimeInterval)?
    private var restoring = false
    private var writing = false
    private var selectionUnsaved = false
    private var expiryTask: Task<Void, Never>?
    private(set) var view = View(status: .loading, selection: nil, groups: [:])
    var onChange: (@MainActor (View) -> Void)?

    var status: Status { view.status }
    var selection: Selection? { view.selection }
    var highWater: AccessGeoSiteAdmission.Receipt? { current?.ledger.highWater }
    var activeFileSHA256: String? { current?.ledger.activeFile }
    var stagedFileSHA256: String? { current?.ledger.stagedFile }
    var refreshState: RefreshState { current?.ledger.refresh ?? RefreshState() }
    var effectiveTime: Date { readClock().date }

    init(storage: AccessGeoSiteStorage, time: TimeSource = TimeSource()) {
        self.storage = storage
        self.time = time
    }

    deinit { expiryTask?.cancel() }

    func restore(migrating: Selection = Selection()) async {
        guard !restoring, current == nil else { return }
        restoring = true
        defer { restoring = false }
        let store = storage
        let wall = time.wall()
        do {
            let recovered = try await Task.detached(priority: .utility) {
                try Self.recover(store, migrating: migrating, now: wall)
            }.value
            try Task.checkCancellation()
            current = recovered
            try checkpointClock()
        } catch is CancellationError {
            return
        } catch {
            if current == nil { display(.unavailable) }
        }
    }

    func setSelection(_ selection: Selection) throws {
        guard var next = current else { throw Failure.unavailable }
        guard selection != next.ledger.selection else { return }
        let clock = readClock()
        next.ledger.selection = selection
        markTime(clock.date, in: &next.ledger)
        do {
            selectionUnsaved = false
            try commit(next, status: clock.rollback ? .clockRollback : .ready)
        } catch {
            // Close the effective route even if the old durable choice remains.
            selectionUnsaved = true
            revision &+= 1
            display(.unsaved)
            throw error
        }
    }

    func updateContext() -> Context? {
        guard let record = current?.ledger, status == .ready, record.selection.mode == .smart,
              !record.selection.categories.isEmpty, !readClock().rollback else { return nil }
        return Context(owner: record.owner, revision: revision, session: session)
    }

    func apply(_ candidate: AccessGeoSiteAdmission.Candidate, using context: Context,
               refreshed: RefreshState? = nil) async throws {
        guard var next = current, context == updateContext() else { throw Failure.ineligible }
        let clock = readClock()
        guard candidate.suffixListSHA256 == RegisteredDomain.verifiedGeoSiteSuffixListSHA256,
              candidate.receipt.tag >= AccessGeoSiteCatalogue.bundled.tag else { throw Failure.stale }
        if candidate.receipt.tag == AccessGeoSiteCatalogue.bundled.tag,
           candidate.receipt.database.sha256 != AccessGeoSiteCatalogue.bundled.rawSHA256 {
            throw AccessGeoSiteAdmission.Failure.equivocation
        }
        _ = try candidate.receipt.expiry(at: clock.date)
        try candidate.receipt.validateSuccessor(of: next.ledger.highWater)
        markTime(clock.date, in: &next.ledger)
        next.ledger.highWater = candidate.receipt
        next.staged = [:]
        for category in AccessGeoSiteCategory.allCases {
            let key = category.rawValue
            guard let offered = candidate.catalogue.groups[category] else {
                next.ledger.decisions[key] = .withdrawn(candidate.receipt.tag)
                next.active[key] = nil
                continue
            }
            let old = Self.scopeGroup(category, in: next)
            let sameScope = next.ledger.decisions[key]?.version?.scope == offered.typedSHA256
            if sameScope || old.map({ Self.additions(in: offered, over: $0).isEmpty }) == true {
                let version = Version(release: candidate.receipt, scope: offered.typedSHA256, expiry: candidate.expiresAt)
                next.ledger.decisions[key] = .accepted(version)
                next.active[key] = offered
            } else {
                next.staged[key] = offered
            }
        }
        try await publish(next, context: context, expiresAt: candidate.expiresAt,
                          suffixSHA: candidate.suffixListSHA256, refreshed: refreshed)
    }

    func proposal(for category: AccessGeoSiteCategory) -> Proposal? {
        guard let current, let context = updateContext(), current.ledger.selection.categories.contains(category) else { return nil }
        let now = readClock().date
        let old = Self.scope(category, in: current, at: now)
        guard let staged = Self.stagedScope(category, in: current, over: old, at: now),
              (1...32).contains(staged.addedRules.count) else { return nil }
        let text = staged.addedRules.map { "\($0.kind.rawValue):\($0.host)\n" }.joined()
        return Proposal(owner: context.owner, category: category, revision: context.revision, version: staged.release.tag,
            group: staged.group, addedRules: staged.addedRules, session: session, candidate: staged.release,
            oldScope: old, deltaDigest: AccessGeoSiteAdmission.sha256(Data(text.utf8)))
    }

    func confirm(_ proposal: Proposal, whileValid: @MainActor () -> Bool = { true }) async throws {
        guard var next = current, let context = updateContext(), self.proposal(for: proposal.category) == proposal,
              let suffixSHA = RegisteredDomain.verifiedGeoSiteSuffixListSHA256, whileValid() else { throw Failure.stale }
        let expiry = try proposal.candidate.expiry(at: readClock().date)
        let key = proposal.category.rawValue
        let version = Version(release: proposal.candidate, scope: proposal.group.typedSHA256, expiry: expiry)
        next.ledger.decisions[key] = .accepted(version)
        next.active[key] = proposal.group
        next.staged[key] = nil
        try await publish(next, context: context, expiresAt: expiry, suffixSHA: suffixSHA) {
            whileValid() && self.proposal(for: proposal.category) == proposal
        }
    }

    func checkpointClock() throws {
        guard var next = current, !selectionUnsaved else { return }
        let clock = readClock()
        markTime(clock.date, in: &next.ledger)
        let nextStatus: Status = clock.rollback ? .clockRollback : .ready
        if next.ledger == current?.ledger {
            if status != nextStatus { revision &+= 1 }
            display(nextStatus, at: clock.date)
            return
        }
        do {
            let change = next.ledger.decisions != current?.ledger.decisions || status != nextStatus
            try commit(next, status: nextStatus, at: clock.date, invalidate: change)
        } catch {
            revision &+= 1
            display(.unavailable)
            throw error
        }
    }

    func setRefreshState(_ state: RefreshState, using context: Context) throws {
        guard var next = current, context == updateContext(), Self.validRefreshState(state)
        else { throw Failure.ineligible }
        let date = readClock().date
        markTime(date, in: &next.ledger)
        let changed = next.ledger.decisions != current?.ledger.decisions
        next.ledger.refresh = state
        try commit(next, status: .ready, at: date, invalidate: changed)
    }

    /// A metadata validator is useful only while its durable receipt and
    /// selected, authorized active data can still be recovered.
    func conditionalReceipt(using context: Context) async -> ConditionalReceipt? {
        guard context == updateContext(), let snapshot = current,
              let etag = snapshot.ledger.refresh.etag, let receipt = snapshot.ledger.highWater,
              let activeFile = snapshot.ledger.activeFile,
              hasValidActive(snapshot, receipt: receipt) else { return nil }
        let record = snapshot.ledger
        let store = storage
        let intact = await Task.detached(priority: .utility) {
            guard let bytes = try? store.readLedger(), let disk = try? JSONDecoder().decode(Ledger.self, from: bytes),
                  disk.owner == record.owner, disk.selection == record.selection,
                  disk.highWater == receipt, disk.refresh.etag == etag,
                  disk.activeFile == activeFile, disk.stagedFile == record.stagedFile,
                  disk.decisions == record.decisions,
                  Self.loadBlob(.active, digest: activeFile, storage: store) == snapshot.active else { return false }
            if let staged = record.stagedFile {
                return !snapshot.staged.isEmpty && Self.loadBlob(.staged, digest: staged, storage: store) == snapshot.staged
            }
            return true
        }.value
        guard intact, !Task.isCancelled, context == updateContext(),
              current?.ledger.highWater == receipt, current?.ledger.activeFile == activeFile,
              current?.ledger.stagedFile == record.stagedFile, current?.ledger.refresh.etag == etag,
              hasValidActive(snapshot, receipt: receipt) else { return nil }
        return ConditionalReceipt(etag: etag, receipt: receipt, activeFile: activeFile, stagedFile: record.stagedFile)
    }

    private func hasValidActive(_ snapshot: Snapshot, receipt: AccessGeoSiteAdmission.Receipt) -> Bool {
        let now = readClock().date
        guard (try? receipt.expiry(at: now)) != nil else { return false }
        let selected = snapshot.ledger.selection.categories.map { Self.scope($0, in: snapshot, at: now) }
        return selected.contains { if case .available(_, .some) = $0 { return true }; return false }
            && selected.allSatisfy {
                switch $0 {
                case .available, .withdrawn: true
                case .expired, .unavailable: false
                }
            }
    }

    func match(_ url: URL) -> Match { runtimeView().match(url) }

    /// Checks expiry and rollback on the send path, including before the next
    /// foreground or timer checkpoint has persisted the time observation.
    func runtimeView() -> View {
        let clock = readClock()
        let status: Status = status == .ready && clock.rollback ? .clockRollback : self.status
        return makeView(status, at: clock.date, includeStaged: false)
    }

    private func publish(_ snapshot: Snapshot, context: Context, expiresAt: Date, suffixSHA: String,
                         refreshed: RefreshState? = nil, whileValid: @MainActor () -> Bool = { true }) async throws {
        guard !writing else { throw Failure.stale }
        writing = true
        defer { writing = false }
        let storage = self.storage
        var next = snapshot
        let files = try await Task.detached(priority: .utility) {
            (try Self.seal(snapshot.active, as: .active, suffixSHA: suffixSHA, storage: storage),
             try Self.seal(snapshot.staged, as: .staged, suffixSHA: suffixSHA, storage: storage))
        }.value
        try Task.checkCancellation()
        let clock = readClock()
        guard context == updateContext(), expiresAt > clock.date, whileValid(),
              RegisteredDomain.verifiedGeoSiteSuffixListSHA256 == suffixSHA else { throw Failure.stale }
        if let refreshed {
            guard Self.validRefreshState(refreshed) else { throw Failure.stale }
            next.ledger.refresh = refreshed
        } else if let latest = current?.ledger {
            next.ledger.refresh = latest.refresh
            if latest.highWater != next.ledger.highWater { next.ledger.refresh.etag = nil }
        }
        next.ledger.activeFile = files.0
        next.ledger.stagedFile = files.1
        markTime(clock.date, in: &next.ledger)
        try commit(next, status: .ready, at: clock.date)
        let keep = next.ledger.files
        storage.prune(keep: keep)
    }

    // No suspension between replacing the one Keychain entry and publishing
    // the corresponding in-memory snapshot.
    private func commit(_ next: Snapshot, status: Status, at date: Date? = nil, invalidate: Bool = true) throws {
        try storage.writeLedger(Self.encode(next.ledger))
        current = next
        if invalidate { revision &+= 1 }
        display(status, at: date)
    }

    private func markTime(_ date: Date, in record: inout Ledger) {
        record.clockFloor = max(record.clockFloor, date)
        for key in record.decisions.keys {
            if case .accepted(let version) = record.decisions[key], version.expiry <= date {
                record.decisions[key] = .expired(version)
            }
        }
    }

    private func readClock() -> (date: Date, rollback: Bool) {
        let wall = time.wall()
        let uptime = time.uptime()
        let monotonic = observed.map { $0.date.addingTimeInterval(max(0, uptime - $0.uptime)) } ?? wall
        let effective = max(wall, current?.ledger.clockFloor ?? wall, monotonic)
        observed = (effective, uptime)
        return (effective, effective.timeIntervalSince(wall) > 300)
    }

    private func display(_ status: Status, at date: Date? = nil) {
        let now = date ?? readClock().date
        let next = makeView(status, at: now)
        guard view != next else { return }
        view = next
        scheduleExpiry(for: next, at: now)
        onChange?(next)
    }

    private func scheduleExpiry(for view: View, at now: Date) {
        expiryTask?.cancel()
        guard view.status == .ready else { return }
        let active = view.groups.values.compactMap { scope -> Date? in
            guard case .available(_, let version) = scope else { return nil }
            return version?.expiry
        }
        guard let expiry = (active + view.staged.values.map(\.expiry)).min() else { return }
        expiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSince(now)))) }
            catch { return }
            try? self?.checkpointClock()
        }
    }

    private func makeView(_ status: Status, at date: Date, includeStaged: Bool = true) -> View {
        guard let current else { return View(status: status, selection: nil, groups: [:]) }
        let groups = Dictionary(uniqueKeysWithValues: AccessGeoSiteCategory.allCases.map { category in
            (category, Self.scope(category, in: current, at: date))
        })
        var view = View(status: status, selection: current.ledger.selection, groups: groups)
        if includeStaged, status == .ready {
            for (category, scope) in groups {
                view.staged[category] = Self.stagedScope(category, in: current, over: scope, at: date)
            }
        }
        return view
    }

    private nonisolated static func stagedScope(_ category: AccessGeoSiteCategory, in snapshot: Snapshot,
                                                over scope: Scope, at now: Date) -> StagedScope? {
        guard let receipt = snapshot.ledger.highWater, let expiry = try? receipt.expiry(at: now),
              let group = snapshot.staged[category.rawValue] else { return nil }
        let added: [AccessGeoSiteCatalogue.Rule]
        if case .available(let old, _) = scope {
            added = additions(in: group, over: old)
        } else {
            added = group.rules
        }
        return StagedScope(release: receipt, expiry: expiry, group: group, addedRules: added)
    }

    private nonisolated static func scope(_ category: AccessGeoSiteCategory, in snapshot: Snapshot, at date: Date) -> Scope {
        let group = scopeGroup(category, in: snapshot)
        switch snapshot.ledger.decisions[category.rawValue] {
        case .bundled:
            return group.map { .available($0, nil) } ?? .unavailable
        case .accepted(let version):
            if version.expiry <= date { return .expired(group, version) }
            return group.map { .available($0, version) } ?? .unavailable
        case .expired(let version):
            return .expired(group, version)
        case .withdrawn(let tag):
            return .withdrawn(tag)
        case nil:
            return .unavailable
        }
    }

    private nonisolated static func scopeGroup(_ category: AccessGeoSiteCategory,
                                               in snapshot: Snapshot) -> AccessGeoSiteCatalogue.Group? {
        let key = category.rawValue
        switch snapshot.ledger.decisions[key] {
        case .bundled: return AccessGeoSiteCatalogue.bundled.groups[category]
        case .accepted, .expired: return snapshot.active[key]
        case .withdrawn, nil: return nil
        }
    }

    private nonisolated static func additions(in offered: AccessGeoSiteCatalogue.Group,
                                              over previous: AccessGeoSiteCatalogue.Group) -> [AccessGeoSiteCatalogue.Rule] {
        offered.rules.filter { rule in
            !previous.rules.contains { old in
                old.matches(rule.host) && (old.kind == .domain || rule.kind == .full)
            }
        }
    }

    private nonisolated static func recover(_ storage: AccessGeoSiteStorage, migrating: Selection, now: Date) throws -> Snapshot {
        let marker = try storage.readMarker()
        var record: Ledger
        if let bytes = try storage.readLedger() {
            record = try JSONDecoder().decode(Ledger.self, from: bytes)
            let owner = Data(record.owner.uuidString.utf8)
            guard marker == nil || marker == owner, validRecord(record) else { throw Failure.unavailable }
            if marker == nil { try storage.writeFile(owner, to: storage.marker) }
        } else {
            guard marker == nil else { throw Failure.unavailable }
            record = .initial(selection: migrating, time: now)
            try storage.writeFile(Data(record.owner.uuidString.utf8), to: storage.marker)
            try storage.writeLedger(encode(record), creating: true)
        }

        let rawActive = loadBlob(.active, digest: record.activeFile, storage: storage)
        let active = rawActive.filter { key, group in record.decisions[key]?.version?.scope == group.typedSHA256 }
        let staged = loadBlob(.staged, digest: record.stagedFile, storage: storage)
        storage.prune(keep: record.files)
        return Snapshot(ledger: record, active: active, staged: staged)
    }

    private nonisolated static func validRefreshState(_ state: RefreshState) -> Bool {
        (0...4).contains(state.failureCount)
            && state.nextAttempt.map { $0.timeIntervalSinceReferenceDate.isFinite } != false
            && state.lastRequest.map { $0.timeIntervalSinceReferenceDate.isFinite } != false
            && AccessGeoSiteUpdateTransport.validETag(state.etag) == state.etag
    }

    private nonisolated static func validRecord(_ record: Ledger) -> Bool {
        let categories = Set(AccessGeoSiteCategory.allCases.map(\.rawValue))
        guard record.schema == 1, Set(record.decisions.keys) == categories,
              record.clockFloor.timeIntervalSinceReferenceDate.isFinite,
              validRefreshState(record.refresh),
              record.activeFile.map(AccessGeoSiteAdmission.isSHA256) != false,
              record.stagedFile.map(AccessGeoSiteAdmission.isSHA256) != false else { return false }
        if let highest = record.highWater {
            guard highest.tag >= AccessGeoSiteCatalogue.bundled.tag,
                  (try? highest.validityDeadline()) != nil else { return false }
        }
        for decision in record.decisions.values {
            if let version = decision.version {
                guard let highest = record.highWater, version.release.tag <= highest.tag,
                      version.release.tag != highest.tag || version.release == highest,
                      AccessGeoSiteAdmission.isSHA256(version.scope),
                      (try? version.release.validityDeadline()) == version.expiry
                else { return false }
            } else if case .withdrawn(let tag) = decision {
                guard let highest = record.highWater, tag <= highest.tag else { return false }
            }
        }
        return true
    }

    private nonisolated static func loadBlob(_ kind: AccessGeoSiteStorage.BlobKind, digest: String?,
                                             storage: AccessGeoSiteStorage) -> [String: AccessGeoSiteCatalogue.Group] {
        guard let digest, let data = try? storage.readBlob(kind, digest: digest),
              let blob = try? JSONDecoder().decode(Blob.self, from: data),
              blob.admissionVersion == AccessGeoSiteAdmission.formatVersion,
              blob.suffixListSHA256 == RegisteredDomain.verifiedGeoSiteSuffixListSHA256,
              blob.groups.count <= AccessGeoSiteCategory.allCases.count else { return [:] }
        var groups: [String: AccessGeoSiteCatalogue.Group] = [:]
        for (key, value) in blob.groups {
            guard AccessGeoSiteCategory(rawValue: key) != nil,
                  let admitted = try? AccessGeoSiteAdmission.checkedGroup(value.rules), admitted == value else { return [:] }
            groups[key] = admitted
        }
        return groups
    }

    private nonisolated static func seal(_ groups: [String: AccessGeoSiteCatalogue.Group],
                                         as kind: AccessGeoSiteStorage.BlobKind, suffixSHA: String,
                                         storage: AccessGeoSiteStorage) throws -> String? {
        guard !groups.isEmpty else { return nil }
        let data = try encode(Blob(groups, suffixListSHA256: suffixSHA))
        let digest = AccessGeoSiteAdmission.sha256(data)
        try storage.writeFile(data, to: storage.blobURL(kind, digest))
        return digest
    }

    private nonisolated static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
