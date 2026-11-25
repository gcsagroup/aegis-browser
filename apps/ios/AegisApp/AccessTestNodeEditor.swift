import AccessKit
import Foundation
import Observation
import Security
import WebKit
import UIKit

/// Package metadata is resolved by native code. Firebase is independent of Access admission.
enum AccessInternalOptions: String {
    case dev, alpha

    static var installed: Self? {
        let bundle = Bundle.main
#if DEBUG
        let debug = true
#else
        let debug = false
#endif
        return resolve(
            bundleID: bundle.bundleIdentifier,
            channel: bundle.object(forInfoDictionaryKey: "AegisAccessReleaseChannel") as? String,
            releaseProfile: bundle.object(forInfoDictionaryKey: "AegisReleaseProfile") as? String,
            capability: bundle.object(forInfoDictionaryKey: "AegisAccessInternalOptions") as? String,
            debug: debug
        )
    }

    static func resolve(
        bundleID: String?, channel: String?, releaseProfile: String?, capability: String?, debug: Bool
    ) -> Self? {
        guard let channel, channel == releaseProfile, capability == "YES" else { return nil }
        switch (bundleID, channel) {
        case ("com.gcsa.aegis", "dev") where debug: return .dev
        case ("com.gcsa.aegis.alpha.internal", "alpha"): return .alpha
        default: return nil
        }
    }
}

/// Admission is limited to the physical iPhone OS build actually verified for this internal path.
enum AccessInternalSOCKSAdmission {
    static func admitted(major: Int, minor: Int, patch: Int, build: String,
                         phone: Bool, simulator: Bool) -> Bool {
        !simulator && phone && major == 26 && minor == 6 && patch == 1 && (build == "23G83" || build.hasSuffix("(Build 23G83)"))
    }

    @MainActor static var current: Bool {
        let os = ProcessInfo.processInfo.operatingSystemVersion
#if targetEnvironment(simulator)
        let simulator = true
#else
        let simulator = false
#endif
        return admitted(major: os.majorVersion, minor: os.minorVersion, patch: os.patchVersion,
                        build: ProcessInfo.processInfo.operatingSystemVersionString,
                        phone: UIDevice.current.userInterfaceIdiom == .phone, simulator: simulator)
    }
}

enum AccessTestNodeTransport: String {
    case automatic, http, socks5

    func select(socksAdmitted: Bool) throws -> AccessInboundTransport {
        switch self {
        case .automatic: return socksAdmitted ? .socks5 : .http
        case .http: return .http
        case .socks5:
            guard socksAdmitted else { throw AccessTestNodeError.unavailable }
            return .socks5
        }
    }
}

enum AccessTestNodeError: Error {
    case unavailable, invalidLink, cameraDenied, cameraUnavailable, conflict, storageUnavailable
}

struct AccessTestNodeRecord: Codable {
    let revision: UUID
    let node: AccessInternalTestNode

    private enum CodingKeys: String, CodingKey {
        case version, revision, address, port, userID, serverName, publicKey, shortID, fingerprint, spiderX
        case requestHost, path, alpn
    }

    private struct StoredIdentity: Decodable {
        let version: Int
        let revision: UUID
    }

    /// Revise or remove a known record even if its outbound can no longer run.
    static func storedRevision(in data: Data) throws -> UUID {
        let identity = try JSONDecoder().decode(StoredIdentity.self, from: data)
        guard identity.version == 1 || identity.version == 2 else { throw AccessTestNodeError.storageUnavailable }
        return identity.revision
    }

    init(_ node: AccessInternalTestNode) {
        revision = UUID()
        self.node = node
    }

    init(_ parameters: AccessRealityVisionParameters) {
        self.init(.realityVision(parameters))
    }

