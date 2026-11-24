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
    }

    private struct State {
        var charged = 0
        var reserved = 0
        var reason: Stop?
    }

    private let state = Mutex(State())
    let started: ContinuousClock.Instant
    let deadline: ContinuousClock.Instant
    let byteLimit: Int

    init(duration: Duration, bytes: Int, started: ContinuousClock.Instant = .now) {
        precondition(duration > .zero && bytes > 0)
        self.started = started
        self.deadline = started.advanced(by: duration)
        self.byteLimit = bytes
    }

    var bytes: (charged: Int, reserved: Int) { state.withLock { ($0.charged, $0.reserved) } }

    func stopReason(at now: ContinuousClock.Instant = .now) -> Stop? {
        state.withLock {
            if $0.reason == nil, now >= deadline { $0.reason = .timeLimit }
            return $0.reason
        }
    }

    func stop(_ reason: Stop) {
        state.withLock { if $0.reason == nil { $0.reason = .now >= deadline ? .timeLimit : reason } }
    }

    func reserve(_ count: Int, wholeChunk: Bool, at now: ContinuousClock.Instant = .now) throws -> Int {
        precondition(count > 0)
        return try state.withLock {
            if $0.reason == nil, now >= deadline { $0.reason = .timeLimit }
            if let reason = $0.reason { throw reason }
            let remaining = byteLimit - $0.charged - $0.reserved
            guard remaining > 0, !wholeChunk || remaining >= count else {
                // Pending reads own part of the envelope. Stop conservatively
                // rather than evict a reservation or overdraw the shared cap.
                $0.reason = .byteLimit
                throw Stop.byteLimit
            }
            let granted = min(remaining, count)
            $0.reserved += granted
            return granted
        }
    }

    func settle(_ reservation: Int, bytes: Int, at now: ContinuousClock.Instant = .now) {
        state.withLock {
            precondition(reservation <= $0.reserved && bytes >= 0)
            $0.reserved -= reservation
            $0.charged += min(bytes, reservation)
            if $0.reason == nil, now >= deadline { $0.reason = .timeLimit }
            if bytes > reservation {
                $0.reason = $0.reason ?? .meteringFailure
            } else if $0.charged == byteLimit {
                $0.reason = $0.reason ?? .byteLimit
            }
        }
    }
}

final class AccessCampaignMeteredCore: AccessEmbeddedCoreControlling, Sendable {
    private let base: any AccessEmbeddedCoreControlling
    private let budget: AccessCampaignBudget
    init(base: any AccessEmbeddedCoreControlling, budget: AccessCampaignBudget) {
        self.base = base
        self.budget = budget
    }

    var isRunning: Bool { base.isRunning }

    func start(configData: Data) async throws {
        if let reason = budget.stopReason() { throw reason }
        try await base.start(configData: configData)
    }

    func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        if let reason = budget.stopReason() { throw reason }
        let stream = try await base.dial(host: host, port: port)
        if let reason = budget.stopReason() {
            stream.close()
            throw reason
        }
        return MeteredStream(base: stream, budget: budget)
    }

    func stop() async { await base.stop() }

    private final class MeteredStream: AccessRealityPathStream, Sendable {
        let base: any AccessRealityPathStream
        let budget: AccessCampaignBudget

        init(base: any AccessRealityPathStream, budget: AccessCampaignBudget) {
            self.base = base
            self.budget = budget
        }

        var isOpen: Bool { base.isOpen && budget.stopReason() == nil }

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

struct AccessCampaignTimeoutStreak {
    private(set) var count = 0

    mutating func observe(navigationIssued: Bool, timedOut: Bool, sawHTTP: Bool) -> Bool {
        count = navigationIssued && timedOut && !sawHTTP ? count + 1 : 0
        return count >= 3
    }
}

final class AccessCampaignBudgetTests: XCTestCase {
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
}
