import Foundation
import Network
import Synchronization

/// Builds the product proxy entry publisher.
///
/// Stay fail-closed unless: lock is `verified_build`, the thin
/// `AegisEmbeddedCore` module is linked, a local or account-provided Reality
/// Vision config is present, and loopback CONNECT can start. Digests alone never dial.
@MainActor
public enum AccessEmbeddedProxyEntryFactory {
    public static let lockResourceName = "embedded-core-lock"
    public static let lockResourceExtension = "json"

    /// Default product publisher. Falls back to fail-closed when any gate fails.
    public static func makeProductPublisher(
        lockData: Data? = nil,
        configPath: String? = AccessLocalV2RayConfigLoader.productPath(),
        verifiedCore: (any AccessEmbeddedCoreControlling)? = nil,
        parameters: (@MainActor () async throws -> AccessRealityVisionParameters)? = nil,
        connectionAllowed: (@MainActor () -> Bool)? = nil,
        retireDocuments: (@MainActor (String, @escaping @MainActor () -> Void) -> Void)? = nil,
        transport: AccessInboundTransport = .http
    ) -> any AccessProxyEntryPublishing {
        do {
            guard let retireDocuments else {
                return AccessFailClosedProxyEntryPublisher()
            }
            let core = try validatedCore(lockData: lockData, supplied: verifiedCore, transport: transport)
            let session: AccessEmbeddedProxyEntrySession
            if let parameters {
                session = AccessEmbeddedProxyEntrySession(core: core, parameters: parameters, retireDocuments: retireDocuments, transport: transport)
            } else {
                guard let configPath else { return AccessFailClosedProxyEntryPublisher() }
                let local = try AccessLocalV2RayConfigLoader.load(path: configPath)
                let outbound = try AccessRealityVisionOutboundConfigBuilder.build(parameters: local.parameters)
                session = AccessEmbeddedProxyEntrySession(core: core, outbound: outbound, transport: transport, retireDocuments: retireDocuments)
            }
            return publisher(for: session, connectionAllowed: connectionAllowed)
        } catch {
            return AccessFailClosedProxyEntryPublisher()
        }
    }

    /// Used by the existing native test Profile after its channel and revision checks.
    public static func makeInternalTestPublisher(
        lockData: Data? = nil,
        verifiedCore: any AccessEmbeddedCoreControlling,
        node: @escaping @MainActor () async throws -> AccessInternalTestNode,
        connectionAllowed: @escaping @MainActor () -> Bool,
        retireDocuments: @escaping @MainActor (String, @escaping @MainActor () -> Void) -> Void,
        transport: AccessInboundTransport
    ) -> any AccessProxyEntryPublishing {
        do {
            let core = try validatedCore(lockData: lockData, supplied: verifiedCore, transport: transport)
            return publisher(for: AccessEmbeddedProxyEntrySession(core: core, internalNode: node,
                retireDocuments: retireDocuments, transport: transport), connectionAllowed: connectionAllowed)
        } catch {
            return AccessFailClosedProxyEntryPublisher()
        }
    }

    private static func validatedCore(
        lockData: Data?, supplied: (any AccessEmbeddedCoreControlling)?, transport: AccessInboundTransport
    ) throws -> any AccessEmbeddedCoreControlling {
        guard transport == .http || transport == .socks5 else { throw AccessSiteSessionError.runtimeNotReady }
        let manifest = try AccessEmbeddedCoreManifest.load(from: lockData ?? loadBundledLockData())
        guard manifest.mayLink else { throw AccessSiteSessionError.runtimeNotReady }
        let core = try supplied ?? AccessGoEmbeddedCore()
        guard AccessEmbeddedCoreAdapter(manifest: manifest, verifiedCore: core).mayDial else {
            throw AccessSiteSessionError.runtimeNotReady
        }
        return core
    }

    private static func publisher(
        for session: AccessEmbeddedProxyEntrySession, connectionAllowed: (@MainActor () -> Bool)?
    ) -> AccessProxyEntryPublisher {
        AccessProxyEntryPublisher(
            provision: { generation, deadline in
                try await session.provision(generation: generation, deadline: deadline)
            },
            shutdown: { identity in
                session.shutdown(identity: identity)
            },
            activate: {
                (connectionAllowed?() ?? true) && session.activate()
            },
            healthCheck: {
                session.isRuntimeHealthy && (connectionAllowed?() ?? true)
            }
        )
    }

