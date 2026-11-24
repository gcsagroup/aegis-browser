import Foundation
import Network
import Synchronization

/// Loopback-only cleartext HTTP inbound listener bound to one registration.
///
/// F3+F4 scope:
/// - Admit only `AccessInboundTransport.http`
/// - Bind exclusively to the registration's loopback endpoint
/// - Refuse start when the lease is inactive
/// - Accept TCP connections and complete HTTP CONNECT admission
///
/// Out of scope: HTTPS TLS front (F5), REALITY / Xray dial (F11), and
/// ProxyConfiguration application (F9).
public final class AccessHTTPInboundListener: @unchecked Sendable {
    public let registration: AccessRegistration

    private let queue: DispatchQueue
    private let gate = Mutex(State())
    private let tunnels: any AccessHTTPTunnelOpening
    private let maximumConnections: Int
    private let preparedSocket: NWListener?
    private let now: @Sendable () -> Date

    private struct State {
        var admissionSummary = ""
        var listener: NWListener?
        var starting = false
        /// Set when NWListener reports `.failed` after the initial ready handshake.
        var listenerFailed = false
        var suspended = false
        var admissionOpen = false
        var leaseDeadline: ContinuousClock.Instant?
        var expiry: Task<Void, Never>?
        var acceptedConnections: UInt64 = 0
        var establishedConnects: UInt64 = 0
        var openConnections: [NWConnection] = []
        var sessions: [ObjectIdentifier: AccessHTTPConnectSession] = [:]
        var bridges: [ObjectIdentifier: AccessHTTPTunnelBridge] = [:]
    }

    public convenience init(registration: AccessRegistration, tunnels: any AccessHTTPTunnelOpening, maximumConnections: Int = 128) throws {
        try self.init(registration: registration, tunnels: tunnels, maximumConnections: maximumConnections, preparedSocket: nil)
    }

    convenience init(registration: AccessRegistration, preparedSocket: NWListener, tunnels: any AccessHTTPTunnelOpening, maximumConnections: Int = 128) throws {
        try self.init(registration: registration, tunnels: tunnels, maximumConnections: maximumConnections, preparedSocket: preparedSocket)
    }

    init(registration: AccessRegistration, tunnels: any AccessHTTPTunnelOpening, maximumConnections: Int,
         preparedSocket: NWListener?, now: @escaping @Sendable () -> Date = { .now }) throws {
        guard registration.transport == .http else {
            throw AccessHTTPInboundError.transportNotHTTP(registration.transport)
        }
        self.registration = registration
        self.tunnels = tunnels
        self.maximumConnections = max(1, maximumConnections)
        self.preparedSocket = preparedSocket
        self.now = now
        self.queue = DispatchQueue(label: "accesskit.http.inbound.\(registration.id.rawValue)")
    }

    public var isListening: Bool {
        gate.withLock { state in
            state.listener != nil && state.listenerFailed == false
        }
    }

    var isAccepting: Bool {
        guard let listener = gate.withLock({ $0.listener }) else { return false }
        return admitsTraffic(from: listener)
    }

    // Only the publisher opens a prepared socket after a live waiter claims it.
    func activate() -> Bool {
        gate.withLock { state in
            guard state.listener != nil, !state.listenerFailed, !state.suspended,
                  leaseIsActive(until: state.leaseDeadline) else { return false }
            state.admissionOpen = true
            return true
        }
    }

    private func leaseIsActive(until deadline: ContinuousClock.Instant?) -> Bool {
        guard let deadline, ContinuousClock.now < deadline else { return false }
        return registration.isActive(at: now(), observedGeneration: registration.generation)
    }

    private func admitsTraffic(from listener: NWListener) -> Bool {
        let (admitted, expired) = gate.withLock { state -> (Bool, Bool) in
            guard state.listener === listener else { return (false, false) }
            let expired = !leaseIsActive(until: state.leaseDeadline)
            return (!expired && !state.listenerFailed && !state.suspended && state.admissionOpen, expired)
        }
        if expired { suspend(from: listener) }
        return admitted
    }

    var listenerStateObserverForTests: (@Sendable (NWListener.State) -> Void)? {
        gate.withLock { $0.listener?.stateUpdateHandler }
    }

    public var boundPort: UInt16? { gate.withLock { $0.listener?.port?.rawValue } }
    var boundSocketForTests: NWListener? { gate.withLock { $0.listener } }

    public var acceptedConnectionCount: UInt64 {
        gate.withLock { $0.acceptedConnections }
    }

