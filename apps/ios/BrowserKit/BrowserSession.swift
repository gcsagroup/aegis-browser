import Combine
import Foundation
import UIKit
import WebKit

public enum BrowserProfile: String, CaseIterable, Identifiable, Sendable {
    case standard
    case privateMode

    public var id: String { rawValue }
    public var title: String { self == .standard ? String(localized: "普通") : String(localized: "私密") }
    public var isPrivate: Bool { self == .privateMode }
}

@MainActor
public final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    public let id: UUID
    private let configuration: WKWebViewConfiguration
    private var loadedWebView: WKWebView?
    /// 只有显式加载或访问当前页面时才创建 WebView；标签列表不得通过此属性读取状态。
    public var webView: WKWebView {
        if let loadedWebView { return loadedWebView }
        let view = BrowserContentWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.scrollView.keyboardDismissMode = .onDrag
        loadedWebView = view
        return view
    }
    public var isResident: Bool { loadedWebView != nil }
    @Published public private(set) var isSuspended = false
    public private(set) var lastActivatedAt = Date.distantPast
    private var isActive = false
    private var savedScrollOffset = CGPoint.zero
    private var restoresScrollOffset = false
    private var recentTerminations: [Date] = []
    var snapshotReaders = 0
    var assistantPinned = false
    public var scrollOffset: Double { Double(isActive && !restoresScrollOffset ? (loadedWebView?.scrollView.contentOffset.y ?? savedScrollOffset.y) : savedScrollOffset.y) }
    public let profile: BrowserProfile
    @Published public private(set) var title = String(localized: "新标签页")
    @Published public private(set) var url: URL?
    @Published public private(set) var isLoading = false
    @Published public private(set) var canGoBack = false
    @Published public private(set) var canGoForward = false
    @Published public private(set) var navigationEpoch: UInt64 = 0
    @Published public private(set) var lastPolicyIntervention: BrowserNavigationPolicyDecision?
    @Published public private(set) var loadingError: String?
    @Published public private(set) var trackingProtectionReady = false
    @Published public internal(set) var groupID: UUID?
    public private(set) var requestedURL: URL?
    private var contentRuleList: WKContentRuleList?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = UUID()

    var onNavigation: ((BrowserTab) -> Void)?
    var onNewWindow: ((URL) -> Void)?
    var onDownload: ((URL) -> Void)?
    private var pendingNavigation: WKNavigation?

    init(id: UUID = UUID(), profile: BrowserProfile, configuration: WKWebViewConfiguration) {
        self.id = id
        self.profile = profile
        self.configuration = configuration
        super.init()
        configuration.userContentController.addUserScript(WKUserScript(source: """
        globalThis.__aegisHasEdits = false;
        document.addEventListener('input', () => { globalThis.__aegisHasEdits = true; }, true);
        document.addEventListener('change', () => { globalThis.__aegisHasEdits = true; }, true);
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
    }

    func prepareForRestore(url: URL?, title: String? = nil, scrollOffset: Double? = nil) {
        self.url = url; requestedURL = url
        self.title = title ?? url?.host ?? String(localized: "新标签页")
        savedScrollOffset = CGPoint(x: 0, y: max(0, scrollOffset ?? 0))
        isSuspended = true
    }

    func setActive(_ value: Bool) {
        // 切换时先记录位置；WebView 离开窗口后，系统可能重设其滚动偏移。
        if isActive, !value, !restoresScrollOffset, let view = loadedWebView { savedScrollOffset = view.scrollView.contentOffset }
        isActive = value
        guard value else { return }
        lastActivatedAt = Date()
        if loadedWebView == nil {
            load(requestedURL ?? url ?? URL(string: "aegis://start")!, preservingScroll: true)
        }
    }

    /// 不读取或保存表单值；只判断是否编辑过表单、是否正在播放媒体。
    @discardableResult
    func suspendIfSafe() async -> Bool {
        guard !profile.isPrivate, !isActive, !isLoading, snapshotReaders == 0, !assistantPinned, let view = loadedWebView,
              view.backForwardList.backList.allSatisfy({ $0.url.scheme == "aegis" }),
              view.backForwardList.forwardList.isEmpty else { return false }
        let epoch = navigationEpoch
        let script = """
        return Boolean(globalThis.__aegisHasEdits)
            || [...document.querySelectorAll('video,audio')].some(media => !media.paused && !media.ended)
            || document.querySelector('iframe,frame') !== null;
        """
        guard let protected = try? await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient),
              let protected = protected as? Bool, !protected,
              !isActive, !isLoading, snapshotReaders == 0, !assistantPinned, epoch == navigationEpoch, !Task.isCancelled else { return false }
        releaseWebView()
        return true
    }

    private func releaseWebView() {
        navigationEpoch &+= 1
        loadGeneration = UUID(); loadTask?.cancel()
        loadedWebView?.stopLoading()
        loadedWebView?.navigationDelegate = nil; loadedWebView?.uiDelegate = nil
        loadedWebView = nil; pendingNavigation = nil
        isLoading = false; isSuspended = true
        canGoBack = false; canGoForward = false
    }

    public func load(_ url: URL) {
        load(url, preservingScroll: false)
    }

    private func load(_ url: URL, preservingScroll: Bool) {
        if !preservingScroll { savedScrollOffset = .zero }
        restoresScrollOffset = preservingScroll
        isSuspended = false
        if url != requestedURL { recentTerminations = [] }
        lastPolicyIntervention = nil
        loadingError = nil
        // 立即让旧页面授权失效，不等网络回调到来。
        navigationEpoch &+= 1
        loadTask?.cancel()
        loadGeneration = UUID()
        let generation = loadGeneration
        let decision = BrowserNavigationPolicy.evaluate(url)
        if decision.kind == .blocked {
            webView.stopLoading()
            lastPolicyIntervention = decision
            isLoading = false
            return
        }
        if decision.kind == .sanitized { lastPolicyIntervention = decision }
        let url = URL(string: decision.effectiveURL) ?? url
        requestedURL = url
        isLoading = true
        if ["http", "https"].contains(url.scheme ?? ""), contentRuleList == nil {
            isLoading = true
            loadTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let list = try await TrackingProtection.shared.ruleList()
                    try Task.checkCancellation()
                    guard generation == loadGeneration else { return }
                    contentRuleList = list
                    configureTrackingProtection(for: url)
                    pendingNavigation = webView.load(URLRequest(url: url, timeoutInterval: 30))
                } catch {
                    guard generation == loadGeneration else { return }
                    isLoading = false
                    loadingError = String(localized: "跟踪保护初始化失败，请重试。")
                }
            }
        } else {
            configureTrackingProtection(for: url)
            pendingNavigation = webView.load(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30))
        }
    }

    public func goBack() {
        loadTask?.cancel(); loadGeneration = UUID()
        if webView.canGoBack {
            navigationEpoch &+= 1
            lastPolicyIntervention = nil
            pendingNavigation = webView.goBack()
        }
    }

    public func goForward() {
        loadTask?.cancel(); loadGeneration = UUID()
        if webView.canGoForward {
            navigationEpoch &+= 1
            lastPolicyIntervention = nil
            pendingNavigation = webView.goForward()
        }
    }

    public func reload() {
        recentTerminations = []
        if let url = requestedURL ?? url { load(url) }
    }

    func prepareForReading() async throws {
        if loadedWebView == nil {
            load(requestedURL ?? url ?? URL(string: "aegis://start")!, preservingScroll: true)
        }
        let deadline = Date().addingTimeInterval(30)
        while isLoading, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        guard !isLoading, loadingError == nil else { throw PageSnapshotError.unavailable }
    }

    public func stop() {
        navigationEpoch &+= 1
        loadGeneration = UUID()
        loadTask?.cancel()
        loadedWebView?.stopLoading()
        isLoading = false
    }

    private func configureTrackingProtection(for url: URL) {
        if let contentRuleList { webView.configuration.userContentController.remove(contentRuleList) }
        if let latest = TrackingProtection.shared.currentList { contentRuleList = latest }
        guard let contentRuleList else { return }
        let enabled = TrackingProtection.enabled && !TrackingProtection.isExcepted(url)
        if enabled { webView.configuration.userContentController.add(contentRuleList) }
        trackingProtectionReady = enabled
    }

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
        if decision.kind != .blocked, ["http", "https"].contains(requestURL.scheme ?? ""), contentRuleList == nil {
            decisionHandler(.cancel)
            load(requestURL)
            return
        }
        configureTrackingProtection(for: requestURL)
        switch decision.kind {
        case .allow:
            if navigationAction.shouldPerformDownload {
                onDownload?(requestURL)
                decisionHandler(.cancel)
                return
            }
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
        guard webView === loadedWebView, isCurrent(navigation) else { return }
        isLoading = true
        navigationEpoch &+= 1
        refreshState()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === loadedWebView, isCurrent(navigation) else { return }
        pendingNavigation = nil
        isLoading = false
        refreshState()
        if restoresScrollOffset {
            let offset = savedScrollOffset
            let epoch = navigationEpoch
            // didFinish 时 UIKit 的 contentSize 可能尚未更新；在网页布局中恢复位置。
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView, webView === loadedWebView, epoch == navigationEpoch,
                      let expectedURL = url else { return }
                defer { if epoch == navigationEpoch { restoresScrollOffset = false } }
                let y = max(0, offset.y + webView.scrollView.adjustedContentInset.top)
                _ = try? await webView.callAsyncJavaScript(
                    "if (location.href === expectedURL) { window.scrollTo(0, y); }",
                    arguments: ["expectedURL": expectedURL.absoluteString, "y": y], in: nil, contentWorld: .defaultClient)
            }
        }
        onNavigation?(self)
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === loadedWebView, isCurrent(navigation) else { return }
        pendingNavigation = nil
        isLoading = false
        if (error as NSError).code != NSURLErrorCancelled { loadingError = error.localizedDescription }
        refreshState()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType,
           let url = navigationResponse.response.url {
            onDownload?(url)
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else { return nil }
        if BrowserNavigationPolicy.evaluate(url).kind != .blocked { onNewWindow?(url) }
        return nil
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === loadedWebView else { return }
        navigationEpoch &+= 1
        let now = Date()
        recentTerminations = recentTerminations.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard isActive else { releaseWebView(); return }
        guard recentTerminations.count <= 1 else {
            loadTask?.cancel(); loadGeneration = UUID(); pendingNavigation = nil; isLoading = false
            loadingError = String(localized: "页面连续停止运行，已暂停自动重载。请手动重试或关闭此标签。")
            return
        }
        isLoading = true
        pendingNavigation = webView.reload()
    }

    private func isCurrent(_ navigation: WKNavigation?) -> Bool {
        guard let pendingNavigation, let navigation else { return pendingNavigation == nil }
        return navigation === pendingNavigation
    }

    private func refreshState() {
        title = webView.title?.isEmpty == false ? webView.title! : (webView.url?.host ?? String(localized: "新标签页"))
        url = webView.url
        if let url { requestedURL = url }
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
    @Published public private(set) var sessionError: String?
    @Published public var pendingDownloadURL: URL?
    @Published public private(set) var standardGroups: [BrowserTabGroup] = []
    @Published public private(set) var privateGroups: [BrowserTabGroup] = []
    @Published private var standardGroupID: UUID?
    @Published private var privateGroupID: UUID?
    private var standardActiveID: UUID?
    private var bookmarkChanges: AnyCancellable?
    private var memoryWarnings: AnyCancellable?
    private var evictionTask: Task<Void, Never>?
    public var residentTabCount: Int { (standardTabs + privateTabs).filter(\.isResident).count }
    public let windowID: UUID
    private let windowStore: BrowserWindowStore?

    public let standardProfileID = UUID()
    public let privateProfileID = UUID()
    public let dataStore: BrowserDataStore
    public let workspaceStore: WorkspaceStore

    private let standardRuntime: WebExtensionRuntime
    private let privateRuntime: WebExtensionRuntime

    public init(dataStore: BrowserDataStore = BrowserDataStore(), workspaceStore: WorkspaceStore = WorkspaceStore(),
                windowID: UUID = UUID(), windowStore: BrowserWindowStore? = nil) {
        self.dataStore = dataStore
        self.workspaceStore = workspaceStore
        self.windowID = windowID
        self.windowStore = windowStore
        standardRuntime = WebExtensionRuntime(isPrivate: false)
        privateRuntime = WebExtensionRuntime(isPrivate: true)
        let snapshot = windowStore?.snapshot(windowID)
        let restored = snapshot?.tabs ?? (windowStore == nil ? workspaceStore.sessionURLs.map {
            SavedBrowserTab(id: UUID(), url: $0, groupID: nil)
        } : [])
        standardGroups = snapshot?.groups ?? []
        standardGroupID = snapshot?.selectedGroupID
        if restored.isEmpty {
            let first = makeTab(profile: .standard)
            standardTabs = [first]
            activeTabID = first.id
        } else {
            standardTabs = restored.map { value in
                let tab = makeTab(profile: .standard, id: value.id)
                tab.groupID = value.groupID
                tab.prepareForRestore(url: value.url, title: value.title, scrollOffset: value.scrollOffset)
                return tab
            }
            activeTabID = snapshot?.activeTabID ?? standardTabs.first?.id
        }
        standardActiveID = activeTabID
        updateActiveTab()
        bookmarkChanges = dataStore.$bookmarks.sink { [weak self] bookmarks in
            guard let self else { return }
            bookmarkIsActive = !profile.isPrivate && bookmarks.contains { $0.url == activeTab?.url?.absoluteString }
        }
        // 窗口会话由视图出现后首次保存，避免构造视图时发布共享存储变更。
        if windowStore == nil { persistSession() }
        memoryWarnings = NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in _ = await self?.releaseInactiveTabs(keeping: 1) }
            }
        Task { await loadWebExtensions() }
    }

    public var visibleTabs: [BrowserTab] {
        profile == .standard ? standardTabs : privateTabs
    }

    public var activeTab: BrowserTab? {
        displayedTabs.first { $0.id == activeTabID } ?? displayedTabs.first
    }

    public var groups: [BrowserTabGroup] { profile.isPrivate ? privateGroups : standardGroups }
    public var selectedGroupID: UUID? { profile.isPrivate ? privateGroupID : standardGroupID }
    public var selectedGroupName: String { groups.first { $0.id == selectedGroupID }?.name ?? String(localized: "所有标签") }
    public var displayedTabs: [BrowserTab] {
        guard let selectedGroupID else { return visibleTabs }
        return visibleTabs.filter { $0.groupID == selectedGroupID }
    }

    public func selectGroup(_ id: UUID?) {
        guard id == nil || groups.contains(where: { $0.id == id }) else { return }
        if profile.isPrivate { privateGroupID = id } else { standardGroupID = id }
        if !displayedTabs.contains(where: { $0.id == activeTabID }) { activeTabID = displayedTabs.first?.id }
        refreshBookmarkState(); persistSession()
    }

    @discardableResult public func createGroup(name: String) throws -> UUID {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw BrowserWindowError.invalidName }
        guard groups.count < 20 else { throw BrowserWindowError.capacity }
        let group = BrowserTabGroup(name: String(title.prefix(80)))
        if profile.isPrivate { privateGroups.append(group) } else { standardGroups.append(group) }
        selectGroup(group.id)
        _ = newTab()
        return group.id
    }

    public func renameGroup(_ id: UUID, to name: String) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw BrowserWindowError.invalidName }
        if profile.isPrivate {
            if let index = privateGroups.firstIndex(where: { $0.id == id }) { privateGroups[index].name = String(title.prefix(80)) }
        } else if let index = standardGroups.firstIndex(where: { $0.id == id }) { standardGroups[index].name = String(title.prefix(80)) }
        persistSession()
    }

    /// 取消分组保留全部标签，不连带关闭网页。
    public func removeGroup(_ id: UUID) {
        for tab in visibleTabs where tab.groupID == id { tab.groupID = nil }
        if profile.isPrivate { privateGroups.removeAll { $0.id == id } }
        else { standardGroups.removeAll { $0.id == id } }
        if selectedGroupID == id { selectGroup(nil) }
        persistSession()
    }

    public func moveTab(_ id: UUID, to groupID: UUID?) {
        guard groupID == nil || groups.contains(where: { $0.id == groupID }),
              let tab = visibleTabs.first(where: { $0.id == id }) else { return }
        tab.groupID = groupID
        if !displayedTabs.contains(where: { $0.id == activeTabID }) { activeTabID = displayedTabs.first?.id }
        objectWillChange.send(); refreshBookmarkState(); persistSession()
    }

    public func discardPrivateSession() {
        privateTabs.forEach { $0.stop() }
        privateTabs = []; privateGroups = []; privateGroupID = nil
        if profile.isPrivate { switchProfile(to: .standard) }
    }

    public var activeProfileID: UUID {
        profile == .standard ? standardProfileID : privateProfileID
    }

    public var agentIsAvailable: Bool { profile == .standard }

    public func switchProfile(to newProfile: BrowserProfile) {
        guard profile != newProfile else { return }
        if profile == .standard { standardActiveID = activeTabID }
        profile = newProfile
        if newProfile == .privateMode, privateTabs.isEmpty {
            privateTabs = [makeTab(profile: .privateMode)]
        }
        activeTabID = newProfile == .standard ? standardActiveID : displayedTabs.first?.id
        refreshBookmarkState()
        persistSession()
    }

    @discardableResult
    public func newTab() -> BrowserTab {
        let tab = makeTab(profile: profile)
        tab.groupID = selectedGroupID
        if profile == .standard {
            standardTabs.append(tab)
        } else {
            privateTabs.append(tab)
        }
        activeTabID = tab.id
        refreshBookmarkState()
        persistSession()
        return tab
    }

    public func activate(_ tabID: UUID) {
        guard displayedTabs.contains(where: { $0.id == tabID }) else { return }
        activeTabID = tabID
        refreshBookmarkState()
        persistSession()
    }

    public func close(_ tabID: UUID) {
        visibleTabs.first { $0.id == tabID }?.stop()
        if profile == .standard {
            standardTabs.removeAll { $0.id == tabID }
            if standardTabs.isEmpty { standardTabs = [makeTab(profile: .standard)] }
        } else {
            privateTabs.removeAll { $0.id == tabID }
            if privateTabs.isEmpty { privateTabs = [makeTab(profile: .privateMode)] }
        }
        if activeTabID == tabID { activeTabID = displayedTabs.first?.id }
        refreshBookmarkState()
        persistSession()
    }

    /// 恢复时追加新标签，保留用户当前打开的页面。
    @discardableResult
    public func restoreWorkspace(_ workspace: SavedWorkspace) -> [UUID] {
        guard !profile.isPrivate else { return [] }
        var created: [UUID] = []
        for url in workspace.urls.prefix(max(0, 50 - standardTabs.count)) {
            let tab = makeTab(profile: .standard)
            tab.groupID = selectedGroupID
            tab.prepareForRestore(url: url)
            standardTabs.append(tab)
            created.append(tab.id)
        }
        if let id = created.last { activeTabID = id }
        refreshBookmarkState(); persistSession()
        return created
    }

    public func saveWorkspace(name: String) throws -> SavedWorkspace {
        guard !profile.isPrivate else { throw WorkspaceError.noPages }
        return try workspaceStore.save(name: name, urls: standardTabs.compactMap { $0.requestedURL ?? $0.url })
    }

    public func clearWebsiteData() async {
        guard !profile.isPrivate else { return }
        for tab in standardTabs { tab.stop() }
        standardGroups = []; standardGroupID = nil
        standardTabs = [makeTab(profile: .standard)]
        activeTabID = standardTabs.first?.id
        await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        persistSession()
        refreshBookmarkState()
    }

    public func persistSession() {
        do {
            if let windowStore {
                if profile == .standard { standardActiveID = activeTabID }
                let tabs = standardTabs.map { SavedBrowserTab(id: $0.id, url: $0.requestedURL ?? $0.url, groupID: $0.groupID,
                                                              title: $0.title, scrollOffset: $0.scrollOffset) }
                try windowStore.save(BrowserWindowSnapshot(id: windowID, name: windowStore.snapshot(windowID)?.name ?? "",
                    tabs: tabs, groups: standardGroups, selectedGroupID: standardGroupID, activeTabID: standardActiveID))
            } else { try workspaceStore.saveSession(urls: standardTabs.compactMap { $0.requestedURL ?? $0.url }) }
            sessionError = nil
        }
        catch { sessionError = "普通标签保存失败：\(error.localizedDescription)" }
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

    private func makeTab(profile: BrowserProfile, id: UUID = UUID()) -> BrowserTab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = profile.isPrivate ? .nonPersistent() : .default()
        configuration.userContentController = WKUserContentController()
        configuration.setURLSchemeHandler(FixtureSchemeHandler(), forURLScheme: "aegis")
        (profile.isPrivate ? privateRuntime : standardRuntime).apply(to: configuration)

        let tab = BrowserTab(id: id, profile: profile, configuration: configuration)
        tab.onNavigation = { [weak self] tab in
            guard let self, let url = tab.url else { return }
            if url.absoluteString != "aegis://start" {
                self.dataStore.record(title: tab.title, url: url, isPrivate: tab.profile.isPrivate)
            }
            if self.activeTabID == tab.id { self.refreshBookmarkState() }
            if !tab.profile.isPrivate { self.persistSession() }
        }
        tab.onNewWindow = { [weak self] url in
            guard let self, self.profile == profile else { return }
            self.newTab().load(url)
        }
        tab.onDownload = { [weak self] url in
            guard let self, self.profile == profile, !profile.isPrivate else { return }
            self.pendingDownloadURL = url
        }
        return tab
    }

    private func refreshBookmarkState() {
        updateActiveTab()
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

    private func updateActiveTab() {
        let activeID = activeTab?.id
        for tab in standardTabs + privateTabs { tab.setActive(tab.id == activeID) }
        evictionTask?.cancel()
        evictionTask = Task { @MainActor [weak self] in _ = await self?.releaseInactiveTabs(keeping: 4) }
    }

    /// 只卸载可安全重新加载的普通页面；表单、媒体及含框架的页面保留。
    @discardableResult
    public func releaseInactiveTabs(keeping limit: Int = 1) async -> Int {
        var released = 0
        for tab in standardTabs.sorted(by: { $0.lastActivatedAt < $1.lastActivatedAt }) {
            guard !Task.isCancelled, residentTabCount > max(1, limit) else { break }
            if await tab.suspendIfSafe() { released += 1 }
        }
        return released
    }

    public func protectAssistantTabs(_ ids: Set<UUID>) {
        for tab in standardTabs { tab.assistantPinned = ids.contains(tab.id) }
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
