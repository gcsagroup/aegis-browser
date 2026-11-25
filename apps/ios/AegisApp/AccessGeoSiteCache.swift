import AccessKit
import AegisPolicyKit
import Darwin
import Foundation
import Security

struct AccessGeoSiteStorage: Sendable {
    enum Step: Equatable, Sendable {
        case readLedger, afterFileSync, afterRename, afterDirectorySync, writeLedger, writeOverseasWithdrawal, writeOverseasJournal
    }

    enum BlobKind: String, Sendable {
        case active, staged
    }

    static let ledgerLimit = 16 * 1024
    static let blobLimit = 128 * 1024
    static let overseasBlobLimit = 4 * 1024 * 1024
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

    static func overseasUITest(keep: Bool) throws -> Self {
        try Self(directory: FileManager.default.temporaryDirectory.appendingPathComponent("GeoSite-Overseas-UITest"),
                 service: "com.gcsa.aegis.ios.geosite.ui-testing.overseas").preparedForUITest(keep: keep)
    }

    private func preparedForUITest(keep: Bool) throws -> Self {
        if !keep {
            var query = key
            query[kSecAttrAccount as String] = nil
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AccessGeoSiteCache.Failure.unavailable }
            do { try FileManager.default.removeItem(at: directory) }
            catch let error as CocoaError where error.code == .fileNoSuchFile {}
        }
        return self
    }
