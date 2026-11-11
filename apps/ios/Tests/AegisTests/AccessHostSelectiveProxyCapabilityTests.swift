import Network
import UIKit
import WebKit
import XCTest
@testable import AccessKit

/// Capability probe for same-page selective proxy via WebKit matchDomains.
/// Product auto-connect stays main-frame recovery until this proves exact-host
/// bilateral receipts (member via proxy, sibling/unlisted via origin).
@MainActor
final class AccessHostSelectiveProxyCapabilityTests: XCTestCase {
    func testMatchDomainsDoesNotProveExactHostSelectiveProxy() async throws {
        let proxy = try RouteProbe()
        try await proxy.start()
        defer { proxy.stop() }

        let store = WKWebsiteDataStore.nonPersistent()
        var configuration = ProxyConfiguration(httpCONNECTProxy: .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: try XCTUnwrap(NWEndpoint.Port(rawValue: proxy.port))
        ))
        configuration.allowFailover = false
        // Suffix match: "login.example" also admits deeper hosts under that label.
        configuration.matchDomains = ["login.example"]
        store.proxyConfigurations = [configuration]

        let page = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: {
                let config = WKWebViewConfiguration()
                config.websiteDataStore = store
                config.defaultWebpagePreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
                return config
            }()
        )
        let window = UIWindow(frame: page.frame)
        window.addSubview(page)
        window.isHidden = false
        defer { window.isHidden = true }

        let sawMember = expectation(description: "member host reaches proxy")
        let sawSibling = expectation(description: "suffix sibling reaches proxy")
        sawMember.assertForOverFulfill = false
        sawSibling.assertForOverFulfill = false
        proxy.onHost = { host in
            if host == "login.example" { sawMember.fulfill() }
            if host == "api.login.example" { sawSibling.fulfill() }
        }

        let html = """
        <html><body>
        <img src="http://login.example/pixel">
        <img src="http://api.login.example/pixel">
        <img src="http://cdn.unrelated.invalid/pixel">
        </body></html>
        """
        page.loadHTMLString(html, baseURL: URL(string: "http://shop.example/"))
        await fulfillment(of: [sawMember, sawSibling], timeout: 8)

        XCTAssertTrue(
            proxy.requestedHosts.contains("login.example"),
            "member host missing. hosts=\(proxy.requestedHosts) transcript=\(proxy.transcript)"
        )
        XCTAssertTrue(
            proxy.requestedHosts.contains("api.login.example"),
            "WebKit matchDomains is suffix-based; deeper hosts inherit the member label. Exact-host same-page selective proxy remains unproven. hosts=\(proxy.requestedHosts)"
        )
        XCTAssertFalse(
            proxy.requestedHosts.contains("cdn.unrelated.invalid"),
            "Unrelated hosts should stay off this matchDomains proxy. hosts=\(proxy.requestedHosts)"
        )
    }
}

private final class RouteProbe: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "access.selective.proxy")
    private let lock = NSLock()
    private var _transcript = ""
    private var _requestedHosts: [String] = []
    var onHost: (@Sendable (String) -> Void)?

    var transcript: String {
        lock.lock(); defer { lock.unlock() }
        return _transcript
    }

    var requestedHosts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _requestedHosts
    }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                if case .ready = state {
                    if let value = listener.port?.rawValue {
                        self.port = value
                    }
                    cont.resume()
                    listener.stateUpdateHandler = nil
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if let text = String(data: next, encoding: .utf8), text.contains("\r\n\r\n") {
                let host = Self.exactHost(from: text)
                self.lock.lock()
                self._transcript += text
                if let host {
                    self._requestedHosts.append(host)
                }
                self.lock.unlock()
                if let host {
                    self.onHost?(host)
                }
                let body = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: body, completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            if error == nil {
                self.receive(connection, buffer: next)
            } else {
                connection.cancel()
            }
        }
    }

    /// Prefer CONNECT authority, absolute-form request URL, or Host header; never substring-match.
    private static func exactHost(from request: String) -> String? {
        let lines = request.split(whereSeparator: \.isNewline).map(String.init)
        if let connect = lines.first(where: { $0.uppercased().hasPrefix("CONNECT ") }) {
            let parts = connect.split(separator: " ")
            if parts.count >= 2 {
                return String(parts[1].split(separator: ":").first ?? parts[1]).lowercased()
            }
        }
        if let requestLine = lines.first {
            let parts = requestLine.split(separator: " ")
            if parts.count >= 2, let url = URL(string: String(parts[1])), let host = url.host {
                return host.lowercased()
            }
        }
        if let hostLine = lines.first(where: { $0.lowercased().hasPrefix("host:") }) {
            let value = hostLine.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            return String(value.split(separator: ":").first ?? Substring(value)).lowercased()
        }
        return nil
    }
}
