import Combine
import Foundation
import WebKit

public enum BrowserProfile: String, CaseIterable, Identifiable, Sendable {
    case standard
    case privateMode

    public var id: String { rawValue }
    public var title: String { self == .standard ? "普通" : "私密" }
    public var isPrivate: Bool { self == .privateMode }
}

@MainActor
public final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate {
    public let id: UUID
    public let webView: WKWebView
    public let profile: BrowserProfile
    @Published public private(set) var title = "新标签页"
    @Published public private(set) var url: URL?
    @Published public private(set) var isLoading = false
    @Published public private(set) var canGoBack = false
    @Published public private(set) var canGoForward = false
    @Published public private(set) var navigationEpoch: UInt64 = 0
    @Published public private(set) var lastPolicyIntervention: BrowserNavigationPolicyDecision?

    var onNavigation: ((BrowserTab) -> Void)?
    private var pendingNavigation: WKNavigation?

    init(id: UUID = UUID(), profile: BrowserProfile, configuration: WKWebViewConfiguration) {
        self.id = id
        self.profile = profile
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .onDrag
        load(URL(string: "aegis://start")!)
    }

    public func load(_ url: URL) {
        lastPolicyIntervention = nil
        pendingNavigation = webView.load(
            URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 20)
        )
    }

    public func goBack() {
        if webView.canGoBack {
            lastPolicyIntervention = nil
            pendingNavigation = webView.goBack()
        }
    }

    public func goForward() {
        if webView.canGoForward {
            lastPolicyIntervention = nil
            pendingNavigation = webView.goForward()
        }
    }

    public func reload() {
        lastPolicyIntervention = nil
        pendingNavigation = webView.reload()
    }

    public func stop() { webView.stopLoading() }

    public func dismissPolicyIntervention() {
        lastPolicyIntervention = nil
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame != false,
              let requestURL = navigationAction.request.url
        else {
            decisionHandler(.allow)
            return
        }

        let decision = BrowserNavigationPolicy.evaluate(
            requestURL,
            httpMethod: navigationAction.request.httpMethod ?? "GET"
        )
        switch decision.kind {
        case .allow:
            if lastPolicyIntervention?.kind != .sanitized
                || lastPolicyIntervention?.effectiveURL != requestURL.absoluteString {
                lastPolicyIntervention = nil
            }
            decisionHandler(.allow)
        case .blocked:
            lastPolicyIntervention = decision
            pendingNavigation = nil
            isLoading = false
            decisionHandler(.cancel)
        case .sanitized:
            guard let cleanedURL = URL(string: decision.effectiveURL),
                  cleanedURL != requestURL
            else {
                lastPolicyIntervention = BrowserNavigationPolicyDecision(
                    kind: .blocked,
                    originalURL: decision.originalURL,
                    effectiveURL: decision.effectiveURL,
                    removedQueryParameters: decision.removedQueryParameters,
                    phishingScore: decision.phishingScore,
                    reasonCodes: decision.reasonCodes + ["invalid_sanitized_target"]
                )
                pendingNavigation = nil
                isLoading = false
                decisionHandler(.cancel)
                return
            }
            lastPolicyIntervention = decision
            var cleanedRequest = navigationAction.request
            cleanedRequest.url = cleanedURL
            decisionHandler(.cancel)
            pendingNavigation = webView.load(cleanedRequest)
        }
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard isCurrent(navigation) else { return }
        isLoading = true
        navigationEpoch &+= 1
        refreshState()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isCurrent(navigation) else { return }
        pendingNavigation = nil
        isLoading = false
        refreshState()
        onNavigation?(self)
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard isCurrent(navigation) else { return }
        pendingNavigation = nil
        isLoading = false
        refreshState()
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationEpoch &+= 1
        pendingNavigation = webView.reload()
    }

    private func isCurrent(_ navigation: WKNavigation?) -> Bool {
        guard let pendingNavigation, let navigation else { return pendingNavigation == nil }
        return navigation === pendingNavigation
    }

    private func refreshState() {
        title = webView.title?.isEmpty == false ? webView.title! : (webView.url?.host ?? "新标签页")
        url = webView.url
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
}

@MainActor
public final class BrowserSession: ObservableObject {
    @Published public private(set) var standardTabs: [BrowserTab] = []
    @Published public private(set) var privateTabs: [BrowserTab] = []
    @Published public var activeTabID: UUID?
    @Published public var profile: BrowserProfile = .standard
    @Published public private(set) var extensionStatus = "WebExtension 正在初始化"
    @Published public private(set) var bookmarkIsActive = false