    public static func loadBundledLockData(
        bundle: Bundle = Bundle(for: AccessEmbeddedCoreAdapter.self)
    ) throws -> Data {
        guard let url = bundle.url(
            forResource: lockResourceName,
            withExtension: lockResourceExtension
        ) else {
            throw AccessEmbeddedCoreError.invalidLock
        }
        return try Data(contentsOf: url)
    }
}

/// Owns one running embedded core + loopback CONNECT listener for the shared entry.
@MainActor
final class AccessEmbeddedProxyEntrySession {
    private let core: any AccessEmbeddedCoreControlling
    private enum Outbound {
        case realityVision(AccessRealityVisionOutboundConfig)
        case vlessWebSocketTLS(AccessVLESSWebSocketTLSParameters)
    }

    private let loadOutbound: @MainActor () async throws -> Outbound
    private var listener: AccessEmbeddedInboundListener?
    private let transport: AccessInboundTransport
    private var identity: String?
    private var published = false
    private var startedCore = false
    private var provisioning = false
    private var pendingStop: Task<Void, Never>?
    private var logLease: AccessDiagnosticLog.Lease?
    private let retireDocuments: @MainActor (String, @escaping @MainActor () -> Void) -> Void
    private let reserveSocket: @MainActor () async throws -> NWListener

    init(core: any AccessEmbeddedCoreControlling, outbound: AccessRealityVisionOutboundConfig,
         transport: AccessInboundTransport = .http,
         retireDocuments: @escaping @MainActor (String, @escaping @MainActor () -> Void) -> Void) {
        self.core = core
        self.transport = transport
        self.retireDocuments = retireDocuments
        self.loadOutbound = { .realityVision(outbound) }
        self.reserveSocket = { try await Self.reserveLoopbackSocket() }
    }

    init(core: any AccessEmbeddedCoreControlling,
         parameters: @escaping @MainActor () async throws -> AccessRealityVisionParameters,
         retireDocuments: @escaping @MainActor (String, @escaping @MainActor () -> Void) -> Void,
         transport: AccessInboundTransport = .http,
         reserveSocket: @escaping @MainActor () async throws -> NWListener = {
             try await AccessEmbeddedProxyEntrySession.reserveLoopbackSocket()
         }) {
        self.core = core
        self.transport = transport
        self.loadOutbound = { .realityVision(try AccessRealityVisionOutboundConfigBuilder.build(parameters: await parameters())) }
        self.retireDocuments = retireDocuments
        self.reserveSocket = reserveSocket
    }

    init(core: any AccessEmbeddedCoreControlling,
         internalNode: @escaping @MainActor () async throws -> AccessInternalTestNode,
         retireDocuments: @escaping @MainActor (String, @escaping @MainActor () -> Void) -> Void,
         transport: AccessInboundTransport,
         reserveSocket: @escaping @MainActor () async throws -> NWListener = {
             try await AccessEmbeddedProxyEntrySession.reserveLoopbackSocket()
         }) {
        self.core = core
        self.transport = transport
        self.retireDocuments = retireDocuments
        self.reserveSocket = reserveSocket
        self.loadOutbound = {
            switch try await internalNode() {
            case .realityVision(let parameters):
                return .realityVision(try AccessRealityVisionOutboundConfigBuilder.build(parameters: parameters))
            case .vlessWebSocketTLS(let parameters):
                return .vlessWebSocketTLS(parameters)
            }
        }
    }

    func provision(generation: UInt64, deadline: Duration) async throws -> AccessProxyEntryPublisher.Provision {
        _ = deadline
        guard !provisioning else { throw AccessSiteSessionError.runtimeNotReady }
        provisioning = true
        defer { provisioning = false }
        do {
            return try await provisionOwned(generation: generation)
        } catch {
            await stopUnpublished()
            throw error
        }
    }