    // REALITY-only test fixtures keep their existing typed accessor.
    func parameters() throws -> AccessRealityVisionParameters {
        guard case .realityVision(let parameters) = node else { throw AccessTestNodeError.unavailable }
        try AccessLocalV2RayConfigLoader.validateManualParameters(parameters)
        return parameters
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let version = try fields.decode(Int.self, forKey: .version)
        guard version == 1 || version == 2 else { throw AccessTestNodeError.storageUnavailable }
        revision = try fields.decode(UUID.self, forKey: .revision)
        let address = try fields.decode(String.self, forKey: .address)
        let port = try fields.decode(UInt16.self, forKey: .port)
        let userID = try fields.decode(String.self, forKey: .userID)
        let serverName = try fields.decode(String.self, forKey: .serverName)
        let fingerprint = try fields.decode(String.self, forKey: .fingerprint)
        if version == 1 {
            node = .realityVision(try AccessRealityVisionParameters(
                address: address, port: port, userID: userID, serverName: serverName,
                publicKey: fields.decode(String.self, forKey: .publicKey),
                shortID: fields.decode(String.self, forKey: .shortID), fingerprint: fingerprint,
                spiderX: fields.decode(String.self, forKey: .spiderX)
            ))
        } else {
            node = .vlessWebSocketTLS(try AccessVLESSWebSocketTLSParameters(
                address: address, port: port, userID: userID, serverName: serverName,
                requestHost: fields.decode(String.self, forKey: .requestHost),
                path: fields.decode(String.self, forKey: .path), fingerprint: fingerprint,
                alpn: fields.decode(String.self, forKey: .alpn)
            ))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(revision, forKey: .revision)
        switch node {
        case .realityVision(let parameters):
            try fields.encode(1, forKey: .version)
            try fields.encode(parameters.address, forKey: .address)
            try fields.encode(parameters.port, forKey: .port)
            try fields.encode(parameters.userID, forKey: .userID)
            try fields.encode(parameters.serverName, forKey: .serverName)
            try fields.encode(parameters.fingerprint, forKey: .fingerprint)
            try fields.encode(parameters.publicKey, forKey: .publicKey)
            try fields.encode(parameters.shortID, forKey: .shortID)
            try fields.encode(parameters.spiderX, forKey: .spiderX)
        case .vlessWebSocketTLS(let parameters):
            try fields.encode(2, forKey: .version)
            try fields.encode(parameters.address, forKey: .address)
            try fields.encode(parameters.port, forKey: .port)
            try fields.encode(parameters.userID, forKey: .userID)
            try fields.encode(parameters.serverName, forKey: .serverName)
            try fields.encode(parameters.fingerprint, forKey: .fingerprint)
            try fields.encode(parameters.requestHost, forKey: .requestHost)
            try fields.encode(parameters.path, forKey: .path)
            try fields.encode(parameters.alpn, forKey: .alpn)
        }
    }
}

@MainActor
protocol AccessTestNodeStoring {
    func read(channel: AccessInternalOptions) throws -> AccessTestNodeRecord?
    func revision(channel: AccessInternalOptions) throws -> UUID?
    func write(_ record: AccessTestNodeRecord, channel: AccessInternalOptions) throws
    func remove(channel: AccessInternalOptions) throws
}

extension AccessTestNodeStoring {
    func revision(channel: AccessInternalOptions) throws -> UUID? {
        try read(channel: channel)?.revision
    }
}

struct AccessTestNodeKeychain: AccessTestNodeStoring {
    var service = "com.gcsa.aegis.ios.access-test-node.v1"

    private func query(for channel: AccessInternalOptions) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: channel.rawValue + ".ordinary.fixed-test-profile",
         kSecAttrSynchronizable as String: false]
    }

    private func data(channel: AccessInternalOptions) throws -> Data? {
        var request = query(for: channel)
        request[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AccessTestNodeError.storageUnavailable
        }
        return data
    }

    func read(channel: AccessInternalOptions) throws -> AccessTestNodeRecord? {
        try data(channel: channel).map { try JSONDecoder().decode(AccessTestNodeRecord.self, from: $0) }
    }

    func revision(channel: AccessInternalOptions) throws -> UUID? {
        try data(channel: channel).map(AccessTestNodeRecord.storedRevision(in:))
    }

    func write(_ record: AccessTestNodeRecord, channel: AccessInternalOptions) throws {
        let request = query(for: channel)
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(record),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(request.merging(attributes) { _, value in value } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AccessTestNodeError.storageUnavailable }
    }

    func remove(channel: AccessInternalOptions) throws {
        let status = SecItemDelete(query(for: channel) as CFDictionary)
        guard status == errSecSuccess else { throw AccessTestNodeError.storageUnavailable }
    }
}

@MainActor
final class AccessTestNodeRepository {
    static let shared = launchRepository(arguments: ProcessInfo.processInfo.arguments)

    static func launchRepository(arguments: [String], channel: AccessInternalOptions? = AccessInternalOptions.installed,
                                 persistentStorage: () -> any AccessTestNodeStoring = { AccessTestNodeKeychain() }) -> AccessTestNodeRepository {
#if DEBUG
        if arguments.contains("--ui-testing") {
            return AccessTestNodeRepository(channel: channel, storage: UITestStorage())
        }
#endif
        return AccessTestNodeRepository(channel: channel, storage: persistentStorage())
    }

#if DEBUG
    private final class UITestStorage: AccessTestNodeStoring {
        private var records: [AccessInternalOptions: AccessTestNodeRecord] = [:]

        func read(channel: AccessInternalOptions) -> AccessTestNodeRecord? { records[channel] }
        func write(_ record: AccessTestNodeRecord, channel: AccessInternalOptions) { records[channel] = record }
        func remove(channel: AccessInternalOptions) { records.removeValue(forKey: channel) }
    }
#endif
    private let channel: AccessInternalOptions?
    private let storage: any AccessTestNodeStoring
    private var revocations: [UUID: @MainActor () -> Void] = [:]

    func observeRevocation(_ callback: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        revocations[id] = callback
        return id
    }

    func removeObserver(_ id: UUID) { revocations[id] = nil }

    private func revokeOpenPages() {
        let callbacks = Array(revocations.values)
        callbacks.forEach { $0() }
    }

    init(channel: AccessInternalOptions? = AccessInternalOptions.installed,
         storage: any AccessTestNodeStoring = AccessTestNodeKeychain()) {
        self.channel = channel
        self.storage = storage
    }

    func allowsEditing(isPrivate: Bool) -> Bool { channel != nil && !isPrivate }

