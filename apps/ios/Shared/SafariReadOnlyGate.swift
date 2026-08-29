import Foundation

enum SafariReadOnlyPhase: String, Sendable {
    case authorize
    case consume
}

struct SafariReadOnlyAuthorization: Equatable {
    let leaseID: UUID
    let extensionInstanceID: UUID
    let gestureNonce: UUID
    let documentToken: UUID
    let navigationEpoch: Int
    let profileID: String
    let tabID: Int
    let frameID: Int
    let origin: String
    let route: String
    let expiresAt: Date
}

enum SafariReadOnlyGateError: String, Error, Equatable {
    case invalidMessage = "invalid_message"
    case unsupportedRoute = "unsupported_route"
    case extensionMismatch = "extension_mismatch"
    case missingProfile = "missing_profile"
    case profileDenied = "profile_denied"
    case privateBrowsingDenied = "private_browsing_denied"
    case invalidOrigin = "invalid_origin"
    case replayedGesture = "replayed_gesture"
    case staleWorker = "stale_worker"
    case snapshotExceeded = "snapshot_exceeded"
    case invalidLease = "invalid_lease"
    case stateExceeded = "state_exceeded"
}

struct SafariReadOnlySnapshot: Sendable {
    let schemaVersion: Int
    let route: String
    let origin: String
    let documentToken: UUID
    let navigationEpoch: Int
    let title: String
    let language: String
    let headings: [String]
    let encodedByteCount: Int
}

struct SafariReadOnlyRequest: Sendable {
    private static let commonKeys: Set<String> = [
        "schemaVersion", "phase", "route", "extensionID", "extensionInstanceID",
        "gestureNonce", "documentToken", "navigationEpoch", "isPrivate", "tabID",
        "frameID", "origin",
    ]
    private static let allowedSnapshotKeys: Set<String> = [
        "schemaVersion", "route", "origin", "documentToken", "navigationEpoch",
        "title", "language", "headings",
    ]

    let schemaVersion: Int
    let phase: SafariReadOnlyPhase
    let route: String
    let extensionID: String
    let extensionInstanceID: UUID
    let gestureNonce: UUID
    let documentToken: UUID
    let navigationEpoch: Int
    let isPrivate: Bool
    let tabID: Int
    let frameID: Int
    let origin: String
    let leaseID: UUID?
    let snapshot: SafariReadOnlySnapshot?

