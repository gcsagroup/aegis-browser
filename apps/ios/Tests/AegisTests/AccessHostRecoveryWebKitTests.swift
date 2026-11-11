import AccessKit
import Network
import os
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
        let listener = try await makeListener(port: 18_240, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
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
        while !(opener.transcript.contains(nonce) && opener.transcript.contains("cdn.invalid")), Date() < deadline {
            if tab.webView.superview == nil {
                tab.webView.frame = window.bounds
                window.addSubview(tab.webView)
                window.makeKeyAndVisible()
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(tab.recoveryLoadCount, 1, coordinator.lastRecoveryFailure ?? opener.transcript)
        XCTAssertTrue(opener.transcript.contains(nonce), "admission=\(listener.admissionSummary) body=\(opener.transcript)")
        XCTAssertTrue(opener.transcript.contains("cdn.invalid"), opener.transcript)
    }

    func testUnreadyTabKeepsTheOriginalStore() async throws {
        let opener = AnsweringOpener()
        let listener = try await makeListener(port: 18_244, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let publisher = AccessProxyEntryPublisher { _, _ in
            throw AccessSiteSessionError.nodeUnavailable
        }
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessContinuousPreparationClock())
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.standardTabs.forEach { $0.stop() } }
        let tab = try XCTUnwrap(browser.activeTab)
        tab.hostCoordinator = coordinator
        let original = tab.websiteDataStore
        let window = show(tab.webView)
        defer { window.isHidden = true }
        tab.load(URLRequest(url: URL(string: "http://example.invalid/unready")!))
        tab.webView.navigationDelegate = NavigationSink()
        tab.webView.stopLoading()
        deliverFailure(tab)
        XCTAssertNotNil(coordinator.retryViaProxy(tab: tab))
        try await Task.sleep(for: .milliseconds(400))
        let host = try AccessSiteHost("example.invalid")
        XCTAssertNil(coordinator.registry.store(
            scopeID: "ordinary",
            host: host,
            isPrivate: false
        ))
        XCTAssertTrue(tab.websiteDataStore === original)
        XCTAssertEqual(tab.recoveryLoadCount, 0)
        XCTAssertFalse(opener.transcript.contains("example.invalid"))
        let snapshot = coordinator.snapshot(for: tab)
        XCTAssertTrue(snapshot.toggleOn)
        XCTAssertEqual(snapshot.attachment, .notAttached)
        XCTAssertEqual(
            AccessSiteProxyToggleModel.attachmentLine(for: snapshot.attachment, intent: snapshot.intent),
            "尚未接入代理，当前页面仍使用原连接"
        )
        XCTAssertNil(snapshot.failureReason)
    }

    func testHttpsReloadRecordsConnectAuthority() async throws {
        let opener = AnsweringOpener()
        let listener = try await makeListener(port: 18_245, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let publisher = readyPublisher(port: 18_245)
        let coordinator = AccessHostStoreCoordinator(publisher: publisher, clock: AccessContinuousPreparationClock())
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.standardTabs.forEach { $0.stop() } }
        let tab = try XCTUnwrap(browser.activeTab)
        tab.hostCoordinator = coordinator
        let window = show(tab.webView)
        defer { window.isHidden = true }
        let sink = NavigationSink()
        tab.load(URLRequest(url: URL(string: "https://example.invalid/secure")!))
        tab.webView.navigationDelegate = sink
        tab.webView.stopLoading()
        deliverFailure(tab)
        XCTAssertNotNil(coordinator.retryViaProxy(tab: tab))
        let deadline = Date().addingTimeInterval(8)
        while !listener.admissionSummary.contains("example.invalid:443"), Date() < deadline {
            if tab.webView.superview == nil {
                tab.webView.frame = window.bounds
                window.addSubview(tab.webView)
                window.makeKeyAndVisible()
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(tab.recoveryLoadCount, 1)
        XCTAssertTrue(
            listener.admissionSummary.contains("example.invalid:443"),
            listener.admissionSummary
        )
        XCTAssertFalse(opener.transcript.contains("GET /secure"))
    }

    func testUnrelatedHostDoesNotEnterTheListener() async throws {
        let opener = AnsweringOpener()
        let listener = try await makeListener(port: 18_241, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
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
        let listener = try await makeListener(port: 18_242, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
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
        try await waitUntil({
            if tab.webView.superview == nil {
                tab.webView.frame = window.bounds
                window.addSubview(tab.webView)
                window.makeKeyAndVisible()
            }
            return opener.transcript.contains("example.invalid")
        }, message: "proxy=\(opener.transcript) loads=\(tab.recoveryLoadCount) loading=\(tab.isLoading) failure=\(coordinator.lastRecoveryFailure ?? "") error=\(tab.loadingError ?? "")")
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

    func testAutoRecoverySendsTheMemberThroughTheProxyAndTheOutsideHostToOrigin() async throws {
        let origin = OriginReceipt(port: 18_247)
        try await origin.start()
        defer { origin.stop() }
        let opener = AnsweringOpener()
        let listener = try await makeListener(port: 18_246, tunnels: opener)
        try await listener.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? listener.stop() }
        let coordinator = AccessHostStoreCoordinator(
            publisher: readyPublisher(port: 18_246),
            clock: AccessContinuousPreparationClock()
        )
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.standardTabs.forEach { $0.stop() } }
        browser.hostCoordinator = coordinator
        let shop = try XCTUnwrap(browser.activeTab)
        let window = show(shop.webView)
        defer { window.isHidden = true }
        shop.load(URLRequest(url: URL(string: "https://shop.example/home")!))
        shop.commitPendingMainFrameForTests()
        let login = try AccessSiteHost("login.example")
        guard case .armed = coordinator.setAutoRecoveryEnabled(true, for: shop, members: [login]) else {
            return XCTFail("committed shop page should only arm")
        }
        XCTAssertEqual(coordinator.registry.ordinaryStores().count, 0)

        let member = browser.newTab()
        let nonce = UUID().uuidString
        member.load(URLRequest(url: URL(string: "http://login.example/start?n=\(nonce)")!))
        member.webView.navigationDelegate = NavigationSink()
        if member.webView.superview == nil {
            member.webView.frame = window.bounds
            window.addSubview(member.webView)
        }
        member.webView.stopLoading()
        deliverFailure(member)
        try await waitUntil(seconds: 15, {
            if member.webView.superview == nil {
                member.webView.frame = window.bounds
                window.addSubview(member.webView)
                window.makeKeyAndVisible()
            }
            return opener.transcript.contains(nonce) && opener.transcript.contains("cdn.invalid")
        }, message: "proxy=\(opener.transcript) loads=\(member.recoveryLoadCount) loading=\(member.isLoading) failure=\(coordinator.lastRecoveryFailure ?? "") error=\(member.loadingError ?? "") last=\(member.lastMainFrameFailure?.url.absoluteString ?? "")")
        guard opener.transcript.contains(nonce), opener.transcript.contains("cdn.invalid") else { return }
        XCTAssertEqual(member.recoveryLoadCount, 1)

        var probe = URLRequest(url: URL(string: "http://127.0.0.1:\(origin.port)/ping")!)
        probe.timeoutInterval = 3
        let probeResponse = try await URLSession.shared.data(for: probe).1 as? HTTPURLResponse
        XCTAssertEqual(probeResponse?.statusCode, 200, origin.transcript)
        XCTAssertTrue(origin.transcript.contains("GET /ping"), origin.transcript)

        let outside = UUID().uuidString
        let direct = browser.newTab()
        try await direct.prepareContentRulesForTests()
        direct.load(URLRequest(url: URL(string: "http://127.0.0.1:\(origin.port)/outside?n=\(outside)")!))
        direct.webView.frame = window.bounds
        window.addSubview(direct.webView)
        window.makeKeyAndVisible()
        try await waitUntil(seconds: 20, {
            if direct.webView.superview == nil {
                direct.webView.frame = window.bounds
                window.addSubview(direct.webView)
                window.makeKeyAndVisible()
            }
            return origin.transcript.contains(outside)
        }, message: "port=\(origin.port) origin=\(origin.transcript) url=\(direct.url?.absoluteString ?? "") requested=\(direct.requestedURL?.absoluteString ?? "") loading=\(direct.isLoading) error=\(direct.loadingError ?? "") proxies=\(direct.websiteDataStore.proxyConfigurations.count)")
        XCTAssertFalse(opener.transcript.contains(outside), opener.transcript)
        XCTAssertFalse(origin.transcript.contains(nonce))
        XCTAssertEqual(direct.websiteDataStore.proxyConfigurations.count, 0)
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

    private func makeListener(port: UInt16, tunnels: any AccessHTTPTunnelOpening) async throws -> AccessHTTPInboundListener {
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
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState != .unattached }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
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
        seconds: TimeInterval = 8,
        _ condition: @MainActor () -> Bool,
        message: @autoclosure () -> String = ""
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(condition(), message())
    }
}

private final class NavigationSink: NSObject, WKNavigationDelegate {}

private final class OriginReceipt: @unchecked Sendable {
    let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "access.auto-recovery.origin")
    private let lock = OSAllocatedUnfairLock(initialState: "")

    init(port: UInt16) { self.port = port }

    var transcript: String { lock.withLock { $0 } }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw URLError(.badURL) }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(connection)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let once = OSAllocatedUnfairLock(initialState: false)
                    listener.stateUpdateHandler = { state in
                        let first = once.withLock { taken -> Bool in
                            if taken { return false }
                            switch state {
                            case .ready, .failed, .cancelled:
                                taken = true
                                return true
                            default:
                                return false
                            }
                        }
                        guard first else { return }
                        switch state {
                        case .ready:
                            continuation.resume()
                        case .failed(let error):
                            continuation.resume(throwing: error)
                        default:
                            continuation.resume(throwing: URLError(.cannotConnectToHost))
                        }
                    }
                    listener.start(queue: self.queue)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw URLError(.timedOut)
            }
            try await group.next()
            group.cancelAll()
        }
        self.listener = listener
    }

    func stop() { listener?.cancel() }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            if let data {
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                self?.lock.withLock { $0.append(text) }
            }
            let body = "ok"
            let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