    func savedNode(isPrivate: Bool) throws -> AccessTestNodeRecord {
        guard let channel, !isPrivate, let record = try storage.read(channel: channel) else {
            throw AccessTestNodeError.unavailable
        }
        return record
    }


    func revision(isPrivate: Bool) throws -> UUID? {
        guard let channel, !isPrivate else { throw AccessTestNodeError.unavailable }
        return try storage.revision(channel: channel)
    }

    func apply(_ draft: AccessRealityVisionParameters, expectedRevision: UUID?, isPrivate: Bool) throws -> UUID {
        try apply(.realityVision(draft), expectedRevision: expectedRevision, isPrivate: isPrivate)
    }

    func apply(_ draft: AccessInternalTestNode, expectedRevision: UUID?, isPrivate: Bool) throws -> UUID {
        guard let channel, !isPrivate else { throw AccessTestNodeError.unavailable }
        guard try revision(isPrivate: isPrivate) == expectedRevision else { throw AccessTestNodeError.conflict }
        if case .realityVision(let parameters) = draft {
            try AccessLocalV2RayConfigLoader.validateManualParameters(parameters)
        }
        let record = AccessTestNodeRecord(draft)
        try storage.write(record, channel: channel)
        revokeOpenPages()
        return record.revision
    }

    func remove(expectedRevision: UUID, isPrivate: Bool) throws {
        guard let channel, !isPrivate else { throw AccessTestNodeError.unavailable }
        guard try revision(isPrivate: isPrivate) == expectedRevision else { throw AccessTestNodeError.conflict }
        try storage.remove(channel: channel)
        revokeOpenPages()
    }
}

@MainActor
@Observable
final class AccessTestNodeEditor {
    struct Scan: Identifiable, Equatable {
        let id = UUID()
    }

    private let repository: AccessTestNodeRepository
    private let isPrivate: Bool
    private var draft: AccessInternalTestNode?
    private var baseRevision: UUID?
    private var loaded = false
    private(set) var scan: Scan?
    private(set) var error: AccessTestNodeError?

    var allowsEditing: Bool { repository.allowsEditing(isPrivate: isPrivate) }
    var hasDraft: Bool { draft != nil }
    var draftProtocolName: String? {
        switch draft {
        case .realityVision: "VLESS / TCP / REALITY / Vision"
        case .vlessWebSocketTLS: "VLESS / WS / TLS"
        case nil: nil
        }
    }
    var hasSavedNode: Bool { baseRevision != nil }
    var showsEmptyProfile: Bool { loaded && !hasSavedNode }
    var canApply: Bool { loaded && hasDraft && scan == nil }

    init(isPrivate: Bool, repository: AccessTestNodeRepository = .shared) {
        self.isPrivate = isPrivate
        self.repository = repository
    }

    /// Each visit to the test Profile starts a new editing lifetime.
    func openProfile() {
        closeProfile()
        do {
            baseRevision = try repository.revision(isPrivate: isPrivate)
            loaded = true
            error = nil
        } catch {
            self.error = allowsEditing ? .storageUnavailable : .unavailable
        }
    }

    func closeProfile() {
        scan = nil
        draft = nil
        baseRevision = nil
        loaded = false
        error = nil
    }

    func preview(_ input: String) {
        guard loaded else { return }
        scan = nil
        do {
            draft = try AccessInternalTestNode.parseSingleShareURI(input)
            error = nil
        } catch {
            // Remove an earlier candidate so Apply cannot save it after a failed preview.
            draft = nil
            self.error = .invalidLink
        }
    }

    func beginScan() -> Scan? {
        guard loaded, scan == nil else { return nil }
        let request = Scan()
        // A new input attempt cannot leave an older candidate ready to Apply.
        draft = nil
        scan = request
        error = nil
        return request
    }

    @discardableResult
    func finishScan(_ request: Scan, result: Result<String, AccessTestNodeError>?) -> Bool {
        guard scan == request else { return false }
        scan = nil
        switch result {
        case .success(let input):
            preview(input)
            return hasDraft && error == nil
        case .failure(let error): self.error = error
        case nil: break
        }
        return false
    }

    func finishScan(_ request: Scan, result: Result<String, AccessTestNodeError>?,
                    pendingText: inout String) {
        if finishScan(request, result: result) { pendingText = "" }
    }

    func apply() {
        guard canApply, let draft else { return }
        do {
            baseRevision = try repository.apply(draft, expectedRevision: baseRevision, isPrivate: isPrivate)
            self.draft = nil
            error = nil
        } catch let failure as AccessTestNodeError {
            error = failure
        } catch {
            self.error = .storageUnavailable
        }
    }

    func discard() {
        openProfile()
    }

    func removeSavedNode() {
        guard loaded, scan == nil, let baseRevision else { return }
        do {
            try repository.remove(expectedRevision: baseRevision, isPrivate: isPrivate)
            openProfile()
        } catch let failure as AccessTestNodeError {
            error = failure
        } catch {
            self.error = .storageUnavailable
        }
    }
}

/// VisionKit and offline QR fixtures use the same whole-capture admission.
enum AccessTestNodeQRCode {
    static func payload(from items: [String?]) -> Result<String, AccessTestNodeError> {
        guard items.count == 1, let payload = items.first ?? nil else { return .failure(.invalidLink) }
        return .success(payload)
    }
}


