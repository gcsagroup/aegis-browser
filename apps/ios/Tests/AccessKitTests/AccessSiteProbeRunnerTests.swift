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
}