    private func provisionOwned(generation: UInt64) async throws -> AccessProxyEntryPublisher.Provision {
        // Synchronous publisher shutdown retains its teardown barrier. A new
        // generation must not observe the old core as running and reuse it.
        if let pendingStop {
            await pendingStop.value
        }
        try Task.checkCancellation()
        if let listener, let identity {
            // Preserve an unhealthy listener's ownership until the publisher
            // fences it and hands it to the document retirement path.
            guard startedCore, listener.isAccepting, let actualPort = listener.boundPort,
                  actualPort != 0, core.isRunning else {
                throw AccessSiteSessionError.runtimeNotReady
            }
            return AccessProxyEntryPublisher.Provision(
                endpoint: AccessManagedProxyEndpoint(
                    identity: identity,
                    generation: generation,
                    loopbackHost: AccessEndpoint.loopbackHost,
                    port: actualPort,
                    state: .ready,
                    transport: transport
                ),
                listenerReady: true,
                runtimeHealthy: true,
                bridgeInstalled: true
            )
        }

        // A session must own the core it will drain before releasing its port.
        if !startedCore {
            guard !core.isRunning else { throw AccessSiteSessionError.runtimeNotReady }
            // Fetch account-selected credentials only when a new core generation is needed.
            // Failure propagates; never reuse a bundled static node in this path.
            let outbound = try await loadOutbound()
            try Task.checkCancellation()
            do {
                switch outbound {
                case .realityVision(let config):
                    logLease = try await Self.startCoreWithDiagnostics(
                        core: core, outbound: config, diagnostics: .shared,
                        level: AccessDiagnosticLog.selectedLevel()
                    )
                case .vlessWebSocketTLS(let parameters):
                    logLease = try await Self.startCoreWithDiagnostics(
                        core: core, diagnostics: .shared, level: AccessDiagnosticLog.selectedLevel(),
                        secrets: parameters.diagnosticSecrets
                    ) { lease in
                        guard let lease else { return try parameters.embeddedInstanceJSONData() }
                        return try parameters.embeddedInstanceJSONData(
                            logLevel: lease.level, errorLogPath: lease.path,
                            logCaptureGeneration: lease.generation
                        )
                    }
                }
            } catch {
                throw AccessSiteSessionError.prepareFailed("core.start: \(error)")
            }
            startedCore = true
        }
        try Task.checkCancellation()
        guard core.isRunning else {
            throw AccessSiteSessionError.runtimeNotReady
        }

        let boundSocket: NWListener
        do {
            boundSocket = try await reserveSocket()
        } catch let error as AccessSiteSessionError {
            throw error
        } catch {
            throw AccessSiteSessionError.prepareFailed("port.reserve: \(error)")
        }
        var transferredSocket = false
        defer { if !transferredSocket { boundSocket.cancel() } }
        try Task.checkCancellation()
        guard let port = boundSocket.port?.rawValue, port != 0,
              transport != .socks5 || port != 1080 else {
            throw AccessSiteSessionError.runtimeNotReady
        }

        let registration: AccessRegistration
        do {
            registration = try AccessRegistration(
                id: try AccessRegistrationID("embedded-entry-\(UUID().uuidString)"),
                owner: try AccessOwner(channel: 1, profile: "ordinary", partition: "default"),
                transport: transport,
                endpoint: try AccessEndpoint(host: AccessEndpoint.loopbackHost, port: port),
                credentialSlot: try AccessCredentialSlot(id: "embedded-entry"),
                lease: try AccessLease(
                    generation: max(generation, 1),
                    expiresAt: Date().addingTimeInterval(60 * 60)
                )
            )
        } catch {
            throw AccessSiteSessionError.prepareFailed("registration: \(error)")
        }

        let opener = AccessEmbeddedTunnelOpener(dialer: AccessEmbeddedRealityDialer(core: core))
        let next: AccessEmbeddedInboundListener
        do {
            switch transport {
            case .http: next = .http(try AccessHTTPInboundListener(registration: registration, preparedSocket: boundSocket, tunnels: opener))
            case .socks5: next = .socks5(try AccessSOCKS5InboundListener(registration: registration, preparedSocket: boundSocket, tunnels: opener))
            case .https: throw AccessSiteSessionError.runtimeNotReady
            }
            try await next.startPaused(at: Date())
        } catch {
            throw AccessSiteSessionError.prepareFailed("listener.start: \(error)")
        }
        guard let actualPort = next.boundPort, actualPort == port, actualPort != 0,
              transport != .socks5 || actualPort != 1080 else {
            try? next.stop()
            throw AccessSiteSessionError.runtimeNotReady
        }
        try Task.checkCancellation()
        let entryIdentity = "embedded-\(transport.rawValue)-\(registration.id.rawValue)"
        transferredSocket = true
        listener = next
        identity = entryIdentity
        return AccessProxyEntryPublisher.Provision(
            endpoint: AccessManagedProxyEndpoint(
                identity: entryIdentity,
                generation: generation,
                loopbackHost: AccessEndpoint.loopbackHost,
                port: actualPort,
                state: .ready,
                transport: transport
            ),
            listenerReady: true,
            runtimeHealthy: true,
            bridgeInstalled: true
        )
    }

