import Foundation
import Network
import Synchronization

/// Loopback-only SOCKS5 inbound listener (no username/password).
///
/// Scope:
/// - Admit only `AccessInboundTransport.socks5`
/// - Negotiate method `0x00` only; reject username/password-only greetings
/// - Admit CONNECT; hold the tunnel endpoint without dialing the target
///
/// Out of scope: SOCKS5 auth, BIND/UDP, macOS browser wiring, REALITY dial.
public final class AccessSOCKS5InboundListener: @unchecked Sendable {
    public let registration: AccessRegistration

    private let queue: DispatchQueue
    private let gate = Mutex(State())

    private struct State {
        var listener: NWListener?
        var acceptedConnections: UInt64 = 0
        var establishedConnects: UInt64 = 0
        var openConnections: [NWConnection] = []
        var sessions: [ObjectIdentifier: AccessSOCKS5InboundSession] = [:]
    }

    public init(registration: AccessRegistration) throws {
        guard registration.transport == .socks5 else {
            throw AccessSOCKS5InboundError.transportNotSOCKS5(registration.transport)
        }
        self.registration = registration
        self.queue = DispatchQueue(label: "accesskit.socks5.inbound.\(registration.id.rawValue)")
    }

    public var isListening: Bool {
        gate.withLock { $0.listener != nil }
    }

    public var acceptedConnectionCount: UInt64 {
        gate.withLock { $0.acceptedConnections }
    }

    public var establishedConnectCount: UInt64 {
        gate.withLock { $0.establishedConnects }
    }

    public func start(at now: Date = Date()) async throws {
        guard registration.isActive(at: now, observedGeneration: registration.generation) else {
            throw AccessSOCKS5InboundError.leaseInactive
        }
        if gate.withLock({ $0.listener != nil }) {
            throw AccessSOCKS5InboundError.alreadyListening
        }

        let host = registration.endpoint.host
        guard AccessEndpoint.isLoopbackHost(host) else {
            throw AccessSOCKS5InboundError.bindFailed("non-loopback host \(host)")
        }
        guard let nwPort = NWEndpoint.Port(rawValue: registration.endpoint.port) else {
            throw AccessSOCKS5InboundError.bindFailed("invalid port")
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
            throw AccessSOCKS5InboundError.bindFailed(String(describing: error))
        }

        nwListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        do {
            try await AccessNWListenerBootstrap.awaitReady(nwListener, on: queue)
        } catch AccessNWListenerBootstrap.Failure.timedOut {
            nwListener.cancel()
            throw AccessSOCKS5InboundError.bindFailed("listener start timed out")
        } catch AccessNWListenerBootstrap.Failure.failed(let message) {
            nwListener.cancel()
            throw AccessSOCKS5InboundError.bindFailed(message)
        } catch is CancellationError {
            nwListener.cancel()
            throw AccessSOCKS5InboundError.bindFailed("listener start cancelled")
        }

        let installed = gate.withLock { state -> Bool in
            if state.listener != nil { return false }
            state.listener = nwListener
            return true
        }
        if !installed {
            nwListener.cancel()
            throw AccessSOCKS5InboundError.alreadyListening
        }
    }

    public func stop() throws {
        let snapshot: (NWListener, [NWConnection])? = gate.withLock { state in
            guard let active = state.listener else { return nil }
            state.listener = nil
            let connections = state.openConnections
            state.openConnections.removeAll()
            state.sessions.removeAll()
            return (active, connections)
        }
        guard let (active, connections) = snapshot else {
            throw AccessSOCKS5InboundError.notListening
        }
        active.cancel()
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
                self.gate.withLock { gateState in
                    gateState.openConnections.removeAll { $0 === connection }
                    gateState.sessions.removeValue(forKey: ObjectIdentifier(connection))
                }
            default:
                break
            }
        }
        connection.start(queue: queue)

        let session = AccessSOCKS5InboundSession(connection: connection, queue: queue) { [weak self] outcome in
            guard let self else { return }
            self.gate.withLock { state in
                if case .established = outcome {
                    state.establishedConnects &+= 1
                }
                state.sessions.removeValue(forKey: ObjectIdentifier(connection))
            }
        }
        gate.withLock { $0.sessions[ObjectIdentifier(connection)] = session }
        session.start()
    }
}