    public var establishedConnectCount: UInt64 {
        gate.withLock { $0.establishedConnects }
    }

    public var admissionSummary: String {
        gate.withLock { $0.admissionSummary }
    }

    // Used by churn tests to verify ownership, independently of allocator caching.
    var retainedResourceCounts: (connections: Int, sessions: Int, bridges: Int) {
        gate.withLock { ($0.openConnections.count, $0.sessions.count, $0.bridges.count) }
    }

    var acceptedConnectionObserverForTests: (@Sendable (NWConnection) -> Void)?

    /// Starts listening on the registration endpoint when the lease is active.
    public func start(at now: Date = Date()) async throws {
        try await start(at: now, accepting: true)
    }

    func start(at now: Date, accepting: Bool) async throws {
        let leaseTime = self.now()
        let remaining = registration.leaseExpiry.timeIntervalSince(leaseTime)
        guard remaining.isFinite, remaining < Double(Int64.max),
              registration.isActive(at: now, observedGeneration: registration.generation),
              registration.isActive(at: leaseTime, observedGeneration: registration.generation) else {
            throw AccessHTTPInboundError.leaseInactive
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(remaining))
        let mayStart = gate.withLock { state in
            guard state.listener == nil, !state.starting, !state.suspended else { return false }
            state.starting = true
            return true
        }
        guard mayStart else {
            throw AccessHTTPInboundError.alreadyListening
        }
        defer { gate.withLock { $0.starting = false } }

        let host = registration.endpoint.host
        guard AccessEndpoint.isLoopbackHost(host) else {
            throw AccessHTTPInboundError.bindFailed("non-loopback host \(host)")
        }
        guard let nwPort = NWEndpoint.Port(rawValue: registration.endpoint.port) else {
            throw AccessHTTPInboundError.bindFailed("invalid port")
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: nwPort
        )

        let nwListener: NWListener
        if let preparedSocket { nwListener = preparedSocket }
        else {
            do { nwListener = try NWListener(using: parameters) }
            catch { throw AccessHTTPInboundError.bindFailed(String(describing: error)) }
        }
        if preparedSocket != nil, nwListener.port?.rawValue != registration.endpoint.port {
            nwListener.cancel()
            throw AccessHTTPInboundError.bindFailed("prepared port differs from registration")
        }

        nwListener.newConnectionHandler = { [weak self, weak nwListener] connection in
            guard let self, let nwListener else { connection.cancel(); return }
            self.accept(connection, from: nwListener)
        }

        let installed = gate.withLock { state -> Bool in
            if state.listener != nil { return false }
            state.listener = nwListener
            state.admissionOpen = accepting
            state.leaseDeadline = deadline
            state.listenerFailed = true // Not healthy until the ready event is observed.
            return true
        }
        if !installed {
            nwListener.cancel()
            throw AccessHTTPInboundError.alreadyListening
        }
        do {
            try await AccessNWListenerBootstrap.awaitReady(nwListener, on: queue, alreadyStarted: preparedSocket != nil) { [weak self, weak nwListener] state in
                guard let self, let nwListener else { return }
                self.gate.withLock { current in
                    guard current.listener === nwListener else { return }
                    switch state {
                    case .ready: current.listenerFailed = false
                    case .failed, .cancelled: current.listenerFailed = true
                    default: break
                    }
                }
            }
        } catch {
            gate.withLock { state in
                if state.listener === nwListener { state.listener = nil }
            }
            nwListener.cancel()
            if case AccessNWListenerBootstrap.Failure.timedOut = error {
                throw AccessHTTPInboundError.bindFailed("listener start timed out")
            }
            if case AccessNWListenerBootstrap.Failure.failed(let message) = error {
                throw AccessHTTPInboundError.bindFailed(message)
            }
            throw AccessHTTPInboundError.bindFailed("listener start cancelled")
        }
        guard nwListener.port?.rawValue == registration.endpoint.port else {
            gate.withLock { if $0.listener === nwListener { $0.listener = nil } }
            nwListener.cancel()
            throw AccessHTTPInboundError.bindFailed("listener port differs from admitted registration")
        }
        let scheduled = gate.withLock { state in
            guard state.listener === nwListener, !state.suspended, leaseIsActive(until: deadline) else { return false }
            state.expiry = Task { [weak self, weak nwListener] in
                do { try await ContinuousClock().sleep(until: deadline) }
                catch { return }
                guard let nwListener, !Task.isCancelled else { return }
                self?.suspend(from: nwListener)
            }
            return true
        }
        guard scheduled else {
            try? stop()
            throw AccessHTTPInboundError.leaseInactive
        }
    }

