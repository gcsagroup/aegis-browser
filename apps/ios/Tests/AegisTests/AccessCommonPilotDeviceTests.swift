import AccessKit
import CryptoKit
import Darwin
import Foundation
import Network
import Synchronization
import UIKit
import WebKit
import XCTest
@testable import Aegis

#if DEBUG
@MainActor
final class AccessCommonPilotDeviceTests: XCTestCase {
    private static let campaignID = "common20-test01-20261121-v1"
    private static let targetsDigest = "1dea57e5de83c9181afe4a0fbec595a545b6dbc654e7f4a61d00b0115f5e1991"
    private static let nodeDigest = "64f817c06af512d2fb573c66246526a3a9227f6bf1cb2545ae3a922a9352c21e"
    private static let deviceAlias = "ios-device-2d62695fc7"
    private static let durationSeconds = 20 * 60
    private static let byteLimit = 256 * 1024 * 1024
    private static let noHTTPLimit = 3
    private static let permitWindow: Duration = .seconds(30)

    @MainActor private struct Attempt {
        let observation: AccessCampaignNavigationObservation
        let page: AccessTestNodePage
        let transport: String
        let budgetStart: ContinuousClock.Instant

        var outcome: AccessCampaignNavigationObservation.Outcome { observation.outcome }

        var fields: [String: Any] {
            var row = observation.fields
            row["actualProtocol"] = transport
            row["port"] = page.initialBinding?.port
            row["pageStartedAtNs"] = stamp(page.timeline.origin)
            row["navigationIssuedAtNs"] = page.timeline.instant(.loadIssued).map(stamp)
            row["preparationStartedAtNs"] = page.preparationStartedAt.map(stamp)
            row["preparationDeadlineAtNs"] = page.preparationDeadline.map(stamp)
            row["observationCutoffAtNs"] = stamp(observation.cutoff)
            row["observedThroughAtNs"] = stamp(observation.observedThrough)
            if let instant = observation.laterStopInstant, var late = row["observedAfterCutoff"] as? [String: Any] {
                late["stopAtNs"] = stamp(instant)
                row["observedAfterCutoff"] = late
            }
            return row
        }

        private func stamp(_ instant: ContinuousClock.Instant) -> Int64 {
            AccessCommonPilotDeviceTests.nanoseconds(budgetStart.duration(to: instant))
        }
    }

    @MainActor private struct AttemptResult {
        let attempt: Attempt
        let retired: Bool
        let quiesced: Bool
        let retirementFields: [String: Any]

        var qualifiesAsSOCKSHealth: Bool {
            let evidence = attempt.observation.evidence
            return attempt.outcome == .finished && evidence.lastHTTPStatus == 200
                && attempt.observation.navigationIssued && evidence.nanoseconds["documentCommit"] != nil
                && evidence.nanoseconds["documentFinish"] != nil
                && attempt.transport == "socks5" && retired && quiesced
        }
    }

    func testTEST01CommonFirst20() async throws {
        let input = try admittedInputs()
        guard input.environment["AEGIS_TEST_COMMON_PILOT"] == Self.campaignID else {
            throw XCTSkip("Frozen common-group pilot inputs are required")
        }
        let documents = Self.documents
        let prefix = "ios208-" + Self.campaignID
        let targets = try loadTargets(from: documents.appendingPathComponent(prefix + ".domains.txt"))
        let ledger = try DurableLedger(url: documents.appendingPathComponent(prefix + "-dispatch.jsonl"))
        let (path, monitor) = startNetworkMonitor()
        defer { monitor.cancel() }
        let networkWait = ContinuousClock.now.advanced(by: .seconds(5))
        while !path.snapshot.reported, ContinuousClock.now < networkWait {
            try await Task.sleep(for: .milliseconds(50))
        }

        let budget = AccessCampaignBudget(duration: .seconds(Self.durationSeconds), bytes: Self.byteLimit,
                                          permitWindow: Self.permitWindow)
        let window = makeWindow()
        defer { window.isHidden = true }
        let receiptIdentity = [
            "campaignID": Self.campaignID, "sourceSHA": input.source, "device": Self.deviceAlias,
            "nodeInputSHA256": Self.nodeDigest, "targetsSHA256": Self.targetsDigest
        ]
        func append(_ event: String, _ fields: [String: Any] = [:]) throws {
            try ledger.appendCampaign(event, fields, identity: receiptIdentity, budget: budget)
        }
        let control = AccessCampaignRunControl(directory: documents, prefix: prefix) { digest in
            guard let issued = budget.runChallengeIssuedAt else { throw CocoaError(.fileWriteUnknown) }
            try append("permit", [
                "challengeSHA256": digest,
                "challengeIssuedAtNs": Self.nanoseconds(budget.started.duration(to: issued))
            ])
        }
        func permitsTraffic() -> Bool {
            guard permitsPinnedNode(input.repository, revision: input.nodeRevision, budget: budget) else { return false }
            if !path.snapshot.wifi {
                budget.stop(.externalStop)
                return false
            }
            return control.permitsTraffic(budget: budget)
        }
        var reserved = 0
        func checkpoint(_ reason: String, keepPhaseReason: Bool = false) throws {
            try ledger.appendCheckpoint(reason, reserved: reserved, keepPhaseReason: keepPhaseReason,
                                        identity: receiptIdentity, budget: budget)
        }
        func health(_ phase: String) async throws -> Bool {
            guard permitsTraffic() else { return false }
            let admittedAt = ContinuousClock.now
            guard budget.stopReason(at: admittedAt) == nil else { return false }
            let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let url = input.origin.appendingPathComponent("health").appending(queryItems: [
                URLQueryItem(name: "nonce", value: nonce)
            ])
            let result = try await run(url, window: window, budget: budget, transport: .socks5,
                                       observation: .seconds(8), repository: input.repository, permit: permitsTraffic)
            try append("health", result.attempt.fields.merging(result.retirementFields) { first, _ in first }
                .merging(["phase": phase, "probeNonce": nonce,
                          "healthAdmittedAtNs": Self.nanoseconds(budget.started.duration(to: admittedAt))]) { first, _ in first })
            return result.qualifiesAsSOCKSHealth
        }

        try append("start", ["byteLimit": Self.byteLimit, "durationLimitSeconds": Self.durationSeconds,
                             "runPermitWindowMs": Self.milliseconds(Self.permitWindow),
                             "maxTargets": targets.count, "noHTTPTimeoutLimit": Self.noHTTPLimit,
                             "bundle": Bundle.main.bundleIdentifier ?? "",
                             "os": ProcessInfo.processInfo.operatingSystemVersionString,
                             "network": path.snapshot.wifi ? "wifi" : "unavailable"])
        guard try await control.awaitGrant(budget: budget, poll: permitsTraffic),
              try await health("before-first-target") else {
            try checkpoint("health-check-failed")
            return
        }

        var streak = AccessCampaignTimeoutStreak()
        var preparationFailures = AccessCampaignPreparationFailureStreak()
        for (index, host) in targets.enumerated() {
            guard permitsTraffic() else {
                try checkpoint("external-stop")
                return
            }
            let url = try XCTUnwrap(URL(string: "https://" + host + "/"))
            let admittedAt = ContinuousClock.now
            if let stop = budget.stopReason(at: admittedAt) {
                try checkpoint(stop.rawValue)
                return
            }
            let identity: [String: Any] = ["host": host, "ordinal": index + 1, "attempt": UUID().uuidString]
            // The before-load reservation is durable. A later abort still consumes
            // this key, and O_EXCL refuses a second launch of the entire pilot.
            reserved += 1
            try append("reserved", identity.merging([
                "admittedAtNs": Self.nanoseconds(budget.started.duration(to: admittedAt))
            ]) { first, _ in first })
            let result = try await run(url, window: window, budget: budget, transport: .socks5,
                                       observation: .seconds(20), repository: input.repository, permit: permitsTraffic,
                                       dispatchCheckpoint: { acceptedAt in
                try append("dispatch", identity.merging([
                    "navigationIssuedAtNs": Self.nanoseconds(budget.started.duration(to: acceptedAt))
                ]) { first, _ in first })
            },
                                       resultCheckpoint: { attempt in
                try append("result", identity.merging(attempt.fields) { first, _ in first })
            })
            try append("retirement", identity.merging(result.retirementFields) { first, _ in first })
            if let stop = budget.stopReason() {
                try checkpoint(stop.rawValue)
                return
            }
            guard result.retired else { try checkpoint("retirement-unconfirmed"); return }
            guard result.quiesced else { try checkpoint("transport-quiescence-unconfirmed"); return }
            let issued = result.attempt.observation.navigationIssued
            if preparationFailures.observe(navigationIssued: issued) {
                try checkpoint("repeated-preparation-failure")
                return
            }
            if streak.observe(navigationIssued: issued, timedOut: result.attempt.outcome == .timeout,
                              sawHTTP: result.attempt.observation.evidence.firstHTTPStatus != nil) {
                let pausedAt = ContinuousClock.now
                if let stop = budget.stopReason(at: pausedAt) {
                    try checkpoint(stop.rawValue)
                    return
                }
                try append("dispatch-paused", ["reason": "three-no-http-timeouts", "reservedCount": reserved,
                                               "pausedAtNs": Self.nanoseconds(budget.started.duration(to: pausedAt))])
                _ = try await health("after-three-no-http-timeouts")
                try checkpoint("three-no-http-timeouts", keepPhaseReason: true)
                return
            }
        }
        try checkpoint("target-limit")
    }

