import Foundation
import Network
import Synchronization

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
    private let gate = Mutex(State())

    private struct State {
        var listener: NWListener?
        var acceptedConnections: UInt64 = 0
        var establishedConnects: UInt64 = 0
        var openConnections: [NWConnection] = []
        var sessions: [ObjectIdentifier: AccessHTTPConnectSession] = [:]
    }

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
        gate.withLock { $0.listener != nil }
    }

    public var acceptedConnectionCount: UInt64 {
        gate.withLock { $0.acceptedConnections }
    }

    public var establishedConnectCount: UInt64 {
        gate.withLock { $0.establishedConnects }
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

    public func start(at now: Date = Date()) async throws {
        let registration = plan.registration
        guard registration.isActive(at: now, observedGeneration: registration.generation) else {
            throw AccessHTTPSInboundError.leaseInactive
        }
        if gate.withLock({ $0.listener != nil }) {
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

        do {
            try await AccessNWListenerBootstrap.awaitReady(nwListener, on: queue)
        } catch AccessNWListenerBootstrap.Failure.timedOut {
            nwListener.cancel()
            throw AccessHTTPSInboundError.bindFailed("listener start timed out")
        } catch AccessNWListenerBootstrap.Failure.failed(let message) {
            nwListener.cancel()
            throw AccessHTTPSInboundError.bindFailed(message)
        } catch is CancellationError {
            nwListener.cancel()
            throw AccessHTTPSInboundError.bindFailed("listener start cancelled")
        }

        let installed = gate.withLock { state -> Bool in
            if state.listener != nil { return false }
            state.listener = nwListener
            return true
        }
        if !installed {
            nwListener.cancel()
            throw AccessHTTPSInboundError.alreadyListening
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
            throw AccessHTTPSInboundError.notListening
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

        let session = AccessHTTPConnectSession(connection: connection, queue: queue) { [weak self] outcome in
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
