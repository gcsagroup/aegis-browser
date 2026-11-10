import AccessKit
import UIKit
import WebKit
import XCTest
@testable import Aegis
@testable import BrowserKit

/// Failed page reloads through the app HTTP CONNECT listener, not a test-only proxy socket.
@MainActor
final class AccessHostRecoveryWebKitTests: XCTestCase {
    func testFailedPageReloadsOnceThroughTheListener() async throws {
        let nonce = UUID().uuidString
        let opener = AnsweringOpener()
        let listener = try makeListener(port: 18_240, tunnels: opener)
        try listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let publisher = readyPublisher(port: 18_240)
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessContinuousPreparationClock())
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.standardTabs.forEach { $0.stop() } }
        let tab = try XCTUnwrap(browser.activeTab)
        tab.hostCoordinator = coordinator
        let window = show(tab.webView)
        defer { window.isHidden = true }

        var request = URLRequest(url: URL(string: "http://example.invalid/page?n=\(nonce)")!)
        request.httpMethod = "GET"
        let sink = NavigationSink()
        tab.load(request)
        tab.webView.navigationDelegate = sink
        tab.webView.stopLoading()
        deliverFailure(tab)
        XCTAssertTrue(tab.loadingErrorAllowsProxyRetry)
        let operation = coordinator.retryViaProxy(tab: tab)
        XCTAssertNotNil(operation)
        let deadline = Date().addingTimeInterval(15)
        while !opener.transcript.contains(nonce), Date() < deadline {
            if tab.webView.superview == nil {
                tab.webView.frame = window.bounds
                window.addSubview(tab.webView)
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(tab.recoveryLoadCount, 1, coordinator.lastRecoveryFailure ?? opener.transcript)
        XCTAssertTrue(opener.transcript.contains(nonce), "admission=\(listener.admissionSummary) body=\(opener.transcript)")
        XCTAssertTrue(opener.transcript.contains("cdn.invalid"), opener.transcript)
    }

    func testUnrelatedHostDoesNotEnterTheListener() async throws {
        let opener = AnsweringOpener()
        let listener = try makeListener(port: 18_241, tunnels: opener)
        try listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.standardTabs.forEach { $0.stop() } }
        let tab = try XCTUnwrap(browser.activeTab)
        let window = show(tab.webView)
        defer { window.isHidden = true }
        tab.load(URLRequest(url: URL(string: "http://other.invalid/")!))
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(opener.transcript.contains("other.invalid"))
    }

    func testFailedEndpointKeepsTheProxyAndDoesNotAddADirectRequest() async throws {
        let opener = AnsweringOpener()
        let listener = try makeListener(port: 18_242, tunnels: opener)
        try listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let publisher = readyPublisher(port: 18_242)
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessContinuousPreparationClock())
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.standardTabs.forEach { $0.stop() } }
        let tab = try XCTUnwrap(browser.activeTab)
        tab.hostCoordinator = coordinator
        let window = show(tab.webView)
        defer { window.isHidden = true }
        let sink = NavigationSink()
        tab.load(URLRequest(url: URL(string: "http://example.invalid/kept")!))
        tab.webView.navigationDelegate = sink
        tab.webView.stopLoading()
        deliverFailure(tab)
        XCTAssertTrue(tab.loadingErrorAllowsProxyRetry)
        _ = coordinator.retryViaProxy(tab: tab)
        try await waitUntil({ opener.transcript.contains("example.invalid") }, message: opener.transcript)
        let host = try AccessSiteHost("example.invalid")
        let store = try XCTUnwrap(coordinator.registry.storeForTab(
            tabID: tab.id.uuidString,
            scopeID: "ordinary",
            isPrivate: false,
            targetHost: host,
            boundHost: host,
            intent: .on
        ))
        let before = store.proxyConfigurations.count
        let seen = opener.transcript
        coordinator.registry.setEndpoint(
            AccessManagedProxyEndpoint(
                identity: "entry-failed",
                generation: 9,
                loopbackHost: "127.0.0.1",
                port: 18_242,
                state: .failed
            ),
            scopeID: "ordinary",
            host: host,
            isPrivate: false
        )
        tab.load(URLRequest(url: URL(string: "http://example.invalid/again")!))
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(store.proxyConfigurations.count, before)
        XCTAssertFalse(store.proxyConfigurations.isEmpty)
        XCTAssertEqual(opener.transcript, seen)
    }

    private func readyPublisher(port: UInt16) -> AccessProxyEntryPublisher {
        AccessProxyEntryPublisher { generation, _ in
            AccessProxyEntryPublisher.Provision(
                endpoint: AccessManagedProxyEndpoint(
                    identity: "listener-\(port)",
                    generation: generation,
                    loopbackHost: "127.0.0.1",
                    port: port,
                    state: .ready
                ),
                listenerReady: true,
                runtimeHealthy: true,
                bridgeInstalled: true
            )
        }
    }

    private func makeListener(port: UInt16, tunnels: any AccessHTTPTunnelOpening) throws -> AccessHTTPInboundListener {
        let registration = AccessRegistration(
            id: try AccessRegistrationID("reg-webkit-\(port)"),
            owner: try AccessOwner(channel: 1, profile: "ordinary", partition: "default"),
            transport: .http,
            endpoint: try AccessEndpoint(host: "127.0.0.1", port: port),
            credentialSlot: try AccessCredentialSlot(id: "cred-webkit-\(port)"),
            lease: try AccessLease(generation: 1, expiresAt: Date(timeIntervalSince1970: 1_700_000_060))
        )
        return try AccessHTTPInboundListener(registration: registration, tunnels: tunnels)
    }

    private func show(_ view: WKWebView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        view.frame = window.bounds
        window.addSubview(view)
        window.makeKeyAndVisible()
        return window
    }

    private func deliverFailure(_ tab: BrowserTab) {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        tab.webView(tab.webView, didFailProvisionalNavigation: tab.currentNavigationForTests, withError: error)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        message: String = ""
    ) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(condition(), message)
    }
}

