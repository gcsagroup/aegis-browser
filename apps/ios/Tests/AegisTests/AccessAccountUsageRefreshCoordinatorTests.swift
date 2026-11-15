import XCTest
@testable import Aegis

@MainActor
final class AccessAccountUsageRefreshCoordinatorTests: XCTestCase {
    func testMultipleOwnersShareFiveSecondCadenceAndClosingLastPanelRestoresBrowsing() async {
        let clock = manualClock()
        var count = 0
        let coordinator = AccessAccountUsageRefreshCoordinator(refresh: {
            count += 1
            return nil
        }, sleep: { try await clock.sleep($0) })
        let a = UUID(), b = UUID()
        coordinator.setVisible(true, owner: a)
        await drain()
        XCTAssertEqual(count, 0)
        coordinator.setActive(true)
        await assertSleep(clock, 1, .seconds(5))
        coordinator.setVisible(true, owner: b)
        coordinator.setVisible(true, owner: a)
        coordinator.setActive(true)
        coordinator.setVisible(false, owner: a)
        await drain()
        XCTAssertEqual(count, 1)
        await clock.resume(1)
        await assertSleep(clock, 2, .seconds(5))
        XCTAssertEqual(count, 2)
        coordinator.setVisible(false, owner: b)
        await assertSleep(clock, 3, .seconds(30))
        // A cancelled five-second timer may wake after the panel has closed.
        await clock.resume(2)
        await drain()
        XCTAssertEqual(count, 2)
        await clock.resume(3)
        await assertSleep(clock, 4, .seconds(30))
        XCTAssertEqual(count, 3)
        coordinator.setActive(false)
    }

    func testForegroundBrowsingPollsAndOpeningPanelRefreshesImmediately() async {
        let clock = manualClock()
        var count = 0
        let coordinator = AccessAccountUsageRefreshCoordinator(refresh: {
            count += 1
            return nil
        }, sleep: { try await clock.sleep($0) })
        coordinator.setActive(true)
        await assertSleep(clock, 1, .seconds(30))
        XCTAssertEqual(count, 1)
        await clock.resume(1)
        await assertSleep(clock, 2, .seconds(30))
        XCTAssertEqual(count, 2)
        coordinator.setVisible(true, owner: UUID())
        await assertSleep(clock, 3, .seconds(5))
        XCTAssertEqual(count, 3)
        await clock.resume(2)
        await drain()
        XCTAssertEqual(count, 3)
        coordinator.setActive(false)
    }

    func testSlowRequestCoalescesVisibleAndManualTriggersBeforeSleeping() async {
        let clock = manualClock(), request = manualClock()
        var count = 0
        var task: Task<Void, Never>?
        let coordinator = AccessAccountUsageRefreshCoordinator(refresh: {
            count += 1
            let owned = Task<Void, Never> { try? await request.sleep(.zero) }
            task = owned
            return owned
        }, sleep: { try await clock.sleep($0) })
        coordinator.setActive(true)
        await request.started(1)
        coordinator.setVisible(true, owner: UUID())
        coordinator.setVisible(true, owner: UUID())
        coordinator.refreshNow()
        coordinator.refreshNow()
        await drain()
        XCTAssertEqual(count, 1)
        let before = await clock.count
        XCTAssertEqual(before, 0)
        await request.resume(1)
        await assertSleep(clock, 1, .seconds(5))
        coordinator.setActive(false)
        XCTAssertFalse(task?.isCancelled ?? true)
        await clock.resume(1)
        await drain()
        XCTAssertEqual(count, 1)
    }

    func testBackgroundStopsObservationWithoutCancellingSessionRequest() async {
        let clock = manualClock(), request = manualClock()
        var count = 0
        var task: Task<Void, Never>?
        let coordinator = AccessAccountUsageRefreshCoordinator(refresh: {
            count += 1
            let owned = Task<Void, Never> { try? await request.sleep(.zero) }
            task = owned
            return owned
        }, sleep: { try await clock.sleep($0) })
        coordinator.setActive(true)
        await request.started(1)
        coordinator.setActive(false)
        coordinator.refreshNow()
        XCTAssertFalse(task?.isCancelled ?? true)
        await request.resume(1)
        await task?.value
        await drain()
        XCTAssertEqual(count, 1)
        let sleeps = await clock.count
        XCTAssertEqual(sleeps, 0)
        coordinator.setActive(true)
        await request.started(2)
        XCTAssertEqual(count, 2, "Foreground return must refresh immediately")
        coordinator.setActive(false)
        await request.resume(2)
        await task?.value
    }