/// First observations only. Never stores URLs, credentials, or document content.
struct AccessTestNodeTimeline {
    enum Milestone: String {
        case loadIssued, loadNotAccepted, provisionalStart, firstVisibleHTTPResponse
        case documentCommit, documentFinish, preparationTimedOut, preparationFailure, navigationFailure, policyRejection
        case retirementRequested, retirementCommit
    }

    enum Observation {
        case http(status: Int, initial: Bool)
        case redirect
        case policyRejection(String)
        case failure(domain: String, code: Int)
    }

    struct Snapshot {
        var nanoseconds: [String: Int64] = [:]
        var milliseconds: [String: Int64] { nanoseconds.mapValues { $0 / 1_000_000 } }
        var firstHTTPStatus: Int?
        var initialHTTPStatus: Int?
        var lastHTTPStatus: Int?
        var serverRedirectCount = 0
        var localPolicyRejection: String?
        var failureDomain: String?
        var failureCode: Int?

        var isEmpty: Bool {
            nanoseconds.isEmpty && lastHTTPStatus == nil && serverRedirectCount == 0
                && localPolicyRejection == nil && failureDomain == nil
        }

        var navigationPolicy: String {
            if let localPolicyRejection { return localPolicyRejection }
            if failureDomain == "WebKitErrorDomain", failureCode == 102 { return "policy-interruption-unattributed" }
            return "no-local-rejection-observed"
        }
    }

    let origin: ContinuousClock.Instant
    private var instants: [Milestone: ContinuousClock.Instant] = [:]
    private var observations: [(instant: ContinuousClock.Instant, value: Observation)] = []

    init(origin: ContinuousClock.Instant = .now) {
        self.origin = origin
    }

    mutating func record(_ milestone: Milestone, at instant: ContinuousClock.Instant = .now) {
        if instants[milestone] == nil { instants[milestone] = instant }
    }

    func instant(_ milestone: Milestone) -> ContinuousClock.Instant? { instants[milestone] }

    mutating func observe(_ value: Observation, at instant: ContinuousClock.Instant) {
        observations.append((instant, value))
    }

    func snapshot(through cutoff: ContinuousClock.Instant, after start: ContinuousClock.Instant? = nil) -> Snapshot {
        func includes(_ instant: ContinuousClock.Instant) -> Bool {
            instant <= cutoff && (start.map { instant > $0 } ?? true)
        }
        var snapshot = Snapshot()
        for (milestone, instant) in instants where includes(instant)
            && milestone != .retirementRequested && milestone != .retirementCommit {
            snapshot.nanoseconds[milestone.rawValue] = nanoseconds(at: instant)
        }
        for observation in observations where includes(observation.instant) {
            switch observation.value {
            case .http(let status, let initial):
                if snapshot.firstHTTPStatus == nil { snapshot.firstHTTPStatus = status }
                if initial { snapshot.initialHTTPStatus = status }
                snapshot.lastHTTPStatus = status
            case .redirect:
                snapshot.serverRedirectCount += 1
            case .policyRejection(let reason):
                snapshot.localPolicyRejection = reason
            case .failure(let domain, let code):
                snapshot.failureDomain = domain
                snapshot.failureCode = code
            }
        }
        return snapshot
    }

    func milliseconds(at instant: ContinuousClock.Instant) -> Int64 {
        nanoseconds(at: instant) / 1_000_000
    }

    private func nanoseconds(at instant: ContinuousClock.Instant) -> Int64 {
        let elapsed = origin.duration(to: instant).components
        return elapsed.seconds * 1_000_000_000 + elapsed.attoseconds / 1_000_000_000
    }

    var milliseconds: [String: Int64] {
        Dictionary(uniqueKeysWithValues: instants.map { milestone, instant in
            (milestone.rawValue, milliseconds(at: instant))
        })
    }
}

