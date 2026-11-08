import Foundation
import Network

/// Drives one inbound TCP connection through CONNECT admission.
///
/// On success it writes `200 Connection Established` and keeps the socket open
/// as a tunnel endpoint. It does **not** dial the target directly — outbound
/// through `reality_vision` is F11.
public final class AccessHTTPConnectSession: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case established(AccessHTTPConnectRequest)
        case rejected(AccessHTTPConnectError)
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var finished = false
    private let onOutcome: (Outcome) -> Void

    public init(
        connection: NWConnection,
        queue: DispatchQueue,
        onOutcome: @escaping (Outcome) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.onOutcome = onOutcome
    }

    public func start() {
        receiveMore()
    }

    private func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                self.handleReceive(data: data, isComplete: isComplete, error: error)
            }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        guard !finished else { return }
        if error != nil {
            finish(.rejected(.incompleteRequest))
            connection.cancel()
            return
        }
        if let data, !data.isEmpty {
            buffer.append(data)
        }
        do {
            if let request = try AccessHTTPConnectParser.parse(buffer: buffer) {
                writeSuccess(for: request)
                return
            }
        } catch let connectError as AccessHTTPConnectError {
            writeFailure(connectError)
            return
        } catch {
            writeFailure(.malformedRequestLine)
            return
        }

        if isComplete {
            finish(.rejected(.incompleteRequest))
            connection.cancel()
            return
        }
        if buffer.count > AccessHTTPConnectParser.maxHeaderBytes {
            writeFailure(.headersTooLarge)
            return
        }
        receiveMore()
    }

    private func writeSuccess(for request: AccessHTTPConnectRequest) {
        let response = AccessHTTPConnectParser.successResponse(httpVersion: request.httpVersion)
        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if error != nil {
                    self.finish(.rejected(.responseWriteFailed))
                    self.connection.cancel()
                    return
                }
                self.finish(.established(request))
                // Tunnel endpoint held open for F11 wiring; idle cancel is the
                // caller's responsibility via listener stop / client close.
            }
        })
    }

    private func writeFailure(_ error: AccessHTTPConnectError) {
        let response: Data
        switch error {
        case .methodNotConnect:
            response = AccessHTTPConnectParser.methodNotAllowedResponse()
        default:
            response = AccessHTTPConnectParser.badRequestResponse()
        }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.finish(.rejected(error))
                self.connection.cancel()
            }
        })
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        onOutcome(outcome)
    }
}
