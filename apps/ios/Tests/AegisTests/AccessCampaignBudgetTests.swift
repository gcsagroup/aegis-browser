import AccessKit
import Foundation
import Synchronization
import XCTest

/// One reservation pool for both directions, every stream, and every page in the batch.
/// Bytes are charged at the embedded relay interface, including origin TLS records.
final class AccessCampaignBudget: Sendable {
    enum Stop: String, Error {
        case timeLimit = "time-limit"
        case byteLimit = "byte-limit"
        case externalStop = "external-stop"
        case meteringFailure = "metering-failure"
        case nodeRevisionChanged = "node-revision-changed"
        case transportLost = "transport-lost"
        case runPermitRequired = "run-permit-required"
        case runPermitExpired = "run-permit-expired"
        case runControlUnavailable = "run-control-unavailable"
        case dispatchLedgerFailed = "dispatch-ledger-failed"
    }

    struct Stoppage {
        let reason: Stop
        let instant: ContinuousClock.Instant
    }

    private struct RunPermit {
        let window: Duration
        var challenge = Self.newChallenge()
        var challengeIssuedAt: ContinuousClock.Instant
        var challengeDeadline: ContinuousClock.Instant
        var grantedUntil: ContinuousClock.Instant?

        static func newChallenge() -> String {
            "aegis-access-lease-v1 " + UUID().uuidString.lowercased() + "\n"
        }
    }

    private struct State {
        var charged = 0
        var reserved = 0
        var stop: Stoppage?
        var permit: RunPermit?
    }

    private let state: Mutex<State>
    let started: ContinuousClock.Instant
    let deadline: ContinuousClock.Instant
    let byteLimit: Int

    init(duration: Duration, bytes: Int, started: ContinuousClock.Instant = .now, permitWindow: Duration? = nil) {
        precondition(duration > .zero && bytes > 0)
        self.started = started
        self.deadline = started.advanced(by: duration)
        self.byteLimit = bytes
        let permit = permitWindow.map { window in
            precondition(window > .zero)
            return RunPermit(window: window, challengeIssuedAt: started, challengeDeadline: started.advanced(by: window))
        }
        self.state = Mutex(State(permit: permit))
    }

    var bytes: (charged: Int, reserved: Int) { state.withLock { ($0.charged, $0.reserved) } }

    func stopReason(at now: ContinuousClock.Instant? = nil) -> Stop? {
        stoppage(at: now)?.reason
    }

    func stoppage(at now: ContinuousClock.Instant? = nil) -> Stoppage? {
        state.withLock {
            latchDeadline(&$0, at: now ?? .now)
            return $0.stop
        }
    }

    func stop(_ reason: Stop, at instant: ContinuousClock.Instant? = nil) {
        state.withLock {
            let now = instant ?? .now
            latchDeadline(&$0, at: now)
            if $0.stop == nil { $0.stop = Stoppage(reason: reason, instant: now) }
        }
    }

    var runChallenge: String? { state.withLock { $0.permit?.challenge } }
    var runChallengeIssuedAt: ContinuousClock.Instant? { state.withLock { $0.permit?.challengeIssuedAt } }

    /// Only an echo of the current device-issued challenge can renew the grant.
    /// Its issuance time bounds delayed delivery, even after host or USB recovery.
    func observeRunControl(_ response: String?, at instant: ContinuousClock.Instant? = nil) {
        state.withLock {
            let now = instant ?? .now
            latchDeadline(&$0, at: now)
            guard $0.stop == nil, var permit = $0.permit else { return }
            if response == "stop\n" {
                $0.stop = Stoppage(reason: .externalStop, instant: now)
            } else if response == permit.challenge {
                permit.grantedUntil = permit.challengeDeadline
                permit.challenge = RunPermit.newChallenge()
                permit.challengeIssuedAt = now
                permit.challengeDeadline = now.advanced(by: permit.window)
                $0.permit = permit
            }
        }
    }

    func trafficRejection(at now: ContinuousClock.Instant? = nil) -> Stop? {
        state.withLock { trafficRejection(&$0, at: now ?? .now) }
    }

