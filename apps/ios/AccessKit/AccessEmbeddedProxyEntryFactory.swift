import Foundation
import Network
import Synchronization

/// Builds the product proxy entry publisher.
///
/// Stay fail-closed unless: lock is `verified_build`, the thin
/// `AegisEmbeddedCore` module is linked, a local Reality Vision config is
/// present, and loopback CONNECT can start. Digests alone never dial.
@MainActor
public enum AccessEmbeddedProxyEntryFactory {
    public static let lockResourceName = "embedded-core-lock"
    public static let lockResourceExtension = "json"

    /// Default product publisher. Falls back to fail-closed when any gate fails.
    public static func makeProductPublisher(
        lockData: Data? = nil,
        configPath: String? = AccessLocalV2RayConfigLoader.productPath(),
        verifiedCore: (any AccessEmbeddedCoreControlling)? = nil
    ) -> any AccessProxyEntryPublishing {
        do {
            let data = try lockData ?? loadBundledLockData()
            let manifest = try AccessEmbeddedCoreManifest.load(from: data)
            guard manifest.mayLink else {
                return AccessFailClosedProxyEntryPublisher()
            }
            let core: any AccessEmbeddedCoreControlling
            if let verifiedCore {
                core = verifiedCore
            } else {
                core = try AccessGoEmbeddedCore()
            }
            let adapter = AccessEmbeddedCoreAdapter(manifest: manifest, verifiedCore: core)
            guard adapter.mayDial else {
                return AccessFailClosedProxyEntryPublisher()
            }
            guard let configPath else {
                return AccessFailClosedProxyEntryPublisher()
            }
            let local = try AccessLocalV2RayConfigLoader.load(path: configPath)
            let outbound = try AccessRealityVisionOutboundConfigBuilder.build(parameters: local.parameters)
            let session = AccessEmbeddedProxyEntrySession(core: core, outbound: outbound)
            return AccessProxyEntryPublisher(
                provision: { generation, deadline in
                    try await session.provision(generation: generation, deadline: deadline)
                },
                shutdown: { identity in
                    session.shutdown(identity: identity)
                },
                healthCheck: {
                    session.isRuntimeHealthy
                }
            )
        } catch {
            return AccessFailClosedProxyEntryPublisher()
        }
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
    private let outbound: AccessRealityVisionOutboundConfig
    private var listener: AccessHTTPInboundListener?
    private var identity: String?
    private var startedCore = false
    private var pendingStop: Task<Void, Never>?
    private var logCapture: AccessDiagnosticLog.Capture?

    init(core: any AccessEmbeddedCoreControlling, outbound: AccessRealityVisionOutboundConfig) {
        self.core = core
        self.outbound = outbound
    }

    func provision(generation: UInt64, deadline: Duration) async throws -> AccessProxyEntryPublisher.Provision {
        _ = deadline
        // Synchronous publisher shutdown retains its teardown barrier. A new
        // generation must not observe the old core as running and reuse it.
        if let pendingStop {
            await pendingStop.value
            self.pendingStop = nil
        }
        try Task.checkCancellation()
        if let listener, let identity, listener.isListening, core.isRunning {
            return AccessProxyEntryPublisher.Provision(
                endpoint: AccessManagedProxyEndpoint(
                    identity: identity,
                    generation: generation,
                    loopbackHost: AccessEndpoint.loopbackHost,
                    port: listener.registration.endpoint.port,
                    state: .ready
                ),
                listenerReady: true,
                runtimeHealthy: true,
                bridgeInstalled: true
            )
        }

        if !core.isRunning {
            do {
                logCapture = try await Self.startCoreWithDiagnostics(
                    core: core, outbound: outbound, diagnostics: .shared,
                    level: AccessDiagnosticLog.selectedLevel()
                )
            } catch {
                if let logCapture { AccessDiagnosticLog.shared.stop(capture: logCapture) }
                logCapture = nil
                throw AccessSiteSessionError.prepareFailed("core.start: \(error)")
            }
            startedCore = true
        }
        guard core.isRunning else {
            throw AccessSiteSessionError.runtimeNotReady
        }

        let port: UInt16
        do {
            port = try await Self.reserveLoopbackPort()
        } catch let error as AccessSiteSessionError {
            throw error
        } catch {
            throw AccessSiteSessionError.prepareFailed("port.reserve: \(error)")
        }

        let registration: AccessRegistration
        do {
            registration = try AccessRegistration(
                id: try AccessRegistrationID("embedded-entry-\(generation)-\(port)"),
                owner: try AccessOwner(channel: 1, profile: "ordinary", partition: "default"),
                transport: .http,
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
        let next: AccessHTTPInboundListener
        do {
            next = try AccessHTTPInboundListener(registration: registration, tunnels: opener)
            try await next.start(at: Date())
        } catch {
            throw AccessSiteSessionError.prepareFailed("listener.start: \(error)")
        }
        let entryIdentity = "embedded-\(registration.id.rawValue)"
        listener = next
        identity = entryIdentity
        return AccessProxyEntryPublisher.Provision(
            endpoint: AccessManagedProxyEndpoint(
                identity: entryIdentity,
                generation: generation,
                loopbackHost: AccessEndpoint.loopbackHost,
                port: port,
                state: .ready
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
        level: AccessLogLevel
    ) async throws -> AccessDiagnosticLog.Capture? {
        let parameters = outbound.parameters
        let capture = try? diagnostics.start(
            level: level, secrets: [parameters.userID, parameters.publicKey, parameters.shortID]
        )
        if level != .none && capture == nil { diagnostics.markUnavailable() }
        do {
            let config = try outbound.embeddedInstanceJSONData(
                logLevel: capture == nil ? .none : level,
                errorLogPath: capture?.path, includeAccessLog: true
            )
            try await core.start(configData: config)
            return capture
        } catch {
            if let capture { diagnostics.stop(capture: capture) }
            let text = (error as NSError).localizedDescription
            let loggerFailure = text.contains("failed to initialize access logger") ||
                text.contains("failed to initialize error logger")
            guard capture != nil, !core.isRunning, loggerFailure else { throw error }
            diagnostics.markUnavailable()
            try await core.start(configData: outbound.embeddedInstanceJSONData())
            return nil
        }
    }

    var isRuntimeHealthy: Bool {
        guard let listener, identity != nil else { return false }
        return listener.isListening && core.isRunning
    }

    func shutdown(identity: String) {
        guard self.identity == identity else { return }
        if let listener {
            try? listener.stop()
        }
        listener = nil
        self.identity = nil
        if startedCore {
            startedCore = false
            let capture = logCapture
            logCapture = nil
            // Publisher shutdown is synchronous; stop the core without blocking callers.
            pendingStop = Task {
                await core.stop()
                if let capture { AccessDiagnosticLog.shared.stop(capture: capture) }
            }
        }
    }

    /// Reserves an ephemeral loopback port via NWListener, then cancels it.
    /// Uses async continuation + task-group timeout — no semaphore / NSLock.
    private static func reserveLoopbackPort() async throws -> UInt16 {
        try await withThrowingTaskGroup(of: UInt16.self) { group in
            group.addTask {
                try await Self.awaitEphemeralLoopbackPort()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw AccessSiteSessionError.prepareFailed("port reserve timed out")
            }
            guard let port = try await group.next() else {
                throw AccessSiteSessionError.prepareFailed("port reserve returned no value")
            }
            group.cancelAll()
            return port
        }
    }

    private static func awaitEphemeralLoopbackPort() async throws -> UInt16 {
        // Prefer `NWListener(using:on:)` for ephemeral bind. Setting
        // `requiredLocalEndpoint` to `port: .any` with reuse can return EINVAL
        // on some simulator runtimes.
        let nwListener: NWListener
        do {
            nwListener = try NWListener(using: .tcp, on: .any)
        } catch {
            throw AccessSiteSessionError.prepareFailed(String(describing: error))
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resume = OncePortResume(continuation)
                // Required before start on current Network.framework — missing handler
                // surfaces as POSIX EINVAL on some simulator runtimes.
                nwListener.newConnectionHandler = { connection in
                    connection.cancel()
                }
                nwListener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let port = nwListener.port?.rawValue, port > 0 {
                            resume.finish(returning: port)
                        } else {
                            resume.finish(
                                throwing: AccessSiteSessionError.prepareFailed(
                                    "port.reserve: listener ready without port"
                                )
                            )
                        }
                        nwListener.cancel()
                    case .failed(let error):
                        resume.finish(
                            throwing: AccessSiteSessionError.prepareFailed(
                                "port.reserve: \(error)"
                            )
                        )
                        nwListener.cancel()
                    case .cancelled:
                        // Success path also cancels; OncePortResume ignores the second finish.
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
private final class OncePortResume: Sendable {
    private let state: Mutex<CheckedContinuation<UInt16, Error>?>

    init(_ continuation: CheckedContinuation<UInt16, Error>) {
        state = Mutex(continuation)
    }

    func finish(returning port: UInt16) {
        take()?.resume(returning: port)
    }

    func finish(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<UInt16, Error>? {
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
