import Foundation
import Network

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
    private let lock = NSLock()
    private var listener: NWListener?
    private var acceptedConnections: UInt64 = 0
    private var establishedConnects: UInt64 = 0
    private var openConnections: [NWConnection] = []
    private var sessions: [ObjectIdentifier: AccessHTTPConnectSession] = [:]

    public init(registration: AccessRegistration) throws {
        guard registration.transport == .http else {
            throw AccessHTTPInboundError.transportNotHTTP(registration.transport)
        }
        self.registration = registration
        self.queue = DispatchQueue(label: "accesskit.http.inbound.\(registration.id.rawValue)")
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

    /// Starts listening on the registration endpoint when the lease is active.
    public func start(at now: Date = Date()) throws {
        guard registration.isActive(at: now, observedGeneration: registration.generation) else {
            throw AccessHTTPInboundError.leaseInactive
        }

        lock.lock()
        let already = listener != nil
        lock.unlock()
        if already {
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

        let started = DispatchSemaphore(value: 0)
        var startError: String?
        nwListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                started.signal()
            case .failed(let error):
                startError = String(describing: error)
                started.signal()
            default:
                break
            }
        }

        nwListener.start(queue: queue)

        let waitResult = started.wait(timeout: .now() + 2.0)
        if waitResult == .timedOut {
            nwListener.cancel()
            throw AccessHTTPInboundError.bindFailed("listener start timed out")
        }
        if let startError {
            nwListener.cancel()
            throw AccessHTTPInboundError.bindFailed(startError)
        }

        lock.lock()
        if listener != nil {
            lock.unlock()
            nwListener.cancel()
            throw AccessHTTPInboundError.alreadyListening
        }
        listener = nwListener
        lock.unlock()
    }

    /// Stops accepting and cancels open connections.
    public func stop() throws {
        lock.lock()
        guard let active = listener else {
            lock.unlock()
            throw AccessHTTPInboundError.notListening
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