/// A deliberately selected ordinary test Profile owns one publisher and one immutable store.
/// Each new page session rereads its saved revision and owns an isolated native core.
@MainActor
@Observable
final class AccessTestNodePage: NSObject, WKNavigationDelegate {
    let id = UUID()
    private(set) var webView: WKWebView?
    private(set) var status = "正在准备连接"
    private(set) var endpoint: AccessManagedProxyEndpoint?
    /// Read-only identity of the store actually created; survives retirement for receipts.
    private(set) var initialBinding: AccessManagedProxyEndpoint?
    private let repository: AccessTestNodeRepository
    private let isPrivate: Bool
    private let registry = AccessHostDataStoreRegistry()
    private let testingCore: (any AccessEmbeddedCoreControlling)?
    private var publisher: (any AccessProxyEntryPublishing)?
    private var key: AccessHostStoreKey?
    private var operationID: UUID?
    private var observerID: UUID?
    private let preparationTimeout: Duration
    private let waitForPreparationDeadline: @MainActor (ContinuousClock.Instant) async throws -> Void
    private var activePreparationDeadline: ContinuousClock.Instant?
    private var deadlineTask: Task<Void, Never>?
    private var preparationWaiter: CheckedContinuation<AccessProxyEntryPrepareResult, Error>?
    private var retirement: (() -> Void)?
    private(set) var retirementNavigation: WKNavigation?
    private var retirementRetryUsed = false
    private let retirementURL = URL(string: "https://aegis.invalid/retired/" + UUID().uuidString)!
    private var retiringOwner: AccessTestNodePage?
    /// Bounded, secret-free lifecycle evidence; no URL or document content.
    private(set) var retirementEvents: [String] = []
    private(set) var retirementRequestedAt: ContinuousClock.Instant?
    private(set) var retirementCommittedAt: ContinuousClock.Instant?
    private(set) var failureDomain: String?
    private(set) var failureCode: Int?
    private(set) var localPolicyRejection: String?
    var navigationPolicyObservation: String {
        if let localPolicyRejection { return localPolicyRejection }
        if failureDomain == "WebKitErrorDomain", failureCode == 102 { return "policy-interruption-unattributed" }
        return "no-local-rejection-observed"
    }
    private(set) var httpStatus: Int?
    private(set) var firstVisibleHTTPStatus: Int?
    private(set) var timeline: AccessTestNodeTimeline
    private(set) var preparationStartedAt: ContinuousClock.Instant?
    private(set) var preparationDeadline: ContinuousClock.Instant?
    private(set) var originalNavigationAfterClose: AccessTestNodeTimeline
    /// WebKit does not expose a redirect's HTTP status through its redirect callback.
    /// Keep the initial response unknown when it was not delivered to the response delegate.
    private(set) var initialHTTPStatus: Int?
    private(set) var serverRedirectCount = 0
    private var observedMainFrameResponse = false
    private let singleNavigation: Bool
    private let transportPreference: AccessTestNodeTransport
    private let socksAdmitted: Bool
    private let navigationAllowed: () -> Bool
    private let onTransportLoss: (() -> Void)?
    private(set) var selectedTransport: AccessInboundTransport?
    private var sentMainFrame = false
    private var committedMainFrame = false
    private var currentNavigation: WKNavigation?
    private(set) var originalNavigation: WKNavigation?
    private var sawMainFrameAction = false
    private var closed = false
    private var retiring = false

    init(isPrivate: Bool, repository: AccessTestNodeRepository = .shared,
         testingCore: (any AccessEmbeddedCoreControlling)? = nil,
         singleNavigation: Bool = false, transport: AccessTestNodeTransport = .automatic,
         socksAdmitted: Bool? = nil, navigationAllowed: @escaping () -> Bool = { true },
         preparationTimeout: Duration = .seconds(15),
         waitForPreparationDeadline: @escaping @MainActor (ContinuousClock.Instant) async throws -> Void = {
             try await ContinuousClock().sleep(until: $0)
         },
         onTransportLoss: (() -> Void)? = nil) {
        self.transportPreference = transport
        self.socksAdmitted = socksAdmitted ?? AccessInternalSOCKSAdmission.current
        self.repository = repository
        self.isPrivate = isPrivate
        self.testingCore = testingCore
        self.singleNavigation = singleNavigation
        self.preparationTimeout = preparationTimeout
        self.waitForPreparationDeadline = waitForPreparationDeadline
        self.navigationAllowed = navigationAllowed
        self.onTransportLoss = onTransportLoss
        let createdAt = ContinuousClock.now
        self.timeline = AccessTestNodeTimeline(origin: createdAt)
        self.originalNavigationAfterClose = AccessTestNodeTimeline(origin: createdAt)
        super.init()
    }

    func open(_ url: URL) async {
        await open(url, recordDispatch: { _ in })
    }