#endif

    private var key: [String: Any] { key(account: "ledger") }

    private func key(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    var marker: URL { directory.appendingPathComponent("installed") }

    func blobURL(_ kind: BlobKind, _ sha256: String) -> URL {
        directory.appendingPathComponent("\(kind.rawValue)-\(sha256).json")
    }

    func readLedger() throws -> Data? {
        try failpoint(.readLedger)
        return try readRecord(key)
    }

    func readOverseasWithdrawal() throws -> Data? { try readRecord(key(account: "overseas-withdrawal")) }

    private func readRecord(_ key: [String: Any]) throws -> Data? {
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
        try failpoint(.writeLedger)
        try writeRecord(bytes, key: key, creating: creating)
    }

    func writeOverseasWithdrawal(_ bytes: Data) throws {
        try failpoint(.writeOverseasWithdrawal)
        let key = key(account: "overseas-withdrawal")
        try writeRecord(bytes, key: key, creating: try readRecord(key) == nil,
                        accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    private func writeRecord(_ bytes: Data, key: [String: Any], creating: Bool,
                             accessibility: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) throws {
        guard (1...Self.ledgerLimit).contains(bytes.count) else { throw AccessGeoSiteCache.Failure.unavailable }
        let attribute = [kSecValueData as String: bytes]
        let status: OSStatus
        if creating {
            var item = key
            item[kSecValueData as String] = bytes
            item[kSecAttrAccessible as String] = accessibility
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

    private var overseasFlight: URL { directory.appendingPathComponent("overseas-refresh.json") }

    func readOverseasFlight() throws -> Data? { try readFile(overseasFlight, maximum: 4096) }

    func writeOverseasFlight(_ bytes: Data) throws {
        try failpoint(.writeOverseasJournal)
        try writeFile(bytes, to: overseasFlight, maximum: 4096, journal: true)
    }

    func clearOverseasFlight() {
        if unlink(overseasFlight.path) == 0 { try? synchronizeDirectory(journal: true) }
    }

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
        try writeFile(bytes, to: destination, maximum: Self.blobLimit)
    }

    func storeOverseas(_ bytes: Data, digest: String, raw: Bool) throws {
        let name = try Self.overseasName(digest, raw: raw)
        let maximum = raw ? AccessGeoSiteAdmission.maximumDatabaseBytes : Self.overseasBlobLimit
        guard (1...maximum).contains(bytes.count), AccessGeoSiteAdmission.sha256(bytes) == digest
        else { throw AccessGeoSiteCache.Failure.unavailable }
        let url = directory.appendingPathComponent(name)
        if (try? readFile(url, maximum: maximum)) == bytes {
            try synchronizeDirectory()
            return
        }
        try writeFile(bytes, to: url, maximum: maximum)
    }

    func readOverseas(digest: String, length: Int, raw: Bool) throws -> Data {
        let name = try Self.overseasName(digest, raw: raw)
        let maximum = raw ? AccessGeoSiteAdmission.maximumDatabaseBytes : Self.overseasBlobLimit
        guard (1...maximum).contains(length),
              let bytes = try readFile(directory.appendingPathComponent(name), maximum: length),
              bytes.count == length, AccessGeoSiteAdmission.sha256(bytes) == digest
        else { throw AccessGeoSiteCache.Failure.unavailable }
        return bytes
    }

    static func overseasName(_ digest: String, raw: Bool) throws -> String {
        guard AccessGeoSiteAdmission.isSHA256(digest) else { throw AccessGeoSiteCache.Failure.unavailable }
        return raw ? "overseas-source-\(digest).dat" : "overseas-\(digest).json"
    }

    private func writeFile(_ bytes: Data, to destination: URL, maximum: Int, journal: Bool = false) throws {
        guard (1...maximum).contains(bytes.count) else { throw AccessGeoSiteCache.Failure.unavailable }
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
        let protection: FileProtectionType = journal ? .completeUntilFirstUserAuthentication : .complete
        try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: temporary.path)
        try file.write(contentsOf: bytes)
        try synchronize(descriptor)
        if !journal { try failpoint(.afterFileSync) }
        try file.close()
        guard rename(temporary.path, destination.path) == 0 else { throw AccessGeoSiteCache.Failure.unavailable }
        if !journal { try failpoint(.afterRename) }
        try synchronizeDirectory(journal: journal)
    }

    private func synchronizeDirectory(journal: Bool = false) throws {
        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else { throw AccessGeoSiteCache.Failure.unavailable }
        defer { _ = close(directoryDescriptor) }
        try synchronize(directoryDescriptor)
        if !journal { try failpoint(.afterDirectorySync) }
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
            let isBlob = ["active-", "staged-", "overseas-"].contains { prefix in
                name.hasPrefix(prefix) && name.hasSuffix(".json")
                    && AccessGeoSiteAdmission.isSHA256(String(name.dropFirst(prefix.count).dropLast(5)))
            }
            let isSource = name.hasPrefix("overseas-source-") && name.hasSuffix(".dat")
                && AccessGeoSiteAdmission.isSHA256(String(name.dropFirst("overseas-source-".count).dropLast(4)))
            if isTemporary || isBlob || isSource {
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
    enum Failure: Error { case unavailable, stale, ineligible, expansionTooLarge }

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

    struct OverseasView: Equatable, Sendable {
        enum Grant: Equatable, Sendable {
            case all(release: String)
            case categories(Set<AccessOverseasCategory>, release: String)
        }

        struct Ceiling: Equatable, Sendable {
            let receipt: AccessGeoSiteAdmission.Receipt
            let scope: AccessOverseasCatalogue.Scope
            let catalogue: AccessOverseasCatalogue

            static func == (lhs: Self, rhs: Self) -> Bool { lhs.receipt == rhs.receipt && lhs.scope == rhs.scope }
        }

        var selection = AccessOverseasSelection()
        var policy: AccessOverseasCatalogue.Policy?
        var pendingPolicy: AccessOverseasCatalogue.Policy?
        var ceiling: Ceiling?
        var verifiedScopeWhileHeld: Ceiling?
        var ready = false
        var activeTag: String?
        var projectedHosts: [AccessOverseasCategory: Set<String>] = [:]
        var pendingTag: String?
        var previewTag: String?
        var awaitingExpansion = false
        var unsaved = false
        var refreshFailed = false
        var previewRequested = false

        func match(_ url: URL) -> Match {
            guard selection.enabled, let host = AccessOverseasCatalogue.eligibleHost(url) else { return .original }
            guard let policy else {
                if let verifiedScopeWhileHeld,
                   !verifiedScopeWhileHeld.catalogue.matches(url, scope: verifiedScopeWhileHeld.scope) { return .original }
                return selection.mode == .all || AccessOverseasCatalogue.mayProject(host, in: selection.categories)
                    ? .indeterminate : .original
            }
            guard policy.matches(url) else { return .original }
            let withinCeiling = ceiling.map { $0.catalogue.matches(url, scope: $0.scope) } != false
            return ready && withinCeiling && pendingPolicy?.matches(url) != false ? .managed : .indeterminate
        }

        func route(for url: URL) -> (match: Match, grant: Grant?) {
            let decision = match(url)
            guard decision == .managed else { return (decision, nil) }
            guard let version = activeTag, let host = AccessOverseasCatalogue.eligibleHost(url) else { return (.indeterminate, nil) }
            if selection.mode == .all { return (.managed, .all(release: version)) }
            let matched = Set(selection.categories.filter { projectedHosts[$0]?.contains(host) == true })
            return matched.isEmpty ? (.indeterminate, nil) : (.managed, .categories(matched, release: version))
        }
    }

    struct OverseasPreview: Sendable {
        let release: String
        let catalogue: AccessOverseasCatalogue
        let fullPolicy: AccessOverseasCatalogue.Policy
    }

    struct OverseasConfirmation: Sendable, Identifiable {
        let id = UUID()
        let selection: AccessOverseasSelection
        let release: String
        var policy: AccessOverseasCatalogue.Policy { approved.policy }
        let newRules: [AccessOverseasCatalogue.Record]
        let removedExclusions: [AccessOverseasCatalogue.Record]
        fileprivate let context: Context
        fileprivate let reference: AccessOverseasCacheSnapshot.Reference
        fileprivate let approved: AccessOverseasCacheSnapshot
    }

    struct View: Equatable, Sendable {
        let status: Status
        let selection: Selection?
        let groups: [AccessGeoSiteCategory: Scope]
        var staged: [AccessGeoSiteCategory: StagedScope] = [:]
        var overseas = OverseasView()

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
        var overseasSelection: AccessOverseasSelection?
        var overseasActive: AccessOverseasCacheSnapshot.Reference?
        var overseasStaged: AccessOverseasCacheSnapshot.Reference?
        var overseasExpansionPending: Bool?
        var overseasAdmissionFailed: Bool?
        var overseasIntersectionUnavailable: Bool?
        var overseasPublication: UUID?
        var overseasReceiptFloor: AccessGeoSiteAdmission.Receipt?

        static func initial(selection: Selection, time: Date) -> Self {
            Self(schema: 1, owner: UUID(), selection: selection, clockFloor: time,
                 decisions: Dictionary(uniqueKeysWithValues: AccessGeoSiteCategory.allCases.map { ($0.rawValue, .bundled) }))
        }

        var files: Set<String> {
            Set([activeFile.map { "active-\($0).json" }, stagedFile.map { "staged-\($0).json" }].compactMap { $0 })
                .union(overseasActive?.files ?? []).union(overseasStaged?.files ?? [])
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
        var overseasActive: AccessOverseasCacheSnapshot?
        var overseasStaged: AccessOverseasCacheSnapshot?
        var overseasWithdrawal: OverseasWithdrawal?
        var overseasRecoveryHeld = false
        var overseasInterruptedBeforeAdmission = false
    }

    /// A verified withdrawal closes the old approval even if the batch is
    /// cancelled between sealing its blobs and committing the main ledger.
    private struct OverseasWithdrawal: Codable, Sendable {
        let owner: UUID
        let publication: UUID?
        let flight: UUID?
        let receipt: AccessGeoSiteAdmission.Receipt
        let firstReceipt: AccessGeoSiteAdmission.Receipt
        let requiresFreshApproval: Bool

        func protects(_ ledger: Ledger) -> Bool { owner == ledger.owner && publication == ledger.overseasPublication }
    }

    private struct OverseasFlight: Codable, Sendable {
        let owner: UUID
        let publication: UUID?
        let id: UUID
        let inherited: OverseasWithdrawal?
        var admitted: OverseasWithdrawal?
        let unresolved: Bool
        var resumingInterrupted: Bool?
        var finished = false

        func protects(_ ledger: Ledger) -> Bool {
            owner == ledger.owner && publication == ledger.overseasPublication
        }
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
    private var overseasSelectionUnsaved = false
    private var overseasFlight: (record: OverseasFlight, keepJournal: Bool)?
    private var observedReceipt: AccessGeoSiteAdmission.Receipt?
    private var pendingOverseasPolicy: AccessOverseasCatalogue.Policy?
    private var overseasCeiling: OverseasView.Ceiling?
    private var requestedOverseasPreview = false
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
    var wantsOverseasRules: Bool {
        if requestedOverseasPreview { return true }
        guard let selection = current?.ledger.overseasSelection, selection.enabled else { return false }
        return selection.mode == .all || !selection.categories.isEmpty
    }

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
        // Overseas rules refresh independently of the domestic website mode.
        guard !selectionUnsaved, let record = current?.ledger, status == .ready, !readClock().rollback,
              (record.selection.mode == .smart && !record.selection.categories.isEmpty) || wantsOverseasRules
        else { return nil }
        return Context(owner: record.owner, revision: revision, session: session)
    }

    func requestOverseasPreview() throws {
        guard let snapshot = current, status == .ready, !selectionUnsaved, !readClock().rollback
        else { throw Failure.ineligible }
        guard !requestedOverseasPreview, offeredOverseas(snapshot, at: readClock().date) == nil else { return }
        if snapshot.ledger.refresh.failureCount == 0, snapshot.ledger.refresh.nextAttempt != nil {
            // A prior successful refresh may have only legacy rules or an
            // overseas offer that is no longer recoverable.
            var next = snapshot
            next.ledger.refresh.nextAttempt = nil
            try commit(next, status: .ready)
        }
        requestedOverseasPreview = true
        revision &+= 1
        display(status)
    }

    func cancelOverseasPreview() {
        guard requestedOverseasPreview else { return }
        requestedOverseasPreview = false
        revision &+= 1
        display(status)
    }

    func beginOverseasRefresh(using context: Context, required: Bool = false, allowUnavailableJournal: Bool = false) throws -> UUID? {
        guard let snapshot = current, required || wantsOverseasRules || snapshot.ledger.overseasStaged != nil
            || snapshot.ledger.overseasReceiptFloor != nil
            || snapshot.overseasWithdrawal != nil || snapshot.overseasRecoveryHeld else { return nil }
        guard context.owner == snapshot.ledger.owner, context.session == session, overseasFlight == nil else { throw Failure.stale }
        let id = UUID()
        let flight = OverseasFlight(owner: context.owner, publication: snapshot.ledger.overseasPublication,
                                    id: id, inherited: snapshot.overseasWithdrawal, admitted: nil,
                                    unresolved: snapshot.overseasRecoveryHeld && !snapshot.overseasInterruptedBeforeAdmission,
                                    resumingInterrupted: snapshot.overseasRecoveryHeld && snapshot.overseasInterruptedBeforeAdmission)
        do { try storage.writeOverseasFlight(Self.encode(flight)) }
        catch { if !allowUnavailableJournal { throw error } }
        overseasFlight = (flight, snapshot.overseasRecoveryHeld || snapshot.overseasWithdrawal != nil)
        return id
    }

    func endOverseasRefresh(_ id: UUID?) {
        guard let id, var flight = overseasFlight, id == flight.record.id else { return }
        if flight.keepJournal {
            flight.record.finished = true
            if let bytes = try? Self.encode(flight.record) { try? storage.writeOverseasFlight(bytes) }
        } else {
            storage.clearOverseasFlight()
        }
        overseasFlight = nil
    }

    private func retainOverseasWithdrawal(_ receipt: AccessGeoSiteAdmission.Receipt,
                                          requiresFreshApproval: Bool = false,
                                          ceiling: OverseasView.Ceiling? = nil) throws {
        guard let snapshot = current, var flight = overseasFlight else { throw Failure.stale }
        let first = snapshot.overseasWithdrawal?.firstReceipt ?? receipt
        let hold = OverseasWithdrawal(owner: snapshot.ledger.owner, publication: snapshot.ledger.overseasPublication,
            flight: flight.record.id, receipt: receipt, firstReceipt: first,
            requiresFreshApproval: requiresFreshApproval || snapshot.overseasRecoveryHeld
                || snapshot.overseasWithdrawal?.requiresFreshApproval == true)
        current?.overseasWithdrawal = hold
        pendingOverseasPolicy = nil
        overseasCeiling = ceiling
        flight.record = OverseasFlight(owner: hold.owner, publication: hold.publication, id: flight.record.id,
                                      inherited: flight.record.inherited, admitted: hold, unresolved: hold.requiresFreshApproval)
        flight.keepJournal = true
        overseasFlight = flight
        display(status)
        do {
            try storage.writeOverseasFlight(Self.encode(flight.record))
        } catch {
            do { try storage.writeOverseasWithdrawal(Self.encode(hold)) }
            catch {
                display(status)
                throw error
            }
            return
        }
        // The independently fsynced journal already protects this receipt
        // when the Keychain record cannot be updated.
        try? storage.writeOverseasWithdrawal(Self.encode(hold))
    }

    var overseasPreview: OverseasPreview? {
        let clock = readClock()
        guard status == .ready, !selectionUnsaved, let current, !clock.rollback,
              let offer = offeredOverseas(current, at: clock.date) else { return nil }
        return OverseasPreview(release: offer.snapshot.receipt.tag, catalogue: offer.snapshot.catalogue,
                               fullPolicy: offer.snapshot.fullPolicy)
    }

    private func overseasApprovalInput(for choice: AccessOverseasSelection) throws
        -> (prior: Snapshot, offered: AccessOverseasCacheSnapshot, reference: AccessOverseasCacheSnapshot.Reference, context: Context) {
        let clock = readClock()
        guard choice.enabled, choice.isCanonical, !selectionUnsaved, overseasFlight == nil,
              status == .ready, !clock.rollback,
              let snapshot = current,
              let offer = offeredOverseas(snapshot, at: clock.date) else { throw Failure.ineligible }
        let prior = snapshot.ledger.overseasSelection
        let missingApproval = snapshot.ledger.overseasActive != nil && snapshot.overseasActive == nil
        if prior?.enabled == true, prior?.scope == choice.scope,
           missingApproval || snapshot.ledger.overseasIntersectionUnavailable == true {
            throw Failure.expansionTooLarge
        }
        return (snapshot, offer.snapshot, offer.reference, Context(owner: snapshot.ledger.owner, revision: revision, session: session))
    }

    func overseasConfirmation(for choice: AccessOverseasSelection) async throws -> OverseasConfirmation {
        let input = try overseasApprovalInput(for: choice)
        let confirmation = try await Task.detached(priority: .utility) {
            let approved = try input.offered.approving(choice)
            let policy = approved.policy
            let prior = input.prior.ledger.overseasSelection
            let expansion = input.prior.overseasActive.map { policy.expansion(over: $0.policy) }
            let rules = expansion?.rules ?? (prior?.enabled == true ? policy.effectiveRules : [])
            let removed = expansion?.removedExclusions ?? []
            if prior?.enabled == true, prior?.scope == choice.scope, rules.count + removed.count > 32 {
                throw Failure.expansionTooLarge
            }
            return OverseasConfirmation(selection: choice, release: approved.receipt.tag,
                newRules: rules, removedExclusions: removed, context: input.context, reference: input.reference, approved: approved)
        }.value
        try Task.checkCancellation()
        _ = try verifiedOverseasConfirmation(confirmation)
        return confirmation
    }

    private func verifiedOverseasConfirmation(_ confirmation: OverseasConfirmation) throws -> Snapshot {
        let input = try overseasApprovalInput(for: confirmation.selection)
        guard input.context == confirmation.context, input.reference == confirmation.reference else { throw Failure.stale }
        return input.prior
    }

    func confirmOverseas(_ confirmation: OverseasConfirmation,
                         whileValid: @MainActor () -> Bool) async throws {
        guard whileValid(), !writing else { throw Failure.stale }
        let owner = try verifiedOverseasConfirmation(confirmation).ledger.owner
        let approved = confirmation.approved
        writing = true
        defer { writing = false }
        let store = storage
        let reference = try await Task.detached(priority: .utility) { try approved.seal(owner: owner, storage: store) }.value
        try Task.checkCancellation()
        guard whileValid() else { throw Failure.stale }
        // Refresh diagnostics can change during the write without changing scope.
        var next = try verifiedOverseasConfirmation(confirmation)
        next.overseasActive = approved
        next.ledger.overseasActive = reference
        next.ledger.overseasSelection = confirmation.selection
        next.ledger.overseasExpansionPending = false
        next.ledger.overseasIntersectionUnavailable = false
        requestedOverseasPreview = false
        markTime(readClock().date, in: &next.ledger)
        try commit(next, status: .ready, clearsOverseasUnsaved: true)
        storage.prune(keep: next.ledger.files)
    }

    func disableOverseas() throws {
        guard var next = current, var selection = next.ledger.overseasSelection, selection.enabled else { return }
        var ownedFlight: UUID?
        defer { endOverseasRefresh(ownedFlight) }
        selection.enabled = false
        next.ledger.overseasSelection = selection
        next.ledger.overseasIntersectionUnavailable = false
        requestedOverseasPreview = false
        overseasSelectionUnsaved = true
        display(status)
        let clock = readClock()
        markTime(clock.date, in: &next.ledger)
        do {
            if overseasFlight == nil {
                let context = Context(owner: next.ledger.owner, revision: revision, session: session)
                ownedFlight = try beginOverseasRefresh(using: context, required: true, allowUnavailableJournal: true)
            }
            if let receipt = [observedReceipt, next.overseasWithdrawal?.receipt, next.ledger.highWater, next.ledger.overseasReceiptFloor]
                .compactMap({ $0 }).max(by: { $0.tag < $1.tag }) {
                try? retainOverseasWithdrawal(receipt, requiresFreshApproval: true)
                next.ledger.overseasReceiptFloor = receipt
            }
            if next.overseasRecoveryHeld || next.overseasStaged.map({
                (try? $0.receipt.validateSuccessor(of: next.ledger.overseasReceiptFloor)) == nil
            }) == true {
                next.overseasStaged = nil
                next.ledger.overseasStaged = nil
            }
            next.ledger.overseasPublication = UUID()
            next.overseasWithdrawal = nil
            next.overseasRecoveryHeld = false
            try commit(next, status: selectionUnsaved ? .unsaved : (clock.rollback ? .clockRollback : .ready),
                       clearsOverseasUnsaved: true)
            overseasFlight?.keepJournal = false
        } catch {
            overseasSelectionUnsaved = true
            revision &+= 1
            display(status)
            throw error
        }
    }

    private func offeredOverseas(_ snapshot: Snapshot, at date: Date)
        -> (snapshot: AccessOverseasCacheSnapshot, reference: AccessOverseasCacheSnapshot.Reference)? {
        if snapshot.overseasWithdrawal == nil, !snapshot.overseasRecoveryHeld,
           let staged = snapshot.overseasStaged, let reference = snapshot.ledger.overseasStaged,
           staged.receipt == snapshot.ledger.highWater, staged.expiresAt > date,
           (try? staged.receipt.validateSuccessor(of: snapshot.ledger.overseasReceiptFloor)) != nil,
           (try? staged.receipt.validateSuccessor(of: observedReceipt)) != nil { return (staged, reference) }
        return nil
    }

    func apply(_ candidate: AccessGeoSiteAdmission.Candidate, using context: Context,
               refreshed: RefreshState? = nil, whileValid: @MainActor () -> Bool = { true }) async throws {
        guard var next = current, context.owner == next.ledger.owner, context.session == session else { throw Failure.ineligible }
        let ownsWrite = !writing
        if ownsWrite { writing = true }
        defer { if ownsWrite { writing = false } }
        var ownedFlight: UUID?
        defer { endOverseasRefresh(ownedFlight) }
        defer { if current?.overseasWithdrawal != nil { display(status) } }
        let clock = readClock()
        guard candidate.suffixListSHA256 == RegisteredDomain.verifiedGeoSiteSuffixListSHA256,
              candidate.receipt.tag >= AccessGeoSiteCatalogue.bundled.tag else { throw Failure.stale }
        if candidate.receipt.tag == AccessGeoSiteCatalogue.bundled.tag,
           candidate.receipt.database.sha256 != AccessGeoSiteCatalogue.bundled.rawSHA256 {
            throw AccessGeoSiteAdmission.Failure.equivocation
        }
        _ = try candidate.receipt.expiry(at: clock.date)
        try candidate.receipt.validateSuccessor(of: next.ledger.highWater)
        try candidate.receipt.validateSuccessor(of: next.ledger.overseasReceiptFloor)
        try candidate.receipt.validateSuccessor(of: next.overseasWithdrawal?.receipt)
        try candidate.receipt.validateSuccessor(of: observedReceipt)
        observedReceipt = candidate.receipt
        markTime(clock.date, in: &next.ledger)
        next.ledger.highWater = candidate.receipt
        let includesOverseas = candidate.overseas != nil
        let supersedesOffer = next.ledger.overseasStaged.map { candidate.receipt.tag > $0.receipt.tag } == true
        let committedReplay = next.overseasStaged?.receipt == candidate.receipt
            && next.overseasWithdrawal == nil && !next.overseasRecoveryHeld
        let capturesOverseas = includesOverseas || candidate.overseasRejected || supersedesOffer || wantsOverseasRules || next.ledger.overseasReceiptFloor != nil
            || next.overseasWithdrawal != nil || next.overseasRecoveryHeld
        if !ownsWrite, capturesOverseas { revision &+= 1 }
        if capturesOverseas, overseasFlight == nil {
            ownedFlight = try beginOverseasRefresh(using: context, required: true)
        }
        if capturesOverseas, !committedReplay {
            let ceiling: OverseasView.Ceiling?
            if let catalogue = candidate.overseas, let scope = Self.retainedOverseasScope(next, for: candidate.receipt, now: clock.date) {
                ceiling = OverseasView.Ceiling(receipt: candidate.receipt, scope: scope, catalogue: catalogue)
            } else {
                ceiling = nil
            }
            try retainOverseasWithdrawal(candidate.receipt, ceiling: ceiling)
        }
        if includesOverseas {
            let prior = next
            let prepared = try await Task.detached(priority: .utility) {
                try Self.prepareOverseas(candidate, prior: prior)
            }.value
            guard let latest = current, latest.ledger.overseasActive == prior.ledger.overseasActive,
                  observedReceipt == candidate.receipt else { throw Failure.stale }
            if latest.overseasWithdrawal != nil {
                pendingOverseasPolicy = prepared.active?.policy
                overseasCeiling = nil
                display(status)
            }
            next.overseasStaged = prepared.staged
            next.ledger.overseasAdmissionFailed = false
            next.overseasActive = prepared.active
            next.ledger.overseasExpansionPending = prepared.awaitingApproval
            next.ledger.overseasIntersectionUnavailable = prepared.intersectionUnavailable
        } else if candidate.overseasRejected {
            next.overseasActive = nil
            next.ledger.overseasActive = nil
            next.overseasStaged = nil
            next.ledger.overseasStaged = nil
            next.ledger.overseasAdmissionFailed = true
            next.ledger.overseasExpansionPending = next.ledger.overseasSelection?.enabled == true
        } else if supersedesOffer {
            next.overseasStaged = nil
            next.ledger.overseasStaged = nil
        }
        guard includesOverseas || candidate.overseasRejected || !wantsOverseasRules else { throw Failure.ineligible }
        if capturesOverseas {
            next.ledger.overseasPublication = UUID()
            next.ledger.overseasReceiptFloor = candidate.receipt
            next.overseasWithdrawal = nil
            next.overseasRecoveryHeld = false
        }
        guard ownsWrite, context == updateContext(), whileValid() else { throw Failure.ineligible }
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
        try Task.checkCancellation()
        try await publish(next, context: context, expiresAt: candidate.expiresAt,
                          suffixSHA: candidate.suffixListSHA256, refreshed: refreshed, writeOverseas: includesOverseas) {
            whileValid() && self.observedReceipt == candidate.receipt
        }
        if includesOverseas || candidate.overseasRejected, requestedOverseasPreview {
            requestedOverseasPreview = false
            display(status)
        }
        if capturesOverseas {
            pendingOverseasPolicy = nil
            overseasCeiling = nil
            overseasFlight?.keepJournal = false
        }
    }

    private nonisolated static func retainedOverseasScope(_ prior: Snapshot, for receipt: AccessGeoSiteAdmission.Receipt,
                                                          now: Date? = nil) -> AccessOverseasCatalogue.Scope? {
        guard let selection = prior.ledger.overseasSelection, selection.enabled,
              let active = prior.overseasActive, now.map({ active.expiresAt > $0 }) != false,
              !prior.overseasRecoveryHeld else { return nil }
        if let hold = prior.overseasWithdrawal,
           hold.requiresFreshApproval || hold.firstReceipt != receipt || hold.receipt != receipt { return nil }
        return selection.scope
    }

    private nonisolated static func prepareOverseas(_ candidate: AccessGeoSiteAdmission.Candidate,
                                                    prior: Snapshot) throws
        -> (staged: AccessOverseasCacheSnapshot, active: AccessOverseasCacheSnapshot?, awaitingApproval: Bool,
            intersectionUnavailable: Bool) {
        let incoming = try AccessOverseasCacheSnapshot(candidate)
        guard let selection = prior.ledger.overseasSelection, selection.enabled else {
            return (incoming, prior.overseasWithdrawal == nil ? prior.overseasActive : nil, false, false)
        }
        // An exact replay can retain a reverified approval, including any
        // restriction from an expansion that was pending before the crash.
        if prior.overseasRecoveryHeld, prior.overseasInterruptedBeforeAdmission, prior.overseasWithdrawal == nil,
           let active = prior.overseasActive, active.receipt == incoming.receipt,
           prior.overseasStaged?.receipt == incoming.receipt {
            return (incoming, active, prior.ledger.overseasExpansionPending == true,
                    prior.ledger.overseasIntersectionUnavailable == true)
        }
        guard let old = prior.overseasActive, retainedOverseasScope(prior, for: candidate.receipt) != nil else {
            let missingApproval = prior.ledger.overseasActive != nil && prior.overseasActive == nil
            let unknownDelta = missingApproval || prior.overseasRecoveryHeld || prior.overseasWithdrawal != nil
            return (incoming, nil, true, unknownDelta || prior.ledger.overseasIntersectionUnavailable == true)
        }
        let proposed = try incoming.approving(selection)
        let delta = proposed.policy.expansion(over: old.policy)
        let expands = !delta.rules.isEmpty || !delta.removedExclusions.isEmpty
        let active = expands ? try incoming.narrowed(to: selection, retaining: old) : proposed
        return (incoming, active, expands, expands && active == nil)
    }

    func proposal(for category: AccessGeoSiteCategory) -> Proposal? {
        guard let current, current.ledger.selection.mode == .smart, let context = updateContext(),
              current.ledger.selection.categories.contains(category) else { return nil }
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
        guard !writing, var next = current, let context = updateContext(), self.proposal(for: proposal.category) == proposal,
              let suffixSHA = RegisteredDomain.verifiedGeoSiteSuffixListSHA256, whileValid() else { throw Failure.stale }
        writing = true
        defer { writing = false }
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
              hasValidActive(snapshot, receipt: receipt) else { return nil }
        let record = snapshot.ledger
        let activeFile = record.activeFile
        let includeOverseas = wantsOverseasRules
        if includeOverseas {
            guard offeredOverseas(snapshot, at: readClock().date) != nil,
                  record.overseasSelection?.enabled != true
                    || snapshot.overseasActive.map({ $0.expiresAt > readClock().date }) == true else { return nil }
        }
        let store = storage
        let intact = await Task.detached(priority: .utility) {
            guard let bytes = try? store.readLedger(), let disk = try? JSONDecoder().decode(Ledger.self, from: bytes),
                  disk.owner == record.owner, disk.selection == record.selection,
                  disk.highWater == receipt, disk.refresh.etag == etag,
                  disk.activeFile == activeFile, disk.stagedFile == record.stagedFile,
                  disk.decisions == record.decisions, disk.overseasSelection == record.overseasSelection,
                  disk.overseasActive == record.overseasActive, disk.overseasStaged == record.overseasStaged,
                  Self.loadBlob(.active, digest: activeFile, storage: store) == snapshot.active else { return false }
            if includeOverseas {
                for reference in [record.overseasActive, record.overseasStaged].compactMap({ $0 }) {
                    let asset = reference.receipt.database
                    guard (try? store.readOverseas(digest: reference.digest, length: reference.length, raw: false)) != nil,
                          (try? store.readOverseas(digest: asset.sha256, length: asset.byteCount, raw: true)) != nil
                    else { return false }
                }
            }
            if let staged = record.stagedFile {
                return !snapshot.staged.isEmpty && Self.loadBlob(.staged, digest: staged, storage: store) == snapshot.staged
            }
            return true
        }.value
        guard intact, !Task.isCancelled, context == updateContext(), let latest = current,
              latest.ledger.highWater == receipt, latest.ledger.activeFile == activeFile,
              latest.ledger.stagedFile == record.stagedFile, latest.ledger.refresh.etag == etag,
              !includeOverseas || offeredOverseas(latest, at: readClock().date) != nil,
              hasValidActive(latest, receipt: receipt) else { return nil }
        return ConditionalReceipt(etag: etag, receipt: receipt, activeFile: activeFile, stagedFile: record.stagedFile)
    }

    private func hasValidActive(_ snapshot: Snapshot, receipt: AccessGeoSiteAdmission.Receipt) -> Bool {
        let now = readClock().date
        guard (try? receipt.expiry(at: now)) != nil else { return false }
        // Manual mode keeps domestic categories but neither routes nor refreshes them.
        let domestic = snapshot.ledger.selection.mode == .smart ? snapshot.ledger.selection.categories : []
        let selected = domestic.map { Self.scope($0, in: snapshot, at: now) }
        // An enabled, unexpired overseas snapshot proves the stored release too,
        // including when every domestic category is bundled or awaiting approval.
        let overseasCurrent = snapshot.ledger.overseasSelection?.enabled == true && snapshot.overseasWithdrawal == nil
            && snapshot.overseasActive.map { $0.expiresAt > now } == true
        if selected.isEmpty { return overseasCurrent }
        return (overseasCurrent || selected.contains { if case .available(_, .some) = $0 { return true }; return false })
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
                         refreshed: RefreshState? = nil, writeOverseas: Bool = false,
                         whileValid: @MainActor () -> Bool = { true }) async throws {
        let storage = self.storage
        var next = snapshot
        let files = try await Task.detached(priority: .utility) {
            let owner = snapshot.ledger.owner
            var active = snapshot.ledger.overseasActive
            var staged = snapshot.ledger.overseasStaged
            if writeOverseas {
                active = try snapshot.overseasActive?.seal(owner: owner, storage: storage)
                if let snapshot = snapshot.overseasStaged { staged = try snapshot.seal(owner: owner, storage: storage) }
            }
            return (try Self.seal(snapshot.active, as: .active, suffixSHA: suffixSHA, storage: storage),
                    try Self.seal(snapshot.staged, as: .staged, suffixSHA: suffixSHA, storage: storage),
                    active, staged)
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
        next.ledger.overseasActive = files.2
        next.ledger.overseasStaged = files.3
        markTime(clock.date, in: &next.ledger)
        try commit(next, status: .ready, at: clock.date)
        let keep = next.ledger.files
        storage.prune(keep: keep)
    }

    // No suspension between replacing the one Keychain entry and publishing
    // the corresponding in-memory snapshot.
    private func commit(_ next: Snapshot, status: Status, at date: Date? = nil, invalidate: Bool = true,
                        clearsOverseasUnsaved: Bool = false) throws {
        try storage.writeLedger(Self.encode(next.ledger))
        if clearsOverseasUnsaved { overseasSelectionUnsaved = false }
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
        let overseas = [current?.overseasActive?.expiresAt, current?.overseasStaged?.expiresAt]
            .compactMap { $0 }.filter { $0 > now }
        guard let expiry = (active + view.staged.values.map(\.expiry) + overseas).min() else { return }
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
        let overseas = current.ledger.overseasSelection ?? AccessOverseasSelection()
        let approved = current.overseasActive
        let pending = current.overseasWithdrawal == nil ? nil : pendingOverseasPolicy
        let ceiling = current.overseasWithdrawal == nil ? nil : overseasCeiling
        let verifiedWhileHeld: OverseasView.Ceiling?
        if approved == nil, let staged = current.overseasStaged,
           staged.receipt == current.ledger.highWater {
            verifiedWhileHeld = OverseasView.Ceiling(receipt: staged.receipt, scope: overseas.scope, catalogue: staged.catalogue)
        } else {
            verifiedWhileHeld = nil
        }
        let offer = status == .ready && includeStaged ? offeredOverseas(current, at: date) : nil
        view.overseas = OverseasView(selection: overseas, policy: approved?.policy, pendingPolicy: pending, ceiling: ceiling,
            verifiedScopeWhileHeld: verifiedWhileHeld,
            ready: status == .ready && !overseasSelectionUnsaved && !current.overseasRecoveryHeld
                && (current.overseasWithdrawal == nil || pending != nil || ceiling != nil)
                && approved.map { $0.expiresAt > date } == true,
            activeTag: approved?.receipt.tag,
            projectedHosts: approved?.catalogue.hosts ?? [:],
            pendingTag: pending == nil ? nil : current.overseasWithdrawal?.receipt.tag,
            previewTag: offer?.snapshot.receipt.tag,
            awaitingExpansion: includeStaged && overseas.enabled
                && (current.overseasWithdrawal != nil || approved == nil || approved.map { $0.expiresAt <= date } == true
                    || current.ledger.overseasExpansionPending == true),
            unsaved: overseasSelectionUnsaved, refreshFailed: current.ledger.refresh.failureCount > 0 || current.ledger.overseasAdmissionFailed == true,
            previewRequested: requestedOverseasPreview)
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
        let clockFloor = max(now, record.clockFloor)
        var approved = record.overseasSelection
        approved?.enabled = true
        var withdrawal: OverseasWithdrawal?
        var flight: OverseasFlight?
        var markerFlight: UUID?
        var overseasHeld = false
        do {
            if let bytes = try storage.readOverseasFlight() {
                let decoded = try JSONDecoder().decode(OverseasFlight.self, from: bytes)
                if decoded.protects(record) {
                    flight = decoded
                    for receipt in [decoded.inherited, decoded.admitted].compactMap({ $0 }) where receipt.protects(record) {
                        withdrawal = try mergeWithdrawal(withdrawal, with: receipt)
                    }
                }
            }
        } catch {
            overseasHeld = true
        }
        do {
            if let bytes = try storage.readOverseasWithdrawal() {
                let pending = try JSONDecoder().decode(OverseasWithdrawal.self, from: bytes)
                if pending.protects(record) {
                    withdrawal = try mergeWithdrawal(withdrawal, with: pending)
                    markerFlight = pending.flight
                }
            }
        } catch {
            overseasHeld = true
        }
        var interruptedBeforeAdmission = false
        if let flight {
            let interrupted = (!flight.finished || flight.resumingInterrupted == true)
                && flight.admitted == nil && markerFlight != flight.id
            interruptedBeforeAdmission = interrupted && !overseasHeld && !flight.unresolved
                && flight.inherited == nil && withdrawal == nil
            overseasHeld = overseasHeld || flight.unresolved || interrupted
        }
        let overseasActive = record.overseasActive.flatMap { reference in
            try? AccessOverseasCacheSnapshot.recover(reference, owner: record.owner, approved: approved,
                                                     storage: storage, now: clockFloor)
        }
        let overseasStaged = record.overseasStaged.flatMap { reference in
            try? AccessOverseasCacheSnapshot.recover(reference, owner: record.owner, approved: nil,
                                                     storage: storage, now: clockFloor, verified: overseasActive)
        }
        storage.prune(keep: record.files)
        return Snapshot(ledger: record, active: active, staged: staged,
                        overseasActive: overseasActive, overseasStaged: overseasStaged,
                        overseasWithdrawal: withdrawal, overseasRecoveryHeld: overseasHeld,
                        overseasInterruptedBeforeAdmission: interruptedBeforeAdmission)
    }

    private nonisolated static func mergeWithdrawal(_ existing: OverseasWithdrawal?, with next: OverseasWithdrawal) throws
        -> OverseasWithdrawal {
        _ = try next.receipt.validityDeadline()
        try next.receipt.validateSuccessor(of: next.firstReceipt)
        guard let existing else { return next }
        if next.receipt.tag == existing.receipt.tag { try next.receipt.validateSuccessor(of: existing.receipt) }
        let latest = existing.receipt.tag > next.receipt.tag ? existing : next
        let first = existing.firstReceipt.tag < next.firstReceipt.tag ? existing.firstReceipt : next.firstReceipt
        return OverseasWithdrawal(owner: latest.owner, publication: latest.publication, flight: latest.flight,
            receipt: latest.receipt, firstReceipt: first,
            requiresFreshApproval: existing.requiresFreshApproval || next.requiresFreshApproval)
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
              record.overseasSelection?.isCanonical != false,
              record.overseasSelection?.enabled != true || record.overseasActive != nil || record.overseasExpansionPending == true,
              record.overseasActive == nil || record.overseasSelection != nil,
              record.overseasActive?.isValid(highWater: record.highWater) != false,
              record.overseasStaged?.isValid(highWater: record.highWater) != false,
              record.activeFile.map(AccessGeoSiteAdmission.isSHA256) != false,
              record.stagedFile.map(AccessGeoSiteAdmission.isSHA256) != false else { return false }
        if let highest = record.highWater {
            guard highest.tag >= AccessGeoSiteCatalogue.bundled.tag,
                  (try? highest.validityDeadline()) != nil else { return false }
        }
        if let floor = record.overseasReceiptFloor {
            guard floor.tag >= AccessGeoSiteCatalogue.bundled.tag, (try? floor.validityDeadline()) != nil else { return false }
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