    /// Revoke traffic while retaining ownership of the port until old documents retire.
    public func suspend() {
        suspend(from: nil)
    }

    private func suspend(from listener: NWListener?) {
        let snapshot = gate.withLock { state -> ([NWConnection], [AccessHTTPTunnelBridge])? in
            if let listener, state.listener !== listener { return nil }
            state.suspended = true
            state.expiry?.cancel()
            state.expiry = nil
            let connections = state.openConnections
            let bridges = Array(state.bridges.values)
            state.openConnections.removeAll()
            state.sessions.removeAll()
            state.bridges.removeAll()
            return (connections, bridges)
        }
        guard let (connections, bridges) = snapshot else { return }
        bridges.forEach { $0.stop() }
        connections.forEach { $0.cancel() }
    }

    /// Stops accepting and cancels open connections.
    public func stop() throws {
        let snapshot: (NWListener, [NWConnection], [AccessHTTPTunnelBridge])? = gate.withLock { state in
            guard let active = state.listener else { return nil }
            state.listener = nil
            state.listenerFailed = false
            state.expiry?.cancel()
            state.expiry = nil
            let connections = state.openConnections
            state.openConnections.removeAll()
            state.sessions.removeAll()
            let bridges = Array(state.bridges.values)
            state.bridges.removeAll()
            return (active, connections, bridges)
        }
        guard let (active, connections, bridges) = snapshot else {
            throw AccessHTTPInboundError.notListening
        }
        active.cancel()
        for bridge in bridges {
            bridge.stop()
        }
        for connection in connections {
            connection.cancel()
        }
    }

    private func accept(_ connection: NWConnection, from listener: NWListener) {
        let admitted = gate.withLock { state in
            guard state.listener === listener, !state.listenerFailed, !state.suspended, state.admissionOpen,
                  leaseIsActive(until: state.leaseDeadline), state.openConnections.count < maximumConnections else { return false }
            state.acceptedConnections &+= 1
            state.openConnections.append(connection)
            return true
        }
        guard admitted else {
            _ = admitsTraffic(from: listener) // Fence expired flows even when this peer was refused.
            connection.cancel()
            return
        }
        acceptedConnectionObserverForTests?(connection)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                let bridge: AccessHTTPTunnelBridge? = self.gate.withLock { gateState in
                    gateState.openConnections.removeAll { $0 === connection }
                    gateState.sessions.removeValue(forKey: ObjectIdentifier(connection))
                    return gateState.bridges.removeValue(forKey: ObjectIdentifier(connection))
                }
                bridge?.stop()
                connection.stateUpdateHandler = nil
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)

        let session = AccessHTTPConnectSession(connection: connection, queue: queue, defersSuccessReply: true) { [weak self, weak connection, weak listener] outcome in
            guard let self, let connection, let listener else { return }
            guard case let .established(request, remainder) = outcome else {
                self.gate.withLock { $0.admissionSummary = "rejected" }
                return
            }
            guard self.admitsTraffic(from: listener) else {
                connection.cancel()
                return
            }
            let bridge = AccessHTTPTunnelBridge(client: connection, queue: self.queue, opener: self.tunnels)
            let installed = self.gate.withLock { state in
                guard state.listener === listener, state.openConnections.contains(where: { $0 === connection }) else { return false }
                state.admissionSummary = "admitted \(request.authority) remainder \(remainder.count)"
                state.sessions.removeValue(forKey: ObjectIdentifier(connection))
                state.bridges[ObjectIdentifier(connection)] = bridge
                return true
            }
            guard installed else { bridge.stop(); return }
            bridge.start(host: request.host, port: request.port, prelude: remainder,
                         successResponse: AccessHTTPConnectParser.successResponse(httpVersion: request.httpVersion),
                         mayOpen: { [weak self, weak listener] in
                             guard let self, let listener else { return false }
                             return self.admitsTraffic(from: listener)
                         }) { [weak self] in
                self?.gate.withLock { $0.establishedConnects &+= 1 }
            }
        }
        let installed = gate.withLock { state in
            guard state.listener === listener, state.openConnections.contains(where: { $0 === connection }) else { return false }
            state.sessions[ObjectIdentifier(connection)] = session
            return true
        }
        guard installed else { connection.cancel(); return }
        session.start()
    }
}