    /// Retries only a recognized Xray log-initialization failure with the same
    /// outbound and quiet logging; ordinary core failures are never hidden.
    static func startCoreWithDiagnostics(
        core: any AccessEmbeddedCoreControlling,
        outbound: AccessRealityVisionOutboundConfig,
        diagnostics: AccessDiagnosticLog,
        level: AccessLogLevel,
        disableCaptureWhenQuiet: Bool = true
    ) async throws -> AccessDiagnosticLog.Lease {
        let parameters = outbound.parameters
        return try await startCoreWithDiagnostics(
            core: core, diagnostics: diagnostics, level: level,
            secrets: [parameters.userID, parameters.publicKey, parameters.shortID],
            disableCaptureWhenQuiet: disableCaptureWhenQuiet
        ) { lease in
            guard let lease else { return try outbound.embeddedInstanceJSONData() }
            return try outbound.embeddedInstanceJSONData(
                logLevel: lease.level, errorLogPath: lease.path, includeAccessLog: true,
                logCaptureGeneration: lease.generation
            )
        }
    }

    private static func startCoreWithDiagnostics(
        core: any AccessEmbeddedCoreControlling,
        diagnostics: AccessDiagnosticLog,
        level: AccessLogLevel,
        secrets: [String],
        disableCaptureWhenQuiet: Bool = true,
        render: (AccessDiagnosticLog.Lease?) throws -> Data
    ) async throws -> AccessDiagnosticLog.Lease {
        let lease = diagnostics.acquireShared(
            level: level, secrets: secrets, disableCaptureWhenQuiet: disableCaptureWhenQuiet
        )
        var started = false
        defer { if !started { diagnostics.stop(lease: lease) } }
        do {
            try await core.start(configData: render(lease))
        } catch {
            let text = (error as NSError).localizedDescription
            let loggerFailure = text.contains("failed to initialize access logger") ||
                text.contains("failed to initialize error logger")
            guard lease.path != nil, !core.isRunning, loggerFailure else { throw error }
            diagnostics.markUnavailable()
            try await core.start(configData: render(nil))
        }
        started = true
        return lease
    }

    private func stopUnpublished() async {
        guard identity == nil, startedCore else { return }
        startedCore = false
        await core.stop()
        if let logLease { AccessDiagnosticLog.shared.stop(lease: logLease) }
        logLease = nil
    }

    var isRuntimeHealthy: Bool {
        guard startedCore, let listener, identity != nil else { return false }
        return listener.isAccepting && core.isRunning
    }

    func activate() -> Bool {
        guard startedCore, let listener, core.isRunning, listener.activate() else { return false }
        published = true
        return true
    }

    func shutdown(identity: String) {
        guard self.identity == identity else { return }
        let listener = self.listener
        listener?.suspend()
        let needsDocumentReceipt = published
        self.listener = nil
        self.identity = nil
        published = false
        let ownsCore = startedCore
        startedCore = false
        let lease = logLease
        logLease = nil

        let retirement = listener.map { AccessEmbeddedListenerRetirement(listener: $0) }
        if !needsDocumentReceipt { retirement?.received(.documents) }
        if !ownsCore {
            retirement?.received(.native)
        }
        if ownsCore {
            // Publisher shutdown is synchronous; stop the core without blocking callers.
            pendingStop = Task { @MainActor [core] in
                await core.stop()
                if let lease { AccessDiagnosticLog.shared.stop(lease: lease) }
                retirement?.received(.native)
            }
        }
        if needsDocumentReceipt {
            retireDocuments(identity) { retirement?.received(.documents) }
        }
    }

    /// The ready socket is transferred intact to the selected protocol listener.
    /// A port number obtained from a cancelled reservation is never published.
    static func reserveLoopbackSocket(on port: NWEndpoint.Port = .any) async throws -> NWListener {
        try await withThrowingTaskGroup(of: NWListener.self) { group in
            group.addTask {
                try await Self.awaitLoopbackSocket(on: port)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw AccessSiteSessionError.prepareFailed("port reserve timed out")
            }
            guard let socket = try await group.next() else {
                throw AccessSiteSessionError.prepareFailed("port reserve returned no value")
            }
            group.cancelAll()
            return socket
        }
    }

