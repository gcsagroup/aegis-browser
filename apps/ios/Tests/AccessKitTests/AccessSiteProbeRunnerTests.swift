import XCTest
@testable import AccessKit

final class AccessSiteProbeRunnerTests: XCTestCase {
    func testPlanSkipsProxiedHostsAndCapsAtThree() throws {
        let direct = try AccessSiteHost("direct.example")
        let proxied = try AccessSiteHost("proxied.example")
        let plan = try XCTUnwrap(
            AccessSiteProbePlan.make(
                candidates: [
                    proxied,
                    direct,
                    try AccessSiteHost("a.example"),
                    try AccessSiteHost("b.example"),
                    try AccessSiteHost("c.example")
                ],
                alreadyRequiringProxy: [proxied],
                channel: .dev
            )
        )
        XCTAssertEqual(plan.hosts.count, 3)
        XCTAssertFalse(plan.hosts.contains(proxied))
        XCTAssertNil(
            AccessSiteProbePlan.make(
                candidates: [direct],
                alreadyRequiringProxy: [],
                channel: .release
            )
        )
    }

    func testRunnerMarksAlreadyProxiedWithoutNetworking() async throws {
        let host = try AccessSiteHost("skip.example")
        let runner = AccessSiteProbeRunner(sessionFactory: {
            XCTFail("already-proxied hosts must not open a session task")
            return URLSession(configuration: .ephemeral)
        })
        let report = await runner.run(
            plan: AccessSiteProbePlan(hosts: [host]),
            alreadyRequiringProxy: [host]
        )
        XCTAssertEqual(report.results.count, 1)
        XCTAssertEqual(report.results[0].outcome, .skippedAlreadyProxied)
        XCTAssertEqual(
            report.suggestionLines,
            ["skip.example · 已要求代理，跳过直连探测"]
        )
    }

    func testRunnerRechecksProxyRequirementPerHost() async throws {
        let first = try AccessSiteHost("a.example")
        let second = try AccessSiteHost("b.example")
        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var armed: Set<AccessSiteHost> = []
            func require(_ host: AccessSiteHost, arming other: AccessSiteHost) -> Bool {
                lock.lock(); defer { lock.unlock() }
                if host == other { return armed.contains(host) }
                armed.insert(other)
                return true
            }
        }
        let gate = Gate()
        let runner = AccessSiteProbeRunner(sessionFactory: {
            XCTFail("recheck skip must not dial")
            return URLSession(configuration: .ephemeral)
        })
        let report = await runner.run(
            plan: AccessSiteProbePlan(hosts: [first, second]),
            alreadyRequiringProxy: [],
            requiresProxy: { host in
                gate.require(host, arming: second)
            }
        )
        XCTAssertEqual(report.results.map(\.outcome), [.skippedAlreadyProxied, .skippedAlreadyProxied])
    }

}
