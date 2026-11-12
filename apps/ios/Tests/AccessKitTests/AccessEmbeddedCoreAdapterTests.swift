import XCTest
import Synchronization
import Network
@testable import AccessKit

@MainActor
final class AccessEmbeddedCoreAdapterTests: XCTestCase {
    func testFrozenLockStillNeedsInjectedCoreToDial() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EmbeddedCore/embedded-core-lock.json")
        let adapter = try AccessEmbeddedCoreAdapter(lockData: Data(contentsOf: url))
        XCTAssertTrue(adapter.manifest.mayLink)
        XCTAssertFalse(adapter.mayDial)
        XCTAssertFalse(adapter.core.isRunning)
        do {
            try await adapter.core.start(configData: Data("{}".utf8))
            XCTFail("verified digests without a linked core must not start")
        } catch AccessEmbeddedCoreError.unverifiedAsset {
        }
        let dialer = AccessEmbeddedRealityDialer(core: adapter.core)
        do {
            _ = try await dialer.dial(host: "example.invalid", port: 443)
            XCTFail("unverified dialer must not open a path")
        } catch AccessEmbeddedCoreError.unverifiedAsset {
        }
    }

    func testVerifiedManifestCanSelectInjectedCore() async throws {
        let json = """
        {"status":"verified_build","xrayCore":{"commit":"676eaf66f8f05d4d558ee7a74b4736623d3feeb9","tag":"v26.11.9"},"artifacts":{"iosArm64Sha256":"aa","iosArm64SimulatorSha256":"bb"}}
        """
        let stub = RecordingEmbeddedCore()
        let adapter = try AccessEmbeddedCoreAdapter(lockData: Data(json.utf8), verifiedCore: stub)
        XCTAssertTrue(adapter.mayDial)
        try await adapter.core.start(configData: Data("{}".utf8))
        XCTAssertTrue(stub.started)
        let stream = try await adapter.core.dial(host: "example.invalid", port: 443)
        XCTAssertTrue(stream.isOpen)
        await adapter.core.stop()
        XCTAssertFalse(stub.started)
    }
}

private final class RecordingEmbeddedCore: AccessEmbeddedCoreControlling, @unchecked Sendable {
    nonisolated(unsafe) private var running = false

    var started: Bool { running }
    var isRunning: Bool { running }

    func start(configData: Data) async throws {
        _ = configData
        running = true
    }

    func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        _ = host
        _ = port
        guard running else { throw AccessEmbeddedCoreError.unverifiedAsset }
        return AccessMemoryRealityStream()
    }

    func stop() async {
        running = false
    }
}

@MainActor
final class AccessGoSchedulingTests: XCTestCase {
    func testParkedNativeReadsAllowDuplexDialCloseAndStop() async throws {
        let count = 2048
        let parked = expectation(description: "all native reads parked concurrently")
        parked.expectedFulfillmentCount = count
        let native = ControlledAsyncNativeCore(onRead: { parked.fulfill() })
        let core = AccessGoEmbeddedCore(native: native)
        defer { native.finishAll() } // Also releases parked work on an assertion failure.
        try await core.start(configData: Data("{}".utf8))
        var streams: [any AccessRealityPathStream] = []
        var reads: [Task<Data?, Error>] = []
        for _ in 0..<count {
            let stream = try await core.dial(host: "controlled.invalid", port: 443)
            streams.append(stream)
            reads.append(Task { try await stream.read(maxBytes: 1024) })
        }
        await fulfillment(of: [parked], timeout: 3)
        XCTAssertEqual(native.snapshot.pending, count)

        // These operations must complete BEFORE any read is released.
        let progress = expectation(description: "write and dial progress beside pending reads")
        let writer = Task {
            try await streams[0].write(Data("request".utf8))
            let extra = try await core.dial(host: "other.invalid", port: 443)
            extra.close()
            progress.fulfill()
        }
        await fulfillment(of: [progress], timeout: 2)
        XCTAssertEqual(native.snapshot.pending, count)
        XCTAssertEqual(native.snapshot.writes, 1)

        // Cancelling the Swift waiter must not double-resume when native close wakes it.
        reads[0].cancel()
        streams[0].close()
        streams[0].close()
        XCTAssertFalse(streams[0].isOpen)
        let first = try await reads[0].value
        XCTAssertNil(first)
        XCTAssertEqual(native.snapshot.closes[1], 1)

        let stopped = expectation(description: "stop wakes all remaining reads")
        let stopper = Task { await core.stop(); stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 2)
        for read in reads.dropFirst() {
            let result = try await read.value
            XCTAssertNil(result)
        }
        try await writer.value
        await stopper.value
        XCTAssertEqual(native.snapshot.pending, 0)
        XCTAssertEqual(native.snapshot.finished, count)
        XCTAssertFalse(core.isRunning)
    }

