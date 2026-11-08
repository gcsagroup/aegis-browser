import Foundation
import Network

/// Drives one inbound TCP connection through SOCKS5 no-auth + CONNECT.
///
/// On success it writes a SOCKS5 success reply and keeps the socket open as a
/// tunnel endpoint. It does **not** dial the target directly.
public final class AccessSOCKS5InboundSession: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case established(AccessSOCKS5ConnectRequest)
        case rejected(AccessSOCKS5InboundError)
    }

    private enum Phase {
        case greeting
        case request
        case done
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var phase: Phase = .greeting
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
            finish(.rejected(phase == .greeting ? .incompleteGreeting : .incompleteRequest))
            connection.cancel()
            return
        }
        if let data, !data.isEmpty {
            buffer.append(data)
        }

        do {
            switch phase {
            case .greeting:
                if let reply = try AccessSOCKS5InboundParser.parseGreeting(buffer: buffer) {
                    let consumed = 2 + Int(buffer[1])
                    buffer.removeSubrange(0..<consumed)
                    phase = .request
                    connection.send(content: reply, completion: .contentProcessed { [weak self] sendError in
                        guard let self else { return }
                        self.queue.async {
                            if sendError != nil {
                                self.finish(.rejected(.responseWriteFailed))
                                self.connection.cancel()
                                return
                            }
                            self.continueAfterGreeting(isComplete: isComplete)
                        }
                    })
                    return
                }
            case .request:
                if let (request, consumed) = try AccessSOCKS5InboundParser.parseConnectRequest(buffer: buffer) {
                    buffer.removeSubrange(0..<consumed)
                    writeSuccess(for: request)
                    return
                }
            case .done:
                return
            }
        } catch let socksError as AccessSOCKS5InboundError {
            writeFailure(socksError)
            return
        } catch {
            writeFailure(phase == .greeting ? .malformedGreeting : .malformedRequest)
            return
        }

        if isComplete {
            finish(.rejected(phase == .greeting ? .incompleteGreeting : .incompleteRequest))
            connection.cancel()
            return
        }
        receiveMore()
    }

    private func continueAfterGreeting(isComplete: Bool) {
        do {
            if let (request, consumed) = try AccessSOCKS5InboundParser.parseConnectRequest(buffer: buffer) {
                buffer.removeSubrange(0..<consumed)
                writeSuccess(for: request)
                return
            }
        } catch let socksError as AccessSOCKS5InboundError {
            writeFailure(socksError)
            return
        } catch {
            writeFailure(.malformedRequest)
            return
        }
        if isComplete {
            finish(.rejected(.incompleteRequest))
            connection.cancel()
            return
        }
        receiveMore()
    }

    private func writeSuccess(for request: AccessSOCKS5ConnectRequest) {
        let reply = AccessSOCKS5InboundParser.successReply()
        connection.send(content: reply, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if error != nil {
                    self.finish(.rejected(.responseWriteFailed))
                    self.connection.cancel()
                    return
                }
                self.phase = .done
                self.finish(.established(request))
            }
        })
    }

    private func writeFailure(_ error: AccessSOCKS5InboundError) {
        let reply: Data
        switch error {
        case .usernamePasswordNotAdmitted, .noAcceptableAuthMethod:
            reply = AccessSOCKS5InboundParser.noAcceptableMethodReply()
        case .unsupportedCommand:
            reply = AccessSOCKS5InboundParser.commandNotSupportedReply()
        default:
            reply = AccessSOCKS5InboundParser.commandNotSupportedReply()
        }
        connection.send(content: reply, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.phase = .done
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
