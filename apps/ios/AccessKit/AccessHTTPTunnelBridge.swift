import Foundation
import Network

/// Opens the outbound stream for one admitted CONNECT target.
public protocol AccessHTTPTunnelOpening: AnyObject, Sendable {
    func open(host: String, port: UInt16) async throws -> any AccessRealityPathStream
}

/// Moves bytes after `200 Connection Established`. One 32 KiB chunk is in flight
/// on each direction. EOF, cancellation, and write failure close both sides.
public final class AccessHTTPTunnelBridge: @unchecked Sendable {
    public static let chunkSize = 32 * 1024

    private let client: NWConnection
    private let queue: DispatchQueue
    private let opener: AccessHTTPTunnelOpening
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var remote: (any AccessRealityPathStream)?
    private var stopped = false

    public init(
        client: NWConnection,
        queue: DispatchQueue,
        opener: AccessHTTPTunnelOpening
    ) {
        self.client = client
        self.queue = queue
        self.opener = opener
    }

    public func start(host: String, port: UInt16, prelude: Data) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let remote = try await self.opener.open(host: host, port: port)
                guard self.storeRemote(remote) else {
                    remote.close()
                    return
                }
                if !prelude.isEmpty {
                    try await remote.write(prelude)
                }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.pumpClient(to: remote) }
                    group.addTask { await self.pumpRemote(remote) }
                }
            } catch {
                self.stop()
            }
        }
    }

    public func stop() {
        let (remote, task) = takeStopState()
        remote?.close()
        client.cancel()
        task?.cancel()
    }

    private func storeRemote(_ stream: any AccessRealityPathStream) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stopped { return false }
        remote = stream
        return true
    }

    private func takeStopState() -> ((any AccessRealityPathStream)?, Task<Void, Never>?) {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        return (remote, task)
    }

    private func pumpClient(to remote: any AccessRealityPathStream) async {
        while !Task.isCancelled {
            do {
                guard let chunk = try await receiveClient() else {
                    remote.close()
                    client.cancel()
                    return
                }
                if chunk.isEmpty { continue }
                try await remote.write(chunk)
            } catch {
                remote.close()
                client.cancel()
                return
            }
        }
    }

    private func pumpRemote(_ remote: any AccessRealityPathStream) async {
        while !Task.isCancelled {
            do {
                guard let chunk = try await remote.read(maxBytes: Self.chunkSize) else {
                    remote.close()
                    client.cancel()
                    return
                }
                try await sendClient(chunk)
            } catch {
                remote.close()
                client.cancel()
                return
            }
        }
    }

    private func receiveClient() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            self.queue.async {
                self.client.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                        return
                    }
                    continuation.resume(returning: isComplete ? nil : Data())
                }
            }
        }
    }

    private func sendClient(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.queue.async {
                self.client.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        }
    }
}

/// In-memory stream for tunnel tests. `close` wakes a pending read or write.
public final class AccessMemoryRealityStream: AccessRealityPathStream, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound = Data()
    private var closed = false
    private var readers: [CheckedContinuation<Data?, Error>] = []
    private var writeGate: CheckedContinuation<Void, Error>?
    public var writeDelay: Duration = .zero
    public var failNextWrite = false
    public private(set) var written = Data()

    public var writtenSnapshot: Data {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    public init() {}

    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    public func read(maxBytes: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            if let immediate = self.beginRead(maxBytes: maxBytes, continuation: continuation) {
                continuation.resume(returning: immediate)
            }
        }
    }

    public func write(_ data: Data) async throws {
        if writeDelay > .zero {
            try await Task.sleep(for: writeDelay)
        }
        try acceptWrite(data)
    }

    public func close() {
        let (pendingReaders, pendingWrite) = closeLocked()
        pendingReaders.forEach { $0.resume(returning: nil) }
        pendingWrite?.resume(throwing: CancellationError())
    }

    public func push(_ data: Data) {
        if let reader = deliver(data) {
            reader.resume(returning: data.isEmpty ? nil : data)
        }
    }

    /// `nil` means the read is parked. `.some(nil)` is EOF.
    private func beginRead(maxBytes: Int, continuation: CheckedContinuation<Data?, Error>) -> Data?? {
        lock.lock()
        defer { lock.unlock() }
        if closed, inbound.isEmpty { return .some(nil) }
        if !inbound.isEmpty {
            let count = min(maxBytes, inbound.count)
            let chunk = Data(inbound.prefix(count))
            inbound.removeFirst(count)
            return .some(chunk)
        }
        readers.append(continuation)
        return nil
    }

    private func acceptWrite(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        if closed || failNextWrite {
            failNextWrite = false
            throw CancellationError()
        }
        written.append(data)
    }

    private func closeLocked() -> ([CheckedContinuation<Data?, Error>], CheckedContinuation<Void, Error>?) {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        let pending = readers
        readers.removeAll()
        let write = writeGate
        writeGate = nil
        return (pending, write)
    }

    private func deliver(_ data: Data) -> CheckedContinuation<Data?, Error>? {
        lock.lock()
        defer { lock.unlock() }
        if closed {
            return readers.isEmpty ? nil : readers.removeFirst()
        }
        if !readers.isEmpty {
            return readers.removeFirst()
        }
        inbound.append(data)
        return nil
    }
}