    private func trafficRejection(_ state: inout State, at now: ContinuousClock.Instant) -> Stop? {
        latchDeadline(&state, at: now)
        if let stop = state.stop { return stop.reason }
        if let permit = state.permit, permit.grantedUntil == nil { return .runPermitRequired }
        return nil
    }

    private func latchDeadline(_ state: inout State, at now: ContinuousClock.Instant) {
        guard state.stop == nil else { return }
        if let permit = state.permit {
            let expiry = permit.grantedUntil ?? permit.challengeDeadline
            if expiry < deadline, now >= expiry {
                state.stop = Stoppage(reason: .runPermitExpired, instant: expiry)
                return
            }
        }
        if now >= deadline { state.stop = Stoppage(reason: .timeLimit, instant: deadline) }
    }

    func reserve(_ count: Int, wholeChunk: Bool, at instant: ContinuousClock.Instant? = nil) throws -> Int {
        precondition(count > 0)
        return try state.withLock {
            let now = instant ?? .now
            if let reason = trafficRejection(&$0, at: now) { throw reason }
            let remaining = byteLimit - $0.charged - $0.reserved
            guard remaining > 0, !wholeChunk || remaining >= count else {
                // Pending reads own part of the envelope. Stop conservatively
                // rather than evict a reservation or overdraw the shared cap.
                $0.stop = Stoppage(reason: .byteLimit, instant: now)
                throw Stop.byteLimit
            }
            let granted = min(remaining, count)
            $0.reserved += granted
            return granted
        }
    }

    func settle(_ reservation: Int, bytes: Int, at instant: ContinuousClock.Instant? = nil) {
        state.withLock {
            let now = instant ?? .now
            precondition(reservation <= $0.reserved && bytes >= 0)
            $0.reserved -= reservation
            $0.charged += min(bytes, reservation)
            latchDeadline(&$0, at: now)
            if $0.stop == nil, bytes > reservation || $0.charged == byteLimit {
                $0.stop = Stoppage(reason: bytes > reservation ? .meteringFailure : .byteLimit, instant: now)
            }
        }
    }
}

final class AccessCampaignMeteredCore: AccessEmbeddedCoreControlling, Sendable {
    private struct Work {
        var operations = 0
        var teardownComplete = true
        var teardownFailed = false
    }

    private let base: any AccessEmbeddedCoreControlling
    private let budget: AccessCampaignBudget
    private let confirmStop: @Sendable () async -> Bool
    private let work = Mutex(Work())
    init(base: any AccessEmbeddedCoreControlling, budget: AccessCampaignBudget,
         confirmStop: (@Sendable () async -> Bool)? = nil) {
        self.base = base
        self.budget = budget
        self.confirmStop = confirmStop ?? {
            if let native = base as? AccessGoEmbeddedCore { return await native.stopAndConfirm() }
            await base.stop()
            return !base.isRunning
        }
    }

    var isRunning: Bool { base.isRunning }
    var isQuiescent: Bool {
        work.withLock { $0.teardownComplete && !$0.teardownFailed && $0.operations == 0 }
            && !base.isRunning && budget.bytes.reserved == 0
    }

    func start(configData: Data) async throws {
        if let reason = budget.trafficRejection() { throw reason }
        work.withLock {
            $0.operations += 1
            $0.teardownComplete = false
        }
        defer { work.withLock { $0.operations -= 1 } }
        do {
            try await base.start(configData: configData)
            work.withLock { $0.teardownComplete = false }
        } catch {
            if !base.isRunning { work.withLock { $0.teardownComplete = true } }
            throw error
        }
        if let reason = budget.trafficRejection() {
            await stop()
            throw reason
        }
    }

