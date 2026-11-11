import Foundation
import Network

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
    private let lock = NSLock()
    private var listener: NWListener?
    private var acceptedConnections: UInt64 = 0
    private var establishedConnects: UInt64 = 0
    private var openConnections: [NWConnection] = []
    private var sessions: [ObjectIdentifier: AccessSOCKS5InboundSession] = [:]

    public init(registration: AccessRegistration) throws {
        guard registration.transport == .socks5 else {
            throw AccessSOCKS5InboundError.transportNotSOCKS5(registration.transport)
        }
        self.registration = registration
        self.queue = DispatchQueue(label: "accesskit.socks5.inbound.\(registration.id.rawValue)")
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

    public func start(at now: Date = Date()) throws {
        guard registration.isActive(at: now, observedGeneration: registration.generation) else {
            throw AccessSOCKS5InboundError.leaseInactive
        }

        lock.lock()
        let already = listener != nil
        lock.unlock()
        if already {
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
            throw AccessSOCKS5InboundError.bindFailed("listener start timed out")
        }
        if let message = startError.value {
            nwListener.cancel()
            throw AccessSOCKS5InboundError.bindFailed(message)
        }

        lock.lock()
        if listener != nil {
            lock.unlock()
            nwListener.cancel()
            throw AccessSOCKS5InboundError.alreadyListening
        }
        listener = nwListener
        lock.unlock()
    }

    public func stop() throws {
        lock.lock()
        guard let active = listener else {
            lock.unlock()
            throw AccessSOCKS5InboundError.notListening
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

        let session = AccessSOCKS5InboundSession(connection: connection, queue: queue) { [weak self] outcome in
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