    init(message: [String: Any]) throws {
        guard let phaseText = message["phase"] as? String,
              let phase = SafariReadOnlyPhase(rawValue: phaseText)
        else { throw SafariReadOnlyGateError.invalidMessage }

        let expectedKeys: Set<String>
        switch phase {
        case .authorize:
            expectedKeys = Self.commonKeys
        case .consume:
            expectedKeys = Self.commonKeys.union(["leaseID", "snapshot"])
        }
        guard Set(message.keys) == expectedKeys,
              let schemaVersion = message["schemaVersion"] as? Int,
              let route = message["route"] as? String,
              let extensionID = message["extensionID"] as? String,
              let instanceText = message["extensionInstanceID"] as? String,
              let extensionInstanceID = UUID(uuidString: instanceText),
              let gestureText = message["gestureNonce"] as? String,
              let gestureNonce = UUID(uuidString: gestureText),
              let documentText = message["documentToken"] as? String,
              let documentToken = UUID(uuidString: documentText),
              let navigationEpoch = message["navigationEpoch"] as? Int,
              navigationEpoch > 0,
              navigationEpoch <= 9_007_199_254_740_991,
              let isPrivate = message["isPrivate"] as? Bool,
              let tabID = message["tabID"] as? Int,
              tabID >= 0,
              let frameID = message["frameID"] as? Int,
              frameID >= 0,
              let origin = message["origin"] as? String
        else { throw SafariReadOnlyGateError.invalidMessage }

        self.schemaVersion = schemaVersion
        self.phase = phase
        self.route = route
        self.extensionID = extensionID
        self.extensionInstanceID = extensionInstanceID
        self.gestureNonce = gestureNonce
        self.documentToken = documentToken
        self.navigationEpoch = navigationEpoch
        self.isPrivate = isPrivate
        self.tabID = tabID
        self.frameID = frameID
        self.origin = origin

        switch phase {
        case .authorize:
            leaseID = nil
            snapshot = nil
        case .consume:
            guard let leaseText = message["leaseID"] as? String,
                  let parsedLeaseID = UUID(uuidString: leaseText),
                  let snapshotMessage = message["snapshot"] as? [String: Any],
                  Set(snapshotMessage.keys) == Self.allowedSnapshotKeys,
                  let snapshotVersion = snapshotMessage["schemaVersion"] as? Int,
                  let snapshotRoute = snapshotMessage["route"] as? String,
                  let snapshotOrigin = snapshotMessage["origin"] as? String,
                  let snapshotDocumentText = snapshotMessage["documentToken"] as? String,
                  let snapshotDocumentToken = UUID(uuidString: snapshotDocumentText),
                  let snapshotNavigationEpoch = snapshotMessage["navigationEpoch"] as? Int,
                  snapshotNavigationEpoch > 0,
                  snapshotNavigationEpoch <= 9_007_199_254_740_991,
                  let title = snapshotMessage["title"] as? String,
                  let language = snapshotMessage["language"] as? String,
                  let headings = snapshotMessage["headings"] as? [String],
                  let encoded = try? JSONSerialization.data(withJSONObject: snapshotMessage)
            else { throw SafariReadOnlyGateError.invalidMessage }
            leaseID = parsedLeaseID
            snapshot = SafariReadOnlySnapshot(
                schemaVersion: snapshotVersion,
                route: snapshotRoute,
                origin: snapshotOrigin,
                documentToken: snapshotDocumentToken,
                navigationEpoch: snapshotNavigationEpoch,
                title: title,
                language: language,
                headings: headings,
                encodedByteCount: encoded.count
            )
        }
    }
}

final class SafariReadOnlyGate: @unchecked Sendable {
    static let allowedRoutes: Set<String> = ["page.observe", "page.extract", "url.health"]
    static let defaultProfileID = "safari-default"

    private let expectedExtensionID: String
    private let lock = NSLock()
    private var activeWorkerByProfile: [String: UUID] = [:]
    private var retiredWorkersByProfile: [String: Set<UUID>] = [:]
    private var consumedGestureNonces: Set<UUID> = []
    private var issuedLeases: [UUID: SafariReadOnlyAuthorization] = [:]

    init(expectedExtensionID: String) {
        self.expectedExtensionID = expectedExtensionID
    }

    func authorize(
        request: SafariReadOnlyRequest,
        profileID: String?,
        now: Date = Date()
    ) throws -> SafariReadOnlyAuthorization {
        lock.lock()
        defer { lock.unlock() }
        removeExpiredLeases(now: now)
        guard request.phase == .authorize else { throw SafariReadOnlyGateError.invalidMessage }
        let profileID = try validateCommon(request: request, profileID: profileID)
        guard consumedGestureNonces.count < 4_096 else {
            throw SafariReadOnlyGateError.stateExceeded
        }
        guard !consumedGestureNonces.contains(request.gestureNonce) else {
            throw SafariReadOnlyGateError.replayedGesture
        }
        let origin = try Self.canonicalOrigin(request.origin)
        if retiredWorkersByProfile[profileID]?.contains(request.extensionInstanceID) == true {
            throw SafariReadOnlyGateError.staleWorker
        }
        if let currentWorker = activeWorkerByProfile[profileID],
           currentWorker != request.extensionInstanceID {
            // 新 service worker 接管时立即撤销旧实例的未消费租约，并永久退役旧实例。
            issuedLeases = issuedLeases.filter { $0.value.profileID != profileID }
            retiredWorkersByProfile[profileID, default: []].insert(currentWorker)
        }

        activeWorkerByProfile[profileID] = request.extensionInstanceID
        consumedGestureNonces.insert(request.gestureNonce)
        let authorization = SafariReadOnlyAuthorization(
            leaseID: UUID(),
            extensionInstanceID: request.extensionInstanceID,
            gestureNonce: request.gestureNonce,
            documentToken: request.documentToken,
            navigationEpoch: request.navigationEpoch,
            profileID: profileID,
            tabID: request.tabID,
            frameID: request.frameID,
            origin: origin,
            route: request.route,
            expiresAt: now.addingTimeInterval(15)
        )
        issuedLeases[authorization.leaseID] = authorization
        return authorization
    }