    func testOldCancelledTimerCannotRefreshOrClearReplacementSchedule() async {
        let clock = manualClock()
        var count = 0
        let coordinator = AccessAccountUsageRefreshCoordinator(refresh: {
            count += 1
            return nil
        }, sleep: { try await clock.sleep($0) })
        coordinator.setActive(true)
        await assertSleep(clock, 1, .seconds(30))
        coordinator.setActive(false)
        coordinator.setActive(true)
        await assertSleep(clock, 2, .seconds(30))
        XCTAssertEqual(count, 2)
        // This clock deliberately ignores cancellation, delivering the old wake late.
        await clock.resume(1)
        await drain()
        coordinator.setActive(true)
        XCTAssertEqual(count, 2)
        await clock.resume(2)
        await assertSleep(clock, 3, .seconds(30))
        XCTAssertEqual(count, 3)
        coordinator.setActive(false)
        await clock.resume(3)
        await drain()
        XCTAssertEqual(count, 3)
    }

    func testManualRefreshIsImmediateDebouncedAndResetsAutomaticDeadline() async {
        let clock = manualClock()
        var now: TimeInterval = 100
        var count = 0
        let coordinator = AccessAccountUsageRefreshCoordinator(refresh: {
            count += 1
            return nil
        }, uptime: { now }, sleep: { try await clock.sleep($0) })
        coordinator.setActive(true)
        await assertSleep(clock, 1, .seconds(30))
        coordinator.refreshNow()
        await assertSleep(clock, 2, .seconds(30))
        XCTAssertEqual(count, 2)
        coordinator.refreshNow()
        now = 100.99
        coordinator.refreshNow()
        await drain()
        XCTAssertEqual(count, 2)
        now = 101
        coordinator.refreshNow()
        await assertSleep(clock, 3, .seconds(30))
        XCTAssertEqual(count, 3)
        await clock.resume(1)
        await clock.resume(2)
        await drain()
        XCTAssertEqual(count, 3)
        coordinator.setActive(false)
        now = 102
        coordinator.refreshNow()
        XCTAssertEqual(count, 3)
    }

    func testFailuresBackOffAtFifteenThenThirtySecondsAndSuccessRestoresCadence() async {
        let clock = manualClock()
        var count = 0
        var coordinator: AccessAccountUsageRefreshCoordinator!
        coordinator = AccessAccountUsageRefreshCoordinator(refresh: {
            count += 1
            let succeeded = count >= 4
            return Task { coordinator.didComplete(succeeded: succeeded) }
        }, sleep: { try await clock.sleep($0) })
        coordinator.setVisible(true, owner: UUID())
        coordinator.setActive(true)
        await assertSleep(clock, 1, .seconds(15))
        await clock.resume(1)
        await assertSleep(clock, 2, .seconds(30))
        await clock.resume(2)
        await assertSleep(clock, 3, .seconds(30))
        await clock.resume(3)
        await assertSleep(clock, 4, .seconds(5))
        XCTAssertEqual(count, 4)
        coordinator.setActive(false)
    }

    func testVisibilityChangesPreserveFailureBackoffAndIdentityResetsItAndDebounce() async {
        let clock = manualClock()
        var count = 0
        let coordinator = AccessAccountUsageRefreshCoordinator(refresh: {
            count += 1
            return nil
        }, uptime: { 100 }, sleep: { try await clock.sleep($0) })
        coordinator.setActive(true)
        await assertSleep(clock, 1, .seconds(30))
        coordinator.refreshNow()
        await assertSleep(clock, 2, .seconds(30))
        coordinator.didComplete(succeeded: false)
        await assertSleep(clock, 3, .seconds(15))
        let owner = UUID()
        coordinator.setVisible(true, owner: owner)
        await drain()
        let visibleSleeps = await clock.count
        XCTAssertEqual(visibleSleeps, 3, "Visibility must not postpone the retry deadline")
        XCTAssertEqual(count, 2, "Opening a panel must not bypass failure backoff")
        coordinator.identityDidChange()
        await assertSleep(clock, 4, .seconds(5))
        coordinator.refreshNow()
        await assertSleep(clock, 5, .seconds(5))
        XCTAssertEqual(count, 3, "Prior identity's manual debounce must not suppress a read")
        coordinator.didComplete(succeeded: false)
        await assertSleep(clock, 6, .seconds(15))
        coordinator.setVisible(false, owner: owner)
        await drain()
        let hiddenSleeps = await clock.count
        XCTAssertEqual(hiddenSleeps, 6)
        coordinator.didComplete(succeeded: true)
        await assertSleep(clock, 7, .seconds(30))
        coordinator.setActive(false)
    }

