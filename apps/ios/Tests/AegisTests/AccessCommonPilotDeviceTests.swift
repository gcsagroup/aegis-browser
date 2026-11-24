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

    private enum Outcome: String {
        case finished, failed, timeout, stopped
        case policyBlocked = "policy-blocked"
    }

    @MainActor private struct Attempt {
        let outcome: Outcome
        let page: AccessTestNodePage
        let transport: String

        var fields: [String: Any] {
            var row: [String: Any] = [
                "outcome": outcome.rawValue,
                "timelineMs": page.timeline.milliseconds.filter { !$0.key.hasPrefix("retirement") },
                "navigationIssued": page.timeline.instant(.loadIssued) != nil,
                "documentCommitted": page.timeline.instant(.documentCommit) != nil,
                "documentFinished": page.timeline.instant(.documentFinish) != nil,
                "initialResponseObserved": page.initialHTTPStatus != nil,
                "serverRedirectCount": page.serverRedirectCount,
                "navigationPolicy": page.navigationPolicyObservation,
                "actualProtocol": transport
            ]
            row["firstVisibleHTTPStatus"] = page.firstVisibleHTTPStatus
            row["initialHTTPStatus"] = page.initialHTTPStatus
            row["lastHTTPStatus"] = page.httpStatus
            row["localPolicyRejection"] = page.localPolicyRejection
            row["errorDomain"] = page.failureDomain
            row["errorCode"] = page.failureCode
            row["port"] = page.initialBinding?.port
            return row
        }
    }

    private struct AttemptResult {
        let attempt: Attempt
        let retired: Bool
        let quiesced: Bool
        let retirementFields: [String: Any]
    }

    func testTEST01CommonFirst20() async throws {
        let input = try admittedInputs()
        guard input.environment["AEGIS_TEST_COMMON_PILOT"] == Self.campaignID else {
            throw XCTSkip("Frozen common-group pilot inputs are required")
        }
        let documents = Self.documents
        let prefix = "ios208-" + Self.campaignID
        let targets = try loadTargets(from: documents.appendingPathComponent(prefix + ".domains.txt"))
        let control = documents.appendingPathComponent(prefix + ".control")
        let ledger = try DurableLedger(url: documents.appendingPathComponent(prefix + "-dispatch.jsonl"))
        let (path, monitor) = startNetworkMonitor()
        defer { monitor.cancel() }
        let networkWait = ContinuousClock.now.advanced(by: .seconds(5))
        while !path.snapshot.reported, ContinuousClock.now < networkWait {
            try await Task.sleep(for: .milliseconds(50))
        }

        let budget = AccessCampaignBudget(duration: .seconds(Self.durationSeconds), bytes: Self.byteLimit)
        let window = makeWindow()
        defer { window.isHidden = true }
        func permitsTraffic() -> Bool {
            guard permitsPinnedNode(input.repository, revision: input.nodeRevision, budget: budget) else { return false }
            let controlValue = try? String(contentsOf: control, encoding: .utf8)
            if controlValue != "run\n" || !path.snapshot.wifi {
                budget.stop(.externalStop)
                return false
            }
            return true
        }
        func append(_ event: String, _ fields: [String: Any] = [:]) throws {
            var row = fields
            row["event"] = event
            row["schemaVersion"] = 2
            row["campaignID"] = Self.campaignID
            row["sourceSHA"] = input.source
            row["device"] = Self.deviceAlias
            row["nodeInputSHA256"] = Self.nodeDigest
            row["targetsSHA256"] = Self.targetsDigest
            row["elapsedMs"] = Self.milliseconds(budget.started.duration(to: .now))
            let bytes = budget.bytes
            row["chargedBytes"] = bytes.charged
            row["reservedBytes"] = bytes.reserved
            try ledger.append(row)
        }
        var reserved = 0
        func checkpoint(_ reason: String) throws {
            var fields: [String: Any] = ["reason": reason, "reservedCount": reserved]
            fields["budgetStopReason"] = budget.stopReason()?.rawValue
            try append("checkpoint", fields)
        }
        func health(_ phase: String) async throws -> Bool {
            guard permitsTraffic() else { return false }
            let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let url = input.origin.appendingPathComponent("health").appending(queryItems: [
                URLQueryItem(name: "nonce", value: nonce)
            ])
            let result = try await run(url, window: window, budget: budget, transport: .socks5,
                                       observation: .seconds(8), repository: input.repository, permit: permitsTraffic)
            try append("health", result.attempt.fields.merging(result.retirementFields) { first, _ in first }
                .merging(["phase": phase, "probeNonce": nonce]) { first, _ in first })
            return result.attempt.outcome == .finished && result.attempt.page.httpStatus == 200
                && result.attempt.transport == "socks5" && result.retired && result.quiesced
        }

        try append("start", ["byteLimit": Self.byteLimit, "durationLimitSeconds": Self.durationSeconds,
                             "maxTargets": targets.count, "noHTTPTimeoutLimit": Self.noHTTPLimit,
                             "bundle": Bundle.main.bundleIdentifier ?? "",
                             "os": ProcessInfo.processInfo.operatingSystemVersionString,
                             "network": path.snapshot.wifi ? "wifi" : "unavailable"])
        guard try await health("before-first-target") else {
            try checkpoint(budget.stopReason()?.rawValue ?? "health-check-failed")
            return
        }

        var streak = AccessCampaignTimeoutStreak()
        var preparationFailures = 0
        for (index, host) in targets.enumerated() {
            guard permitsTraffic() else {
                try checkpoint(budget.stopReason()?.rawValue ?? "external-stop")
                return
            }
            let url = try XCTUnwrap(URL(string: "https://" + host + "/"))
            let identity: [String: Any] = ["host": host, "ordinal": index + 1, "attempt": UUID().uuidString]
            // The before-load reservation is durable. A later abort still consumes
            // this key, and O_EXCL refuses a second launch of the entire pilot.
            reserved += 1
            try append("reserved", identity)
            let result = try await run(url, window: window, budget: budget, transport: .socks5,
                                       observation: .seconds(20), repository: input.repository, permit: permitsTraffic,
                                       resultCheckpoint: { attempt in
                var row = identity.merging(attempt.fields) { first, _ in first }
                if let issued = attempt.page.timeline.instant(.loadIssued) {
                    row["navigationIssuedAtMs"] = Self.milliseconds(budget.started.duration(to: issued))
                }
                try append("result", row)
            })
            try append("retirement", identity.merging(result.retirementFields) { first, _ in first })
            if let stop = budget.stopReason() {
                try checkpoint(stop.rawValue)
                return
            }
            guard result.retired else { try checkpoint("retirement-unconfirmed"); return }
            guard result.quiesced else { try checkpoint("transport-quiescence-unconfirmed"); return }
            let issued = result.attempt.page.timeline.instant(.loadIssued) != nil
            preparationFailures = issued ? 0 : preparationFailures + 1
            if preparationFailures == 3 { try checkpoint("repeated-preparation-failure"); return }
            if streak.observe(navigationIssued: issued, timedOut: result.attempt.outcome == .timeout,
                              sawHTTP: result.attempt.page.firstVisibleHTTPStatus != nil) {
                try append("dispatch-paused", ["reason": "three-no-http-timeouts", "reservedCount": reserved])
                _ = try await health("after-three-no-http-timeouts")
                try checkpoint("three-no-http-timeouts")
                return
            }
        }
        try checkpoint("target-limit")
    }

    func testControlledStageMatrixForBothInbounds() async throws {
        let input = try admittedInputs()
        guard input.environment["AEGIS_TEST_COMMON_MATRIX"] == "1" else {
            throw XCTSkip("Explicit controlled fixture required")
        }
        let window = makeWindow()
        defer { window.isHidden = true }
        let ledger = try fixtureLedger("matrix", input.environment)
        for transport in [AccessTestNodeTransport.http, .socks5] {
            for name in ["redirect", "script", "status", "certificate", "slow", "retire"] {
                let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                // BadSSL supplies a dedicated self-signed certificate test host.
                // Keep the certificate case on the same embedded TEST01 path.
                let target = name == "certificate"
                    ? URL(string: "https://self-signed.badssl.com/")!
                    : input.origin.appendingPathComponent(name).appending(queryItems: [URLQueryItem(name: "nonce", value: nonce)])
                let budget = AccessCampaignBudget(duration: .seconds(30), bytes: 8 * 1024 * 1024)
                let result = try await run(target, window: window, budget: budget, transport: transport,
                                           observation: name == "slow" ? .seconds(8) : .seconds(20),
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

    private func run(_ url: URL, window: UIWindow, budget: AccessCampaignBudget,
                     transport: AccessTestNodeTransport, observation: Duration,
                     settleBeforeRetiring: Duration = .zero, competeDuringRetirement: Bool = false,
                     repository: AccessTestNodeRepository, permit: @escaping () -> Bool = { true },
                     afterCommit: ((any AccessEmbeddedCoreControlling) async throws -> Void)? = nil,
                     resultCheckpoint: (Attempt) throws -> Void = { _ in }) async throws -> AttemptResult {
        let core = AccessCampaignMeteredCore(base: try AccessGoEmbeddedCore(isolated: true), budget: budget)
        let page = AccessTestNodePage(isPrivate: false, repository: repository, testingCore: core, singleNavigation: true,
                                      transport: transport, navigationAllowed: { budget.stopReason() == nil && permit() },
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
        await page.open(url)
        if let view = page.webView {
            view.frame = window.bounds
            window.addSubview(view)
        }
        let navigationDeadline = page.timeline.instant(.loadIssued)?.advanced(by: observation)
        var commitAction = afterCommit
        if let navigationDeadline {
            while page.status == "正在加载", budget.stopReason() == nil, ContinuousClock.now < navigationDeadline {
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
        let finishedWithinBudget = page.timeline.instant(.documentFinish).map { finish in
            navigationDeadline.map { finish <= $0 } ?? false
        } ?? false
        let outcome: Outcome
        if budget.stopReason() != nil || !permit() { outcome = .stopped }
        else if page.localPolicyRejection != nil { outcome = .policyBlocked }
        else if finishedWithinBudget { outcome = .finished }
        else if page.status == "正在加载" || page.timeline.instant(.documentFinish) != nil
            || (page.failureDomain == NSURLErrorDomain
                 && page.failureCode == NSURLErrorTimedOut && navigationDeadline != nil) { outcome = .timeout }
        else { outcome = .failed }
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
        let attempt = Attempt(outcome: outcome, page: page, transport: actualProtocol)
        try resultCheckpoint(attempt)
        // Close signals the product fence before awaiting local retirement. The
        // deadline does not grant extra browsing time for the retirement wait.
        page.close()
        if competeDuringRetirement { _ = page.webView?.load(URLRequest(url: URL(string: "about:blank")!)) }
        let requested = page.timeline.instant(.retirementRequested) ?? .now
        let retirementDeadline = requested.advanced(by: .seconds(10))
        while (page.endpoint != nil || core.isRunning || budget.bytes.reserved > 0),
              ContinuousClock.now < retirementDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let commit = page.timeline.instant(.retirementCommit)
        let unbound = page.webView == nil
        let retired = unbound || (page.endpoint == nil && (commit.map { $0 <= retirementDeadline } ?? false))
        let quiesced = !core.isRunning && budget.bytes.reserved == 0
        if retired { page.webView?.removeFromSuperview() }
        var retirement: [String: Any] = [
            "retirementState": unbound ? "unbound" : retired ? "confirmed" : "unconfirmed",
            "transportQuiesced": quiesced,
            "retirementEvents": page.retirementEvents,
            "retirementObservedMs": Self.milliseconds(requested.duration(to: .now))
        ]
        retirement["retirementRequestedAtMs"] = page.timeline.milliseconds["retirementRequested"]
        retirement["retirementCommitAtMs"] = page.timeline.milliseconds["retirementCommit"]
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
    }
}
#endif
