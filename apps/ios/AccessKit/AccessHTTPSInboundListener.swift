import Foundation
import Network

/// Loopback HTTPS inbound TLS front bound to one registration.
///
/// F5 scope:
/// - Admit only `AccessInboundTransport.https`
/// - Require a local TLS identity label + provider
/// - Bind exclusively to the registration loopback endpoint
/// - After TLS, reuse F4 CONNECT admission
///
/// Out of scope: site MITM, REALITY dial (F11), private-browsing isolation (F13).
public final class AccessHTTPSInboundListener: @unchecked Sendable {
    public let plan: AccessHTTPSInboundFrontPlan

    private let tlsProvider: AccessHTTPSInboundTLSProviding
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var listener: NWListener?
    private var acceptedConnections: UInt64 = 0
    private var establishedConnects: UInt64 = 0
    private var openConnections: [NWConnection] = []
    private var sessions: [ObjectIdentifier: AccessHTTPConnectSession] = [:]

    public init(
        plan: AccessHTTPSInboundFrontPlan,
        tlsProvider: AccessHTTPSInboundTLSProviding
    ) {
        self.plan = plan
        self.tlsProvider = tlsProvider
        self.queue = DispatchQueue(label: "accesskit.https.inbound.\(plan.registration.id.rawValue)")
    }

    public convenience init(
        registration: AccessRegistration,
        identityLabel: String,
        tlsProvider: AccessHTTPSInboundTLSProviding
    ) throws {
        let plan = try AccessHTTPSInboundFrontBuilder.plan(
            registration: registration,
            identityLabel: identityLabel
        )
        self.init(plan: plan, tlsProvider: tlsProvider)
    }

    public var isListening: Bool {
        lock.lock(); defer { lock.unlock() }
        return listener != nil
    }

    public var acceptedConnectionCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return acceptedConnections
    }

    public var establishedConnectCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return establishedConnects
    }

    /// Builds TLS+TCP parameters for the local front (testable without bind).
    public func makeParameters() throws -> NWParameters {
        let tlsOptions: NWProtocolTLS.Options
        do {
            tlsOptions = try tlsProvider.makeServerTLSOptions(identityLabel: plan.identityLabel)
        } catch let error as AccessHTTPSInboundError {
            throw error
        } catch {
            throw AccessHTTPSInboundError.tlsIdentityUnavailable(String(describing: error))
        }
        let tcp = NWProtocolTCP.Options()
        let parameters = NWParameters(tls: tlsOptions, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        let host = plan.registration.endpoint.host
        guard AccessEndpoint.isLoopbackHost(host) else {
            throw AccessHTTPSInboundError.bindFailed("non-loopback host \(host)")
        }
        guard let nwPort = NWEndpoint.Port(rawValue: plan.registration.endpoint.port) else {
            throw AccessHTTPSInboundError.bindFailed("invalid port")
        }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: nwPort
        )
        return parameters
    }

    public func start(at now: Date = Date()) throws {
        let registration = plan.registration
        guard registration.isActive(at: now, observedGeneration: registration.generation) else {
            throw AccessHTTPSInboundError.leaseInactive
        }

        lock.lock()
        let already = listener != nil
        lock.unlock()
        if already {
            throw AccessHTTPSInboundError.alreadyListening
        }

        let parameters = try makeParameters()
        let nwListener: NWListener
        do {
            nwListener = try NWListener(using: parameters)
        } catch {
            throw AccessHTTPSInboundError.bindFailed(String(describing: error))
        }

        nwListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        let started = DispatchSemaphore(value: 0)
        let startError = AccessInboundStartErrorBox()
        nwListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                started.signal()
            case .failed(let error):
                startError.value = String(describing: error)
                started.signal()
            default:
                break
            }
        }
        nwListener.start(queue: queue)

        let waitResult = started.wait(timeout: .now() + 2.0)
        if waitResult == .timedOut {
            nwListener.cancel()
            throw AccessHTTPSInboundError.bindFailed("listener start timed out")
        }
        if let message = startError.value {
            nwListener.cancel()
            throw AccessHTTPSInboundError.bindFailed(message)
        }

        lock.lock()
        if listener != nil {
            lock.unlock()
            nwListener.cancel()
            throw AccessHTTPSInboundError.alreadyListening
        }
        listener = nwListener
        lock.unlock()
    }

    public func stop() throws {
        lock.lock()
        guard let active = listener else {
            lock.unlock()
            throw AccessHTTPSInboundError.notListening
        }
        listener = nil
        let connections = openConnections
        openConnections.removeAll()
        sessions.removeAll()
        lock.unlock()

        active.cancel()
        for connection in connections {
            connection.cancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        acceptedConnections &+= 1
        openConnections.append(connection)
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.lock.lock()
                self.openConnections.removeAll { $0 === connection }
                self.sessions.removeValue(forKey: ObjectIdentifier(connection))
                self.lock.unlock()
            default:
                break
            }
        }
        connection.start(queue: queue)

        let session = AccessHTTPConnectSession(connection: connection, queue: queue) { [weak self] outcome in
            guard let self else { return }
            self.lock.lock()
            if case .established = outcome {
                self.establishedConnects &+= 1
            }
            self.sessions.removeValue(forKey: ObjectIdentifier(connection))
            self.lock.unlock()
        }
        lock.lock()
        sessions[ObjectIdentifier(connection)] = session
        lock.unlock()
        session.start()
    }
}