    func open(_ url: URL, recordDispatch: (ContinuousClock.Instant) throws -> Void) async rethrows {
        let preparingAt = ContinuousClock.now
        let deadline = preparingAt.advanced(by: preparationTimeout)
        guard publisher == nil, activePreparationDeadline == nil, !closed, url.scheme == "https", url.user == nil, url.password == nil,
              let rawHost = url.host, let host = try? AccessSiteHost(rawHost),
              navigationAllowed(), repository.allowsEditing(isPrivate: isPrivate) else {
            status = "连接暂不可用"
            return
        }
        activePreparationDeadline = deadline
        preparationStartedAt = preparingAt
        preparationDeadline = deadline
        let view: WKWebView
        do {
            let transport = try transportPreference.select(socksAdmitted: socksAdmitted)
            selectedTransport = transport
            let record = try repository.savedNode(isPrivate: isPrivate)
            guard !closed, ContinuousClock.now < deadline else { throw AccessTestNodeError.unavailable }
            let revision = record.revision
            observerID = repository.observeRevocation { [weak self] in self?.close() }
            let core = try testingCore ?? AccessGoEmbeddedCore(isolated: true)
            let newPublisher = AccessEmbeddedProxyEntryFactory.makeInternalTestPublisher(
                verifiedCore: core,
                node: { [repository, isPrivate] in
                    guard ContinuousClock.now < deadline else { throw AccessTestNodeError.unavailable }
                    let current = try repository.savedNode(isPrivate: isPrivate)
                    guard current.revision == revision else { throw AccessTestNodeError.conflict }
                    if case .realityVision = current.node { _ = try current.parameters() }
                    guard ContinuousClock.now < deadline else { throw AccessTestNodeError.unavailable }
                    return current.node
                },
                connectionAllowed: { [weak self, repository] in
                    guard let self, !self.closed, !self.preparationDeadlineElapsed, self.navigationAllowed() else { return false }
                    return (try? repository.revision(isPrivate: self.isPrivate)) == revision
                        && !self.closed && !self.preparationDeadlineElapsed
                },
                retireDocuments: { [weak self] _, finish in
                    self?.retire(finish)
                }, transport: transport)
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard !closed, remaining > .zero else { throw AccessTestNodeError.unavailable }
            publisher = newPublisher
            let operation = UUID()
            operationID = operation
            deadlineTask = Task { [weak self, waitForPreparationDeadline] in
                try? await waitForPreparationDeadline(deadline)
                guard !Task.isCancelled, let self, self.activePreparationDeadline == deadline,
                      ContinuousClock.now >= deadline else { return }
                self.timeline.record(.preparationTimedOut, at: deadline)
                self.close()
            }
            let request = AccessProxyEntryPrepareRequest(operationID: operation, deadline: remaining)
            let result = try await withCheckedThrowingContinuation { continuation in
                preparationWaiter = continuation
                // The publisher owns native startup and disposal of its late
                // result. Closing this page only resolves its own wait.
                Task { [weak self] in
                    guard self?.preparationWaiter != nil else { return }
                    guard ContinuousClock.now < deadline else {
                        self?.close()
                        return
                    }
                    do {
                        let result = try await newPublisher.prepare(request)
                        self?.finishPreparation(.success(result))
                    } catch {
                        self?.finishPreparation(.failure(error))
                    }
                }
            }
            guard !closed, ContinuousClock.now < deadline,
                  (try? repository.revision(isPrivate: isPrivate)) == revision,
                  result.endpoint.transport == transport,
                  newPublisher.validateReady(result) else { throw AccessTestNodeError.unavailable }
            let storeKey = AccessHostStoreKey(scopeID: "test-" + id.uuidString, host: host, isPrivate: isPrivate)
            guard newPublisher.retain(result.endpoint, for: storeKey) else { throw AccessTestNodeError.unavailable }
            key = storeKey
            guard registry.setEndpoint(result.endpoint, scopeID: storeKey.scopeID, host: host, isPrivate: isPrivate),
                let store = registry.storeForTab(tabID: id.uuidString, scopeID: storeKey.scopeID,
                isPrivate: isPrivate, targetHost: host, boundHost: nil, intent: .on),
                store.proxyConfigurations.count == 1,
                store.proxyConfigurations.first?.allowFailover == false,
                ContinuousClock.now < deadline else {
                throw AccessTestNodeError.unavailable
            }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = store
            view = WKWebView(frame: .zero, configuration: configuration)
            guard !closed, ContinuousClock.now < deadline else { throw AccessTestNodeError.unavailable }
            deadlineTask?.cancel()
            activePreparationDeadline = nil
            endpoint = result.endpoint
            view.navigationDelegate = self
            webView = view
            initialBinding = result.endpoint
        } catch {
            if !closed {
                if preparationDeadlineElapsed, let activePreparationDeadline {
                    timeline.record(.preparationTimedOut, at: activePreparationDeadline)
                } else {
                    recordFailure(error as NSError)
                }
            }
            close()
            return
        }
        guard navigationAllowed(), !observeBoundEntryLoss() else { close(); return }
        guard let navigation = view.load(URLRequest(url: url)) else {
            timeline.record(.loadNotAccepted)
            close()
            return
        }
        let acceptedAt = ContinuousClock.now
        currentNavigation = navigation
        if singleNavigation { originalNavigation = navigation }
        status = "正在加载"
        timeline.record(.loadIssued, at: acceptedAt)
        do {
            try recordDispatch(acceptedAt)
        } catch {
            close()
            throw error
        }
    }

    private func finishPreparation(_ result: Result<AccessProxyEntryPrepareResult, Error>) {
        let waiter = preparationWaiter
        preparationWaiter = nil
        waiter?.resume(with: result)
    }

    private var preparationDeadlineElapsed: Bool {
        activePreparationDeadline.map { ContinuousClock.now >= $0 } ?? false
    }

    func close() {
        guard !closed else { return }
        if retirementRequestedAt == nil { retirementRequestedAt = .now }
        timeline.record(.retirementRequested)
        if preparationDeadlineElapsed, let activePreparationDeadline {
            timeline.record(.preparationTimedOut, at: activePreparationDeadline)
            if failureDomain == nil {
                failureDomain = NSURLErrorDomain
                failureCode = NSURLErrorTimedOut
            }
        }
        // A navigation error can arrive before the publisher's health poll.
        // Sample its current entry before ordinary shutdown makes it unhealthy.
        observeBoundEntryLoss()
        closed = true
        if let observerID { repository.removeObserver(observerID) }
        observerID = nil
        status = "连接暂不可用"
        deadlineTask?.cancel()
        activePreparationDeadline = nil
        if let operationID { publisher?.cancel(operationID: operationID) }
        finishPreparation(.failure(CancellationError()))
        if let publisher = publisher as? AccessProxyEntryPublisher {
            if key != nil { publisher.closeCurrentGeneration() }
        } else { retire {} }
    }