private final class AnsweringOpener: AccessHTTPTunnelOpening, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: "")
    var transcript: String {
        lock.withLock { $0 }
    }

    func open(host: String, port: UInt16) async throws -> any AccessRealityPathStream {
        let stream = AnsweringStream(host: host)
        stream.onRequest = { [weak self] request in
            self?.append(request)
        }
        return stream
    }

    fileprivate func append(_ request: String) {
        lock.withLock { $0.append(request) }
    }
}

private final class AnsweringStream: AccessRealityPathStream, @unchecked Sendable {
    private struct State {
        var request = Data()
        var response = Data()
        var closed = false
        var readers: [CheckedContinuation<Data?, Error>] = []
        var announced = false
    }

    let host: String
    var onRequest: ((String) -> Void)?
    private let lock = OSAllocatedUnfairLock(initialState: State())

    init(host: String) { self.host = host }

    var isOpen: Bool {
        lock.withLock { !$0.closed }
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
        lock.withLock { state in
            state.request.append(data)
            guard !state.announced,
                  let text = String(data: state.request, encoding: .utf8),
                  text.contains("\r\n\r\n") else {
                return nil
            }
            state.announced = true
            return text
        }
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
        let reader: CheckedContinuation<Data?, Error>? = lock.withLock { state in
            if state.readers.isEmpty {
                state.response.append(data)
                return nil
            }
            return state.readers.removeFirst()
        }
        reader?.resume(returning: data)
    }

    private func takeResponse(maxBytes: Int, continuation: CheckedContinuation<Data?, Error>) -> Data?? {
        lock.withLock { state in
            if state.closed, state.response.isEmpty { return .some(nil) }
            if !state.response.isEmpty {
                let count = min(maxBytes, state.response.count)
                let chunk = Data(state.response.prefix(count))
                state.response.removeFirst(count)
                return .some(chunk)
            }
            state.readers.append(continuation)
            return nil
        }
    }

    private func closeLocked() -> [CheckedContinuation<Data?, Error>] {
        lock.withLock { state in
            state.closed = true
            let pending = state.readers
            state.readers.removeAll()
            return pending
        }
    }
}