    func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        if let reason = budget.trafficRejection() { throw reason }
        work.withLock { $0.operations += 1 }
        defer { work.withLock { $0.operations -= 1 } }
        let stream = try await base.dial(host: host, port: port)
        if let reason = budget.trafficRejection() {
            stream.close()
            throw reason
        }
        return MeteredStream(base: stream, budget: budget)
    }

    func stop() async {
        work.withLock {
            $0.operations += 1
            $0.teardownComplete = false
        }
        let succeeded = await confirmStop()
        work.withLock {
            $0.teardownComplete = succeeded
            $0.teardownFailed = $0.teardownFailed || !succeeded
            $0.operations -= 1
        }
    }

    private final class MeteredStream: AccessRealityPathStream, Sendable {
        let base: any AccessRealityPathStream
        let budget: AccessCampaignBudget

        init(base: any AccessRealityPathStream, budget: AccessCampaignBudget) {
            self.base = base
            self.budget = budget
        }

        var isOpen: Bool { base.isOpen && budget.trafficRejection() == nil }

        func read(maxBytes: Int) async throws -> Data? {
            let reservation = try budget.reserve(maxBytes, wholeChunk: false)
            let data: Data?
            do {
                data = try await base.read(maxBytes: reservation)
            } catch {
                // A throwing lower layer cannot report partial I/O. Charge the
                // full reservation rather than undercount the failed transfer.
                budget.settle(reservation, bytes: reservation)
                throw error
            }
            budget.settle(reservation, bytes: data?.count ?? 0)
            if let reason = budget.stopReason() { throw reason }
            return data
        }

        func write(_ data: Data) async throws {
            guard !data.isEmpty else { return }
            let reservation = try budget.reserve(data.count, wholeChunk: true)
            defer { budget.settle(reservation, bytes: reservation) }
            try await base.write(data)
        }

        func close() { base.close() }
    }
}

struct AccessCampaignPreparationFailureStreak {
    private var count = 0

    mutating func observe(navigationIssued: Bool) -> Bool {
        count = navigationIssued ? 0 : count + 1
        return count >= 3
    }
}

struct AccessCampaignTimeoutStreak {
    private(set) var count = 0

    mutating func observe(navigationIssued: Bool, timedOut: Bool, sawHTTP: Bool) -> Bool {
        count = navigationIssued && timedOut && !sawHTTP ? count + 1 : 0
        return count >= 3
    }
}

final class AccessCampaignBudgetTests: XCTestCase {
    func testRepeatedAttemptsWithoutWebKitAcceptanceReachTheLocalFailureLimit() {
        var failures = AccessCampaignPreparationFailureStreak()
        XCTAssertFalse(failures.observe(navigationIssued: false))
        XCTAssertFalse(failures.observe(navigationIssued: false))
        XCTAssertFalse(failures.observe(navigationIssued: true))
        XCTAssertFalse(failures.observe(navigationIssued: false))
        XCTAssertFalse(failures.observe(navigationIssued: false))
        XCTAssertTrue(failures.observe(navigationIssued: false))
    }

    func testSharedReadAndWriteReservationsCannotOverdrawByteLimit() throws {
        let meter = AccessCampaignBudget(duration: .seconds(1200), bytes: 100)
        let read = try meter.reserve(60, wholeChunk: false)
        let write = try meter.reserve(25, wholeChunk: true)
        let secondRead = try meter.reserve(200, wholeChunk: false)
        XCTAssertEqual(secondRead, 15)
        meter.settle(read, bytes: 10)
        let remaining = try meter.reserve(50, wholeChunk: true)
        meter.settle(write, bytes: 25)
        meter.settle(secondRead, bytes: 15)
        XCTAssertNil(meter.stopReason())
        meter.settle(remaining, bytes: 50)
        XCTAssertEqual(meter.bytes.charged, 100)
        XCTAssertEqual(meter.stopReason(), .byteLimit)
        XCTAssertThrowsError(try meter.reserve(1, wholeChunk: false))
    }

    func testPendingReadsCannotBeOverdrawnByAnotherStreamUpload() throws {
        let meter = AccessCampaignBudget(duration: .seconds(1200), bytes: 100)
        let read = try meter.reserve(90, wholeChunk: false)
        XCTAssertThrowsError(try meter.reserve(11, wholeChunk: true)) { error in
            XCTAssertEqual(error as? AccessCampaignBudget.Stop, .byteLimit)
        }
        meter.settle(read, bytes: 30)
        XCTAssertEqual(meter.bytes.charged, 30)
        XCTAssertThrowsError(try meter.reserve(1, wholeChunk: true))
    }