    func testControlledStageMatrixForBothInbounds() async throws {
        let input = try admittedInputs()
        guard input.environment["AEGIS_TEST_COMMON_MATRIX"] == "1",
              let certificateOrigin = input.environment["AEGIS_TEST_COMMON_CERTIFICATE_FIXTURE"].flatMap(URL.init(string:)),
              certificateOrigin.scheme == "https", let certificateHost = certificateOrigin.host,
              certificateHost != input.origin.host, certificateOrigin.user == nil, certificateOrigin.password == nil,
              certificateOrigin.query == nil, certificateOrigin.fragment == nil else {
            throw XCTSkip("Explicit owned HTTP and untrusted certificate fixtures are required")
        }
        let window = makeWindow()
        defer { window.isHidden = true }
        let ledger = try fixtureLedger("matrix", input.environment)
        for transport in [AccessTestNodeTransport.http, .socks5] {
            for name in ["redirect", "script", "status", "certificate", "no-response", "slow", "retire"] {
                let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                let origin = name == "certificate" ? certificateOrigin : input.origin
                let target = origin.appendingPathComponent(name).appending(queryItems: [URLQueryItem(name: "nonce", value: nonce)])
                let budget = AccessCampaignBudget(duration: .seconds(30), bytes: 8 * 1024 * 1024)
                let result = try await run(target, window: window, budget: budget, transport: transport,
                                           observation: ["slow", "no-response"].contains(name) ? .seconds(8) : .seconds(20),
                                           settleBeforeRetiring: name == "script" ? .milliseconds(800) : .zero,
                                           competeDuringRetirement: name == "retire", repository: input.repository)
                let page = result.attempt.page
                let stage = page.timeline
                var row = result.attempt.fields.merging(result.retirementFields) { first, _ in first }
                row["case"] = name
                row["nonce"] = nonce
                row["sourceSHA"] = input.source
                row["chargedBytes"] = budget.bytes.charged
                try ledger.append(row)
                XCTAssertNil(budget.stopReason(), name)
                XCTAssertEqual(result.attempt.transport, transport == .http ? "http" : "socks5", name)
                XCTAssertTrue(result.retired, name)
                XCTAssertTrue(result.quiesced, name)
                XCTAssertNotNil(stage.instant(.retirementCommit), name)
                switch name {
                case "redirect", "status", "retire":
                    XCTAssertEqual(result.attempt.outcome, .finished, name)
                    XCTAssertEqual(page.firstVisibleHTTPStatus, name == "status" ? 403 : 200, name)
                    let response = try XCTUnwrap(stage.instant(.firstVisibleHTTPResponse))
                    let commit = try XCTUnwrap(stage.instant(.documentCommit))
                    let finish = try XCTUnwrap(stage.instant(.documentFinish))
                    XCTAssertLessThanOrEqual(response, commit, name)
                    XCTAssertLessThanOrEqual(commit, finish, name)
                    if name == "redirect" {
                        XCTAssertGreaterThanOrEqual(page.serverRedirectCount, 1)
                        XCTAssertNil(page.initialHTTPStatus)
                    }
                    if name == "retire" {
                        XCTAssertEqual(page.retirementEvents.filter { $0 == "replacement-retry-scheduled" }.count, 1)
                        XCTAssertTrue(page.retirementEvents.contains("denied-about-main"))
                    }
                case "script":
                    XCTAssertEqual(result.attempt.outcome, .policyBlocked)
                    XCTAssertEqual(page.localPolicyRejection, "additional-top-level-navigation")
                    XCTAssertNotNil(stage.instant(.documentCommit))
                    XCTAssertNotNil(stage.instant(.policyRejection))
                case "certificate":
                    XCTAssertEqual(result.attempt.outcome, .failed)
                    XCTAssertEqual(page.failureDomain, NSURLErrorDomain)
                    XCTAssertEqual(page.failureCode, NSURLErrorServerCertificateUntrusted)
                    XCTAssertGreaterThan(budget.bytes.charged, 0)
                    XCTAssertNil(stage.instant(.firstVisibleHTTPResponse))
                    XCTAssertNil(stage.instant(.documentCommit))
                case "slow":
                    XCTAssertEqual(result.attempt.outcome, .timeout)
                    XCTAssertEqual(page.firstVisibleHTTPStatus, 200)
                    XCTAssertNotNil(stage.instant(.documentCommit))
                    XCTAssertNil(stage.instant(.documentFinish))
                case "no-response":
                    XCTAssertEqual(result.attempt.outcome, .timeout)
                    XCTAssertGreaterThan(budget.bytes.charged, 0)
                    XCTAssertNil(stage.instant(.firstVisibleHTTPResponse))
                    XCTAssertNil(stage.instant(.documentCommit))
                default: XCTFail("Unknown owned fixture")
                }
            }
        }
    }

    func testControlledInFlightBudgetFence() async throws {
        let input = try admittedInputs()
        guard input.environment["AEGIS_TEST_COMMON_MATRIX"] == "1" else { throw XCTSkip("Owned fixture required") }
        let window = makeWindow()
        defer { window.isHidden = true }
        let ledger = try fixtureLedger("budget", input.environment)
        for limits in [(AccessCampaignBudget.Stop.timeLimit, "slow", Duration.seconds(8), 8 * 1024 * 1024),
                       (.byteLimit, "stream", .seconds(30), 256 * 1024)] {
            let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let url = input.origin.appendingPathComponent(limits.1).appending(queryItems: [
                URLQueryItem(name: "nonce", value: nonce)
            ])
            let budget = AccessCampaignBudget(duration: limits.2, bytes: limits.3)
            let result = try await run(url, window: window, budget: budget, transport: .socks5,
                                       observation: .seconds(25), repository: input.repository)
            let reason = try XCTUnwrap(budget.stopReason())
            var row = result.attempt.fields.merging(result.retirementFields) { first, _ in first }
            row["sourceSHA"] = input.source
            row["nonce"] = nonce
            row["stopReason"] = reason.rawValue
            row["chargedBytes"] = budget.bytes.charged
            row["byteLimit"] = limits.3
            try ledger.append(row)
            XCTAssertEqual(reason, limits.0)
            XCTAssertEqual(result.attempt.outcome, .stopped)
            XCTAssertTrue(result.retired)
            XCTAssertTrue(result.quiesced)
            XCTAssertLessThanOrEqual(budget.bytes.charged, limits.3)
            XCTAssertGreaterThan(budget.bytes.charged, 0)
            XCTAssertNotNil(result.attempt.page.timeline.instant(.loadIssued))
            XCTAssertNil(result.attempt.page.timeline.instant(.documentFinish))
        }
    }