    public let standardProfileID = UUID()
    public let privateProfileID = UUID()
    public let dataStore: BrowserDataStore

    private let standardRuntime: WebExtensionRuntime
    private let privateRuntime: WebExtensionRuntime

    public init(dataStore: BrowserDataStore = BrowserDataStore()) {
        self.dataStore = dataStore
        standardRuntime = WebExtensionRuntime(isPrivate: false)
        privateRuntime = WebExtensionRuntime(isPrivate: true)
        let first = makeTab(profile: .standard)
        standardTabs = [first]
        activeTabID = first.id
        Task { await loadWebExtensions() }
    }

    public var visibleTabs: [BrowserTab] {
        profile == .standard ? standardTabs : privateTabs
    }

    public var activeTab: BrowserTab? {
        visibleTabs.first { $0.id == activeTabID } ?? visibleTabs.first
    }

    public var activeProfileID: UUID {
        profile == .standard ? standardProfileID : privateProfileID
    }

    public var agentIsAvailable: Bool { profile == .standard }

    public func switchProfile(to newProfile: BrowserProfile) {
        guard profile != newProfile else { return }
        profile = newProfile
        if newProfile == .privateMode, privateTabs.isEmpty {
            privateTabs = [makeTab(profile: .privateMode)]
        }
        activeTabID = visibleTabs.first?.id
        refreshBookmarkState()
    }

    @discardableResult
    public func newTab() -> BrowserTab {
        let tab = makeTab(profile: profile)
        if profile == .standard {
            standardTabs.append(tab)
        } else {
            privateTabs.append(tab)
        }
        activeTabID = tab.id
        return tab
    }

    public func activate(_ tabID: UUID) {
        guard visibleTabs.contains(where: { $0.id == tabID }) else { return }
        activeTabID = tabID
        refreshBookmarkState()
    }

    public func close(_ tabID: UUID) {
        if profile == .standard {
            standardTabs.removeAll { $0.id == tabID }
            if standardTabs.isEmpty { standardTabs = [makeTab(profile: .standard)] }
        } else {
            privateTabs.removeAll { $0.id == tabID }
            if privateTabs.isEmpty { privateTabs = [makeTab(profile: .privateMode)] }
        }
        if activeTabID == tabID { activeTabID = visibleTabs.first?.id }
        refreshBookmarkState()
    }

    public func navigate(address: String) {
        guard let tab = activeTab, let url = Self.normalizedURL(from: address) else { return }
        tab.load(url)
    }

    public func toggleBookmark() {
        guard let tab = activeTab, let url = tab.url else { return }
        bookmarkIsActive = dataStore.toggleBookmark(
            title: tab.title,
            url: url,
            isPrivate: profile.isPrivate
        )
    }

    public static func normalizedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return URL(string: "aegis://start") }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }
        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }

    private func makeTab(profile: BrowserProfile) -> BrowserTab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = profile.isPrivate ? .nonPersistent() : .default()
        configuration.userContentController = WKUserContentController()
        configuration.setURLSchemeHandler(FixtureSchemeHandler(), forURLScheme: "aegis")
        (profile.isPrivate ? privateRuntime : standardRuntime).apply(to: configuration)

        let tab = BrowserTab(profile: profile, configuration: configuration)
        tab.onNavigation = { [weak self] tab in
            guard let self, let url = tab.url else { return }
            if url.absoluteString != "aegis://start" {
                self.dataStore.record(title: tab.title, url: url, isPrivate: tab.profile.isPrivate)
            }
            if self.activeTabID == tab.id { self.refreshBookmarkState() }
        }
        return tab
    }

    private func refreshBookmarkState() {
        guard !profile.isPrivate else {
            bookmarkIsActive = false
            return
        }
        guard let url = activeTab?.url else {
            bookmarkIsActive = false
            return
        }
        bookmarkIsActive = dataStore.bookmarks.contains { $0.url == url.absoluteString }
    }

    private func loadWebExtensions() async {
        // SharedWebExtension 的 manifest 与脚本作为 App 资源复制到 bundle 根目录；
        // Safari companion 同样从这一源码目录构建，避免复制后漂移。
        let resources = Bundle.main.bundleURL
        do {
            try await standardRuntime.loadSharedResources(from: resources)
            try await privateRuntime.loadSharedResources(from: resources)
            extensionStatus = standardRuntime.status
        } catch {
            extensionStatus = "WebExtension 不可用：\(error.localizedDescription)"
        }
    }
}