    func testNativeReadErrorAndEmptyEOFPropagateThroughCallback() async throws {
        let native = ControlledAsyncNativeCore(onRead: {})
        let core = AccessGoEmbeddedCore(native: native)
        try await core.start(configData: Data("{}".utf8))
        let stream = try await core.dial(host: "controlled.invalid", port: 443)
        do {
            _ = try await stream.read(maxBytes: -1)
            XCTFail("native read error must reach caller")
        } catch AccessEmbeddedCoreError.unverifiedAsset {}
        await core.stop()
        let eof = try await stream.read(maxBytes: 1)
        XCTAssertNil(eof)
    }
}

/// Native callback contract double. Actual blocking saturation is exercised by
/// bridge_test.go with 2048 net.Pipe reads; no artificial Swift thread pool here.
private final class ControlledAsyncNativeCore: AccessGoNativeCore, Sendable {
    struct State {
        var running = false
        var nextID: Int64 = 0
        var finished = 0
        var writes = 0
        var closes: [Int64: Int] = [:]
        var reads: [Int64: CheckedContinuation<Data?, Error>] = [:]
        var pending: Int { reads.count }
    }
    private let state = Mutex(State())
    private let onRead: @Sendable () -> Void
    init(onRead: @escaping @Sendable () -> Void) { self.onRead = onRead }
    var snapshot: State { state.withLock { $0 } }
    var isRunning: Bool { snapshot.running }
    func start(_ json: String) async { state.withLock { $0.running = true } }
    func dial(host: String, port: UInt16) async throws -> Int64 {
        try state.withLock {
            guard $0.running else { throw AccessEmbeddedCoreError.unverifiedAsset }
            $0.nextID += 1; return $0.nextID
        }
    }
    func read(_ id: Int64, maxBytes: Int) async throws -> Data? {
        guard maxBytes > 0 else { throw AccessEmbeddedCoreError.unverifiedAsset }
        return try await withCheckedThrowingContinuation { continuation in
            let parked = state.withLock {
                guard $0.running, $0.closes[id] == nil else { return false }
                $0.reads[id] = continuation; return true
            }
            if parked { onRead() } else { continuation.resume(returning: Data()) }
        }
    }
    func write(_ id: Int64, data: Data) async throws {
        try state.withLock {
            guard $0.running else { throw AccessEmbeddedCoreError.unverifiedAsset }
            $0.writes += 1
        }
    }
    func close(_ id: Int64) {
        let read = state.withLock {
            $0.closes[id, default: 0] += 1
            let read = $0.reads.removeValue(forKey: id)
            if read != nil { $0.finished += 1 }
            return read
        }
        read?.resume(returning: Data())
    }
    func stop() async { finishAll() }
    func finishAll() {
        let reads = state.withLock {
            $0.running = false
            let reads = Array($0.reads.values)
            $0.reads = [:]; $0.finished += reads.count
            return reads
        }
        reads.forEach { $0.resume(returning: Data()) }
    }
}

@MainActor
final class AccessGoNativeCallbackIntegrationTests: XCTestCase {
    func testFreshNativeCallbacksSupportDuplexCancellationAndStop() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let connections = Mutex<[NWConnection]>([])
        listener.newConnectionHandler = { connection in
            connections.withLock { $0.append(connection) }
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, error in
                if let data, error == nil {
                    connection.send(content: data, completion: .contentProcessed { _ in })
                }
            }
        }
        let ready = expectation(description: "local native origin ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(listener.port?.rawValue)
        defer { listener.cancel(); connections.withLock { $0.forEach { $0.cancel() } } }
        let core = try AccessGoEmbeddedCore()
        // Test-only local outbound. Product configuration remains Reality Vision.
        let config = Data(#"{"log":{"loglevel":"none"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}"#.utf8)
        try await core.start(configData: config)
        addTeardownBlock { await core.stop() }
        let stream = try await core.dial(host: "127.0.0.1", port: port)
        let read = Task { try await stream.read(maxBytes: 1024) }
        try await stream.write(Data("callback-echo".utf8))
        let echo = try await read.value
        XCTAssertEqual(echo, Data("callback-echo".utf8))
        let cancelledRead = Task { try await stream.read(maxBytes: 1024) }
        cancelledRead.cancel()
        _ = await cancelledRead.result
        XCTAssertFalse(stream.isOpen)
        let second = try await core.dial(host: "127.0.0.1", port: port)
        let stoppedRead = Task { try await second.read(maxBytes: 1024) }
        await core.stop()
        _ = await stoppedRead.result
        XCTAssertFalse(core.isRunning)
    }
}
