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

    func testHTTPResponsesAndATSAreDistinguishableFromTransportFailure() async throws {
        let runner = AccessSiteProbeRunner(sessionFactory: {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SiteProbeProtocol.self]
            return URLSession(configuration: config)
        })
        for code in [200, 403, 429, 503] {
            let host = try AccessSiteHost("status-\(code).example")
            let report = await runner.run(plan: .init(hosts: [host]), alreadyRequiringProxy: [])
            XCTAssertEqual(report.results.first?.outcome, .reachable)
            XCTAssertEqual(report.results.first?.httpStatus, code)
            if code >= 400 { XCTAssertTrue(report.suggestionLines.first?.contains("HTTP \(code)") == true) }
        }
        let host = try AccessSiteHost("ats.example")
        let report = await runner.run(plan: .init(hosts: [host]), alreadyRequiringProxy: [])
        XCTAssertEqual(report.results.first?.outcome, .insecureTransportBlocked)
        XCTAssertNil(report.results.first?.httpStatus)
    }

    func testRedirectStopsBeforeFollowingEitherHostOrTransportChanges() throws {
        let origin = try XCTUnwrap(URL(string: "https://probe.example/"))
        let response = try XCTUnwrap(HTTPURLResponse(url: origin, statusCode: 302,
                                                     httpVersion: "HTTP/1.1", headerFields: nil))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: origin)
        let cases: [(String, AccessSiteProbeOutcome?)] = [
            ("https://probe.example/next", nil),
            ("http://probe.example/next", .insecureTransportBlocked),
            ("https://other.example/next", .redirectedOffHost),
            ("http://other.example/next", .redirectedOffHost)
        ]
        for (destination, outcome) in cases {
            let guardDelegate = AccessSiteProbeRedirectGuard(expectedHost: "probe.example")
            let request = URLRequest(url: try XCTUnwrap(URL(string: destination)))
            let decision = expectation(description: destination)
            guardDelegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                     newRequest: request) { next in
                XCTAssertNil(next)
                decision.fulfill()
            }
            wait(for: [decision], timeout: 1)
            XCTAssertEqual(guardDelegate.stoppedOutcome, outcome, destination)
        }
    }

    func testThumbnailProbeKeepsTheChosenHostAndUsesAnImagePath() async throws {
        let runner = AccessSiteProbeRunner(sessionFactory: {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SiteProbeProtocol.self]
            return URLSession(configuration: config)
        })
        let host = try AccessSiteHost("i.ytimg.com")
        let report = await runner.run(plan: .init(hosts: [host]), alreadyRequiringProxy: [])
        XCTAssertEqual(report.results.first?.httpStatus, 200)
    }
}

private final class SiteProbeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        if host == "ats.example" {
            client?.urlProtocol(self, didFailWithError: URLError(.appTransportSecurityRequiresSecureConnection))
            return
        }
        let status: Int
        if host == "i.ytimg.com" {
            status = request.httpMethod == "HEAD" && url.path == "/vi/M7lc1UVf-VE/hqdefault.jpg" ? 200 : 404
        } else {
            status = Int(host.dropFirst("status-".count).prefix(while: { $0.isNumber })) ?? 500
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}