private final class NavigationSink: NSObject, WKNavigationDelegate {}

private final class AnsweringOpener: AccessHTTPTunnelOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    var transcript: String {
        lock.lock(); defer { lock.unlock() }
        return text
    }

    func open(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        let stream = AnsweringStream(host: host)
        stream.onRequest = { [weak self] request in
            self?.append(request)
        }
        return stream
    }

    fileprivate func append(_ request: String) {
        lock.lock()
        text.append(request)
        lock.unlock()
    }
}

private final class AnsweringStream: AccessRealityPathStream, @unchecked Sendable {
    let host: String
    var onRequest: ((String) -> Void)?
    private let lock = NSLock()
    private var request = Data()
    private var response = Data()
    private var closed = false
    private var readers: [CheckedContinuation<Data?, Error>] = []
    private var announced = false

    init(host: String) { self.host = host }

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed
    }

    func read(maxBytes: Int) async throws -> Data? {
        return try await withCheckedThrowingContinuation { continuation in
            if let immediate = self.takeResponse(maxBytes: maxBytes, continuation: continuation) {
                continuation.resume(returning: immediate)
            }
        }
    }

    func write(_ data: Data) async throws {
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            onRequest?(text)
        }
        let finished = appendRequest(data)
        if let finished {
            enqueue(answer(for: finished))
        }
    }

    func close() {
        let pending = closeLocked()
        pending.forEach { $0.resume(returning: nil) }
    }

    private func appendRequest(_ data: Data) -> String? {
        lock.lock()
        defer { lock.unlock() }
        request.append(data)
        guard !announced, let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
            return nil
        }
        announced = true
        return text
    }

    private func answer(for request: String) -> Data {
        let body = host == "cdn.invalid"
            ? "body{}"
            : "<link rel=\"stylesheet\" href=\"http://cdn.invalid/a.css\">"
        let type = host == "cdn.invalid" ? "text/css" : "text/html"
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = request
        return Data(header.utf8)
    }

    private func enqueue(_ data: Data) {
        lock.lock()
        let reader = readers.isEmpty ? nil : readers.removeFirst()
        if reader == nil { response.append(data) }
        lock.unlock()
        reader?.resume(returning: data)
    }

    private func takeResponse(maxBytes: Int, continuation: CheckedContinuation<Data?, Error>) -> Data?? {
        lock.lock()
        defer { lock.unlock() }
        if closed, response.isEmpty { return .some(nil) }
        if !response.isEmpty {
            let count = min(maxBytes, response.count)
            let chunk = Data(response.prefix(count))
            response.removeFirst(count)
            return .some(chunk)
        }
        readers.append(continuation)
        return nil
    }

    private func closeLocked() -> [CheckedContinuation<Data?, Error>] {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        let pending = readers
        readers.removeAll()
        return pending
    }
}