    func testMonotonicDeadlineEndsBothDirectionsWhileAReadIsPending() throws {
        let start = ContinuousClock.now
        let meter = AccessCampaignBudget(duration: .seconds(1200), bytes: 100, started: start)
        let lastReservation = try meter.reserve(10, wholeChunk: false, at: meter.deadline - .milliseconds(1))
        XCTAssertEqual(meter.stopReason(at: meter.deadline), .timeLimit)
        XCTAssertThrowsError(try meter.reserve(10, wholeChunk: true, at: meter.deadline))
        XCTAssertThrowsError(try meter.reserve(10, wholeChunk: false, at: meter.deadline))
        meter.settle(lastReservation, bytes: 4)
        XCTAssertEqual(meter.bytes.charged, 4)
        XCTAssertEqual(meter.stopReason(at: meter.deadline), .timeLimit)
    }

    func testTimeLimitWinsWhenTheLastReservationSettlesAtTheDeadline() throws {
        let start = ContinuousClock.now
        let meter = AccessCampaignBudget(duration: .seconds(1), bytes: 10, started: start)
        let reservation = try meter.reserve(10, wholeChunk: true, at: start)
        meter.settle(reservation, bytes: 10, at: meter.deadline)
        XCTAssertEqual(meter.bytes.charged, 10)
        XCTAssertEqual(meter.stopReason(), .timeLimit)
    }

    func testRunPermitRequiresTheCurrentEchoAndDoesNotReopenAfterExpiry() throws {
        let start = ContinuousClock.now
        let meter = AccessCampaignBudget(duration: .seconds(45 * 60), bytes: 512 * 1024 * 1024,
                                         started: start, permitWindow: .seconds(30))
        let initial = try XCTUnwrap(meter.runChallenge)
        XCTAssertEqual(meter.runChallengeIssuedAt, start)
        meter.observeRunControl("run\n", at: start)
        meter.observeRunControl(String(initial.dropLast()), at: start)
        XCTAssertEqual(meter.trafficRejection(at: start), .runPermitRequired)
        XCTAssertThrowsError(try meter.reserve(1, wholeChunk: false, at: start))

        meter.observeRunControl(initial, at: start + .seconds(10))
        let next = try XCTUnwrap(meter.runChallenge)
        XCTAssertEqual(meter.runChallengeIssuedAt, start + .seconds(10))
        XCTAssertNotEqual(initial, next)
        XCTAssertNil(meter.trafficRejection(at: start + .seconds(20)))
        meter.observeRunControl(next, at: start + .seconds(25))
        let late = try XCTUnwrap(meter.runChallenge)
        meter.observeRunControl(next, at: start + .seconds(39))
        XCTAssertNil(meter.trafficRejection(at: start + .seconds(39)))
        meter.observeRunControl(late, at: start + .seconds(40))
        XCTAssertEqual(meter.stoppage(at: start + .seconds(50))?.instant, start + .seconds(40))
        XCTAssertEqual(meter.trafficRejection(at: start + .seconds(50)), .runPermitExpired)
        XCTAssertThrowsError(try meter.reserve(1, wholeChunk: true, at: start + .seconds(50)))
    }

    func testRunGrantCannotExtendDeadlineOrUndoStop() throws {
        let start = ContinuousClock.now
        let meter = AccessCampaignBudget(duration: .seconds(15), bytes: 12,
                                         started: start, permitWindow: .seconds(30))
        meter.observeRunControl(try XCTUnwrap(meter.runChallenge), at: start + .seconds(2))
        XCTAssertNil(meter.trafficRejection(at: start + .seconds(14)))
        XCTAssertEqual(meter.stopReason(at: start + .seconds(36)), .timeLimit)
        XCTAssertEqual(meter.stoppage(at: start + .seconds(36))?.instant, meter.deadline)

        let stopped = AccessCampaignBudget(duration: .seconds(60), bytes: 12,
                                           started: start, permitWindow: .seconds(30))
        stopped.observeRunControl("stop\n", at: start + .seconds(2))
        stopped.observeRunControl(try XCTUnwrap(stopped.runChallenge), at: start + .seconds(3))
        XCTAssertEqual(stopped.trafficRejection(at: start + .seconds(3)), .externalStop)
    }