    private static func awaitLoopbackSocket(on port: NWEndpoint.Port) async throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        // The local endpoint already specifies the port. Passing a fixed
        // port again to NWListener would try to override the endpoint.
        let nwListener = try NWListener(using: parameters)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resume = OnceSocketResume(continuation)
                // Required before start on current Network.framework — missing handler
                // surfaces as POSIX EINVAL on some simulator runtimes.
                nwListener.newConnectionHandler = { connection in
                    connection.cancel()
                }
                nwListener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let port = nwListener.port?.rawValue, port > 0 {
                            nwListener.stateUpdateHandler = nil
                            resume.finish(returning: nwListener)
                        } else {
                            resume.finish(
                                throwing: AccessSiteSessionError.prepareFailed(
                                    "port.reserve: listener ready without port"
                                )
                            )
                            nwListener.cancel()
                        }
                    case .failed(let error):
                        nwListener.stateUpdateHandler = nil
                        resume.finish(throwing: error)
                        nwListener.cancel()
                    case .cancelled:
                        nwListener.stateUpdateHandler = nil
                        resume.finish(throwing: CancellationError())
                    default:
                        break
                    }
                }
                nwListener.start(queue: DispatchQueue(label: "accesskit.embedded.port.reserve"))
            }
        } onCancel: {
            nwListener.cancel()
        }
    }
}

/// One-shot continuation resume for NWListener callbacks (any queue).
///
/// `Mutex` is preferred over `NSLock` on iOS 18+/Swift 6; kept as a class so the
/// non-Copyable mutex can own the continuation.
private final class OnceSocketResume: Sendable {
    private let state: Mutex<CheckedContinuation<NWListener, Error>?>

    init(_ continuation: CheckedContinuation<NWListener, Error>) {
        state = Mutex(continuation)
    }

    func finish(returning listener: NWListener) {
        take()?.resume(returning: listener)
    }

    func finish(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<NWListener, Error>? {
        state.withLock { pending in
            let value = pending
            pending = nil
            return value
        }
    }
}

private final class AccessEmbeddedTunnelOpener: AccessHTTPTunnelOpening, @unchecked Sendable {
    private let dialer: AccessEmbeddedRealityDialer

    init(dialer: AccessEmbeddedRealityDialer) {
        self.dialer = dialer
    }

    func open(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        try await dialer.dial(host: host, port: port)
    }
}

/// Missing receipts leave the old socket fenced and held, even if the
/// publisher and session have already been released.
@MainActor
private final class AccessEmbeddedListenerRetirement {
    enum Receipt { case documents, native }

    private static var held: [ObjectIdentifier: AccessEmbeddedListenerRetirement] = [:]
    private let listener: AccessEmbeddedInboundListener
    private var pending: Set<Receipt> = [.documents, .native]

    init(listener: AccessEmbeddedInboundListener) {
        self.listener = listener
        Self.held[ObjectIdentifier(self)] = self
    }

    func received(_ receipt: Receipt) {
        guard pending.remove(receipt) != nil, pending.isEmpty else { return }
        try? listener.stop()
        Self.held.removeValue(forKey: ObjectIdentifier(self))
    }
}


private enum AccessEmbeddedInboundListener {
    case http(AccessHTTPInboundListener)
    case socks5(AccessSOCKS5InboundListener)

    var isAccepting: Bool {
        switch self { case .http(let value): value.isAccepting; case .socks5(let value): value.isAccepting }
    }
    var boundPort: UInt16? {
        switch self { case .http(let value): value.boundPort; case .socks5(let value): value.boundPort }
    }
    func startPaused(at now: Date) async throws {
        switch self {
        case .http(let value): try await value.start(at: now, accepting: false)
        case .socks5(let value): try await value.start(at: now, accepting: false)
        }
    }
    func activate() -> Bool {
        switch self { case .http(let value): value.activate(); case .socks5(let value): value.activate() }
    }
    func suspend() {
        switch self { case .http(let value): value.suspend(); case .socks5(let value): value.suspend() }
    }
    func stop() throws {
        switch self { case .http(let value): try value.stop(); case .socks5(let value): try value.stop() }
    }
}
