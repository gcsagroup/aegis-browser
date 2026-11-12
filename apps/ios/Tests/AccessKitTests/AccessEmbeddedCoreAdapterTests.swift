import XCTest
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
        let count = 24
        let parked = expectation(description: "all native reads parked concurrently")
        parked.expectedFulfillmentCount = count
        let native = BlockingNativeCore(onRead: { parked.fulfill() })
        let core = AccessGoEmbeddedCore(native: native)
        defer { native.stop() } // Also releases parked work on an assertion failure.
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
        XCTAssertEqual(native.snapshot.timedOut, 0)
        XCTAssertFalse(core.isRunning)
    }

    func testNativeReadErrorAndEmptyEOFPropagateThroughDispatch() async throws {
        let native = BlockingNativeCore(onRead: {})
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

/// Synchronous condition waits deliberately model conn.Read, with bounded
/// fallback solely to prevent a broken scheduler from hanging the test process.
private final class BlockingNativeCore: AccessGoNativeCore, @unchecked Sendable {
    struct State {
        var running = false
        var nextID: Int64 = 0
        var pending = 0
        var finished = 0
        var writes = 0
        var timedOut = 0
        var closes: [Int64: Int] = [:]
    }
    private let condition = NSCondition()
    private var state = State()
    private let onRead: @Sendable () -> Void
    init(onRead: @escaping @Sendable () -> Void) { self.onRead = onRead }
    var snapshot: State { condition.lock(); defer { condition.unlock() }; return state }
    var isRunning: Bool { snapshot.running }
    func start(_ json: String) { condition.lock(); state.running = true; condition.unlock() }
    func dial(host: String, port: UInt16) throws -> Int64 {
        condition.lock(); defer { condition.unlock() }
        guard state.running else { throw AccessEmbeddedCoreError.unverifiedAsset }
        state.nextID += 1
        return state.nextID
    }
    func read(_ id: Int64, maxBytes: Int) throws -> Data? {
        guard maxBytes > 0 else { throw AccessEmbeddedCoreError.unverifiedAsset }
        condition.lock(); defer { condition.unlock() }
        state.pending += 1
        onRead()
        let deadline = Date().addingTimeInterval(10)
        while state.running && state.closes[id] == nil {
            if !condition.wait(until: deadline) { state.timedOut += 1; break }
        }
        state.pending -= 1
        state.finished += 1
        return Data()
    }
    func write(_ id: Int64, data: Data) throws {
        condition.lock(); defer { condition.unlock() }
        guard state.running else { throw AccessEmbeddedCoreError.unverifiedAsset }
        state.writes += 1
    }
    func close(_ id: Int64) {
        condition.lock()
        state.closes[id, default: 0] += 1
        condition.broadcast()
        condition.unlock()
    }
    func stop() {
        condition.lock(); state.running = false; condition.broadcast(); condition.unlock()
    }
}
