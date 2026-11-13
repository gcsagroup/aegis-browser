import Network
import os
import WebKit
import XCTest

/// I0 counterexamples. A passing assertion here means the public WebKit proxy
/// API does **not** meet the exact-host / top-level-document contract.
@MainActor
final class AccessWebKitRoutingCapabilityTests: XCTestCase {
    func testMatchDomainsAlsoProxiesChildHost() async throws {
        let probe = try RoutingProxyProbe()
        try await probe.start()
        defer { probe.stop() }
        let store = WKWebsiteDataStore.nonPersistent()
        var proxy = ProxyConfiguration(httpCONNECTProxy: probe.endpoint)
        proxy.matchDomains = ["target.invalid"]
        store.proxyConfigurations = [proxy]

        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration(store))
        let sawChild = expectation(description: "child host reaches proxy")
        probe.onText = { text in
            if text.contains("child.target.invalid") {
                sawChild.fulfill()
            }
        }
        page.load(URLRequest(url: URL(string: "http://child.target.invalid/")!))
        await fulfillment(of: [sawChild], timeout: 8)
        XCTAssertTrue(
            probe.transcript.contains("child.target.invalid"),
            "matchDomains=[target.invalid] also proxied child.target.invalid; exact-host contract is not met"
        )
    }

    func testAnotherTopLevelDocumentForMatchedHostAlsoUsesProxy() async throws {
        let probe = try RoutingProxyProbe()
        try await probe.start()
        defer { probe.stop() }
        let store = WKWebsiteDataStore.nonPersistent()
        var proxy = ProxyConfiguration(httpCONNECTProxy: probe.endpoint)
        proxy.matchDomains = ["target.invalid"]
        store.proxyConfigurations = [proxy]

        let first = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration(store))
        let second = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration(store))
        _ = first
        let sawTarget = expectation(description: "second top-level document reaches proxy")
        probe.onText = { text in
            if text.contains("target.invalid") {
                sawTarget.fulfill()
            }
        }
        second.load(URLRequest(url: URL(string: "http://target.invalid/")!))
        await fulfillment(of: [sawTarget], timeout: 8)
        XCTAssertTrue(
            probe.transcript.contains("target.invalid"),
            "a different top-level WKWebView on the same data store inherited the proxy; document-scoped authorization is not available"
        )
    }

    private func configuration(_ store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        return configuration
    }
}

private final class RoutingProxyProbe: @unchecked Sendable {
    private(set) var endpoint: NWEndpoint = .hostPort(host: "127.0.0.1", port: 9)
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "access.i0.proxy-probe")
    private let lock = OSAllocatedUnfairLock(initialState: "")
    var onText: ((String) -> Void)?

    var transcript: String {
        lock.withLock { $0 }
    }

    init() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(connection)
        }
        self.listener = listener
    }

    func start() async throws {
        guard let listener else { throw RoutingProbeError.listenerFailed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { continuation.resume() }
                case .failed(let error):
                    if once.take() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.take() { continuation.resume(throwing: RoutingProbeError.listenerFailed) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        guard let port = listener.port else {
            listener.cancel()
            throw RoutingProbeError.listenerFailed
        }
        endpoint = .hostPort(host: "127.0.0.1", port: port)
    }

    func stop() {
        listener?.cancel()
    }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data, let chunk = String(data: data, encoding: .utf8) else { return }
            let snapshot = self.lock.withLock { text -> String in
                text.append(chunk)
                return text
            }
            self.onText?(snapshot)
            connection.cancel()
        }
    }
}

private enum RoutingProbeError: Error {
    case listenerFailed
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    func take() -> Bool {
        lock.withLock { done in
            if done { return false }
            done = true
            return true
        }
    }
}