    func testOnlyThreeConsecutiveNavigationTimeoutsWithoutHTTPStopDispatch() {
        var streak = AccessCampaignTimeoutStreak()
        XCTAssertFalse(streak.observe(navigationIssued: true, timedOut: true, sawHTTP: false))
        XCTAssertFalse(streak.observe(navigationIssued: true, timedOut: true, sawHTTP: true))
        XCTAssertEqual(streak.count, 0)
        XCTAssertFalse(streak.observe(navigationIssued: false, timedOut: true, sawHTTP: false))
        XCTAssertFalse(streak.observe(navigationIssued: true, timedOut: false, sawHTTP: false))
        XCTAssertFalse(streak.observe(navigationIssued: true, timedOut: true, sawHTTP: false))
        XCTAssertFalse(streak.observe(navigationIssued: true, timedOut: true, sawHTTP: false))
        XCTAssertTrue(streak.observe(navigationIssued: true, timedOut: true, sawHTTP: false))
    }

    func testQuiescenceRequiresAcknowledgedCoreStopAndPendingDialDrain() async throws {
        let base = GatedCampaignCore()
        let budget = AccessCampaignBudget(duration: .seconds(30), bytes: 128 * 1024)
        let core = AccessCampaignMeteredCore(base: base, budget: budget)
        try await core.start(configData: Data())
        let dialing = Task { try await core.dial(host: "owned.invalid", port: 443) }
        await base.dialGate.waitForEntry()

        budget.stop(.externalStop)
        let stopping = Task { await core.stop() }
        await base.stopGate.waitForEntry()
        XCTAssertFalse(core.isRunning)
        XCTAssertFalse(core.isQuiescent)
        await base.stopGate.finish()
        await stopping.value
        XCTAssertFalse(core.isQuiescent, "The already-issued dial has not drained")

        await base.dialGate.finish()
        do {
            _ = try await dialing.value
            XCTFail("An in-flight dial returned a stream after the grant stopped")
        } catch let stop as AccessCampaignBudget.Stop {
            XCTAssertEqual(stop, .externalStop)
        }
        XCTAssertTrue(core.isQuiescent)
    }

    func testFailedTeardownIsNotReplacedByAnIdempotentStopAcknowledgement() async throws {
        let base = GatedCampaignCore()
        let confirmations = Mutex([false, true])
        let budget = AccessCampaignBudget(duration: .seconds(30), bytes: 128 * 1024)
        let core = AccessCampaignMeteredCore(base: base, budget: budget, confirmStop: {
            await base.stop()
            return confirmations.withLock { $0.removeFirst() }
        })
        try await core.start(configData: Data())
        for _ in 0..<2 {
            let stopping = Task { await core.stop() }
            await base.stopGate.waitForEntry()
            await base.stopGate.finish()
            await stopping.value
            XCTAssertFalse(core.isRunning)
            XCTAssertFalse(core.isQuiescent)
        }
    }
}

private final class GatedCampaignCore: AccessEmbeddedCoreControlling, Sendable {
    private let running = Mutex(false)
    let dialGate = CampaignOperationGate()
    let stopGate = CampaignOperationGate()

    var isRunning: Bool { running.withLock { $0 } }
    func start(configData: Data) async throws { running.withLock { $0 = true } }
    func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        await dialGate.pause()
        return AccessMemoryRealityStream()
    }
    func stop() async {
        running.withLock { $0 = false }
        await stopGate.pause()
    }
}

private actor CampaignOperationGate {
    private var action: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation {
            action = $0
            observer?.resume()
            observer = nil
        }
    }

    func waitForEntry() async {
        if action != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func finish() {
        action?.resume()
        action = nil
    }
}