    @discardableResult
    func observeBoundEntryLoss() -> Bool {
        guard !closed, !retiring, let onTransportLoss, initialBinding != nil,
              (publisher as? AccessProxyEntryPublisher)?.isCurrentEntryHealthy != true else { return false }
        onTransportLoss()
        return true
    }

    private func retire(_ finish: @escaping () -> Void) {
        if retirementRequestedAt == nil { retirementRequestedAt = .now }
        // A publisher can initiate retirement itself when its health watch fails.
        if !closed, initialBinding != nil { onTransportLoss?() }
        status = "连接暂不可用"
        retiring = true
        timeline.record(.retirementRequested)
        recordRetirement("requested")
        guard let view = webView else { finish(); release(); return }
        retirement = finish
        // Retain the suspended listener and old document until their exact stop acknowledgement.
        retiringOwner = self
        view.stopLoading()
        view.configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        loadRetirementReplacement(in: view)
        if retirementNavigation == nil { retryRetirementReplacement(in: view) }
    }

    private func loadRetirementReplacement(in view: WKWebView) {
        // Give the local replacement a host-bearing identity under the proxied store.
        // loadHTMLString does not fetch this synthetic HTTPS URL.
        retirementNavigation = view.loadHTMLString("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'\">", baseURL: retirementURL)
        recordRetirement(retirementNavigation == nil ? "replacement-not-created" : "replacement-created")
    }

    private func retryRetirementReplacement(in view: WKWebView) {
        guard retiring, retirement != nil, view === webView, !retirementRetryUsed else { return }
        retirementRetryUsed = true
        // An interrupted navigation can never become an acknowledgement later.
        // Keep the same suspended endpoint and retry only the inert local document,
        // after the current policy/failure callback has returned. No target replay.
        retirementNavigation = nil
        recordRetirement("replacement-retry-scheduled")
        Task { @MainActor [weak self, weak view] in
            guard let self, let view, self.retirement != nil, view === self.webView else { return }
            self.recordRetirement("replacement-retried")
            self.loadRetirementReplacement(in: view)
        }
    }

    private func recordRetirement(_ event: String) {
        if retirementEvents.count == 32 { retirementEvents.removeFirst() }
        retirementEvents.append(event)
    }