    @discardableResult
    func consume(
        request: SafariReadOnlyRequest,
        profileID: String?,
        now: Date = Date()
    ) throws -> SafariReadOnlyAuthorization {
        lock.lock()
        defer { lock.unlock() }
        guard request.phase == .consume,
              let leaseID = request.leaseID,
              let snapshot = request.snapshot,
              let lease = issuedLeases.removeValue(forKey: leaseID)
        else { throw SafariReadOnlyGateError.invalidLease }

        // 先移除后校验：任何失败的消费尝试都会烧掉该租约。
        let validatedProfileID = try validateCommon(request: request, profileID: profileID)
        let origin = try Self.canonicalOrigin(request.origin)
        guard now < lease.expiresAt,
              lease.extensionInstanceID == request.extensionInstanceID,
              lease.gestureNonce == request.gestureNonce,
              lease.documentToken == request.documentToken,
              lease.navigationEpoch == request.navigationEpoch,
              lease.profileID == validatedProfileID,
              lease.tabID == request.tabID,
              lease.frameID == request.frameID,
              lease.origin == origin,
              lease.route == request.route,
              snapshot.documentToken == lease.documentToken,
              snapshot.navigationEpoch == lease.navigationEpoch
        else { throw SafariReadOnlyGateError.invalidLease }
        try validate(snapshot: snapshot, origin: origin, route: request.route)
        return lease
    }

    private func validateCommon(request: SafariReadOnlyRequest, profileID: String?) throws -> String {
        guard request.schemaVersion == 1 else { throw SafariReadOnlyGateError.invalidMessage }
        guard Self.allowedRoutes.contains(request.route) else {
            throw SafariReadOnlyGateError.unsupportedRoute
        }
        guard request.extensionID == expectedExtensionID else {
            throw SafariReadOnlyGateError.extensionMismatch
        }
        guard !request.isPrivate else {
            throw SafariReadOnlyGateError.privateBrowsingDenied
        }
        return try Self.canonicalProfileID(profileID)
    }

    private func validate(snapshot: SafariReadOnlySnapshot, origin: String, route: String) throws {
        guard snapshot.schemaVersion == 1,
              snapshot.route == "\(route).result",
              (try? Self.canonicalOrigin(snapshot.origin)) == origin,
              snapshot.title.utf8.count <= 240,
              snapshot.language.utf8.count <= 32,
              snapshot.headings.count <= 12,
              snapshot.headings.allSatisfy({ $0.utf8.count <= 160 }),
              snapshot.encodedByteCount <= 8 * 1_024
        else { throw SafariReadOnlyGateError.snapshotExceeded }
    }

    static func canonicalProfileID(_ value: String?) throws -> String {
        guard let value, !value.isEmpty else { throw SafariReadOnlyGateError.missingProfile }
        if value == Self.defaultProfileID { return value }
        guard value == value.lowercased(),
              let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value
        else { throw SafariReadOnlyGateError.profileDenied }
        return value
    }

    private static func canonicalOrigin(_ value: String) throws -> String {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { throw SafariReadOnlyGateError.invalidOrigin }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = components.port == defaultPort ? nil : components.port
        return "\(scheme)://\(host)\(port.map { ":\($0)" } ?? "")"
    }

    private func removeExpiredLeases(now: Date) {
        issuedLeases = issuedLeases.filter { now < $0.value.expiresAt }
    }
}
