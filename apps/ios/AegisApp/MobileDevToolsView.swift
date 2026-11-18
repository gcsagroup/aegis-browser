#if DEBUG && targetEnvironment(simulator)
import BrowserKit
import SwiftUI
import WebKit

/// 模拟器的开发工具从临时目录收发指令，网页在独立的非持久会话中运行。
struct MobileDevToolsView: View {
    struct Configuration {
        let directory: URL
        let origin: URL

        static var current: Self? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let flag = arguments.firstIndex(of: "--mobile-devtools"),
                  arguments.indices.contains(flag + 2),
                  let id = UUID(uuidString: arguments[flag + 1]),
                  let port = UInt16(arguments[flag + 2]), port > 0,
                  let origin = URL(string: "http://127.0.0.1:\(port)") else { return nil }
            return Self(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("mobile-devtools-\(id.uuidString)", isDirectory: true), origin: origin)
        }
    }

    private struct Request: Decodable {
        let id: UUID
        let method: String
        let url: URL?
    }

    private struct ManifestInfo: Codable {
        let manifestURL: URL?
        let id: URL?
        let startURL: URL?
        let scope: URL?
        let name: String?
        let display: String?
    }

    private struct Result: Encodable {
        var url: URL? = nil
        var title: String? = nil
        var text: String? = nil
        var truncated: Bool? = nil
        var png: Data? = nil
        var manifest: ManifestInfo? = nil
        var error: String? = nil
    }

    private struct Reply: Encodable {
        let id: UUID
        let result: Result
    }

    let configuration: Configuration

    var body: some View {
        DiagnosticSurface(configuration: configuration)
    }

    private struct DiagnosticSurface: View {
        @StateObject private var page: DiagnosticPage
        let configuration: Configuration

        init(configuration: Configuration) {
            self.configuration = configuration
            _page = StateObject(wrappedValue: DiagnosticPage(origin: configuration.origin))
        }

        var body: some View {
            VStack(spacing: 0) {
                Text("Aegis 移动网页诊断").font(.headline).padding(8)
                BrowserWebView(webView: page.webView).allowsHitTesting(false)
            }
            .task {
                guard (try? await page.prepare(in: configuration.directory)) != nil else { return }
                await MobileDevToolsView.serve(configuration: configuration, on: page)
            }
        }
    }

    private static func serve(configuration: Configuration, on page: DiagnosticPage) async {
        let requestURL = configuration.directory.appendingPathComponent("request.json")
        let replyURL = configuration.directory.appendingPathComponent("reply.json")
        try? Data().write(to: configuration.directory.appendingPathComponent("ready"), options: .atomic)
        while !Task.isCancelled {
            if let data = try? Data(contentsOf: requestURL), data.count <= 8192,
               let request = try? JSONDecoder().decode(Request.self, from: data) {
                try? FileManager.default.removeItem(at: requestURL)
                let result: Result
                do {
                    result = try await page.perform(request)
                } catch {
                    result = Result(error: error.localizedDescription)
                }
                let encoder = JSONEncoder()
                if let encoded = try? encoder.encode(Reply(id: request.id, result: result)) {
                    try? encoded.write(to: replyURL, options: .atomic)
                }
            }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
    }

    @MainActor
    private final class DiagnosticPage: NSObject, ObservableObject, WKNavigationDelegate {
        let webView: WKWebView
        private let origin: URL
        private var completed: WKNavigation?
        private var failed: WKNavigation?
        private var documentVersion = 0

        init(origin: URL) {
            self.origin = origin
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
            webView = WKWebView(frame: .zero, configuration: configuration)
            super.init()
            webView.navigationDelegate = self
        }

        func prepare(in directory: URL) async throws {
            guard let store = WKContentRuleListStore(url: directory), let port = origin.port
            else { throw CocoaError(.coderInvalidValue) }
            let pattern = "^http://127\\.0\\.0\\.1:\(port)/"
            let rules = [
                ["trigger": ["url-filter": "^https?://"], "action": ["type": "block"]],
                ["trigger": ["url-filter": pattern], "action": ["type": "ignore-previous-rules"]],
            ]
            let json = String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)
            guard let list = try await store.compileContentRuleList(forIdentifier: "mobile-devtools", encodedContentRuleList: json)
            else { throw CocoaError(.coderInvalidValue) }
            webView.configuration.userContentController.add(list)
        }

        private func isAllowed(_ url: URL) -> Bool {
            url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port &&
                url.user == nil && url.password == nil
        }

        private func inspectManifest(at url: URL) async throws -> ManifestInfo {
            let version = documentVersion
            let script = """
            if (location.href !== expectedURL) return null;
            const link = document.querySelector('link[rel~="manifest" i][href]');
            if (!link) return JSON.stringify({});
            const sameOrigin = (value, base) => {
                if (typeof value !== 'string' || !value) return null;
                try {
                    const parsed = new URL(value, base);
                    return parsed.origin === location.origin && !parsed.username && !parsed.password ? parsed : null;
                } catch { return null; }
            };
            const manifestURL = sameOrigin(link.href, location.href);
            if (!manifestURL) throw Error('Manifest 需要与当前网页同源。');
            const response = await fetch(manifestURL, {credentials: 'omit', redirect: 'error'});
            if (!response.ok || !response.body) throw Error('无法读取 Manifest。');
            const reader = response.body.getReader();
            const decoder = new TextDecoder();
            let bytes = 0;
            let contents = '';
            for (;;) {
                const {done, value} = await reader.read();
                if (done) break;
                bytes += value.byteLength;
                if (bytes > 65536) {
                    await reader.cancel();
                    throw Error('Manifest 超过 64 KB。');
                }
                contents += decoder.decode(value, {stream: true});
            }
            const manifest = JSON.parse(contents + decoder.decode());
            if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) throw Error('Manifest 不是 JSON 对象。');
            const start = sameOrigin(manifest.start_url, manifestURL) ?? new URL(location.href);
            const id = sameOrigin(manifest.id, start.origin + '/') ?? new URL(start);
            id.hash = '';
            const scope = sameOrigin(manifest.scope, manifestURL) ?? new URL('.', start);
            scope.search = '';
            scope.hash = '';
            const bounded = value => typeof value === 'string' ? value.slice(0, 512) : null;
            return JSON.stringify({manifestURL: manifestURL.href, id: id.href, startURL: start.href,
                scope: scope.href, name: bounded(manifest.name || manifest.short_name), display: bounded(manifest.display)});
            """
            let value = try await webView.callAsyncJavaScript(script, arguments: ["expectedURL": url.absoluteString],
                in: nil, contentWorld: .defaultClient)
            guard version == documentVersion, webView.url == url, !webView.isLoading,
                  let json = value as? String else { throw Failure.unavailable }
            return try JSONDecoder().decode(ManifestInfo.self, from: Data(json.utf8))
        }

        func perform(_ request: Request) async throws -> Result {
            switch request.method {
            case "navigate_page":
                guard let url = request.url, isAllowed(url),
                      let navigation = webView.load(URLRequest(url: url)) else { throw Failure.invalid }
                let deadline = ContinuousClock.now + .seconds(15)
                while completed !== navigation && failed !== navigation && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard completed === navigation, webView.url == url else {
                    webView.stopLoading()
                    throw Failure.unavailable
                }
                return Result(url: url, title: webView.title)
            case "inspect_web_app":
                guard let url = webView.url, isAllowed(url), !webView.isLoading else { throw Failure.unavailable }
                return Result(url: url, manifest: try await inspectManifest(at: url))
            case "take_snapshot", "take_screenshot":
                guard let url = webView.url, isAllowed(url), !webView.isLoading else { throw Failure.unavailable }
                let version = documentVersion
                let snapshot = try await PageSnapshot.visibleDOM(in: webView, at: url)
                guard version == documentVersion else { throw Failure.unavailable }
                if request.method == "take_snapshot" {
                    return Result(url: url, title: snapshot.title, text: snapshot.text, truncated: snapshot.truncated)
                }
                let image = try await webView.takeSnapshot(configuration: nil)
                guard version == documentVersion, webView.url == url, !webView.isLoading,
                      let png = image.pngData() else { throw Failure.unavailable }
                return Result(url: url, png: png)
            default:
                throw Failure.invalid
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.targetFrame != nil, let url = action.request.url, isAllowed(url) else { return .cancel }
            return .allow
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            documentVersion += 1
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            completed = navigation
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failed = navigation
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed = navigation
        }
    }

    private enum Failure: LocalizedError {
        case invalid, unavailable

        var errorDescription: String? {
            switch self {
            case .invalid: "仅支持当前诊断会话中的本机测试页面。"
            case .unavailable: "页面尚未完成加载、被拦截或已切换。"
            }
        }
    }
}
#endif