    private func release() {
        if let key { publisher?.release(for: key) }
        if let operationID { publisher?.cancel(operationID: operationID) }
        key = nil
        endpoint = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        recordOriginalAfterClose(.documentCommit, navigation: navigation, in: webView)
        if retiring {
            guard webView === self.webView, let navigation, navigation === retirementNavigation,
                  let finish = retirement else { recordRetirement("other-commit"); return }
            retirementCommittedAt = .now
            recordRetirement("replacement-committed")
            timeline.record(.retirementCommit)
            retirement = nil
            finish()
            release()
            retiringOwner = nil
            return
        }
        if let navigation, navigation === currentNavigation {
            if webView === self.webView { timeline.record(.documentCommit) }
            committedMainFrame = true
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        recordOriginalAfterClose(.provisionalStart, navigation: navigation, in: webView)
        if retiring { recordRetirement(navigation != nil && navigation === retirementNavigation ? "replacement-started" : "other-start") }
        guard !retiring, let navigation else { return }
        if webView === self.webView { timeline.record(.provisionalStart) }
        currentNavigation = navigation
        committedMainFrame = false
        status = "正在加载"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        recordOriginalAfterClose(.documentFinish, navigation: navigation, in: webView)
        if retiring { recordRetirement(navigation != nil && navigation === retirementNavigation ? "replacement-finished" : "other-finish") }
        if !retiring, let navigation, navigation === currentNavigation {
            if webView === self.webView { timeline.record(.documentFinish) }
            status = "已连接"
        }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if isOriginalAfterClose(navigation, in: webView) { originalNavigationAfterClose.observe(.redirect, at: .now) }
        if !retiring, let navigation, navigation === currentNavigation {
            serverRedirectCount += 1
            if singleNavigation, webView === self.webView { timeline.observe(.redirect, at: .now) }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        recordOriginalFailureAfterClose(error as NSError, navigation: navigation, in: webView)
        if retiring { recordRetirement("provisional-failure-" + String((error as NSError).code)) }
        if retiring, webView === self.webView, let navigation, navigation === retirementNavigation {
            retirementNavigation = nil
            retryRetirementReplacement(in: webView)
        }
        if ownsFailure(navigation, error: error) {
            recordFailure(error as NSError, observesTimeline: webView === self.webView)
            close()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        recordOriginalFailureAfterClose(error as NSError, navigation: navigation, in: webView)
        if retiring { recordRetirement("navigation-failure-" + String((error as NSError).code)) }
        if retiring, webView === self.webView, let navigation, navigation === retirementNavigation {
            retirementNavigation = nil
            retryRetirementReplacement(in: webView)
        }
        if ownsFailure(navigation, error: error) {
            recordFailure(error as NSError, observesTimeline: webView === self.webView)
            close()
        }
    }

    private func ownsFailure(_ navigation: WKNavigation?, error: Error) -> Bool {
        let failure = error as NSError
        guard !retiring, !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled),
              let navigation else { return false }
        return navigation === currentNavigation
    }

    private func isOriginalAfterClose(_ navigation: WKNavigation?, in view: WKWebView) -> Bool {
        retiring && view === webView && navigation != nil && navigation === originalNavigation
    }

    private func recordOriginalAfterClose(_ milestone: AccessTestNodeTimeline.Milestone, navigation: WKNavigation?,
                                          in view: WKWebView) {
        guard isOriginalAfterClose(navigation, in: view), timeline.instant(milestone) == nil else { return }
        if milestone == .documentFinish, timeline.instant(.documentCommit) == nil,
           originalNavigationAfterClose.instant(.documentCommit) == nil { return }
        originalNavigationAfterClose.record(milestone)
    }

    private func recordOriginalFailureAfterClose(_ error: NSError, navigation: WKNavigation?, in view: WKWebView) {
        guard isOriginalAfterClose(navigation, in: view) else { return }
        let now = ContinuousClock.now
        originalNavigationAfterClose.record(.navigationFailure, at: now)
        originalNavigationAfterClose.observe(.failure(domain: error.domain, code: error.code), at: now)
    }

    private func recordFailure(_ error: NSError, observesTimeline: Bool = true) {
        failureDomain = error.domain
        failureCode = error.code
        guard observesTimeline else { return }
        let now = ContinuousClock.now
        timeline.record(timeline.instant(.loadIssued) == nil ? .preparationFailure : .navigationFailure, at: now)
        if singleNavigation { timeline.observe(.failure(domain: error.domain, code: error.code), at: now) }
    }

    private func recordPolicyRejection(_ reason: String, in view: WKWebView) {
        localPolicyRejection = reason
        guard view === webView else { return }
        let now = ContinuousClock.now
        timeline.record(.policyRejection, at: now)
        if singleNavigation { timeline.observe(.policyRejection(reason), at: now) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        recordRetirement("web-content-process-terminated")
        // Termination is an error, never a successful document-retirement ack.
        // A fresh inert replacement must still commit before the port is freed.
        if !retiring {
            recordFailure(NSError(domain: WKError.errorDomain, code: WKError.Code.webContentProcessTerminated.rawValue))
            close()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, !retiring {
            httpStatus = (response.response as? HTTPURLResponse)?.statusCode
            let initial = !observedMainFrameResponse && serverRedirectCount == 0
            if webView === self.webView, let httpStatus {
                let now = ContinuousClock.now
                if firstVisibleHTTPStatus == nil {
                    firstVisibleHTTPStatus = httpStatus
                    timeline.record(.firstVisibleHTTPResponse, at: now)
                }
                if singleNavigation { timeline.observe(.http(status: httpStatus, initial: initial), at: now) }
            }
            if initial { initialHTTPStatus = httpStatus }
            observedMainFrameResponse = true
            if !response.canShowMIMEType {
                recordPolicyRejection("unsupported-mime-type", in: webView)
            }
        }
        decisionHandler(response.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if retiring {
            let replacement = action.request.url == retirementURL
            recordRetirement(replacement ? "replacement-policy-allowed" : "other-policy-denied")
            if !replacement {
                let kind = action.request.url?.scheme == "about" ? "about" :
                    action.request.url?.scheme == "https" ? "https" : "other"
                let frame = action.targetFrame?.isMainFrame == true ? "main" : "sub-or-new"
                recordRetirement("denied-" + kind + "-" + frame)
            }
            decisionHandler(replacement ? .allow : .cancel)
            if !replacement, action.targetFrame?.isMainFrame == true {
                retryRetirementReplacement(in: webView)
            }
        } else {
            if singleNavigation, action.targetFrame?.isMainFrame == true {
                // HTTP redirects are presented as .other before WebKit reports the
                // redirect callback. Let the initial provisional load continue;
                // document scripts cannot execute until its first commit. Once it
                // commits, all further top-level actions are separate navigations.
                let initialRedirect = !committedMainFrame && action.navigationType == .other
                guard !sentMainFrame || initialRedirect else {
                    recordPolicyRejection("additional-top-level-navigation", in: webView)
                    decisionHandler(.cancel)
                    failureDomain = "AdditionalTopLevelNavigation"
                    failureCode = 1
                    close()
                    return
                }
                sentMainFrame = true
            }
            let scheme = action.request.url?.scheme
            let allowed = scheme == "https" && !action.shouldPerformDownload
            if !allowed, action.targetFrame?.isMainFrame == true {
                recordPolicyRejection(action.shouldPerformDownload ? "download-navigation" : "non-https-navigation",
                                      in: webView)
            }
            if allowed, action.targetFrame?.isMainFrame == true {
                let continuesProvisional = !committedMainFrame && action.navigationType == .other
                if sawMainFrameAction && !continuesProvisional {
                    // Policy precedes didStart. Ignore the old navigation even if
                    // its cancellation is delivered before the new didStart.
                    currentNavigation = nil
                    committedMainFrame = false
                }
                sawMainFrameAction = true
            }
            decisionHandler(allowed ? .allow : .cancel)
        }
    }
}
