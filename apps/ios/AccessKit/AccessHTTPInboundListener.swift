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

    private struct State {
        var admissionSummary = ""
        var listener: NWListener?
        /// Set when NWListener reports `.failed` after the initial ready handshake.
        var listenerFailed = false
        var acceptedConnections: UInt64 = 0
        var establishedConnects: UInt64 = 0
        var openConnections: [NWConnection] = []
        var sessions: [ObjectIdentifier: AccessHTTPConnectSession] = [:]
        var bridges: [ObjectIdentifier: AccessHTTPTunnelBridge] = [:]
    }

    public init(registration: AccessRegistration, tunnels: any AccessHTTPTunnelOpening) throws {
        guard registration.transport == .http else {
            throw AccessHTTPInboundError.transportNotHTTP(registration.transport)
        }
        self.registration = registration
        self.tunnels = tunnels
        self.queue = DispatchQueue(label: "accesskit.http.inbound.\(registration.id.rawValue)")
    }

    public var isListening: Bool {
        gate.withLock { state in
            state.listener != nil && state.listenerFailed == false
        }
    }

    public var acceptedConnectionCount: UInt64 {
        gate.withLock { $0.acceptedConnections }
    }

    public var establishedConnectCount: UInt64 {
        gate.withLock { $0.establishedConnects }
    }

    public var admissionSummary: String {
        gate.withLock { $0.admissionSummary }
    }

    /// Starts listening on the registration endpoint when the lease is active.
    public func start(at now: Date = Date()) async throws {
        guard registration.isActive(at: now, observedGeneration: registration.generation) else {
            throw AccessHTTPInboundError.leaseInactive
        }
        if gate.withLock({ $0.listener != nil }) {
            throw AccessHTTPInboundError.alreadyListening
        }

        let host = registration.endpoint.host
        guard AccessEndpoint.isLoopbackHost(host) else {
            throw AccessHTTPInboundError.bindFailed("non-loopback host \(host)")
        }
        guard let nwPort = NWEndpoint.Port(rawValue: registration.endpoint.port) else {
            throw AccessHTTPInboundError.bindFailed("invalid port")
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: nwPort
        )

        let nwListener: NWListener
        do {
            nwListener = try NWListener(using: parameters)
        } catch {
            throw AccessHTTPInboundError.bindFailed(String(describing: error))
        }

        nwListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        do {
            try await AccessNWListenerBootstrap.awaitReady(nwListener, on: queue)
        } catch AccessNWListenerBootstrap.Failure.timedOut {
            nwListener.cancel()
            throw AccessHTTPInboundError.bindFailed("listener start timed out")
        } catch AccessNWListenerBootstrap.Failure.failed(let message) {
            nwListener.cancel()
            throw AccessHTTPInboundError.bindFailed(message)
        } catch is CancellationError {
            nwListener.cancel()
            throw AccessHTTPInboundError.bindFailed("listener start cancelled")
        }

        let installed = gate.withLock { state -> Bool in
            if state.listener != nil { return false }
            state.listener = nwListener
            state.listenerFailed = false
            return true
        }
        if !installed {
            nwListener.cancel()
            throw AccessHTTPInboundError.alreadyListening
        }
        // Keep observing after the bootstrap handshake so a later `.failed`
        // clears readiness for the product health check.
        nwListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                self.gate.withLock { gateState in
                    gateState.listenerFailed = true
                }
            }
        }
    }

    /// Stops accepting and cancels open connections.
    public func stop() throws {
        let snapshot: (NWListener, [NWConnection], [AccessHTTPTunnelBridge])? = gate.withLock { state in
            guard let active = state.listener else { return nil }
            state.listener = nil
            state.listenerFailed = false
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

    private func accept(_ connection: NWConnection) {
        gate.withLock { state in
            state.acceptedConnections &+= 1
            state.openConnections.append(connection)
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                let bridge: AccessHTTPTunnelBridge? = self.gate.withLock { gateState in
                    gateState.openConnections.removeAll { $0 === connection }
                    gateState.sessions.removeValue(forKey: ObjectIdentifier(connection))
                    return gateState.bridges.removeValue(forKey: ObjectIdentifier(connection))
                }
                bridge?.stop()
            default:
                break
            }
        }
        connection.start(queue: queue)

        let session = AccessHTTPConnectSession(connection: connection, queue: queue) { [weak self] outcome in
            guard let self else { return }
            guard case let .established(request, remainder) = outcome else {
                self.gate.withLock { $0.admissionSummary = "rejected" }
                return
            }
            self.gate.withLock {
                $0.admissionSummary = "established \(request.authority) remainder \(remainder.count)"
            }
            let bridge = AccessHTTPTunnelBridge(client: connection, queue: self.queue, opener: self.tunnels)
            self.gate.withLock { state in
                state.establishedConnects &+= 1
                state.bridges[ObjectIdentifier(connection)] = bridge
            }
            bridge.start(host: request.host, port: request.port, prelude: remainder)
        }
        gate.withLock { $0.sessions[ObjectIdentifier(connection)] = session }
        session.start()
    }
}