    func testControlledCampaignStopsOnRouteLoss() async throws {
        let input = try admittedInputs()
        guard input.environment["AEGIS_TEST_COMMON_MATRIX"] == "1" else { throw XCTSkip("Owned fixture required") }
        let window = makeWindow()
        defer { window.isHidden = true }
        let ledger = try fixtureLedger("route-loss", input.environment)
        for stop in [AccessCampaignBudget.Stop.nodeRevisionChanged, .transportLost] {
            let repository = AccessTestNodeRepository(channel: .dev, storage: FixtureNodeStorage())
            let revision = try repository.apply(input.parameters, expectedRevision: nil, isPrivate: false)
            let budget = AccessCampaignBudget(duration: .seconds(35), bytes: 8 * 1024 * 1024)
            let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let query = [URLQueryItem(name: "nonce", value: nonce)]
            let slow = input.origin.appendingPathComponent("slow").appending(queryItems: query)
            func permit() -> Bool { permitsPinnedNode(repository, revision: revision, budget: budget) }

            let active = try await run(slow, window: window, budget: budget, transport: .socks5,
                                       observation: .seconds(16), repository: repository, permit: permit, afterCommit: { core in
                if stop == .nodeRevisionChanged {
                    // The same authorized parameters saved again create a different revision.
                    _ = try repository.apply(input.parameters, expectedRevision: revision, isPrivate: false)
                } else {
                    await core.stop()
                }
            })
            let forbidden = input.origin.appendingPathComponent("forbidden").appending(queryItems: query)
            let later = try await run(forbidden, window: window, budget: budget, transport: .socks5,
                                      observation: .seconds(5), repository: repository, permit: permit)
            let reason = try XCTUnwrap(budget.stopReason())
            var row = active.attempt.fields.merging(active.retirementFields) { first, _ in first }
            row["nonce"] = nonce
            row["sourceSHA"] = input.source
            row["stopReason"] = reason.rawValue
            row["subsequentNavigationIssued"] = later.attempt.page.timeline.instant(.loadIssued) != nil
            try ledger.append(row)

            XCTAssertEqual(reason, stop)
            XCTAssertEqual(active.attempt.outcome, .stopped)
            XCTAssertEqual(active.attempt.page.firstVisibleHTTPStatus, 200)
            XCTAssertNotNil(active.attempt.page.timeline.instant(.documentCommit))
            XCTAssertTrue(active.retired)
            XCTAssertTrue(active.quiesced)
            XCTAssertNil(later.attempt.page.timeline.instant(.loadIssued))
            XCTAssertNil(later.attempt.page.initialBinding)
        }
    }

