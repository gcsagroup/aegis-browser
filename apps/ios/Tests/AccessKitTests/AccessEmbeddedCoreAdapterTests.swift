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

    func testStopJoinsAStreamCloseAlreadyRemovedFromTheNativeRegistry() async throws {
        let closing = expectation(description: "stream close is in flight outside the native registry")
        let registryStopped = expectation(description: "first native stop drained its registry")
        let nextRegistryStopped = expectation(description: "second owner stopped its native registry")
        let allowClose = DispatchSemaphore(value: 0)
        let stopped = Mutex(false)
        let native = ControlledAsyncNativeCore(onRead: {}, onClose: {
            closing.fulfill()
            _ = allowClose.wait(timeout: .now() + 5)
        }, onStop: { count in
            switch count {
            case 1: registryStopped.fulfill()
            case 2: nextRegistryStopped.fulfill()
            default: XCTFail("Unexpected native stop \(count)")
            }
        })
        let ownership = AccessGoRuntimeOwnership()
        let core = AccessGoEmbeddedCore(native: native, ownership: ownership)
        let next = AccessGoEmbeddedCore(native: native, ownership: ownership)
        defer { allowClose.signal() }
        try await core.start(configData: Data("{}".utf8))
        let stream = try await core.dial(host: "controlled.invalid", port: 443)
        // Close runs outside the caller and can take longer than the core stop receipt.
        Task.detached { stream.close() }
        await fulfillment(of: [closing], timeout: 2)
        let completion = expectation(description: "full teardown")
        let stop = Task {
            await core.stop()
            stopped.withLock { $0 = true }
            completion.fulfill()
        }
        await fulfillment(of: [registryStopped], timeout: 2)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(stopped.withLock { $0 })
        XCTAssertFalse(stream.isOpen)
        XCTAssertFalse(native.isRunning)
        do {
            try await next.start(configData: Data("next".utf8))
            XCTFail("A new adapter acquired the runtime before the previous stream drained")
        } catch AccessEmbeddedCoreError.unverifiedAsset {}
        XCTAssertEqual(native.snapshot.starts, 1)
        XCTAssertEqual(native.snapshot.stops, 1)
        allowClose.signal()
        await fulfillment(of: [completion], timeout: 2)
        await stop.value
        XCTAssertEqual(native.snapshot.closes[1], 1)
        XCTAssertEqual(native.snapshot.stops, 1)
        try await next.start(configData: Data("next".utf8))
        XCTAssertEqual(native.snapshot.starts, 2)
        await core.stop()
        XCTAssertEqual(native.snapshot.stops, 1)
        XCTAssertTrue(next.isRunning)
        let nextStream = try await next.dial(host: "controlled.invalid", port: 443)
        try await nextStream.write(Data("next".utf8))
        XCTAssertEqual(native.snapshot.writes, 1)
        await next.stop()
        await fulfillment(of: [nextRegistryStopped], timeout: 2)
        await next.stop()
        XCTAssertEqual(native.snapshot.stops, 2)
        XCTAssertFalse(nextStream.isOpen)
        XCTAssertFalse(next.isRunning)
        XCTAssertFalse(native.isRunning)
    }

    func testSharedNativeClaimSurvivesCancelAndConcurrentShutdownUntilDrain() async throws {
        let startup = AccessProvisionTestGate(entered: expectation(description: "native start entered"))
        let gate = AccessGoRuntimeOwnership()
        let native = ControlledAsyncNativeCore(onRead: {}, beforeStart: { if $0 == 1 { await startup.wait() } })
        let owner = AccessGoEmbeddedCore(native: native, ownership: gate)
        let other = AccessGoEmbeddedCore(native: native, ownership: gate)
        let start = Task { try await owner.start(configData: Data("owner".utf8)) }
        defer { startup.finish() }
        await fulfillment(of: [startup.entered], timeout: 2)
        do {
            try await other.start(configData: Data("foreign".utf8))
            XCTFail("A second adapter acquired the runtime")
        } catch AccessEmbeddedCoreError.unverifiedAsset {}
        await other.stop()
        XCTAssertEqual(native.snapshot.stops, 0)
        XCTAssertFalse(other.isRunning)
        start.cancel()
        let stopped = expectation(description: "both shutdown callers received the drain")
        let stop = Task {
            async let a: Void = owner.stop()
            async let b: Void = owner.stop()
            _ = await (a, b)
            stopped.fulfill()
        }
        await Task.yield()
        startup.finish()
        // The start either reports ownership or observes shutdown's fence.
        // Both outcomes still owe a stop for the successful native start.
        do { try await start.value } catch is CancellationError {}
        await fulfillment(of: [stopped], timeout: 2)
        await stop.value
        XCTAssertEqual(native.snapshot.starts, 1)
        XCTAssertEqual(native.snapshot.stops, 1)
        XCTAssertFalse(native.isRunning)
        try await other.start(configData: Data("foreign-after-drain".utf8))
        XCTAssertTrue(other.isRunning)
        await owner.stop()
        XCTAssertTrue(other.isRunning)
        XCTAssertEqual(native.snapshot.stops, 1)
        await other.stop()
    }

    func testRedundantStartCannotFenceCloseForAnActiveParkedStream() async throws {
        let (retry, gate) = AsyncStream<Void>.makeStream()
        let reading = expectation(description: "an owned native stream parked in read")
        let closed = expectation(description: "native close completed")
        let native = ControlledAsyncNativeCore(onRead: { reading.fulfill() }, onClose: { closed.fulfill() },
            beforeStart: { attempt in if attempt > 1 { for await _ in retry { break } } })
        let core = AccessGoEmbeddedCore(native: native)
        defer { gate.finish(); native.finishAll() }
        try await core.start(configData: Data("configured".utf8))
        let stream = try await core.dial(host: "controlled.invalid", port: 443)
        let reader = Task { try await stream.read(maxBytes: 128) }
        await fulfillment(of: [reading], timeout: 2)
        let returned = Mutex(false)
        let duplicate = Task {
            defer { returned.withLock { $0 = true } }
            try await core.start(configData: Data("redundant".utf8))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while native.snapshot.starts == 1, !returned.withLock({ $0 }), ContinuousClock.now < deadline {
            await Task.yield()
        }
        duplicate.cancel()
        reader.cancel()
        stream.close()
        await fulfillment(of: [closed], timeout: 2)
        gate.finish()
        do { try await duplicate.value; XCTFail("Redundant native start succeeded") }
        catch AccessEmbeddedCoreError.unverifiedAsset {}
        let value = try await reader.value
        XCTAssertNil(value)
        XCTAssertEqual(native.snapshot.starts, 1)
        XCTAssertEqual(native.snapshot.closes[1], 1)
        XCTAssertTrue(core.isRunning)
        await core.stop()
    }

    func testNativeTeardownAcknowledgementReportsTheNativeError() async throws {
        for shouldFail in [false, true] {
            let native = ControlledAsyncNativeCore(onRead: {}, failStop: shouldFail)
            let core = AccessGoEmbeddedCore(native: native)
            try await core.start(configData: Data("{}".utf8))
            let acknowledged = await core.stopAndConfirm()
            XCTAssertEqual(acknowledged, !shouldFail)
            XCTAssertFalse(core.isRunning)
        }
    }
}

