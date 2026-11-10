import Network
import os
import UIKit
import WebKit
import XCTest
@testable import AccessKit

/// Records which hosts a dedicated store sends to its loopback proxy.
@MainActor
final class AccessHostWebKitRouteTests: XCTestCase {
    func testHostStoreProxiesPageAndCrossOriginResources() async throws {
        let probe = try HostRouteProxy()
        try await probe.start()
        defer { probe.stop() }
        let registry = AccessHostDataStoreRegistry()
        let host = try AccessSiteHost("example.invalid")
        registry.setEndpoint(endpoint(probe.port), scopeID: "ordinary", host: host, isPrivate: false)
        let store = try XCTUnwrap(registry.storeForTab(
            tabID: "page",
            scopeID: "ordinary",
            isPrivate: false,
            targetHost: host,
            boundHost: nil,
            intent: .on
        ))
        let page = webView(store)
        let window = UIWindow(frame: page.frame)
        window.addSubview(page)
        window.isHidden = false
        defer { window.isHidden = true }
        let sawPage = expectation(description: "page host reaches proxy")
        let sawResource = expectation(description: "cross-origin resource reaches proxy")
        sawPage.assertForOverFulfill = false
        sawResource.assertForOverFulfill = false
        probe.onText = { text in
            if text.contains("example.invalid") { sawPage.fulfill() }
            if text.contains("cdn.invalid") { sawResource.fulfill() }
        }
        page.load(URLRequest(url: URL(string: "http://example.invalid/page")!))
        await fulfillment(of: [sawPage, sawResource], timeout: 8)
        XCTAssertTrue(probe.transcript.contains("example.invalid"), probe.transcript)
        XCTAssertTrue(probe.transcript.contains("cdn.invalid"), probe.transcript)
    }

    func testAnotherHostDoesNotUseTheDedicatedProxy() async throws {
        let probe = try HostRouteProxy()
        try await probe.start()
        defer { probe.stop() }
        let registry = AccessHostDataStoreRegistry()
        let host = try AccessSiteHost("example.invalid")
        registry.setEndpoint(endpoint(probe.port), scopeID: "ordinary", host: host, isPrivate: false)
        _ = registry.storeForTab(
            tabID: "page",
            scopeID: "ordinary",
            isPrivate: false,
            targetHost: host,
            boundHost: nil,
            intent: .on
        )
        let other = webView(.nonPersistent())
        other.load(URLRequest(url: URL(string: "http://other.invalid/")!))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertFalse(probe.transcript.contains("other.invalid"))
    }

    func testFailedEndpointKeepsProxyConfiguration() throws {
        let registry = AccessHostDataStoreRegistry()
        let host = try AccessSiteHost("example.invalid")
        registry.setEndpoint(endpoint(9), scopeID: "ordinary", host: host, isPrivate: false)
        let store = try XCTUnwrap(registry.storeForTab(
            tabID: "page",
            scopeID: "ordinary",
            isPrivate: false,
            targetHost: host,
            boundHost: nil,
            intent: .on
        ))
        let before = store.proxyConfigurations.count
        registry.setEndpoint(
            endpoint(9, generation: 2, state: .failed),
            scopeID: "ordinary",
            host: host,
            isPrivate: false
        )
        let kept = registry.storeForTab(
            tabID: "page",
            scopeID: "ordinary",
            isPrivate: false,
            targetHost: host,
            boundHost: host,
            intent: .on
        )
        XCTAssertTrue(store === kept)
        XCTAssertEqual(kept?.proxyConfigurations.count, before)
        XCTAssertFalse(kept?.proxyConfigurations.isEmpty ?? true)
    }

    func testEvictedStoreDoesNotKeepCookies() async throws {
        let registry = AccessHostDataStoreRegistry()
        let host = try AccessSiteHost("example.invalid")
        registry.setEndpoint(endpoint(9), scopeID: "ordinary", host: host, isPrivate: false)
        let store = try XCTUnwrap(registry.storeForTab(
            tabID: "page",
            scopeID: "ordinary",
            isPrivate: false,
            targetHost: host,
            boundHost: nil,
            intent: .on
        ))
        let cookie = HTTPCookie(properties: [
            .domain: "example.invalid",
            .path: "/",
            .name: "session",
            .value: "secret"
        ])!
        await store.httpCookieStore.setCookie(cookie)
        registry.unbind("page")
        _ = registry.revoke(scopeID: "ordinary", host: host, isPrivate: false)
        registry.setEndpoint(endpoint(9, generation: 2), scopeID: "ordinary", host: host, isPrivate: false)
        let recreated = try XCTUnwrap(registry.storeForTab(
            tabID: "page",
            scopeID: "ordinary",
            isPrivate: false,
            targetHost: host,
            boundHost: nil,
            intent: .on
        ))
        let cookies = await recreated.httpCookieStore.allCookies()
        XCTAssertFalse(cookies.contains { $0.name == "session" && $0.value == "secret" })
        XCTAssertFalse(store === recreated)
    }

    private func endpoint(
        _ port: UInt16,
        generation: UInt64 = 1,
        state: AccessProxyEndpointState = .ready
    ) -> AccessManagedProxyEndpoint {
        AccessManagedProxyEndpoint(
            identity: "entry-\(generation)",
            generation: generation,
            loopbackHost: "127.0.0.1",
            port: port,
            state: state
        )
    }

    private func webView(_ store: WKWebsiteDataStore) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        return WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
    }
}

private final class HostRouteProxy: @unchecked Sendable {
    private(set) var port: UInt16 = 9
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "access.host-route.proxy")
    private let lock = OSAllocatedUnfairLock(initialState: "")
    var onText: ((String) -> Void)?

    var transcript: String {
        lock.withLock { $0 }
    }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws {
        guard let listener else { return }
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(connection)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = HostRouteOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { continuation.resume() }
                case .failed(let error):
                    if once.take() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.take() { continuation.resume(throwing: URLError(.cannotConnectToHost)) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 9
    }

    func stop() {
        listener?.cancel()
    }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: "")
    }

    private func read(_ connection: NWConnection, buffer: String) {
        if buffer.contains("\r\n\r\n") {
            finish(connection, text: buffer)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let chunk = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let text = buffer + chunk
            let snapshot = self.lock.withLock { transcript -> String in
                transcript.append(chunk)
                return transcript
            }
            self.onText?(snapshot)
            self.finish(connection, text: text)
        }
    }

    private func finish(_ connection: NWConnection, text: String) {
        guard text.contains("\r\n\r\n") else {
            read(connection, buffer: text)
            return
        }
        if text.hasPrefix("CONNECT ") {
            let remainder = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
            let established = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
            connection.send(content: established, completion: .contentProcessed { [weak self] _ in
                self?.read(connection, buffer: remainder)
            })
            return
        }
        let body = "<link rel=\"stylesheet\" href=\"http://cdn.invalid/a.css\"><script src=\"http://cdn.invalid/a.js\"></script>"
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private final class HostRouteOnce: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    func take() -> Bool {
        lock.withLock { done in
            if done { return false }
            done = true
            return true
        }
    }
}