    func testOwnedRelayClosesWhenHostCannotRenewAndDispatchIsDurable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledgerURL = directory.appendingPathComponent("dispatch.jsonl")
        let ledger = try DurableLedger(url: ledgerURL)
        let control = AccessCampaignRunControl(directory: directory, prefix: "owned-case") { digest in
            try ledger.append(["event": "permit", "challengeSHA256": digest])
        }
        let budget = AccessCampaignBudget(duration: .seconds(45), bytes: 8 * 1024 * 1024, permitWindow: .seconds(8))
        func permitsTraffic() -> Bool { control.permitsTraffic(budget: budget) }
        try Data("run\n".utf8).write(to: control.commandFile)
        let initialGrant = Task { try await control.awaitGrant(budget: budget, poll: permitsTraffic) }
        defer { initialGrant.cancel() }
        let startupDeadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: control.challengeFile.path), ContinuousClock.now < startupDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(permitsTraffic(), "An old run command cannot admit traffic")
        try Data(contentsOf: control.challengeFile).write(to: control.commandFile, options: .atomic)
        let admitted = try await initialGrant.value
        XCTAssertTrue(admitted)

        let repository = try makeSimulatorFixtureRepository()
        let core = HoldingFixtureCore()
        let window = makeWindow()
        defer { window.isHidden = true }
        let url = URL(string: "https://owned-no-response.invalid/hold")!
        var issued: ContinuousClock.Instant?
        try ledger.append(["event": "reserved", "ordinal": 1])
        let result = try await run(url, window: window, budget: budget, transport: .http,
                                   observation: .seconds(20), repository: repository, permit: permitsTraffic,
                                   testingCore: core, dispatchCheckpoint: { instant in
            issued = instant
            try ledger.append(["event": "dispatch", "ordinal": 1])
            let records = try String(contentsOf: ledgerURL, encoding: .utf8)
            XCTAssertEqual(records.split(separator: "\n").count, 4)
            XCTAssertFalse(records.contains("result"))
        }, resultCheckpoint: { _ in
            try ledger.append(["event": "result", "ordinal": 1])
        })
        try ledger.append(["event": "retirement", "ordinal": 1])
        XCTAssertNotNil(issued)
        XCTAssertEqual(issued, result.attempt.page.timeline.instant(.loadIssued))
        XCTAssertGreaterThan(core.dialCount, 0)
        XCTAssertFalse(core.stream.writtenSnapshot.isEmpty)
        XCTAssertEqual(result.attempt.outcome, .stopped)
        XCTAssertEqual(budget.stopReason(), .runPermitExpired)
        let fields = result.attempt.fields
        let began = try XCTUnwrap(fields["preparationStartedAtNs"] as? Int64)
        let due = try XCTUnwrap(fields["preparationDeadlineAtNs"] as? Int64)
        XCTAssertEqual(due - began, 15_000_000_000)
        XCTAssertEqual(fields["observationCutoffAtNs"] as? Int64, 8_000_000_000)
        XCTAssertNotNil(result.retirementFields["retirementCommitAtNs"] as? Int64)
        XCTAssertNotNil(result.retirementFields["transportQuiescedAtNs"] as? Int64)
        XCTAssertTrue(result.retired)
        XCTAssertTrue(result.quiesced)
        XCTAssertFalse(core.stream.isOpen)
        XCTAssertThrowsError(try DurableLedger(url: ledgerURL))

        try Data(contentsOf: control.challengeFile).write(to: control.commandFile, options: .atomic)
        let dialCount = core.dialCount
        let denied = try await run(url, window: window, budget: budget, transport: .http,
                                   observation: .seconds(4), repository: repository, permit: permitsTraffic,
                                   testingCore: core, dispatchCheckpoint: { _ in XCTFail("An expired permit reopened") })
        XCTAssertFalse(denied.attempt.observation.navigationIssued)
        XCTAssertEqual(core.dialCount, dialCount)
        XCTAssertEqual(try String(contentsOf: ledgerURL, encoding: .utf8).split(separator: "\n").count, 6)
    }

    func testFailedDispatchWriteStopsTheBatchBeforeAnotherLoad() async throws {
        let repository = try makeSimulatorFixtureRepository()
        let core = HoldingFixtureCore()
        let window = makeWindow()
        defer { window.isHidden = true }
        let budget = AccessCampaignBudget(duration: .seconds(30), bytes: 128 * 1024)
        let url = URL(string: "https://owned-no-response.invalid/write-failure")!
        do {
            _ = try await run(url, window: window, budget: budget, transport: .http,
                              observation: .seconds(5), repository: repository,
                              testingCore: core, dispatchCheckpoint: { _ in throw POSIXError(.EIO) },
                              resultCheckpoint: { _ in XCTFail("A result concealed the missing dispatch write") })
            XCTFail("The failed write was swallowed")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .EIO)
        }
        XCTAssertEqual(budget.stopReason(), .dispatchLedgerFailed)

        let later = try await run(url, window: window, budget: budget, transport: .http,
                                  observation: .seconds(5), repository: repository,
                                  testingCore: HoldingFixtureCore())
        XCTAssertFalse(later.attempt.observation.navigationIssued)
        XCTAssertNil(later.attempt.page.initialBinding)
    }

    func testRetirementKeepsOriginalHandleEvidenceSeparate() async throws {
        let repository = try makeSimulatorFixtureRepository()
        let page = AccessTestNodePage(isPrivate: false, repository: repository, testingCore: HoldingFixtureCore(),
                                      singleNavigation: true, transport: .http)
        await page.open(URL(string: "https://owned-no-response.invalid/late")!)
        let view = try XCTUnwrap(page.webView)
        let original = try XCTUnwrap(page.originalNavigation)
        page.close()
        let replacement = try XCTUnwrap(page.retirementNavigation)
        page.webView(view, didFinish: replacement)
        XCTAssertNil(page.originalNavigationAfterClose.instant(.documentFinish))
        page.webView(view, didCommit: original)
        page.webView(view, didFinish: original)
        XCTAssertNotNil(page.originalNavigationAfterClose.instant(.documentCommit))
        XCTAssertNotNil(page.originalNavigationAfterClose.instant(.documentFinish))
        XCTAssertNil(page.timeline.instant(.documentCommit))
        XCTAssertNil(page.timeline.instant(.documentFinish))
        XCTAssertNotNil(page.endpoint)
        page.webView(view, didCommit: replacement)
        XCTAssertNil(page.endpoint)
    }

    func testOwnedLoopbackHTTPSDistinguishesRelayCertificateAndResponseStages() async throws {
#if targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        guard let trusted = environment["AEGIS_LOOPBACK_TRUSTED_PORT"].flatMap(UInt16.init), trusted > 0,
              let untrusted = environment["AEGIS_LOOPBACK_UNTRUSTED_PORT"].flatMap(UInt16.init), untrusted > 0,
              let receiptPort = environment["AEGIS_LOOPBACK_RECEIPTS_PORT"].flatMap(UInt16.init), receiptPort > 0,
              Set([trusted, untrusted, receiptPort]).count == 3 else {
            throw XCTSkip("Start the owned simulator HTTPS fixture and its receipt server")
        }
        let repository = try makeSimulatorFixtureRepository()
        let window = makeWindow()
        defer { window.isHidden = true }
        for name in ["relay-failure", "certificate", "no-response", "slow-resource", "finished"] {
            let originPort = name == "certificate" ? untrusted : trusted
            let core = LoopbackFixtureCore(port: originPort, failRelay: name == "relay-failure")
            let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let url = URL(string: "https://\(LoopbackFixtureCore.host):\(originPort)/\(name)?nonce=\(nonce)")!
            let budget = AccessCampaignBudget(duration: .seconds(20), bytes: 8 * 1024 * 1024)
            let observation: Duration = ["no-response", "slow-resource"].contains(name) ? .seconds(4) : .seconds(10)
            let result = try await run(url, window: window, budget: budget, transport: .http,
                                       observation: observation, repository: repository, testingCore: core)
            let observed = result.attempt.observation.evidence
            XCTAssertTrue(result.attempt.observation.navigationIssued, name)
            XCTAssertTrue(result.retired, name)
            XCTAssertTrue(result.quiesced, name)
            XCTAssertEqual(result.attempt.transport, "http", name)
            XCTAssertGreaterThan(core.dialCount, 0, name)
            XCTAssertNil(budget.stopReason(), name)
            let cutoffTicks = try fixtureClockTicks(for: result.attempt.observation.cutoff)
            let receipts = try await loopbackReceipts(port: receiptPort, nonce: nonce)
                .filter { $0.atTicks <= cutoffTicks }.map(\.path)
            switch name {
            case "relay-failure":
                XCTAssertEqual(result.attempt.outcome, .failed)
                XCTAssertEqual(budget.bytes.charged, 0)
                XCTAssertNil(observed.firstHTTPStatus)
                XCTAssertTrue(receipts.isEmpty)
            case "certificate":
                XCTAssertEqual(result.attempt.outcome, .failed)
                XCTAssertEqual(observed.failureDomain, NSURLErrorDomain)
                XCTAssertEqual(observed.failureCode, NSURLErrorServerCertificateUntrusted)
                XCTAssertGreaterThan(budget.bytes.charged, 0)
                XCTAssertNil(observed.firstHTTPStatus)
                XCTAssertTrue(receipts.isEmpty)
            case "no-response":
                XCTAssertEqual(result.attempt.outcome, .timeout)
                XCTAssertGreaterThan(budget.bytes.charged, 0)
                XCTAssertNil(observed.firstHTTPStatus)
                XCTAssertNil(observed.milliseconds["documentCommit"])
                XCTAssertEqual(receipts, ["/no-response"])
            case "slow-resource":
                XCTAssertEqual(result.attempt.outcome, .timeout)
                XCTAssertEqual(observed.initialHTTPStatus, 200)
                XCTAssertNotNil(observed.milliseconds["documentCommit"])
                XCTAssertNil(observed.milliseconds["documentFinish"])
                XCTAssertEqual(receipts, ["/slow-resource", "/held-image"])
            case "finished":
                XCTAssertEqual(result.attempt.outcome, .finished)
                XCTAssertEqual(observed.initialHTTPStatus, 200)
                XCTAssertNotNil(observed.milliseconds["documentFinish"])
                XCTAssertEqual(receipts, ["/finished"])
            default: XCTFail("Unknown loopback fixture")
            }
        }
#else
        throw XCTSkip("Loopback HTTPS test uses a disposable simulator")
#endif
    }

    func testOwnedSOCKSLedgerForHostReconciliation() async throws {
        try await runOwnedSOCKSLedger(.finished)
    }

    func testOwnedSOCKSUnfinishedHealthPreservesLedger() async throws {
        try await runOwnedSOCKSLedger(.unfinished)
    }

    func testOwnedSOCKSExpiredBeforeChallengePreservesLedger() async throws {
        try await runOwnedSOCKSLedger(.expired)
    }

    private enum OwnedLedgerScenario {
        case finished, unfinished, expired

        var identity: String {
            switch self {
            case .finished: return "owned-simulator-ledger"
            case .unfinished: return "owned-simulator-unfinished-health"
            case .expired: return "owned-simulator-expired-before-challenge"
            }
        }

        var attachmentName: String {
            switch self {
            case .finished: return "owned-socks-campaign-ledger"
            case .unfinished: return "owned-socks-unfinished-health-ledger"
            case .expired: return "owned-socks-expired-before-challenge-ledger"
            }
        }
    }

    private func runOwnedSOCKSLedger(_ scenario: OwnedLedgerScenario) async throws {
#if targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["AEGIS_LOOPBACK_TRUSTED_PORT"].flatMap(UInt16.init), port > 0,
              let receiptPort = environment["AEGIS_LOOPBACK_RECEIPTS_PORT"].flatMap(UInt16.init),
              receiptPort > 0, receiptPort != port,
              let source = environment["AEGIS_TEST_SOURCE_SHA"], source.count == 40 else {
            throw XCTSkip("Start the owned simulator HTTPS fixture with an explicit source revision")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = LoopbackFixtureCore.host
        let identity = [
            "campaignID": scenario.identity, "sourceSHA": source, "device": "owned-simulator",
            "nodeInputSHA256": Self.sha256(Data("owned-loopback-core".utf8)),
            "targetsSHA256": Self.sha256(Data((host + "\n").utf8))
        ]
        let file = directory.appendingPathComponent("receipt.jsonl")
        let ledger = try DurableLedger(url: file)
        defer {
            do {
                let attachment = XCTAttachment(data: try Data(contentsOf: file), uniformTypeIdentifier: "public.plain-text")
                attachment.name = scenario.attachmentName
                attachment.lifetime = .keepAlways
                add(attachment)
            } catch {
                XCTFail("Unable to retain the owned campaign ledger: \(error)")
            }
        }
        let byteLimit = 8 * 1024 * 1024
        let start = ContinuousClock.now - (scenario == .expired ? .seconds(31) : .zero)
        let budget = AccessCampaignBudget(duration: .seconds(45), bytes: byteLimit, started: start, permitWindow: .seconds(30))
        func append(_ event: String, _ fields: [String: Any]) throws {
            try ledger.appendCampaign(event, fields, identity: identity, budget: budget)
        }
        func stamp(_ instant: ContinuousClock.Instant) -> Int64 { Self.nanoseconds(budget.started.duration(to: instant)) }
        let control = AccessCampaignRunControl(directory: directory, prefix: "owned") { digest in
            try append("permit", ["challengeSHA256": digest,
                                  "challengeIssuedAtNs": stamp(try XCTUnwrap(budget.runChallengeIssuedAt))])
        }
        func permitsTraffic() -> Bool { control.permitsTraffic(budget: budget) }
        try append("start", ["byteLimit": byteLimit, "durationLimitSeconds": 45, "runPermitWindowMs": 30_000,
                             "maxTargets": 1, "noHTTPTimeoutLimit": 3])
        let grant = Task { try await control.awaitGrant(budget: budget, poll: permitsTraffic) }
        defer { grant.cancel() }
        let readyBy = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: control.challengeFile.path),
              ContinuousClock.now < readyBy, budget.stopReason() == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        do {
            if budget.stopReason() == nil {
                try Data(contentsOf: control.challengeFile).write(to: control.commandFile, options: .atomic)
            }
        } catch {
            guard budget.stopReason() != nil else { throw error }
        }
        guard try await grant.value else {
            let stop = try ledger.appendCheckpoint("health-check-failed", reserved: 0, identity: identity, budget: budget)
            if scenario == .expired {
                XCTAssertEqual(stop?.reason, .runPermitExpired)
                XCTAssertFalse(FileManager.default.fileExists(atPath: control.challengeFile.path))
            } else { XCTFail("Owned run permit did not arm") }
            return
        }
        guard scenario != .expired else { XCTFail("An expired permit admitted the owned probe"); return }

        let repository = try makeSimulatorFixtureRepository()
        let window = makeWindow()
        defer { window.isHidden = true }
        func ownedURL(_ path: String, nonce: String) throws -> URL {
            return try XCTUnwrap(URL(string: "https://\(host):\(port)/\(path)?nonce=\(nonce)"))
        }
        let permitted = permitsTraffic()
        let probeAt = ContinuousClock.now
        guard permitted, budget.stopReason(at: probeAt) == nil else {
            try ledger.appendCheckpoint("health-check-failed", reserved: 0, identity: identity, budget: budget)
            XCTFail("Owned health probe did not enter its authorized window")
            return
        }
        let probeNonce = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let health = try await run(ownedURL(scenario == .finished ? "finished" : "slow-resource", nonce: probeNonce),
                                   window: window, budget: budget, transport: .socks5, observation: .seconds(8),
                                   repository: repository, permit: permitsTraffic, socksAdmitted: true,
                                   testingCore: LoopbackFixtureCore(port: port, failRelay: false))
        var probe = health.attempt.fields.merging(health.retirementFields) { first, _ in first }
        probe["phase"] = "before-first-target"
        probe["probeNonce"] = probeNonce
        probe["healthAdmittedAtNs"] = stamp(probeAt)
        try append("health", probe)
        let admittedAt = ContinuousClock.now
        guard health.qualifiesAsSOCKSHealth, budget.stopReason(at: admittedAt) == nil else {
            let checkpointStop = try ledger.appendCheckpoint("health-check-failed", reserved: 0, identity: identity, budget: budget)
            if scenario == .finished {
                XCTFail("Owned HTTPS health did not admit the target")
            } else {
                XCTAssertEqual(health.attempt.observation.evidence.initialHTTPStatus, 200)
                XCTAssertEqual(health.attempt.outcome, .timeout)
                XCTAssertNotNil(health.attempt.observation.evidence.nanoseconds["documentCommit"])
                XCTAssertNil(health.attempt.observation.evidence.nanoseconds["documentFinish"])
                XCTAssertTrue(health.retired && health.quiesced)
                XCTAssertNil(checkpointStop)
                let cutoffTicks = try fixtureClockTicks(for: health.attempt.observation.cutoff)
                let paths = try await loopbackReceipts(port: receiptPort, nonce: probeNonce)
                    .filter { $0.atTicks <= cutoffTicks }.map(\.path)
                XCTAssertEqual(paths, ["/slow-resource", "/held-image"])
            }
            return
        }
        guard scenario == .finished else { XCTFail("An unfinished probe admitted traffic"); return }

        let attempt: [String: Any] = ["ordinal": 1, "host": host, "attempt": UUID().uuidString]
        try append("reserved", attempt.merging(["admittedAtNs": stamp(admittedAt)]) { first, _ in first })
        let targetNonce = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let result = try await run(ownedURL("finished", nonce: targetNonce), window: window, budget: budget,
                                  transport: .socks5, observation: .seconds(20),
                                  repository: repository, permit: permitsTraffic, socksAdmitted: true,
                                  testingCore: LoopbackFixtureCore(port: port, failRelay: false),
                                  dispatchCheckpoint: { acceptedAt in
            try append("dispatch", attempt.merging(["navigationIssuedAtNs": stamp(acceptedAt)]) { first, _ in first })
        }, resultCheckpoint: { observation in
            try append("result", attempt.merging(observation.fields) { first, _ in first })
        })
        XCTAssertEqual(result.attempt.outcome, .finished)
        XCTAssertTrue(result.retired && result.quiesced)
        try append("retirement", attempt.merging(result.retirementFields) { first, _ in first })
        try ledger.appendCheckpoint("target-limit", reserved: 1, identity: identity, budget: budget)
#else
        throw XCTSkip("Owned receipt export is simulator-only")
#endif
    }

    private struct LoopbackReceipt: Decodable {
        let path: String
        let atTicks: UInt64
    }

    /// The simulator and its loopback origin share the Mac kernel's continuous clock.
    private func fixtureClockTicks(for cutoff: ContinuousClock.Instant) throws -> UInt64 {
        let sampledTicks = mach_continuous_time()
        let elapsed = cutoff.duration(to: .now).components
        let elapsedNanoseconds = elapsed.seconds * 1_000_000_000 + (elapsed.attoseconds + 999_999_999) / 1_000_000_000
        var timebase = mach_timebase_info_data_t()
        guard elapsedNanoseconds >= 0, mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer > 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        // Convert round-up so sampling order and rounding cannot admit a late request.
        let elapsedTicks = (UInt64(elapsedNanoseconds) * UInt64(timebase.denom) + UInt64(timebase.numer) - 1)
            / UInt64(timebase.numer)
        guard elapsedTicks <= sampledTicks else { throw CocoaError(.fileReadCorruptFile) }
        return sampledTicks - elapsedTicks
    }

    private func loopbackReceipts(port: UInt16, nonce: String) async throws -> [LoopbackReceipt] {
        let url = URL(string: "http://127.0.0.1:\(port)/receipt/\(nonce)")!
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 3))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode([LoopbackReceipt].self, from: data)
    }

    private func makeSimulatorFixtureRepository() throws -> AccessTestNodeRepository {
        let repository = AccessTestNodeRepository(channel: .dev, storage: FixtureNodeStorage())
        let link = "vless://550e8400-e29b-41d4-a716-446655440000@198.51.100.10:443"
            + "?type=tcp&security=reality&flow=xtls-rprx-vision&sni=example.invalid"
            + "&pbk=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&sid=abcd1234"
        _ = try repository.apply(AccessLocalV2RayConfigLoader.parseSingleShareURI(link),
                                 expectedRevision: nil, isPrivate: false)
        return repository
    }

    private func run(_ url: URL, window: UIWindow, budget: AccessCampaignBudget,
                     transport: AccessTestNodeTransport, observation: Duration,
                     settleBeforeRetiring: Duration = .zero, competeDuringRetirement: Bool = false,
                     repository: AccessTestNodeRepository, permit: @escaping () -> Bool = { true },
                     socksAdmitted: Bool? = nil,
                     testingCore: (any AccessEmbeddedCoreControlling)? = nil,
                     afterCommit: ((any AccessEmbeddedCoreControlling) async throws -> Void)? = nil,
                     dispatchCheckpoint: (ContinuousClock.Instant) throws -> Void = { _ in },
                     resultCheckpoint: (Attempt) throws -> Void = { _ in }) async throws -> AttemptResult {
        let core = AccessCampaignMeteredCore(base: try testingCore ?? AccessGoEmbeddedCore(isolated: true), budget: budget)
        let page = AccessTestNodePage(isPrivate: false, repository: repository, testingCore: core, singleNavigation: true,
                                      transport: transport, socksAdmitted: socksAdmitted,
                                      navigationAllowed: { budget.stopReason() == nil && permit() },
                                      onTransportLoss: { if permit() { budget.stop(.transportLost) } })
        let fence = Task { @MainActor in
            while !Task.isCancelled {
                if budget.stopReason() != nil || !permit() || page.observeBoundEntryLoss() {
                    page.close()
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { fence.cancel(); page.close() }
        try await page.open(url) { acceptedAt in
            do {
                try dispatchCheckpoint(acceptedAt)
            } catch {
                budget.stop(.dispatchLedgerFailed)
                throw error
            }
        }
        if let view = page.webView {
            view.frame = window.bounds
            window.addSubview(view)
        }
        let navigationDeadline = page.timeline.instant(.loadIssued)?.advanced(by: observation)
        var commitAction = afterCommit
        if let navigationDeadline {
            while page.endpoint != nil, page.timeline.instant(.documentFinish) == nil,
                  page.timeline.instant(.navigationFailure) == nil, page.timeline.instant(.policyRejection) == nil,
                  budget.stopReason() == nil, ContinuousClock.now < navigationDeadline {
                if let action = commitAction, page.timeline.instant(.documentCommit) != nil {
                    commitAction = nil
                    try await action(core)
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        if settleBeforeRetiring > .zero, budget.stopReason() == nil {
            try await Task.sleep(for: settleBeforeRetiring)
        }
        // WebKit can finish after an interrupted subresource. Check the live
        // binding before recording that callback as the attempt's outcome.
        page.observeBoundEntryLoss()
        _ = permit()
        let observedAt = ContinuousClock.now
        let evidence = AccessCampaignNavigationObservation(timeline: page.timeline, observationDeadline: navigationDeadline,
                    preparationDeadline: page.preparationDeadline,
                    observedAt: observedAt, stop: budget.stoppage(at: observedAt))
        let actualProtocol = page.initialBinding.map { $0.transport == .http ? "http" : "socks5" } ?? "unbound"
        if let binding = page.initialBinding {
            guard binding.port != 0, binding.port != 1080,
                  actualProtocol == (transport == .socks5 ? "socks5" : "http"),
                  page.webView?.configuration.websiteDataStore.proxyConfigurations.count == 1,
                  page.webView?.configuration.websiteDataStore.proxyConfigurations.first?.allowFailover == false else {
                page.close()
                throw URLError(.cannotConnectToHost)
            }
        }
        let attempt = Attempt(observation: evidence, page: page, transport: actualProtocol, budgetStart: budget.started)
        // Close signals the product fence before awaiting local retirement. The
        // deadline does not grant extra browsing time for the retirement wait.
        let closeRequested = ContinuousClock.now
        page.close()
        let requested = page.timeline.instant(.retirementRequested) ?? closeRequested
        try resultCheckpoint(attempt)
        if competeDuringRetirement { _ = page.webView?.load(URLRequest(url: URL(string: "about:blank")!)) }
        let retirementDeadline = requested.advanced(by: .seconds(10))
        var quiescence = AccessCampaignQuiescence()
        var firstPoll: ContinuousClock.Instant?
        let exitPoll: ContinuousClock.Instant
        while true {
            let idle = core.isQuiescent
            let sampledAt = ContinuousClock.now
            if firstPoll == nil { firstPoll = sampledAt }
            quiescence.observe(idle: idle, at: sampledAt, through: retirementDeadline)
            if sampledAt >= retirementDeadline || (page.endpoint == nil && quiescence.firstObserved != nil) {
                exitPoll = sampledAt
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let commit = page.timeline.instant(.retirementCommit)
        let unbound = page.webView == nil
        let retired = unbound || (page.endpoint == nil && (commit.map { $0 <= retirementDeadline } ?? false))
        let quiesced = quiescence.firstObserved != nil && core.isQuiescent
        if retired { page.webView?.removeFromSuperview() }
        let retirementObservedAt = ContinuousClock.now
        var retirement: [String: Any] = [
            "retirementState": unbound ? "unbound" : retired ? "confirmed" : "unconfirmed",
            "transportQuiesced": quiesced,
            "retirementEvents": page.retirementEvents,
            "retirementObservedMs": Self.milliseconds(requested.duration(to: retirementObservedAt)),
            "retirementRequestedAtNs": Self.nanoseconds(budget.started.duration(to: requested)),
            "retirementFirstPolledAtNs": Self.nanoseconds(budget.started.duration(to: firstPoll ?? exitPoll)),
            "retirementExitPolledAtNs": Self.nanoseconds(budget.started.duration(to: exitPoll)),
            "retirementObservedThroughAtNs": Self.nanoseconds(budget.started.duration(to: retirementObservedAt))
        ]
        retirement["retirementRequestedAtMs"] = page.timeline.milliseconds(at: requested)
        retirement["retirementCommitAtMs"] = page.timeline.milliseconds["retirementCommit"]
        retirement["retirementCommitAtNs"] = commit.map { Self.nanoseconds(budget.started.duration(to: $0)) }
        retirement["transportQuiescedAtMs"] = quiescence.firstObserved.map { page.timeline.milliseconds(at: $0) }
        retirement["transportQuiescedAtNs"] = quiescence.firstObserved.map {
            Self.nanoseconds(budget.started.duration(to: $0))
        }
        let lateOriginal = page.originalNavigationAfterClose.snapshot(through: min(retirementDeadline, exitPoll))
        if !lateOriginal.isEmpty {
            retirement["originalNavigationAfterClose"] = AccessCampaignNavigationObservation.fields(for: lateOriginal)
        }
        if let stop = budget.stoppage(at: retirementObservedAt),
           stop.instant > evidence.observedThrough, stop.instant <= retirementObservedAt {
            retirement["haltDuringRetirement"] = ["stopReason": stop.reason.rawValue,
                                                  "stopAtNs": Self.nanoseconds(budget.started.duration(to: stop.instant)),
                                                  "stopAtMs": page.timeline.milliseconds(at: stop.instant)]
        }
        return AttemptResult(attempt: attempt, retired: retired, quiesced: quiesced, retirementFields: retirement)
    }

    private func permitsPinnedNode(_ repository: AccessTestNodeRepository, revision: UUID,
                                   budget: AccessCampaignBudget) -> Bool {
        guard budget.stopReason() == nil else { return false }
        guard (try? repository.revision(isPrivate: false)) == revision else {
            budget.stop(.nodeRevisionChanged)
            return false
        }
        return true
    }

    private func admittedInputs() throws -> (environment: [String: String], origin: URL, source: String,
                                             repository: AccessTestNodeRepository, nodeRevision: UUID,
                                             parameters: AccessRealityVisionParameters) {
#if targetEnvironment(simulator)
        throw XCTSkip("TEST01 pilot requires the designated physical iPhone")
#else
        let environment = ProcessInfo.processInfo.environment
        guard environment["AEGIS_TEST_CAMPAIGN_DEVICE"] == Self.deviceAlias,
              let node = environment["AEGIS_TEST_AUTHORIZED_NODE"],
              let origin = environment["AEGIS_TEST_COMMON_FIXTURE"].flatMap(URL.init(string:)),
              let source = environment["AEGIS_TEST_SOURCE_SHA"] else {
            throw XCTSkip("Explicit authorized physical pilot inputs required")
        }
        var machine = utsname()
        uname(&machine)
        let model = withUnsafePointer(to: &machine.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        let allowedOrigin = origin.scheme == "https" && origin.host?.hasSuffix(".trycloudflare.com") == true
            && origin.user == nil && origin.password == nil && origin.query == nil && origin.fragment == nil
        let bundle = Bundle.main
        guard model == "iPhone14,3", Self.sha256(Data(node.utf8)) == Self.nodeDigest,
              allowedOrigin, source.count == 40,
              bundle.bundleIdentifier == "com.gcsa.aegis.alpha.internal.validation208",
              bundle.object(forInfoDictionaryKey: "AegisAccessReleaseChannel") as? String == "alpha",
              bundle.object(forInfoDictionaryKey: "AegisReleaseProfile") as? String == "alpha",
              bundle.object(forInfoDictionaryKey: "AegisAccessInternalOptions") as? String == "YES",
              AccessInternalOptions.installed == nil,
              AccessInternalSOCKSAdmission.current else { throw CocoaError(.fileReadCorruptFile) }
        // This signed XCTest host is outside product Options admission. Its
        // dedicated Keychain service uses the same storage and revision APIs.
        let repository = AccessTestNodeRepository(channel: .alpha,
            storage: AccessTestNodeKeychain(service: "com.gcsa.aegis.ios.access-common-pilot.v2"))
        let parameters = try AccessLocalV2RayConfigLoader.parseSingleShareURI(node)
        let revision: UUID
        if let saved = try? repository.savedNode(isPrivate: false), try saved.parameters() == parameters {
            revision = saved.revision
        } else {
            revision = try repository.apply(parameters, expectedRevision: repository.revision(isPrivate: false), isPrivate: false)
        }
        return (environment, origin, source, repository, revision, parameters)
#endif
    }

    private func loadTargets(from url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        let hosts = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        guard Self.sha256(data) == Self.targetsDigest, hosts.count == 20, Set(hosts).count == hosts.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return hosts
    }

    private func fixtureLedger(_ name: String, _ environment: [String: String]) throws -> DurableLedger {
        let run = try XCTUnwrap(environment["AEGIS_TEST_COMMON_FIXTURE_RUN"])
        guard AccessDomainCampaignInput.validID(run) else { throw CocoaError(.fileReadCorruptFile) }
        return try DurableLedger(url: Self.documents.appendingPathComponent("ios208-common-" + run + "-" + name + ".jsonl"))
    }

    private func makeWindow() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.makeKeyAndVisible()
        return window
    }

    private final class NetworkState: Sendable {
        private let state = Mutex((reported: false, wifi: false))
        func update(wifi: Bool) { state.withLock { $0 = (true, wifi) } }
        var snapshot: (reported: Bool, wifi: Bool) { state.withLock { $0 } }
    }

    private final class FixtureNodeStorage: AccessTestNodeStoring {
        private var record: AccessTestNodeRecord?

        func read(channel: AccessInternalOptions) throws -> AccessTestNodeRecord? { record }
        func write(_ record: AccessTestNodeRecord, channel: AccessInternalOptions) throws { self.record = record }
        func remove(channel: AccessInternalOptions) throws { record = nil }
    }

    private final class HoldingFixtureCore: AccessEmbeddedCoreControlling, Sendable {
        private let state = Mutex((running: false, dials: 0))
        let stream = AccessMemoryRealityStream()

        var dialCount: Int { state.withLock { $0.dials } }
        var isRunning: Bool { state.withLock { $0.running } }
        func start(configData: Data) async throws { state.withLock { $0.running = true } }
        func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
            guard host == "owned-no-response.invalid", port == 443 else { throw URLError(.cannotConnectToHost) }
            state.withLock { $0.dials += 1 }
            return stream
        }
        func stop() async {
            stream.close()
            state.withLock { $0.running = false }
        }
    }

    private final class LoopbackFixtureCore: AccessEmbeddedCoreControlling, Sendable {
        static let host = "aegis-campaign-fixture.invalid"
        private struct State {
            var running = false
            var dials = 0
            var streams: [LoopbackStream] = []
        }
        private let state = Mutex(State())
        private let port: UInt16
        private let failRelay: Bool

        init(port: UInt16, failRelay: Bool) {
            self.port = port
            self.failRelay = failRelay
        }

        var dialCount: Int { state.withLock { $0.dials } }
        var isRunning: Bool { state.withLock { $0.running } }
        func start(configData: Data) async throws { state.withLock { $0.running = true } }

        func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
            guard host == Self.host, port == self.port, let local = NWEndpoint.Port(rawValue: port) else {
                throw URLError(.cannotConnectToHost)
            }
            return try state.withLock {
                $0.dials += 1
                guard $0.running, !failRelay else { throw URLError(.cannotConnectToHost) }
                let stream = LoopbackStream(port: local)
                $0.streams.append(stream)
                return stream
            }
        }

        func stop() async {
            let streams = state.withLock {
                $0.running = false
                let streams = $0.streams
                $0.streams.removeAll()
                return streams
            }
            for stream in streams { stream.close() }
        }
    }

    private final class LoopbackStream: AccessRealityPathStream, Sendable {
        private let connection: NWConnection
        private let open = Mutex(true)

        init(port: NWEndpoint.Port) {
            connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            connection.start(queue: DispatchQueue(label: "ios-access-owned-fixture"))
        }

        var isOpen: Bool { open.withLock { $0 } }

        func read(maxBytes: Int) async throws -> Data? {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: maxBytes) { data, _, _, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: data) }
                    }
                }
            } onCancel: { self.close() }
        }

        func write(_ data: Data) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    })
                }
            } onCancel: { self.close() }
        }

        func close() {
            let wasOpen = open.withLock { flag in
                defer { flag = false }
                return flag
            }
            if wasOpen { connection.cancel() }
        }
    }

    private func startNetworkMonitor() -> (NetworkState, NWPathMonitor) {
        let state = NetworkState()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { state.update(wifi: $0.status == .satisfied && $0.usesInterfaceType(.wifi)) }
        monitor.start(queue: DispatchQueue(label: "ios208-common-pilot-network"))
        return (state, monitor)
    }

    private static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000
    }

    private static func nanoseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000_000_000 + duration.components.attoseconds / 1_000_000_000
    }

    private final class DurableLedger {
        let file: FileHandle

        init(url: URL) throws {
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }

        func append(_ row: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            data.append(10)
            try file.write(contentsOf: data)
            try file.synchronize()
        }

        @MainActor func appendCampaign(_ event: String, _ fields: [String: Any], identity: [String: String],
                            budget: AccessCampaignBudget) throws {
            var row = fields
            row.merge(identity) { _, identity in identity }
            row["event"] = event
            row["schemaVersion"] = 3
            let elapsed = AccessCommonPilotDeviceTests.nanoseconds(budget.started.duration(to: .now))
            row["elapsedNs"] = elapsed
            row["elapsedMs"] = elapsed / 1_000_000
            let bytes = budget.bytes
            row["chargedBytes"] = bytes.charged
            row["reservedBytes"] = bytes.reserved
            try append(row)
        }

        @MainActor @discardableResult
        func appendCheckpoint(_ reason: String, reserved: Int, keepPhaseReason: Bool = false,
                              identity: [String: String], budget: AccessCampaignBudget) throws -> AccessCampaignBudget.Stoppage? {
            let stop = budget.stoppage()
            var fields: [String: Any] = ["reason": keepPhaseReason ? reason : stop?.reason.rawValue ?? reason,
                                         "reservedCount": reserved]
            fields["budgetStopReason"] = stop?.reason.rawValue
            fields["budgetStopAtNs"] = stop.map { AccessCommonPilotDeviceTests.nanoseconds(budget.started.duration(to: $0.instant)) }
            try appendCampaign("checkpoint", fields, identity: identity, budget: budget)
            return stop
        }
    }
}

