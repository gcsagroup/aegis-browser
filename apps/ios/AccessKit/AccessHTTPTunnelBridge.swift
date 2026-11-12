import Foundation
import Network
import os

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
    private let lock = OSAllocatedUnfairLock()
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

    /// Caller is the connection queue, which is where the 200 completion runs.
    public func start(host: String, port: UInt16, prelude: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, task == nil else { return }
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
                async let download: Void = self.pumpRemote(remote)
                do {
                    try await Self.forwardUpload(receive: self.receiveClient, write: remote.write)
                } catch {
                    // A failed read or write terminates both directions, like EOF.
                }
                self.stop()
                await download
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
        let active = (remote, task)
        remote = nil
        task = nil
        return active
    }

    /// Wait for the current write before requesting another client chunk.
    static func forwardUpload(
        receive: () async throws -> (Data?, Bool),
        write: (Data) async throws -> Void
    ) async throws {
        while !Task.isCancelled {
            let (data, complete) = try await receive()
            if let data, !data.isEmpty {
                try await write(data)
            }
            if complete { return }
        }
    }

    private func receiveClient() async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            client.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) { data, _, complete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, complete))
                }
            }
        }
    }

    private func pumpRemote(_ remote: any AccessRealityPathStream) async {
        while !Task.isCancelled {
            do {
                guard let chunk = try await remote.read(maxBytes: Self.chunkSize) else {
                    stop()
                    return
                }
                try await sendClient(chunk)
            } catch {
                stop()
                return
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
    private let lock = OSAllocatedUnfairLock()
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
            switch self.beginRead(maxBytes: maxBytes, continuation: continuation) {
            case nil:
                break
            case .some(let data):
                continuation.resume(returning: data)
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
