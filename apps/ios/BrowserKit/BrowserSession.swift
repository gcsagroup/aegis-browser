import AegisPolicyKit
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
    private var titleObservation: NSKeyValueObservation?
    /// 只有显式加载或访问当前页面时才创建 WebView；标签列表不得通过此属性读取状态。
    public var webView: WKWebView {
        if let loadedWebView { return loadedWebView }
        let view = BrowserContentWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.isInspectable = inspectionEnabled
        view.scrollView.keyboardDismissMode = .onDrag
        loadedWebView = view
        // 页面标题也可能在导航完成之后更新，标签和操作预览必须跟随真实标题。
        titleObservation = view.observe(\.title, options: [.new]) { [weak self, weak view] _, _ in
            Task { @MainActor [weak self, weak view] in
                guard let self, let view, view === self.loadedWebView else { return }
                self.title = view.title?.isEmpty == false ? view.title! : (view.url?.host ?? String(localized: "新标签页"))
            }
        }
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
    public let preferences: BrowserPreferences
    public let enhancementStore: WebsiteEnhancementStore
    public private(set) var userScripts: UserScriptController!
    @Published public private(set) var inspectionEnabled = false
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
    @Published public private(set) var protectionIncident: PageProtectionIncident?
    @Published public private(set) var protectionNotice: String?
    @Published public private(set) var securityRulesReady = false
    @Published public private(set) var fingerprintSignals: [String] = []
    private var securityLists: [String: WKContentRuleList] = [:]
    private let securityRuleStore: SecurityRuleStore
    private var structureTask: Task<Void, Never>?
    private var temporaryPermission: (url: URL, expires: Date)?
    private var protectionUserScript: WKUserScript?
    private var resourceException: (origin: String, expires: Date)?
    private var exceptionExpiryTask: Task<Void, Never>?
    private var contentRuleList: WKContentRuleList?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = UUID()

    var onNavigation: ((BrowserTab) -> Void)?
    var onNewWindow: ((URL, Bool) -> Void)?
    var inheritedHardenedSecurity = false
    private var activeHardenedSecurity = false
    var onDownload: ((URL) -> Void)?
    var onMarkdown: ((MarkdownDocument) -> Void)?
    private var pendingNavigation: WKNavigation?

    init(id: UUID = UUID(), profile: BrowserProfile, configuration: WKWebViewConfiguration,
         preferences: BrowserPreferences = BrowserPreferences(), securityRuleStore: SecurityRuleStore = .shared,
         enhancementStore: WebsiteEnhancementStore = WebsiteEnhancementStore()) {
        self.id = id
        self.profile = profile
        self.configuration = configuration
        self.preferences = preferences
        self.securityRuleStore = securityRuleStore
        self.enhancementStore = enhancementStore
        PageProtection.applySystem(configuration, hardened: preferences.values.hardenedSecurity ?? false)
        super.init()
        configuration.userContentController.addUserScript(WKUserScript(source: """
        globalThis.__aegisHasEdits = false;
        document.addEventListener('input', () => { globalThis.__aegisHasEdits = true; }, true);
        document.addEventListener('change', () => { globalThis.__aegisHasEdits = true; }, true);
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        userScripts = UserScriptController(store: enhancementStore, controller: configuration.userContentController)
        userScripts.tab = self
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
        if loadedWebView == nil, protectionIncident == nil {
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

    public func setInspectionEnabled(_ enabled: Bool) throws {
        guard let current = webView.url, ScriptMatch.origin(current) != nil else { throw EnhancementError.invalid("只能检查当前 HTTP/HTTPS 网页。") }
        inspectionEnabled = enabled; webView.isInspectable = enabled
    }

    /// 原生恢复入口不等待页面脚本回应，避免卡死脚本阻塞停用操作。
    public func recoverAfterDisablingScripts() {
        let current = requestedURL ?? url
        releaseWebView()
        if let current { load(current) }
    }

    private func releaseWebView() {
        userScripts?.navigated()
        inspectionEnabled = false
        navigationEpoch &+= 1
        structureTask?.cancel()
        loadGeneration = UUID(); loadTask?.cancel()
        loadedWebView?.stopLoading()
        loadedWebView?.navigationDelegate = nil; loadedWebView?.uiDelegate = nil
        titleObservation = nil
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
        protectionIncident = nil; protectionNotice = nil; fingerprintSignals = []
        structureTask?.cancel()
        if temporaryPermission?.url != url { temporaryPermission = nil }
        loadingError = nil
        // 立即让旧页面授权失效，不等网络回调到来。
        navigationEpoch &+= 1
        loadTask?.cancel()
        loadGeneration = UUID()
        let generation = loadGeneration
        let decision = navigationDecision(url)
        if decision.kind == .blocked {
            blockNavigation(decision)
            lastPolicyIntervention = decision
            isLoading = false
            return
        }
        if preferences.values.phishingProtection, decision.phishingScore >= 55, !hasTemporaryPermission(url) {
            protectionNotice = String(localized: "此页面有登录风险信号，请核对网址和提交目的地。")
        }
        if decision.kind == .sanitized { lastPolicyIntervention = decision }
        let url = URL(string: decision.effectiveURL) ?? url
        requestedURL = url
        isLoading = true
        if ["http", "https"].contains(url.scheme ?? ""), contentRuleList == nil || securityLists.count < 2 {
            isLoading = true
            loadTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let list = try await TrackingProtection.shared.ruleList()
                    try Task.checkCancellation()
                    guard generation == loadGeneration else { return }
                    contentRuleList = list
                    for category in ["mining", "fingerprinting"] { securityLists[category] = try await securityRuleStore.list(category: category) }
                    try Task.checkCancellation()
                    guard generation == loadGeneration else { return }
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
        guard protectionIncident == nil else { throw PageSnapshotError.unavailable }
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
        structureTask?.cancel()
        navigationEpoch &+= 1
        loadGeneration = UUID()
        loadTask?.cancel()
        loadedWebView?.stopLoading()
        isLoading = false
    }

    private func configureTrackingProtection(for url: URL) {
        configurePageProtection(for: url)
        webView.pageZoom = preferences.site(for: url).zoom ?? preferences.values.zoom
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
        preferences webPreferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        let finish: (WKNavigationActionPolicy) -> Void = { decisionHandler($0, webPreferences) }
        guard webView === loadedWebView, let requestURL = navigationAction.request.url
        else {
            finish(.allow)
            return
        }
        let localOrInternal = ["aegis", "about"].contains(requestURL.scheme ?? "") ||
            (requestURL.scheme == "http" && ["127.0.0.1", "localhost", "[::1]", "::1"].contains(requestURL.host ?? ""))
        if localOrInternal { webPreferences.preferredHTTPSNavigationPolicy = .keepAsRequested }
        if navigationAction.targetFrame?.isMainFrame == false {
            let decision = navigationDecision(requestURL, method: navigationAction.request.httpMethod ?? "GET")
            finish(decision.kind == .blocked ? .cancel : .allow)
            return
        }
        if temporaryPermission?.url != requestURL { temporaryPermission = nil }
        let site = preferences.site(for: requestURL)
        activeHardenedSecurity = inheritedHardenedSecurity || (site.hardenedSecurity ?? preferences.values.hardenedSecurity ?? false)
        PageProtection.applySystem(webPreferences, hardened: activeHardenedSecurity)
        // 本机服务没有公网 HTTPS 身份；明确保留用户输入的本机 HTTP。
        if localOrInternal {
            webPreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        }
        webPreferences.preferredContentMode = (site.desktop ?? preferences.values.desktop) ? .desktop : .recommended
        webPreferences.allowsContentJavaScript = site.javaScript ?? preferences.values.javaScript
        let decision = navigationDecision(requestURL, method: navigationAction.request.httpMethod ?? "GET")
        if decision.kind != .blocked, ["http", "https"].contains(requestURL.scheme ?? ""), (contentRuleList == nil || securityLists.count < 2) {
            finish(.cancel)
            load(requestURL)
            return
        }
        configureTrackingProtection(for: requestURL)
        switch decision.kind {
        case .allow:
            if navigationAction.shouldPerformDownload {
                onDownload?(requestURL)
                finish(.cancel)
                return
            }
            if lastPolicyIntervention?.kind != .sanitized
                || lastPolicyIntervention?.effectiveURL != requestURL.absoluteString {
                lastPolicyIntervention = nil
            }
            finish(.allow)
        case .blocked:
            blockNavigation(decision)
            lastPolicyIntervention = decision
            pendingNavigation = nil
            isLoading = false
            finish(.cancel)
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
                finish(.cancel)
                return
            }
            lastPolicyIntervention = decision
            var cleanedRequest = navigationAction.request
            cleanedRequest.url = cleanedURL
            finish(.cancel)
            pendingNavigation = webView.load(cleanedRequest)
        }
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === loadedWebView, isCurrent(navigation) else { return }
        isLoading = true
        userScripts?.navigated()
        inspectionEnabled = false; webView.isInspectable = false
        navigationEpoch &+= 1
        structureTask?.cancel()
        refreshState()
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === loadedWebView, isCurrent(navigation) else { return }
        // 新文档不继承前页的结构或接口提示；当前页面的检查会重新生成提示。
        protectionNotice = nil
        fingerprintSignals = []
        startStructureChecks(webView)
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
        if let current = url, MarkdownDocument.accepts(current), preferences.site(for: current).markdownPreview == true {
            Task { @MainActor [weak self] in
                guard let self, let document = try? await MarkdownDocument.capture(self) else { return }
                self.onMarkdown?(document)
            }
        }
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
        guard navigationAction.navigationType == .linkActivated || preferences.values.allowPopups else { return nil }
        if navigationDecision(url).kind != .blocked { onNewWindow?(url, activeHardenedSecurity) }
        return nil
    }

    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        var originParts = URLComponents()
        originParts.scheme = origin.protocol; originParts.host = origin.host
        if origin.port != 0 { originParts.port = origin.port }
        guard frame.isMainFrame, let url = frame.request.url, let originURL = originParts.url,
              let current = self.url, BrowserPreferences.origin(url) == BrowserPreferences.origin(current),
              BrowserPreferences.origin(originURL) == BrowserPreferences.origin(current) else { decisionHandler(.deny); return }
        let site = preferences.site(for: url)
        let blocked = (type != .microphone && site.camera == .deny) || (type != .camera && site.microphone == .deny)
        // “询问”交给系统与 WebKit，不授予静默或跨来源权限。
        decisionHandler(blocked ? .deny : .prompt)
    }

    public func applyDisplayPreferences() {
        loadedWebView?.pageZoom = preferences.site(for: requestedURL ?? url).zoom ?? preferences.values.zoom
    }

    private func navigationDecision(_ url: URL, method: String = "GET") -> BrowserNavigationPolicyDecision {
        BrowserNavigationPolicy.evaluate(url, httpMethod: method,
            sanitizeLinks: preferences.values.linkSanitization, checkPhishing: preferences.values.phishingProtection && !hasTemporaryPermission(url))
    }

    private func hasTemporaryPermission(_ url: URL) -> Bool {
        temporaryPermission.map { $0.url == url && $0.expires > Date() } ?? false
    }

    public func temporarilyRestoreSecurityResources() {
        guard let target = requestedURL ?? url, let origin = BrowserPreferences.origin(target) else { return }
        resourceException = (origin, Date().addingTimeInterval(600))
        scheduleExceptionExpiry()
        reload()
    }
    public func restoreSecurityResourceProtection() { resourceException = nil; reload() }
    public var securityResourcesTemporarilyAllowed: Bool {
        resourceException.map { $0.origin == (requestedURL ?? url).flatMap(BrowserPreferences.origin) && $0.expires > Date() } ?? false
    }

    public func continueProtectedPageOnce() {
        guard let incident = protectionIncident, ["http", "https"].contains(incident.url.scheme ?? ""),
              incident.url.user == nil, incident.url.password == nil else { return }
        temporaryPermission = (incident.url, Date().addingTimeInterval(600))
        scheduleExceptionExpiry()
        load(incident.url)
    }

    private func scheduleExceptionExpiry() {
        exceptionExpiryTask?.cancel()
        let next = [temporaryPermission?.expires, resourceException?.expires].compactMap { $0 }.min()
        guard let next else { return }
        exceptionExpiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow))) } catch { return }
            self?.expireTemporaryPermissions()
        }
    }

    func expireTemporaryPermissions(now: Date = Date()) {
        if let exception = resourceException, exception.expires <= now {
            resourceException = nil
            if loadedWebView != nil, let current = requestedURL ?? url { configurePageProtection(for: current) }
        }
        if let permission = temporaryPermission, permission.expires <= now {
            temporaryPermission = nil
            if let view = loadedWebView, let current = view.url {
                let decision = navigationDecision(current)
                if decision.kind == .blocked { blockNavigation(decision) }
                else { startStructureChecks(view) }
            }
        }
        scheduleExceptionExpiry()
    }

    private func blockNavigation(_ decision: BrowserNavigationPolicyDecision) {
        guard let target = URL(string: decision.originalURL),
              ["http", "https"].contains(target.scheme ?? ""), target.user == nil, target.password == nil,
              !decision.reasonCodes.contains("unsafe_sanitization_method") else { return }
        showProtectionIncident(PageProtectionIncident(url: target, reasons: decision.reasonCodes,
            score: decision.phishingScore, fromPage: false))
    }

    private func showProtectionIncident(_ incident: PageProtectionIncident) {
        // SwiftUI 可能暂时持有旧视图；先替换其文档，再解除浏览器持有，避免只盖住仍在运行的页面。
        loadedWebView?.loadHTMLString("", baseURL: nil)
        releaseWebView()
        requestedURL = incident.url; url = incident.url
        protectionIncident = incident
        title = String(localized: "已阻止风险页面")
    }

    private func configurePageProtection(for url: URL) {
        let controller = webView.configuration.userContentController
        for (category, list) in securityLists {
            controller.remove(list)
            let enabled = category == "mining" ? (preferences.values.miningProtection ?? true)
                : (preferences.values.fingerprintProtection ?? true)
            let excepted = resourceException.map { $0.origin == BrowserPreferences.origin(url) && $0.expires > Date() } ?? false
            if enabled && !excepted { controller.add(list) }
        }
        securityRulesReady = securityLists.count == 2
        // 只替换本模块自己的脚本；保留扩展及页面编辑状态观察器。
        let otherScripts = controller.userScripts.filter { $0 !== protectionUserScript }
        controller.removeAllUserScripts()
        otherScripts.forEach(controller.addUserScript)
        let strict = preferences.site(for: url).strictFingerprinting ?? preferences.values.strictFingerprinting ?? false
        let script = WKUserScript(source: PageProtection.fingerprintScript.replacingOccurrences(of: "__STRICT__", with: strict ? "true" : "false"),
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        protectionUserScript = script; controller.addUserScript(script)
    }

    private func startStructureChecks(_ view: WKWebView) {
        structureTask?.cancel()
        guard let expected = view.url, ["http", "https"].contains(expected.scheme ?? "") else { return }
        let epoch = navigationEpoch
        structureTask = Task { @MainActor [weak self, weak view] in
            // 首次提交后立即检查，再观察一分钟；页面退出、导航或释放即取消。
            for _ in 0..<31 {
                guard await self?.inspectProtection(view, expected: expected, epoch: epoch) == true else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func inspectProtection(_ view: WKWebView?, expected: URL, epoch: UInt64) async -> Bool {
        guard let view, view === loadedWebView, epoch == navigationEpoch, !Task.isCancelled,
              let current = view.url, let origin = BrowserPreferences.origin(expected),
              BrowserPreferences.origin(current) == origin else { return false }
        if temporaryPermission?.url != current { temporaryPermission = nil }
        var notice: String?
        if preferences.values.phishingProtection,
           let raw = try? await view.callAsyncJavaScript(PageProtection.structureScript, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any],
           view === loadedWebView, epoch == navigationEpoch, !Task.isCancelled,
           let current = view.url, BrowserPreferences.origin(current) == origin,
           !hasTemporaryPermission(current),
           let assessment = PageProtection.assessment(raw, url: current) {
            // 同一文档的 pushState 可以改变路径；仍绑定当前来源和导航版本，并核对实际快照网址。
            if PageProtection.shouldUnload(assessment) {
                showProtectionIncident(PageProtectionIncident(url: current, reasons: assessment.reasons.map(\.code), score: assessment.score, fromPage: true))
                return false
            }
            if assessment.score >= 55 {
                notice = String(localized: "此页面有登录风险信号，请核对网址和提交目的地。")
            }
        }
        if let counts = try? await view.callAsyncJavaScript("return globalThis.__aegisProtectionCounts || {};", arguments: [:], in: nil, contentWorld: .page) as? [String: Int],
           view === loadedWebView, epoch == navigationEpoch, !Task.isCancelled {
            // 页面世界数据可伪造，只用于提示，不据此授权、封禁或调用原生操作。
            let observed = ["canvas", "webgl", "audio"].filter { (counts[$0] ?? 0) > 0 }
            if fingerprintSignals != observed { fingerprintSignals = observed }
            if (counts["worker"] ?? 0) > 0, (counts["wasm"] ?? 0) > 0 {
                notice = String(localized: "页面使用了 Worker 和 WASM；这些也是正常计算能力，尚不能据此判断挖矿。")
            }
        }
        guard view === loadedWebView, epoch == navigationEpoch, !Task.isCancelled else { return false }
        if protectionNotice != notice { protectionNotice = notice }
        return true
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
    private final class WeakSession { weak var value: BrowserSession?; init(_ value: BrowserSession) { self.value = value } }
    private static var sessions: [WeakSession] = []
    @Published public private(set) var standardTabs: [BrowserTab] = []
    @Published public private(set) var privateTabs: [BrowserTab] = []
    @Published public var activeTabID: UUID?
    @Published public var profile: BrowserProfile = .standard
    @Published public private(set) var extensionStatus = "WebExtension 正在初始化"
    @Published public private(set) var bookmarkIsActive = false
    @Published public private(set) var sessionError: String?
    @Published public var pendingDownloadURL: URL?
    @Published public var pendingMarkdown: MarkdownDocument?
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
    public let preferences: BrowserPreferences
    private var preferenceChanges: AnyCancellable?

    private let standardEnhancements: WebsiteEnhancementStore
    private var privateEnhancements = WebsiteEnhancementStore()
    public var enhancements: WebsiteEnhancementStore { profile.isPrivate ? privateEnhancements : standardEnhancements }

    private let standardRuntime: WebExtensionRuntime
    private let privateRuntime: WebExtensionRuntime

    public init(dataStore: BrowserDataStore = BrowserDataStore(), workspaceStore: WorkspaceStore = WorkspaceStore(),
                windowID: UUID = UUID(), windowStore: BrowserWindowStore? = nil,
                preferences: BrowserPreferences = BrowserPreferences(),
                enhancementStore: WebsiteEnhancementStore = .shared) {
        self.dataStore = dataStore
        self.workspaceStore = workspaceStore
        self.windowID = windowID
        self.windowStore = windowStore
        self.preferences = preferences
        self.standardEnhancements = enhancementStore
        standardRuntime = WebExtensionRuntime(isPrivate: false)
        privateRuntime = WebExtensionRuntime(isPrivate: true)
        let snapshot = windowStore?.snapshot(windowID)
        let restored = preferences.values.startup == .restore ? (snapshot?.tabs ?? (windowStore == nil ? workspaceStore.sessionURLs.map {
            SavedBrowserTab(id: UUID(), url: $0, groupID: nil)
        } : [])) : []
        standardGroups = preferences.values.startup == .restore ? snapshot?.groups ?? [] : []
        standardGroupID = preferences.values.startup == .restore ? snapshot?.selectedGroupID : nil
        if restored.isEmpty {
            let first = makeTab(profile: .standard)
            if preferences.values.startup == .homePage { first.prepareForRestore(url: preferences.homeURL) }
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
            bookmarkIsActive = bookmarks.contains { $0.url == activeTab?.url?.absoluteString }
        }
        preferenceChanges = preferences.$values.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                (standardTabs + privateTabs).forEach { $0.applyDisplayPreferences() }
            }
        }
        // 窗口会话由视图出现后首次保存，避免构造视图时发布共享存储变更。
        if windowStore == nil { persistSession() }
        memoryWarnings = NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in _ = await self?.releaseInactiveTabs(keeping: 1) }
            }
        Task { await loadWebExtensions() }
        Self.sessions.removeAll { $0.value == nil }
        Self.sessions.append(WeakSession(self))
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

    public var agentIsAvailable: Bool { activeTab != nil }

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
        if preferences.values.newTabsUseHomepage { tab.prepareForRestore(url: preferences.homeURL) }
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
            if privateTabs.isEmpty { privateEnhancements = WebsiteEnhancementStore(); privateTabs = [makeTab(profile: .privateMode)] }
        }
        if activeTabID == tabID { activeTabID = displayedTabs.first?.id }
        refreshBookmarkState()
        persistSession()
    }

    /// 恢复时追加新标签，保留用户当前打开的页面。
    @discardableResult
    public func restoreWorkspace(_ workspace: SavedWorkspace) -> [UUID] {
        var created: [UUID] = []
        for url in workspace.urls.prefix(max(0, 50 - visibleTabs.count)) {
            let tab = makeTab(profile: profile)
            tab.groupID = selectedGroupID
            tab.prepareForRestore(url: url)
            if profile.isPrivate { privateTabs.append(tab) } else { standardTabs.append(tab) }
            created.append(tab.id)
        }
        if let id = created.last { activeTabID = id }
        refreshBookmarkState(); persistSession()
        return created
    }

    public func saveWorkspace(name: String, privateSaveConfirmed: Bool = false) throws -> SavedWorkspace {
        guard !profile.isPrivate || privateSaveConfirmed else { throw WorkspaceError.noPages }
        return try workspaceStore.save(name: name, urls: visibleTabs.compactMap { $0.requestedURL ?? $0.url })
    }

    public func clearWebsiteData(records: [WKWebsiteDataRecord]? = nil) async {
        guard !profile.isPrivate else { return }
        // WebKit 的普通网站存储由各窗口共享，清除前同时停止所有普通页面。
        for session in Self.sessions.compactMap(\.value) {
            session.standardTabs.forEach { $0.stop() }
            session.standardGroups = []; session.standardGroupID = nil
            session.standardTabs = [session.makeTab(profile: .standard)]
            session.standardActiveID = session.standardTabs.first?.id
            if !session.profile.isPrivate { session.activeTabID = session.standardActiveID }
            session.persistSession(); session.refreshBookmarkState()
        }
        if let records {
            await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        } else {
            await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
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
        guard let tab = activeTab else { return }
        guard let url = Self.normalizedURL(from: address, preferences: preferences.values) else {
            if preferences.values.availableSearchEngines.isEmpty {
                sessionError = String(localized: "尚未启用搜索引擎，请输入网址，或在浏览设置中恢复搜索引擎。")
            }
            return
        }
        tab.load(url)
    }

    public func toggleBookmark(privateSaveConfirmed: Bool = false) {
        guard !profile.isPrivate || privateSaveConfirmed,
              let tab = activeTab, let url = tab.url else { return }
        bookmarkIsActive = dataStore.toggleBookmark(
            title: tab.title,
            url: url,
            isPrivate: false // 私密页面只允许在上方明确确认后写入收藏。
        )
    }

    public static func normalizedURL(from input: String, preferences: BrowserPreferenceValues = BrowserPreferenceValues()) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return URL(string: "aegis://start") }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }
        return BrowserPreferences.searchURL(trimmed, values: preferences)
    }

    private func makeTab(profile: BrowserProfile, id: UUID = UUID()) -> BrowserTab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = profile.isPrivate ? .nonPersistent() : .default()
        configuration.userContentController = WKUserContentController()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = preferences.values.allowPopups
        configuration.mediaTypesRequiringUserActionForPlayback = preferences.values.requireMediaGesture ? .all : []
        configuration.setURLSchemeHandler(FixtureSchemeHandler(), forURLScheme: "aegis")
        (profile.isPrivate ? privateRuntime : standardRuntime).apply(to: configuration)

        #if DEBUG
        let rules = ProcessInfo.processInfo.arguments.contains("--ui-testing-security") ? SecurityRuleStore(fixtureRules: true) : .shared
        #else
        let rules = SecurityRuleStore.shared
        #endif
        let tab = BrowserTab(id: id, profile: profile, configuration: configuration, preferences: preferences, securityRuleStore: rules,
                             enhancementStore: profile.isPrivate ? privateEnhancements : standardEnhancements)
        tab.onNavigation = { [weak self] tab in
            guard let self, let url = tab.url else { return }
            if url.absoluteString != "aegis://start", preferences.values.saveHistory {
                self.dataStore.record(title: tab.title, url: url, isPrivate: tab.profile.isPrivate)
            }
            if self.activeTabID == tab.id { self.refreshBookmarkState() }
            if !tab.profile.isPrivate { self.persistSession() }
        }
        tab.onMarkdown = { [weak self, weak tab] document in
            guard let self, let tab, self.activeTabID == tab.id else { return }
            self.pendingMarkdown = document
        }
        tab.onNewWindow = { [weak self] url, hardened in
            guard let self, self.profile == profile else { return }
            let child = self.newTab()
            child.inheritedHardenedSecurity = hardened
            child.load(url)
        }
        tab.onDownload = { [weak self] url in
            guard let self, self.profile == profile else { return }
            self.pendingDownloadURL = url
        }
        return tab
    }

    private func refreshBookmarkState() {
        updateActiveTab()
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
        for tab in standardTabs + privateTabs { tab.assistantPinned = ids.contains(tab.id) }
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