/// A renewed grant is owned by the phone's clock. A missing, partial, or old
/// command cannot advance it, and the previous campaign's "run" is inert.
@MainActor
struct AccessCampaignRunControl {
    let directory: URL
    let prefix: String
    let recordChallenge: (String) throws -> Void

    var challengeFile: URL { directory.appendingPathComponent(prefix + ".permit") }
    var commandFile: URL { directory.appendingPathComponent(prefix + ".control") }

    func awaitGrant(budget: AccessCampaignBudget, poll: () -> Bool) async throws -> Bool {
        guard budget.stopReason() == nil else { return false }
        guard let challenge = budget.runChallenge else { throw CocoaError(.fileWriteUnknown) }
        try publish(challenge)
        while budget.stopReason() == nil {
            if poll() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func permitsTraffic(budget: AccessCampaignBudget) -> Bool {
        guard budget.stopReason() == nil, let challenge = budget.runChallenge else { return false }
        budget.observeRunControl(readCommand(maximum: challenge.utf8.count))
        if let next = budget.runChallenge, next != challenge {
            do { try publish(next) }
            catch { budget.stop(.runControlUnavailable) }
        }
        return budget.trafficRejection() == nil
    }

    private func publish(_ challenge: String) throws {
        let bytes = Data(challenge.utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try recordChallenge(digest)
        try bytes.write(to: challengeFile, options: .atomic)
    }

    private func readCommand(maximum: Int) -> String? {
        guard let file = try? FileHandle(forReadingFrom: commandFile) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: maximum + 1), data.count <= maximum else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct AccessCampaignQuiescence {
    private(set) var firstObserved: ContinuousClock.Instant?

    mutating func observe(idle: Bool, at instant: ContinuousClock.Instant, through deadline: ContinuousClock.Instant) {
        if !idle { firstObserved = nil }
        else if firstObserved == nil, instant <= deadline { firstObserved = instant }
    }
}

struct AccessCampaignNavigationObservation {
    enum Outcome: String {
        case finished, failed, timeout, stopped
        case policyBlocked = "policy-blocked"
    }

    let outcome: Outcome
    let navigationIssued: Bool
    let evidence: AccessTestNodeTimeline.Snapshot
    let later: AccessTestNodeTimeline.Snapshot
    let cutoff: ContinuousClock.Instant
    let observedThrough: ContinuousClock.Instant
    let cutoffMs: Int64
    let stopReason: AccessCampaignBudget.Stop?
    let laterStopReason: AccessCampaignBudget.Stop?
    let laterStopInstant: ContinuousClock.Instant?
    let laterStopMs: Int64?

    init(timeline: AccessTestNodeTimeline, observationDeadline: ContinuousClock.Instant?,
         preparationDeadline: ContinuousClock.Instant? = nil,
         observedAt: ContinuousClock.Instant, stop: AccessCampaignBudget.Stoppage?) {
        let possibleEnd = min(observationDeadline ?? preparationDeadline ?? observedAt, observedAt)
        let cutoff = min(possibleEnd, stop?.instant ?? possibleEnd)
        self.cutoff = cutoff
        observedThrough = observedAt
        cutoffMs = timeline.milliseconds(at: cutoff)
        navigationIssued = timeline.instant(.loadIssued) != nil
        evidence = timeline.snapshot(through: cutoff)
        later = timeline.snapshot(through: observedAt, after: cutoff)
        stopReason = stop.flatMap { $0.instant <= possibleEnd ? $0.reason : nil }
        let laterStop = stop.flatMap { $0.instant > cutoff && $0.instant <= observedAt ? $0 : nil }
        laterStopReason = laterStop?.reason
        laterStopInstant = laterStop?.instant
        laterStopMs = laterStop.map { timeline.milliseconds(at: $0.instant) }

        if stopReason != nil { outcome = .stopped }
        else if evidence.localPolicyRejection != nil { outcome = .policyBlocked }
        else if evidence.milliseconds["documentFinish"] != nil { outcome = .finished }
        else if navigationIssued, evidence.failureDomain == NSURLErrorDomain,
                evidence.failureCode == NSURLErrorTimedOut { outcome = .timeout }
        else if evidence.failureDomain == nil, let observationDeadline, cutoff == observationDeadline { outcome = .timeout }
        else { outcome = .failed }
    }

    var fields: [String: Any] {
        var row = Self.fields(for: evidence)
        row["outcome"] = outcome.rawValue
        row["navigationIssued"] = navigationIssued
        row["observationCutoffMs"] = cutoffMs
        row["stopReason"] = stopReason?.rawValue
        if !later.isEmpty || laterStopReason != nil {
            var late = Self.fields(for: later)
            late["stopReason"] = laterStopReason?.rawValue
            late["stopAtMs"] = laterStopMs
            row["observedAfterCutoff"] = late
        }
        return row
    }

    static func fields(for snapshot: AccessTestNodeTimeline.Snapshot) -> [String: Any] {
        var fields: [String: Any] = [
            "timelineMs": snapshot.milliseconds,
            "timelineNs": snapshot.nanoseconds,
            "documentCommitted": snapshot.milliseconds["documentCommit"] != nil,
            "documentFinished": snapshot.milliseconds["documentFinish"] != nil,
            "initialResponseObserved": snapshot.initialHTTPStatus != nil,
            "serverRedirectCount": snapshot.serverRedirectCount,
            "navigationPolicy": snapshot.navigationPolicy
        ]
        fields["firstVisibleHTTPStatus"] = snapshot.firstHTTPStatus
        fields["initialHTTPStatus"] = snapshot.initialHTTPStatus
        fields["lastHTTPStatus"] = snapshot.lastHTTPStatus
        fields["localPolicyRejection"] = snapshot.localPolicyRejection
        fields["errorDomain"] = snapshot.failureDomain
        fields["errorCode"] = snapshot.failureCode
        if snapshot.milliseconds["loadNotAccepted"] != nil { fields["localLoadDisposition"] = "load-not-accepted" }
        if snapshot.milliseconds["preparationTimedOut"] != nil { fields["localPreparationDisposition"] = "preparation-timeout" }
        return fields
    }
}

final class AccessCampaignNavigationObservationTests: XCTestCase {
    func testQuiescenceWitnessSurvivesASeparateDocumentTimeout() {
        let requested = ContinuousClock.now
        let idle = requested + .seconds(2)
        let deadline = requested + .seconds(10)
        var quiescence = AccessCampaignQuiescence()
        quiescence.observe(idle: false, at: requested, through: deadline)
        quiescence.observe(idle: true, at: idle, through: deadline)
        quiescence.observe(idle: true, at: deadline + .milliseconds(10), through: deadline)
        XCTAssertEqual(quiescence.firstObserved, idle)

        var late = AccessCampaignQuiescence()
        late.observe(idle: true, at: deadline + .milliseconds(1), through: deadline)
        XCTAssertNil(late.firstObserved)
    }

    func testLoadWithoutHandleIsLocalAndDoesNotSupplyNetworkEvidence() {
        var timeline = AccessTestNodeTimeline()
        timeline.record(.preparationTimedOut)
        let preparation = AccessCampaignNavigationObservation(timeline: timeline, observationDeadline: nil,
                                                               observedAt: .now, stop: nil)
        XCTAssertEqual(preparation.outcome, .failed)
        XCTAssertNil(preparation.evidence.failureDomain)
        XCTAssertEqual(preparation.fields["localPreparationDisposition"] as? String, "preparation-timeout")

        timeline = AccessTestNodeTimeline()
        timeline.record(.loadNotAccepted)
        let report = AccessCampaignNavigationObservation(timeline: timeline, observationDeadline: nil,
                                                          observedAt: .now, stop: nil)
        XCTAssertFalse(report.navigationIssued)
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertNil(report.evidence.failureDomain)
        XCTAssertEqual(report.fields["localLoadDisposition"] as? String, "load-not-accepted")
    }

    func testUndispatchedPreparationUsesItsDeadlineBeforeALaterPermitStop() {
        let start = ContinuousClock.now
        let deadline = start + .seconds(15)
        let stopped = start + .seconds(16)
        var timeline = AccessTestNodeTimeline(origin: start)
        timeline.record(.preparationTimedOut, at: deadline)
        let observation = AccessCampaignNavigationObservation(timeline: timeline, observationDeadline: nil,
            preparationDeadline: deadline, observedAt: start + .seconds(18),
            stop: .init(reason: .runPermitExpired, instant: stopped))
        XCTAssertEqual(observation.outcome, .failed)
        XCTAssertEqual(observation.cutoffMs, 15_000)
        XCTAssertEqual(observation.fields["localPreparationDisposition"] as? String, "preparation-timeout")
        XCTAssertEqual(observation.laterStopMs, 16_000)
        XCTAssertEqual(observation.laterStopReason, .runPermitExpired)
        XCTAssertEqual(observation.laterStopInstant, stopped)
    }

    func testHaltAfterCutoffStaysSeparateFromTimeout() {
        let issued = ContinuousClock.now
        let cutoff = issued + .seconds(20)
        let stopped = cutoff + .milliseconds(10)
        var timeline = AccessTestNodeTimeline(origin: issued)
        timeline.record(.loadIssued, at: issued)
        let report = AccessCampaignNavigationObservation(timeline: timeline, observationDeadline: cutoff,
            observedAt: stopped, stop: .init(reason: .runPermitExpired, instant: stopped))
        XCTAssertEqual(report.outcome, .timeout)
        XCTAssertNil(report.stopReason)
        XCTAssertEqual(report.laterStopReason, .runPermitExpired)
        XCTAssertEqual(report.laterStopMs, 20_010)
    }

    func testLateHTTPAndLateFinishCannotResetTheNoHTTPTimeoutStreak() {
        var timeline = AccessTestNodeTimeline()
        let issued = ContinuousClock.now
        let cutoff = issued + .seconds(20)
        let late = cutoff + .milliseconds(1)
        timeline.record(.loadIssued, at: issued)
        timeline.record(.firstVisibleHTTPResponse, at: late)
        timeline.observe(.http(status: 200, initial: true), at: late)
        timeline.record(.documentCommit, at: late)
        timeline.record(.documentFinish, at: late)
        let report = AccessCampaignNavigationObservation(timeline: timeline, observationDeadline: cutoff,
                                                          observedAt: late, stop: nil)
        XCTAssertEqual(report.outcome, .timeout)
        XCTAssertNil(report.evidence.firstHTTPStatus)
        XCTAssertNil(report.evidence.milliseconds["documentFinish"])
        XCTAssertEqual(report.later.initialHTTPStatus, 200)
        XCTAssertNotNil(report.later.milliseconds["documentFinish"])
        var streak = AccessCampaignTimeoutStreak()
        for attempt in 1...3 {
            XCTAssertEqual(streak.observe(navigationIssued: report.navigationIssued, timedOut: report.outcome == .timeout,
                                          sawHTTP: report.evidence.firstHTTPStatus != nil), attempt == 3)
        }
    }

    func testExactCutoffIncludesResponseAndCommitButExcludesLaterPolicyAndFailure() {
        var timeline = AccessTestNodeTimeline()
        let issued = ContinuousClock.now
        let cutoff = issued + .seconds(20)
        let late = cutoff + .milliseconds(1)
        timeline.record(.loadIssued, at: issued)
        timeline.observe(.redirect, at: cutoff)
        timeline.record(.firstVisibleHTTPResponse, at: cutoff)
        timeline.observe(.http(status: 403, initial: false), at: cutoff)
        timeline.record(.documentCommit, at: cutoff)
        timeline.record(.policyRejection, at: late)
        timeline.observe(.policyRejection("additional-top-level-navigation"), at: late)
        timeline.record(.navigationFailure, at: late)
        timeline.observe(.failure(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed), at: late)
        let report = AccessCampaignNavigationObservation(timeline: timeline, observationDeadline: cutoff,
                                                          observedAt: late, stop: nil)
        XCTAssertEqual(report.outcome, .timeout)
        XCTAssertEqual(report.evidence.lastHTTPStatus, 403)
        XCTAssertNil(report.evidence.initialHTTPStatus)
        XCTAssertEqual(report.evidence.serverRedirectCount, 1)
        XCTAssertNotNil(report.evidence.milliseconds["documentCommit"])
        XCTAssertNil(report.evidence.failureCode)
        XCTAssertEqual(report.later.localPolicyRejection, "additional-top-level-navigation")
        XCTAssertEqual(report.later.failureCode, NSURLErrorSecureConnectionFailed)
    }

    func testRunStopBeforeDeadlineKeepsOnlyTheEarlierEvidence() {
        var timeline = AccessTestNodeTimeline()
        let issued = ContinuousClock.now
        let stopped = issued + .seconds(5)
        let finish = stopped + .milliseconds(20)
        timeline.record(.loadIssued, at: issued)
        timeline.observe(.http(status: 200, initial: true), at: stopped)
        timeline.record(.documentFinish, at: finish)
        timeline.record(.retirementCommit, at: finish)
        let report = AccessCampaignNavigationObservation(timeline: timeline, observationDeadline: issued + .seconds(20),
            observedAt: finish, stop: .init(reason: .runPermitExpired, instant: stopped))
        XCTAssertEqual(report.outcome, .stopped)
        XCTAssertEqual(report.evidence.initialHTTPStatus, 200)
        XCTAssertNil(report.evidence.milliseconds["documentFinish"])
        XCTAssertNotNil(report.later.milliseconds["documentFinish"])
        XCTAssertNil(report.later.milliseconds["retirementCommit"])
    }
}
#endif
