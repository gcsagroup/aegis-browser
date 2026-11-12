import Foundation
import Network

/// Drives one inbound TCP connection through CONNECT admission.
///
/// On success it writes `200 Connection Established` and keeps the socket open
/// as a tunnel endpoint. It does **not** dial the target directly — outbound
/// through `reality_vision` is F11.
public final class AccessHTTPConnectSession: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case established(AccessHTTPConnectRequest, Data)
        case rejected(AccessHTTPConnectError)
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var lateBytes = Data()
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
        if finished {
            if let data, !data.isEmpty { lateBytes.append(data) }
            return
        }
        if error != nil {
            finish(.rejected(.incompleteRequest))
            connection.cancel()
            return
        }
        if let data, !data.isEmpty {
            buffer.append(data)
        }
        do {
            if let (request, remainder) = try AccessHTTPConnectParser.split(buffer: buffer) {
                writeSuccess(for: request, remainder: remainder)
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

    private func writeSuccess(for request: AccessHTTPConnectRequest, remainder: Data) {
        finished = true
        let response = AccessHTTPConnectParser.successResponse(httpVersion: request.httpVersion)
        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if error != nil {
                    self.onOutcome(.rejected(.responseWriteFailed))
                    self.connection.cancel()
                    return
                }
                var payload = remainder
                payload.append(self.lateBytes)
                self.lateBytes.removeAll()
                self.onOutcome(.established(request, payload))
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
