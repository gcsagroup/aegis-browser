import Foundation
import Synchronization

/// Outcome of one DEV/Alpha suggestion probe. Never expands authorization.
public enum AccessSiteProbeOutcome: String, Sendable, Equatable {
    case reachable
    case timedOut
    case redirectedOffHost
    case skippedAlreadyProxied
    case failed
}

public struct AccessSiteProbeHostResult: Sendable, Equatable {
    public var host: AccessSiteHost
    public var outcome: AccessSiteProbeOutcome
    public var detail: String

    public init(host: AccessSiteHost, outcome: AccessSiteProbeOutcome, detail: String) {
        self.host = host
        self.outcome = outcome
        self.detail = detail
    }
}

public struct AccessSiteProbeReport: Sendable, Equatable {
    public var results: [AccessSiteProbeHostResult]
    public var exhaustedBudget: Bool

    public init(results: [AccessSiteProbeHostResult], exhaustedBudget: Bool) {
        self.results = results
        self.exhaustedBudget = exhaustedBudget
    }

    public var suggestionLines: [String] {
        results.map { item in
            switch item.outcome {
            case .reachable:
                return "\(item.host.rawValue) · 直连可达（仅建议）"
            case .timedOut:
                return "\(item.host.rawValue) · 探测超时"
            case .redirectedOffHost:
                return "\(item.host.rawValue) · 跨域跳转已停止"
            case .skippedAlreadyProxied:
                return "\(item.host.rawValue) · 已要求代理，跳过直连探测"
            case .failed:
                return "\(item.host.rawValue) · 探测失败"
            }
        }
    }
}

/// Ephemeral HEAD probes. No cookies, no credentials, no navigation coupling.
public struct AccessSiteProbeRunner: Sendable {
    public var sessionFactory: @Sendable () -> URLSession

    public init(
        sessionFactory: @escaping @Sendable () -> URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 5
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            return URLSession(configuration: configuration)
        }
    ) {
        self.sessionFactory = sessionFactory
    }

    public func run(
        plan: AccessSiteProbePlan,
        alreadyRequiringProxy: Set<AccessSiteHost>,
        budget: Duration = AccessSiteProbePlan.budget,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        requiresProxy: (@Sendable (AccessSiteHost) async -> Bool)? = nil
    ) async -> AccessSiteProbeReport {
        let started = now()
        let deadline = started.advanced(by: budget)
        var results: [AccessSiteProbeHostResult] = []
        var session: URLSession?

        for host in plan.hosts {
            if now() >= deadline {
                session?.invalidateAndCancel()
                return AccessSiteProbeReport(results: results, exhaustedBudget: true)
            }
            // Recheck per host so a mid-batch proxy arm skips the remaining direct probes.
            let skipDirect: Bool
            if let requiresProxy {
                skipDirect = await requiresProxy(host)
            } else {
                skipDirect = alreadyRequiringProxy.contains(host)
            }
            if skipDirect {
                results.append(
                    AccessSiteProbeHostResult(
                        host: host,
                        outcome: .skippedAlreadyProxied,
                        detail: "already requiring proxy"
                    )
                )
                continue
            }
            let active = session ?? {
                let created = sessionFactory()
                session = created
                return created
            }()
            // Recheck again immediately before the socket work so a mid-batch arm
            // that landed after the first check still skips the direct probe.
            if let requiresProxy, await requiresProxy(host) {
                results.append(
                    AccessSiteProbeHostResult(
                        host: host,
                        outcome: .skippedAlreadyProxied,
                        detail: "already requiring proxy"
                    )
                )
                continue
            }
            let result = await probe(host: host, session: active)
            results.append(result)
            if result.outcome == AccessSiteProbeOutcome.redirectedOffHost {
                break
            }
        }
        session?.invalidateAndCancel()
        return AccessSiteProbeReport(results: results, exhaustedBudget: now() >= deadline)
    }

    private func probe(
        host: AccessSiteHost,
        session: URLSession
    ) async -> AccessSiteProbeHostResult {
        guard let url = URL(string: "https://\(host.rawValue)/") else {
            return AccessSiteProbeHostResult(host: host, outcome: .failed, detail: "bad url")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        let guardDelegate = RedirectGuard(expectedHost: host.rawValue)
        do {
            let (_, response) = try await session.data(for: request, delegate: guardDelegate)
            if guardDelegate.redirectedOffHost {
                return AccessSiteProbeHostResult(
                    host: host,
                    outcome: .redirectedOffHost,
                    detail: "cross-host redirect"
                )
            }
            guard let http = response as? HTTPURLResponse else {
                return AccessSiteProbeHostResult(host: host, outcome: .failed, detail: "non-http")
            }
            if (200..<400).contains(http.statusCode) {
                return AccessSiteProbeHostResult(
                    host: host,
                    outcome: .reachable,
                    detail: "status \(http.statusCode)"
                )
            }
            return AccessSiteProbeHostResult(
                host: host,
                outcome: .failed,
                detail: "status \(http.statusCode)"
            )
        } catch let error as URLError where error.code == .timedOut {
            return AccessSiteProbeHostResult(host: host, outcome: .timedOut, detail: "url timeout")
        } catch {
            if guardDelegate.redirectedOffHost {
                return AccessSiteProbeHostResult(
                    host: host,
                    outcome: .redirectedOffHost,
                    detail: "cross-host redirect"
                )
            }
            return AccessSiteProbeHostResult(host: host, outcome: .failed, detail: "network")
        }
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let expectedHost: String
    private let flags = Mutex(false)

    var redirectedOffHost: Bool {
        flags.withLock { $0 }
    }

    init(expectedHost: String) {
        self.expectedHost = expectedHost.lowercased()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let nextHost = request.url?.host?.lowercased()
        if nextHost != expectedHost {
            flags.withLock { $0 = true }
            completionHandler(nil)
            return
        }
        // Never follow same-host redirects on ephemeral probes. Following would
        // issue another direct hop after the caller may have armed proxy mid-flight.
        // The redirect response itself (3xx) still counts as reachable above.
        completionHandler(nil)
    }
}