    func testSessionFailureAndAccountSwitchFenceLateResultsAndCoalesceManualReads() async throws {
        let clock = manualClock()
        let reads = UsageRefreshAccountReads()
        let keychain = AccessAccountKeychain(service: "test.usage.refresh." + UUID().uuidString)
        addTeardownBlock { try keychain.save(nil) }
        let client = try AccessAccountClient(origin: "https://account.example.test")
        let session = AccessAccountSession(client: client, keychain: keychain) { _, credential in
            try await reads.fetch(credential.token)
        }
        let coordinator = AccessAccountUsageRefreshCoordinator(refresh: { [weak session] in
            session?.refresh()
        }, sleep: { try await clock.sleep($0) })
        session.usageRefresh = coordinator
        let first = try XCTUnwrap(session.bind(accountID: "A", token: "one"))
        await reads.started("one")
        coordinator.setActive(true)
        coordinator.refreshNow()
        coordinator.refreshNow()
        let initialReads = await reads.count
        XCTAssertEqual(initialReads, 1)
        await reads.fail("one")
        await first.value
        await assertSleep(clock, 1, .seconds(15))
        XCTAssertEqual(session.state, .unavailable)
        await clock.resume(1)
        await reads.started("one")
        // The cancelled A request deliberately ignores cancellation and fails after B succeeds.
        let second = try XCTUnwrap(session.bind(accountID: "B", token: "two"))
        coordinator.refreshNow()
        await reads.started("two")
        let b = try JSONDecoder().decode(AccessAccountEntitlement.self, from: Data(
            #"{"entitlementAccountId":"B","status":"not_subscribed"}"#.utf8))
        await reads.respond("two", with: b)
        await second.value
        await assertSleep(clock, 2, .seconds(30))
        XCTAssertEqual(session.state, .ready(b))
        await reads.fail("one")
        await drain()
        XCTAssertEqual(session.state, .ready(b))
        let sleeps = await clock.count
        XCTAssertEqual(sleeps, 2, "Old identity must not replace B's successful cadence")
        let totalReads = await reads.count
        XCTAssertEqual(totalReads, 3)
        coordinator.setActive(false)
        session.signOut()
    }

    private func manualClock() -> UsageRefreshManualClock {
        let clock = UsageRefreshManualClock()
        addTeardownBlock { await clock.resumeAll() }
        return clock
    }

    private func assertSleep(_ clock: UsageRefreshManualClock, _ id: Int, _ expected: Duration,
                             file: StaticString = #filePath, line: UInt = #line) async {
        await clock.started(id)
        let interval = await clock.duration(id)
        XCTAssertEqual(interval, expected, file: file, line: line)
    }

    private func drain() async {
        // No wall-clock sleeps: let released continuations and MainActor tasks run.
        for _ in 0..<20 { await Task.yield() }
    }
}

private actor UsageRefreshManualClock {
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var durations: [Int: Duration] = [:]
    private(set) var count = 0

    func sleep(_ duration: Duration) async throws {
        count += 1
        let id = count
        durations[id] = duration
        await withCheckedContinuation { continuation in
            pending[id] = continuation
            waiters.removeValue(forKey: id)?.resume()
        }
    }

    func started(_ id: Int) async {
        if durations[id] != nil { return }
        await withCheckedContinuation { waiters[id] = $0 }
    }

    func resume(_ id: Int) { pending.removeValue(forKey: id)?.resume() }
    func duration(_ id: Int) -> Duration? { durations[id] }
    func resumeAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

private actor UsageRefreshAccountReads {
    private var reads: [String: CheckedContinuation<AccessAccountEntitlement, any Error>] = [:]
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var count = 0

    func fetch(_ token: String) async throws -> AccessAccountEntitlement {
        count += 1
        return try await withCheckedThrowingContinuation { continuation in
            reads[token] = continuation
            waiters.removeValue(forKey: token)?.resume()
        }
    }
    func started(_ token: String) async {
        if reads[token] == nil { await withCheckedContinuation { waiters[token] = $0 } }
    }
    func respond(_ token: String, with result: AccessAccountEntitlement) {
        reads.removeValue(forKey: token)?.resume(returning: result)
    }
    func fail(_ token: String) { reads.removeValue(forKey: token)?.resume(throwing: URLError(.timedOut)) }
}