/// Native callback contract double. Actual blocking saturation is exercised by
/// bridge_test.go with 2048 net.Pipe reads; no artificial Swift thread pool here.
private final class ControlledAsyncNativeCore: AccessGoNativeCore, Sendable {
    struct State {
        var running = false
        var nextID: Int64 = 0
        var starts = 0
        var stops = 0
        var finished = 0
        var writes = 0
        var closes: [Int64: Int] = [:]
        var reads: [Int64: CheckedContinuation<Data?, Error>] = [:]
        var pending: Int { reads.count }
    }
    private let state = Mutex(State())
    private let onRead: @Sendable () -> Void
    private let onClose: @Sendable () -> Void
    private let onStop: @Sendable (Int) -> Void
    private let beforeStart: @Sendable (Int) async -> Void
    private let failStop: Bool
    init(onRead: @escaping @Sendable () -> Void, onClose: @escaping @Sendable () -> Void = {},
         onStop: @escaping @Sendable (Int) -> Void = { _ in },
         beforeStart: @escaping @Sendable (Int) async -> Void = { _ in }, failStop: Bool = false) {
        self.onRead = onRead
        self.onClose = onClose
        self.onStop = onStop
        self.beforeStart = beforeStart
        self.failStop = failStop
    }
    var snapshot: State { state.withLock { $0 } }
    var isRunning: Bool { snapshot.running }
    func start(_ json: String) async throws {
        let attempt = state.withLock { $0.starts += 1; return $0.starts }
        await beforeStart(attempt)
        try state.withLock {
            guard !$0.running else { throw AccessEmbeddedCoreError.unverifiedAsset }
            $0.running = true
        }
    }
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
        onClose()
        read?.resume(returning: Data())
    }
    func stop() async throws {
        let count = state.withLock { $0.stops += 1; return $0.stops }
        finishAll()
        onStop(count)
        if failStop { throw AccessEmbeddedCoreError.unverifiedAsset }
    }
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
    func testTwoNativeRuntimesKeepTrafficAndSharedCaptureOpen() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let connections = Mutex<[NWConnection]>([])
        listener.newConnectionHandler = { connection in
            connections.withLock { $0.append(connection) }
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                if let data { connection.send(content: data, completion: .contentProcessed { _ in }) }
            }
        }
        let ready = expectation(description: "local diagnostic origin ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(listener.port?.rawValue)
        defer { listener.cancel(); connections.withLock { $0.forEach { $0.cancel() } } }
        let diagnostics = AccessDiagnosticLog()
        // Test-only local transport: no external target or product DIRECT fallback.
        let first = try AccessGoEmbeddedCore(isolated: true)
        let second = try AccessGoEmbeddedCore(isolated: true)
        let firstCapture = diagnostics.acquireShared(level: .info, secrets: [])
        addTeardownBlock { await first.stop(); diagnostics.stop(lease: firstCapture) }
        let path = try XCTUnwrap(firstCapture.path)
        func config(path: String, capture: AccessDiagnosticLog.Lease) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "log": ["loglevel": "info", "access": path, "error": path],
                "aegisLogCaptureGeneration": try XCTUnwrap(capture.generation),
                "inbounds": [], "outbounds": [["protocol": "freedom"]]
            ])
        }
        let oldConfig = try config(path: path, capture: firstCapture)
        try await first.start(configData: oldConfig)
        let lateCapture = diagnostics.acquireShared(level: .info, secrets: [])
        XCTAssertEqual(lateCapture.generation, firstCapture.generation)
        let late = try AccessGoEmbeddedCore(isolated: true)
        addTeardownBlock { await late.stop(); diagnostics.stop(lease: lateCapture) }
        diagnostics.disableAndClear()
        let oldWriter = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? oldWriter.close() }
        try oldWriter.write(contentsOf: Data("2026/11/20 00:00:00 from local accepted //off-period.invalid:443\n".utf8))
        let secondCapture = diagnostics.acquireShared(level: .info, secrets: [])
        addTeardownBlock { await second.stop(); diagnostics.stop(lease: secondCapture) }
        let resumedPath = try XCTUnwrap(secondCapture.path)
        XCTAssertNotEqual(path, resumedPath)
        try await second.start(configData: config(path: resumedPath, capture: secondCapture))
        try await late.start(configData: oldConfig)
        XCTAssertTrue(late.isRunning)
        await second.stop()
        XCTAssertTrue(diagnostics.stop(lease: secondCapture))
        XCTAssertTrue(first.isRunning)
        let quiet = try AccessGoEmbeddedCore(isolated: true)
        let quietLease = diagnostics.acquireShared(level: .none, secrets: [], disableCaptureWhenQuiet: false)
        addTeardownBlock { await quiet.stop(); diagnostics.stop(lease: quietLease) }
        try await quiet.start(configData: Data(#"{"log":{"loglevel":"none"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}"#.utf8))
        let previousInfoCount = diagnostics.snapshot().components(separatedBy: "[Info] details withheld").count
        let stream = try await first.dial(host: "127.0.0.1", port: port)
        defer { stream.close() }
        try await stream.write(Data("surviving-core".utf8))
        let echoed = try await stream.read(maxBytes: 1024)
        XCTAssertEqual(echoed, Data("surviving-core".utf8))
        // The pinned freedom outbound logs its local connection through Xray.
        // The production redactor retains its severity and withholds details.
        let deadline = Date().addingTimeInterval(3)
        while diagnostics.snapshot().components(separatedBy: "[Info] details withheld").count == previousInfoCount,
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let captured = diagnostics.snapshot()
        XCTAssertGreaterThan(captured.components(separatedBy: "[Info] details withheld").count, previousInfoCount)
        XCTAssertFalse(captured.contains("off-period.invalid"))
        await quiet.stop()
        XCTAssertTrue(diagnostics.stop(lease: quietLease))
        await late.stop()
        XCTAssertTrue(diagnostics.stop(lease: lateCapture))
        await first.stop()
        XCTAssertTrue(diagnostics.stop(lease: firstCapture))
    }

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
