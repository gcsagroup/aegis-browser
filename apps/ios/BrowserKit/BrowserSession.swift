import AegisPolicyKit
import Combine
import Foundation
import UIKit
import WebKit

/// Captured when WebKit hands a native download to the browser. Each event
/// keeps its own identity even when a tab requests the same URL again.
public struct BrowserAccessDownload: Equatable {
    fileprivate let requestID = UUID()
    fileprivate let selectionID: UUID
    public let tab: UUID
    public let privateMode: Bool
    public let target: URL
    public let host: String

    public static func canonicalHost(of url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return RegisteredDomain.normalizedHost(host)
    }
}

/// App-owned exact-host stores. Nil keeps every tab on the store it was created with.
public enum BrowserNavigationFailure {
    /// Main-frame failures that may receive one Access retry.
    /// Allow-list only: DNS, connect, connection lost, timeout.
    /// Offline, cancel, TLS/ATS, HTTP status, redirect loops, and auth challenges do not qualify.
    public static func isRecoverableNetworkFailure(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorTimedOut:
            return true
        default:
            return false
        }
    }
}

public struct BrowserMainFrameFailure: Equatable, Sendable {
    public var failureID: UUID
    public var navigationID: String
    public var url: URL
    public var method: String
    /// True when a body, stream, auth context, or uncertain redirected method
    /// cannot safely be replayed. Blocks automatic proxy retry.
    public var hasReplayableBody: Bool
    public var recoveryOperationID: UUID?

    public init(
        failureID: UUID,
        navigationID: String,
        url: URL,
        method: String,
        hasReplayableBody: Bool = false,
        recoveryOperationID: UUID? = nil
    ) {
        self.failureID = failureID
        self.navigationID = navigationID
        self.url = url
        self.method = method
        self.hasReplayableBody = hasReplayableBody
        self.recoveryOperationID = recoveryOperationID
    }

    /// Body, upload stream, or Authorization header cannot be reconstructed for retry.
    public static func requestHasUnsafeReplaySurface(_ request: URLRequest) -> Bool {
        if request.httpBody != nil { return true }
        if request.httpBodyStream != nil { return true }
        if request.value(forHTTPHeaderField: "Authorization") != nil { return true }
        return false
    }
}

@MainActor
public protocol BrowserHostStoreCoordinating: AnyObject {
    func wouldSwitchStore(tab: BrowserTab, url: URL) -> Bool
    func dataStoreForMainFrame(tab: BrowserTab, url: URL) -> WKWebsiteDataStore?
    func mainFrameFailed(tab: BrowserTab, failure: BrowserMainFrameFailure, error: NSError)
    func pendingRecoveryInvalidated(tab: BrowserTab)
    func tabClosed(_ tab: BrowserTab)
    func ordinaryHostStores() -> [WKWebsiteDataStore]
    func endPrivateSession(scopeID: String)
}

public enum BrowserProfile: String, CaseIterable, Identifiable, Sendable {
    case standard
    case privateMode

    public var id: String { rawValue }
    public var title: String { self == .standard ? AegisLocalization.string("普通") : AegisLocalization.string("私密") }
    public var isPrivate: Bool { self == .privateMode }
}

@MainActor
public final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    public let id: UUID
    public var onAccessContextClosed: (() -> Void)?
    fileprivate var accessSelectionID = UUID()
    public var selectedAccessHost: String? { didSet { accessSelectionID = UUID() } }
    /// Live ownership is never reused when a saved tab UUID is restored.
    public let instanceID = UUID()
    private var configuration: WKWebViewConfiguration
    /// Store captured when the tab was created. Returning to the original connection uses this object.
    public let originalWebsiteDataStore: WKWebsiteDataStore
    public var websiteDataStore: WKWebsiteDataStore { configuration.websiteDataStore }
    /// Tab-local parent of a canonical HTTPS landing page. The landing host has its own store.
    public private(set) var proxyLandingParent: String?
    private var proxyLandingTarget: String?
    public func clearProxyLanding() {
        proxyLandingParent = nil
        proxyLandingTarget = nil
    }

    public func parentForProxyLanding(_ url: URL) -> String? {
        guard url.scheme == "https", url.port == nil || url.port == 443,
              url.host?.lowercased() == proxyLandingTarget else { return nil }
        return proxyLandingParent
    }
    public var boundHostName: String?
    public var browsingScopeID = "ordinary"
    var configurationFactory: ((WKWebsiteDataStore) -> WKWebViewConfiguration)?
    public weak var hostCoordinator: BrowserHostStoreCoordinating?
    private var committedRequestMethod = "GET"
    private struct MainFrameAttempt {
        var navigationID: String
        var url: URL
        var method: String
        var hasReplayableBody: Bool
        /// Monotonic allow order. A newer allow becomes current even if an older
        /// provisional navigation is still mapped.
        var allowSequence: UInt64
        var failureID: UUID?
        var recoveryOperationID: UUID?
        var policyType: WKNavigationType?

        func acceptsRedirectPolicy(_ type: WKNavigationType?) -> Bool {
            type != nil && (type == .other || type == policyType)
        }
    }
    private var nextAllowSequence: UInt64 = 0
    private var attempt = MainFrameAttempt(
        navigationID: UUID().uuidString,
        url: URL(string: "about:blank")!,
        method: "GET",
        hasReplayableBody: false,
        allowSequence: 0,
        failureID: nil,
        recoveryOperationID: nil
    )
    private var attemptsByNavigation: [ObjectIdentifier: MainFrameAttempt] = [:]
    /// Policy-approved main-frame attempts waiting for a matching `didStart` / load bind.
    /// Paired FIFO so a late start cannot inherit a newer sibling's URL/method.
    private var unboundAttempts: [MainFrameAttempt] = []
    /// Only app-issued loads waiting for content rules / a window / the next turn.
    /// Policy-approved page actions already belong to WebKit and must survive cancellation here.
    private weak var provisionalNavigation: WKNavigation?
    private var provisionalDeadlineExpired = false
    private var provisionalDeadline: Task<Void, Never>?
    private var deferredDocumentNavigationID: String?
    private var programmaticPolicyNavigationID: String?
    private var confirmedRedirectPolicy: (navigationID: String, url: URL)?
    @Published public private(set) var lastMainFrameFailure: BrowserMainFrameFailure?
    @Published public private(set) var loadingErrorAllowsProxyRetry = false
    /// Set only after the recovery navigation commits while this attempt is a proxy retry.
    @Published public private(set) var proxyRecoveryCommitted = false
    internal private(set) var recoveryLoadCount = 0
    var currentAttemptIDForTests: String { attempt.navigationID }
    var currentNavigationForTests: WKNavigation? { pendingNavigation }

    /// Records the pending main-frame URL as committed. Unit tests have no WebKit commit callback.
    public func commitPendingMainFrameForTests() {
        let recorded: URL
        if let pendingNavigation,
           let match = attemptsByNavigation[ObjectIdentifier(pendingNavigation)] {
            recorded = match.url
        } else {
            recorded = attempt.url
        }
        let scheme = recorded.scheme?.lowercased() ?? ""
        guard ["http", "https"].contains(scheme) else { return }
        committedMainFrameURL = recorded
        url = recorded
    }

    /// Unit tests have no WebKit commit. Production sets the flag in `didCommit`.
    public func noteRecoveryCommittedForTests() {
        proxyRecoveryCommitted = true
    }

    /// The routing receipt should not wait on a cold content-rule compile.
    public func prepareContentRulesForTests() async throws {
        let list = try await TrackingProtection.shared.ruleList()
        contentRuleList = list
        for category in ["mining", "fingerprinting"] {
            securityLists[category] = try await securityRuleStore.list(category: category)
        }
    }
    private var loadedWebView: WKWebView?
    public private(set) var isDisposed = false
    private var closedPlaceholder: BrowserContentWebView?
    private var titleObservation: NSKeyValueObservation?
    /// 只有显式加载或访问当前页面时才创建 WebView；标签列表不得通过此属性读取状态。
    public var webView: WKWebView {
        if isDisposed {
            if let closedPlaceholder { return closedPlaceholder }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.defaultWebpagePreferences.allowsContentJavaScript = false
            let placeholder = BrowserContentWebView(frame: .zero, configuration: config)
            placeholder.terminateDocument {}
            closedPlaceholder = placeholder
            return placeholder
        }
        if let loadedWebView { return loadedWebView }
        let view = BrowserContentWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.isInspectable = inspectionEnabled
        view.scrollView.keyboardDismissMode = .onDrag
        view.onDidMoveToWindow = { [weak self] in
            self?.flushPendingAttachedLoad()
        }
        loadedWebView = view
        // 页面标题也可能在导航完成之后更新，标签和操作预览必须跟随真实标题。
        titleObservation = view.observe(\.title, options: [.new]) { [weak self, weak view] _, _ in
            Task { @MainActor [weak self, weak view] in
                guard let self, let view, view === self.loadedWebView else { return }
                self.updateTitle(view.title, url: view.url)
            }
        }
        return view
    }
    public var isResident: Bool { loadedWebView != nil }
    @Published public private(set) var webViewGeneration: UInt64 = 0
    private var pendingAttachedLoad: URLRequest?
    /// Set when a store swap destroys the visible web view. The replacement loads only after it is in a window.
    private var needsWindowBeforeLoad = false
    private var windowFlushScheduled = false
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
    @Published private var titlePresentation: AegisLocalizedMessage = .resource("新标签页")
    public var title: String { titlePresentation.text }
    @Published public private(set) var url: URL?
    @Published public private(set) var isLoading = false
    @Published public private(set) var canGoBack = false
    @Published public private(set) var canGoForward = false
    @Published public private(set) var navigationEpoch: UInt64 = 0
    @Published public private(set) var lastPolicyIntervention: BrowserNavigationPolicyDecision?
    @Published private var loadingErrorPresentation: AegisLocalizedMessage?
    public var loadingError: String? { loadingErrorPresentation?.text }
    @Published public private(set) var trackingProtectionReady = false
    @Published public internal(set) var groupID: UUID?
    public private(set) var requestedURL: URL?
    /// HTTP(S) main document that reached `didCommit`. In-flight `requestedURL` is not authorization.
    public private(set) var committedMainFrameURL: URL?
    @Published public private(set) var protectionIncident: PageProtectionIncident?
    @Published private var protectionNoticePresentation: AegisLocalizedMessage?
    public var protectionNotice: String? { protectionNoticePresentation?.text }
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
    /// A document is realigned or paused for content rules at most once.
    /// Repeating that cancel/reload pair never reaches the network.
    private var realignedNavigationURL: URL?
    private var contentRulesNavigationURL: URL?

    init(id: UUID = UUID(), profile: BrowserProfile, configuration: WKWebViewConfiguration,
         preferences: BrowserPreferences = BrowserPreferences(), securityRuleStore: SecurityRuleStore = .shared,
         enhancementStore: WebsiteEnhancementStore = WebsiteEnhancementStore()) {
        self.id = id
        self.profile = profile
        self.configuration = configuration
        self.originalWebsiteDataStore = configuration.websiteDataStore
        self.preferences = preferences
        self.securityRuleStore = securityRuleStore
        self.enhancementStore = enhancementStore
        super.init()
        installContentHooks()
    }

    private func installContentHooks() {
        PageProtection.applySystem(configuration, hardened: preferences.values.hardenedSecurity ?? false)
        configuration.userContentController.addUserScript(WKUserScript(source: """
        globalThis.__aegisHasEdits = false;
        document.addEventListener('input', () => { globalThis.__aegisHasEdits = true; }, true);
        document.addEventListener('change', () => { globalThis.__aegisHasEdits = true; }, true);
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        userScripts = UserScriptController(store: enhancementStore, controller: configuration.userContentController)
        userScripts?.tab = self
    }

    private func beginUserNavigation(
        url: URL,
        method: String,
        hasReplayableBody: Bool = false,
        policyType: WKNavigationType? = nil
    ) {
        invalidateDeferredDocumentLoad()
        hostCoordinator?.pendingRecoveryInvalidated(tab: self)
        programmaticPolicyNavigationID = nil
        confirmedRedirectPolicy = nil
        if realignedNavigationURL != url { realignedNavigationURL = nil }
        if contentRulesNavigationURL != url { contentRulesNavigationURL = nil }
        pendingAttachedLoad = nil
        loadingErrorPresentation = nil
        loadingErrorAllowsProxyRetry = false
        proxyRecoveryCommitted = false
        lastMainFrameFailure = nil
        nextAllowSequence &+= 1
        attempt = MainFrameAttempt(
            navigationID: UUID().uuidString,
            url: url,
            method: method.uppercased(),
            hasReplayableBody: hasReplayableBody,
            allowSequence: nextAllowSequence,
            failureID: nil,
            recoveryOperationID: nil,
            policyType: policyType
        )
        // Keep prior unbound rows so a competing allow cannot erase an earlier
        // identity before didStart binds it. Abandoned rows are retired when a
        // deferred load is superseded / invalidated, or when the document finishes.
        unboundAttempts.append(attempt)
    }

    private func dequeueUnboundAttempt() -> MainFrameAttempt? {
        guard !unboundAttempts.isEmpty else { return nil }
        return unboundAttempts.removeFirst()
    }

    private func retireUnboundAttempt(navigationID: String) {
        unboundAttempts.removeAll { $0.navigationID == navigationID }
    }

    private func bindNavigation(_ navigation: WKNavigation, to recorded: MainFrameAttempt) {
        attemptsByNavigation[ObjectIdentifier(navigation)] = recorded
        retireUnboundAttempt(navigationID: recorded.navigationID)
    }

    private func retireNavigationIdentity(_ navigation: WKNavigation?) {
        if let navigation {
            if let retired = attemptsByNavigation.removeValue(forKey: ObjectIdentifier(navigation)) {
                if programmaticPolicyNavigationID == retired.navigationID { programmaticPolicyNavigationID = nil }
                if confirmedRedirectPolicy?.navigationID == retired.navigationID { confirmedRedirectPolicy = nil }
            }
        }
    }

    private func retireAllNavigationIdentities() {
        provisionalNavigation = nil
        provisionalDeadline?.cancel()
        attemptsByNavigation.removeAll()
        unboundAttempts.removeAll()
        pendingNavigation = nil
        programmaticPolicyNavigationID = nil
        confirmedRedirectPolicy = nil
    }

    /// Records the actual main-frame URL/method for policy-allowed navigations,
    /// redirects, and sanitized replacements.
    ///
    /// Same-navigation redirects may update the in-flight identity in place.
    /// A competing page navigation (link, form, history) mints a fresh attempt and
    /// must not rewrite the still-pending navigation's recorded URL/method.
    private func adoptMainFrameNavigation(
        url: URL,
        method: String,
        continuesExistingNavigation: Bool,
        hasReplayableBody: Bool = false,
        policyType: WKNavigationType? = nil
    ) {
        let normalizedMethod = method.uppercased()
        let confirmedRedirect = attempt.acceptsRedirectPolicy(policyType)
            && confirmedRedirectPolicy?.navigationID == attempt.navigationID
            && confirmedRedirectPolicy?.url == url
        if continuesExistingNavigation || confirmedRedirect {
            confirmedRedirectPolicy = nil
            if let pending = pendingNavigation,
               var mapped = attemptsByNavigation[ObjectIdentifier(pending)] {
                mapped.url = url
                if confirmedRedirect, mapped.method != normalizedMethod {
                    // A policy action has no WKNavigation identity. A different method
                    // at this URL cannot promote the original chain to safe replay.
                    mapped.hasReplayableBody = true
                } else {
                    mapped.method = normalizedMethod
                }
                // Redirects must not clear an earlier unsafe replay surface.
                mapped.hasReplayableBody = mapped.hasReplayableBody || hasReplayableBody
                attemptsByNavigation[ObjectIdentifier(pending)] = mapped
                if attempt.navigationID == mapped.navigationID {
                    attempt = mapped
                }
                requestedURL = url
                return
            }
            if var unbound = unboundAttempts.last {
                unbound.url = url
                if confirmedRedirect, unbound.method != normalizedMethod {
                    unbound.hasReplayableBody = true
                } else {
                    unbound.method = normalizedMethod
                }
                unbound.hasReplayableBody = unbound.hasReplayableBody || hasReplayableBody
                unboundAttempts[unboundAttempts.count - 1] = unbound
                if attempt.navigationID == unbound.navigationID {
                    attempt = unbound
                }
                requestedURL = url
                return
            }
        }
        // `WKWebView.load` may call decidePolicyFor before it returns the navigation.
        // Keep the identity minted by commitPreservingMethod / retry in that window.
        let historyAcknowledgment = attempt.policyType == .backForward
            && (policyType == .backForward || policyType == .formResubmitted)
        if attempt.url == url, programmaticPolicyNavigationID == attempt.navigationID,
           historyAcknowledgment || (attempt.policyType != .backForward && attempt.method == normalizedMethod) {
            programmaticPolicyNavigationID = nil
            if historyAcknowledgment {
                // The history item has no request method. The policy request supplies it.
                attempt.method = normalizedMethod
                attempt.hasReplayableBody = hasReplayableBody
            } else {
                attempt.hasReplayableBody = attempt.hasReplayableBody || hasReplayableBody
            }
            attempt.policyType = policyType
            if let pending = pendingNavigation,
               attemptsByNavigation[ObjectIdentifier(pending)]?.navigationID == attempt.navigationID {
                attemptsByNavigation[ObjectIdentifier(pending)] = attempt
            }
            if let idx = unboundAttempts.lastIndex(where: { $0.navigationID == attempt.navigationID }) {
                unboundAttempts[idx] = attempt
            }
            committedRequestMethod = normalizedMethod
            requestedURL = url
            return
        }
        beginUserNavigation(url: url, method: normalizedMethod, hasReplayableBody: hasReplayableBody,
                            policyType: policyType)
        requestedURL = url
        committedRequestMethod = normalizedMethod
        isLoading = true
    }

    /// Unit tests drive same-host in-page identity without synthesizing `WKNavigationAction`.
    public func adoptPolicyMainFrameNavigationForTests(
        url: URL,
        method: String = "GET",
        continuesExistingNavigation: Bool = false,
        hasReplayableBody: Bool = false
    ) {
        adoptMainFrameNavigation(
            url: url,
            method: method,
            continuesExistingNavigation: continuesExistingNavigation,
            hasReplayableBody: hasReplayableBody
        )
    }

    /// Cancels a deferred `WKWebView.load` that has not been issued yet (Stop, revoke, tab close).
    public func invalidateDeferredDocumentLoad() {
        loadGeneration = UUID()
        pendingAttachedLoad = nil
        needsWindowBeforeLoad = false
        if let abandonedID = deferredDocumentNavigationID {
            retireUnboundAttempt(navigationID: abandonedID)
        }
        if deferredDocumentNavigationID == attempt.navigationID {
            attempt.recoveryOperationID = nil
        }
        deferredDocumentNavigationID = nil
    }

    private func rejectUnavailableLanding(_ url: URL, store: WKWebsiteDataStore?) -> Bool {
        guard parentForProxyLanding(url) != nil, store == nil else { return false }
        loadingErrorPresentation = .resource("代理入口还不能使用")
        loadingErrorAllowsProxyRetry = false
        isLoading = false
        return true
    }

    func alignStore(for url: URL, previous: URL?, method: String, body: Data?) -> Bool {
        guard !isDisposed else { return false }
        let hostChanged = previous?.host?.lowercased() != nil
            && url.host?.lowercased() != nil
            && previous?.host?.lowercased() != url.host?.lowercased()
        if ["POST", "PATCH"].contains(method.uppercased()), body == nil,
           hostCoordinator?.wouldSwitchStore(tab: self, url: url) == true {
            loadingErrorPresentation = .resource("无法在切换连接时保留这次提交，请返回后重新提交。")
            loadingErrorAllowsProxyRetry = false
            return false
        }
        if url.scheme != "https" || (url.port != nil && url.port != 443) || url.host?.lowercased() != proxyLandingTarget {
            clearProxyLanding()
        }
        let routed = hostCoordinator?.dataStoreForMainFrame(tab: self, url: url)
        guard !rejectUnavailableLanding(url, store: routed) else { return false }
        let desired = routed ?? originalWebsiteDataStore
        guard hostChanged || desired !== configuration.websiteDataStore else { return true }
        if ["POST", "PATCH"].contains(method.uppercased()), body == nil, desired !== configuration.websiteDataStore {
            loadingErrorPresentation = .resource("无法在切换连接时保留这次提交，请返回后重新提交。")
            loadingErrorAllowsProxyRetry = false
            return false
        }
        rebindWebsiteDataStore(desired, host: routed == nil ? nil : url.host?.lowercased())
        return true
    }

    func commitPreservingMethod(_ request: URLRequest, continuesAttempt: Bool = false) {
        guard !isDisposed else { return }
        let method = request.httpMethod ?? "GET"
        let url = request.url ?? URL(string: "about:blank")!
        let unsafeReplay = BrowserMainFrameFailure.requestHasUnsafeReplaySurface(request)
        if !continuesAttempt {
            // Supersede deferred allows from an earlier load (commonly `aegis://start`
            // from `setActive`). Policy-adopted competing allows still stack via
            // `adoptMainFrameNavigation` → `beginUserNavigation` without this clear.
            loadGeneration = UUID()
            beginUserNavigation(url: url, method: method, hasReplayableBody: unsafeReplay)
        } else {
            attempt.url = url
            attempt.method = method
            attempt.hasReplayableBody = attempt.hasReplayableBody || unsafeReplay
            if let idx = unboundAttempts.lastIndex(where: { $0.navigationID == attempt.navigationID }) {
                unboundAttempts[idx] = attempt
            } else {
                // Recovery / continue loads still need a didStart pairing slot.
                unboundAttempts.append(attempt)
            }
        }
        deferredDocumentNavigationID = attempt.navigationID
        committedRequestMethod = method
        guard alignStore(for: url, previous: requestedURL, method: method, body: request.httpBody) else { return }
        requestedURL = url
        isLoading = true
        var outgoing = request
        outgoing.httpMethod = method
        preserveExplicitHTTP(outgoing.url)
        // A loopback page loaded before its web view is on screen never opens a
        // socket. Hold it until the view moves into a window.
        if loadedWebView?.window == nil, isLoopbackHTTP(outgoing.url) || needsWindowBeforeLoad {
            parkUntilWindow(outgoing)
            return
        }
        needsWindowBeforeLoad = false
        performLoad(outgoing)
    }

    /// Loopback HTTP has no public TLS name. `WKWebView` copies its configuration
    /// at creation, so this has to land on the tab configuration before that copy.
    private func preserveExplicitHTTP(_ url: URL?) {
        guard isLoopbackHTTP(url) else { return }
        configuration.defaultWebpagePreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
    }

    private func isLoopbackHTTP(_ url: URL?) -> Bool {
        guard url?.scheme?.lowercased() == "http" else { return false }
        return ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url?.host ?? "")
    }

    private func performLoad(_ request: URLRequest) {
        guard !isDisposed else { return }
        if attempt.recoveryOperationID != nil, request.url?.scheme?.lowercased() == "http" {
            configuration.defaultWebpagePreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
            loadedWebView?.configuration.defaultWebpagePreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        }
        issueDocumentLoad(request)
    }

    /// Content-rule reloads call `WKWebView.load` directly. Hold loopback the same way
    /// as the first load, so that request is not issued before the view has a window.
    /// The actual load is deferred one turn: `decidePolicy` and `didMoveToWindow`
    /// both drop a re-entrant `WKWebView.load`.
    private func issueDocumentLoad(_ request: URLRequest) {
        guard !isDisposed else { return }
        deferredDocumentNavigationID = attempt.navigationID
        preserveExplicitHTTP(request.url)
        if loadedWebView?.window == nil, isLoopbackHTTP(request.url) || needsWindowBeforeLoad {
            parkUntilWindow(request)
            return
        }
        needsWindowBeforeLoad = false
        let generation = loadGeneration
        let expectedNavigationID = attempt.navigationID
        let expectedRecoveryID = attempt.recoveryOperationID
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            guard generation == self.loadGeneration else {
                self.retireUnboundAttempt(navigationID: expectedNavigationID)
                return
            }
            guard self.attempt.navigationID == expectedNavigationID else {
                // Superseded by a newer allow — drop the abandoned identity from the queue.
                self.retireUnboundAttempt(navigationID: expectedNavigationID)
                return
            }
            if let expectedRecoveryID {
                guard self.attempt.recoveryOperationID == expectedRecoveryID else {
                    self.retireUnboundAttempt(navigationID: expectedNavigationID)
                    return
                }
            }
            if self.loadedWebView?.window == nil, self.isLoopbackHTTP(request.url) || self.needsWindowBeforeLoad {
                self.parkUntilWindow(request)
                return
            }
            self.deliverDocumentLoad(request)
        }
    }

    /// `didMoveToWindow` can run before the pending request is stored. One later
    /// turn covers that without retrying forever while the view stays off screen.
    private func parkUntilWindow(_ request: URLRequest) {
        pendingAttachedLoad = request
        needsWindowBeforeLoad = true
        guard !windowFlushScheduled else { return }
        windowFlushScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.windowFlushScheduled = false
            self.flushPendingAttachedLoad()
        }
    }

    private func deliverDocumentLoad(_ request: URLRequest) {
        // A nil-failure must not be replayed by a late deferred load of the same allow.
        // Recovery intentionally reuses that navigation ID; let that replay through.
        let replayingFailure = attempt.recoveryOperationID != nil
            && lastMainFrameFailure?.navigationID == attempt.navigationID
        guard isLoading, replayingFailure || lastMainFrameFailure?.navigationID != attempt.navigationID else {
            retireUnboundAttempt(navigationID: attempt.navigationID)
            return
        }
        if replayingFailure {
            lastMainFrameFailure = nil
        }
        let recorded = attempt
        deferredDocumentNavigationID = nil
        programmaticPolicyNavigationID = recorded.navigationID
        let navigation = webView.load(request)
        pendingNavigation = navigation
        if let navigation {
            // A synchronous policy acknowledgment can add request details before load returns.
            bindNavigation(navigation, to: attempt.navigationID == recorded.navigationID ? attempt : recorded)
            if ["http", "https"].contains(request.url?.scheme ?? ""), request.timeoutInterval > 0 {
                armProvisionalDeadline(for: navigation, seconds: request.timeoutInterval)
            }
        } else {
            retireUnboundAttempt(navigationID: recorded.navigationID)
        }
    }

    /// Some WebKit failures end the network load without delivering a terminal
    /// delegate callback. Bound the provisional phase of this exact request.
    private func armProvisionalDeadline(for navigation: WKNavigation, seconds: TimeInterval) {
        provisionalDeadline?.cancel()
        provisionalNavigation = navigation
        provisionalDeadlineExpired = false
        provisionalDeadline = Task { @MainActor [weak self, weak navigation] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled, let self, let navigation, navigation === provisionalNavigation else { return }
            provisionalDeadlineExpired = true
            failExpiredProvisionalNavigation(navigation)
        }
    }

    private func failExpiredProvisionalNavigation(_ navigation: WKNavigation) {
        guard provisionalDeadlineExpired, navigation === provisionalNavigation, navigation === pendingNavigation,
              isCurrent(navigation), isLoading, let view = loadedWebView else { return }
        provisionalDeadlineExpired = false
        view.stopLoading()
        webView(view, didFailProvisionalNavigation: navigation, withError: URLError(.timedOut))
    }

    private func flushPendingAttachedLoad() {
        guard loadedWebView?.window != nil, let request = pendingAttachedLoad else { return }
        let generation = loadGeneration
        pendingAttachedLoad = nil
        needsWindowBeforeLoad = false
        guard generation == loadGeneration else { return }
        performLoad(request)
    }

    public func load(_ request: URLRequest) {
        commitPreservingMethod(request)
    }

    /// Reloads the failed main-frame request without minting a new navigation identity.
    /// Returns false when this tab is no longer showing that failure.
    @discardableResult
    public func retryFailedNavigation(
        _ request: URLRequest,
        expectedNavigationID: String,
        recoveryOperationID: UUID
    ) -> Bool {
        guard !isDisposed, lastMainFrameFailure?.navigationID == expectedNavigationID else { return false }
        guard request.url != nil else { return false }
        let method = (request.httpMethod ?? "GET").uppercased()
        guard method == "GET" || method == "HEAD" else { return false }
        attempt.navigationID = expectedNavigationID
        attempt.method = method
        attempt.url = request.url ?? attempt.url
        attempt.failureID = lastMainFrameFailure?.failureID
        attempt.recoveryOperationID = recoveryOperationID
        loadingErrorPresentation = nil
        loadingErrorAllowsProxyRetry = false
        recoveryLoadCount += 1
        commitPreservingMethod(request, continuesAttempt: true)
        // The document load is deferred one turn, so pendingNavigation is still nil here.
        return isLoading
    }

    public func rebindWebsiteDataStore(_ store: WKWebsiteDataStore, host: String?) {
        guard !isDisposed else { return }
        if host == nil {
            clearProxyLanding()
        }
        guard store !== configuration.websiteDataStore else {
            boundHostName = host
            return
        }
        releaseWebView()
        needsWindowBeforeLoad = true
        if let configurationFactory {
            configuration = configurationFactory(store)
            installContentHooks()
        }
        boundHostName = host
    }

    func prepareForRestore(url: URL?, title: String? = nil, scrollOffset: Double? = nil) {
        self.url = url; requestedURL = url
        updateTitle(title, url: url)
        savedScrollOffset = CGPoint(x: 0, y: max(0, scrollOffset ?? 0))
        isSuspended = true
    }

    func setActive(_ value: Bool) {
        guard !isDisposed else { return }
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

    /// Terminal teardown is distinct from suspension. Keep the host binding
    /// until the old document has been replaced or the WebView is destroyed.
    /// A retained BrowserTab can only expose an inert, non-navigable placeholder.
    func dispose(completion: @escaping @MainActor () -> Void) {
        guard !isDisposed else { return }
        if isActive, !restoresScrollOffset, let view = loadedWebView {
            savedScrollOffset = view.scrollView.contentOffset
        }
        isDisposed = true
        onAccessContextClosed?()
        onAccessContextClosed = nil
        selectedAccessHost = nil
        stop()
        if let view = loadedWebView as? BrowserContentWebView {
            view.terminateDocument(completion: completion)
            releaseWebView(keepTerminalDelegate: true)
        } else {
            releaseWebView()
            completion()
        }
        hostCoordinator = nil
        onNavigation = nil
    }

    private func releaseWebView(keepTerminalDelegate: Bool = false) {
        provisionalDeadline?.cancel()
        userScripts?.navigated()
        inspectionEnabled = false
        navigationEpoch &+= 1
        structureTask?.cancel()
        loadGeneration = UUID(); loadTask?.cancel()
        if !keepTerminalDelegate { loadedWebView?.stopLoading() }
        if !keepTerminalDelegate { loadedWebView?.navigationDelegate = nil }
        loadedWebView?.uiDelegate = nil
        loadedWebView?.removeFromSuperview()
        titleObservation = nil
        loadedWebView = nil; pendingNavigation = nil
        isLoading = false; isSuspended = true
        canGoBack = false; canGoForward = false
    }

    public func load(_ url: URL) {
        load(url, preservingScroll: false)
    }

    private func load(_ url: URL, preservingScroll: Bool) {
        guard !isDisposed else { return }
        if !preservingScroll { savedScrollOffset = .zero }
        restoresScrollOffset = preservingScroll
        isSuspended = false
        if url != requestedURL { recentTerminations = [] }
        lastPolicyIntervention = nil
        protectionIncident = nil; protectionNoticePresentation = nil; fingerprintSignals = []
        structureTask?.cancel()
        if temporaryPermission?.url != url { temporaryPermission = nil }
        // 立即让旧页面授权失效，不等网络回调到来。
        navigationEpoch &+= 1
        loadTask?.cancel()
        loadGeneration = UUID()
        beginUserNavigation(url: url, method: "GET")
        deferredDocumentNavigationID = attempt.navigationID
        let decision = navigationDecision(url)
        if decision.kind == .blocked {
            blockNavigation(decision)
            lastPolicyIntervention = decision
            isLoading = false
            return
        }
        if preferences.values.phishingProtection, decision.phishingScore >= 55, !hasTemporaryPermission(url) {
            protectionNoticePresentation = .resource("此页面有登录风险信号，请核对网址和提交目的地。")
        }
        if decision.kind == .sanitized { lastPolicyIntervention = decision }
        let url = URL(string: decision.effectiveURL) ?? url
        let previous = requestedURL
        requestedURL = url
        attempt.url = url
        attempt.method = "GET"
        committedRequestMethod = "GET"
        guard alignStore(for: url, previous: previous, method: "GET", body: nil) else { return }
        // Store replacement releases the old WebView and changes loadGeneration.
        let generation = loadGeneration
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
                    issueDocumentLoad(URLRequest(url: url, timeoutInterval: 30))
                } catch {
                    guard generation == loadGeneration else { return }
                    isLoading = false
                    loadingErrorAllowsProxyRetry = false
                    loadingErrorPresentation = .resource("跟踪保护初始化失败，请重试。")
                }
            }
        } else {
            configureTrackingProtection(for: url)
            issueDocumentLoad(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30))
        }
    }

    /// Content rules are not ready on the first recovery load. Fetch them without minting a new navigation.
    private func scheduleRecoveryAfterRules(_ url: URL) {
        loadTask?.cancel()
        let generation = loadGeneration
        let operationID = attempt.recoveryOperationID
        let method = attempt.method
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let list = try await TrackingProtection.shared.ruleList()
                try Task.checkCancellation()
                guard generation == self.loadGeneration, self.attempt.recoveryOperationID == operationID else { return }
                self.contentRuleList = list
                for category in ["mining", "fingerprinting"] {
                    self.securityLists[category] = try await self.securityRuleStore.list(category: category)
                }
                try Task.checkCancellation()
                guard generation == self.loadGeneration, self.attempt.recoveryOperationID == operationID else { return }
                var request = URLRequest(url: url)
                request.httpMethod = method
                self.commitPreservingMethod(request, continuesAttempt: true)
            } catch {
                guard generation == self.loadGeneration, self.attempt.recoveryOperationID == operationID else { return }
                self.isLoading = false
                self.loadingErrorAllowsProxyRetry = false
                self.loadingErrorPresentation = .resource("跟踪保护初始化失败，请重试。")
            }
        }
    }

    public func goBack() {
        navigateHistory(to: webView.backForwardList.backItem)
    }

    public func goForward() {
        navigateHistory(to: webView.backForwardList.forwardItem)
    }

    private func navigateHistory(to item: WKBackForwardListItem?) {
        guard let item else { return }
        beginUserNavigation(url: item.url, method: "GET", hasReplayableBody: true, policyType: .backForward)
        loadTask?.cancel()
        navigationEpoch &+= 1
        lastPolicyIntervention = nil
        let navigationID = attempt.navigationID
        programmaticPolicyNavigationID = navigationID
        guard let navigation = webView.go(to: item) else {
            retireUnboundAttempt(navigationID: navigationID)
            if programmaticPolicyNavigationID == navigationID { programmaticPolicyNavigationID = nil }
            return
        }
        guard attempt.navigationID == navigationID else { return }
        pendingNavigation = navigation
        bindNavigation(navigation, to: attempt)
        isLoading = true
    }

    public func reload() {
        recentTerminations = []
        if let url = requestedURL ?? url { load(url) }
    }

    func prepareForReading() async throws {
        guard !isDisposed, protectionIncident == nil else { throw PageSnapshotError.unavailable }
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
        beginUserNavigation(url: requestedURL ?? url ?? URL(string: "about:blank")!, method: committedRequestMethod)
        // Stop retires every in-flight WKNavigation identity so a late failure
        // cannot reopen automatic proxy recovery for the cancelled load.
        retireAllNavigationIdentities()
        structureTask?.cancel()
        navigationEpoch &+= 1
        invalidateDeferredDocumentLoad()
        loadTask?.cancel()
        loadedWebView?.stopLoading()
        isLoading = false
        loadingErrorAllowsProxyRetry = false
        lastMainFrameFailure = nil
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
        // `targetFrame == nil` is a new window / `_blank`, not this tab's main frame.
        if navigationAction.targetFrame == nil {
            let decision = navigationDecision(requestURL, method: navigationAction.request.httpMethod ?? "GET")
            finish(decision.kind == .blocked ? .cancel : .allow)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == false {
            if requestURL.scheme == "http", attempt.recoveryOperationID != nil || requestedURL?.scheme == "http" {
                webPreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
            }
            let decision = navigationDecision(requestURL, method: navigationAction.request.httpMethod ?? "GET")
            finish(decision.kind == .blocked ? .cancel : .allow)
            return
        }
        if temporaryPermission?.url != requestURL { temporaryPermission = nil }
        let site = preferences.site(for: requestURL)
        activeHardenedSecurity = inheritedHardenedSecurity || (site.hardenedSecurity ?? preferences.values.hardenedSecurity ?? false)
        PageProtection.applySystem(webPreferences, hardened: activeHardenedSecurity)
        // 本机服务没有公网 HTTPS 身份；明确保留用户输入的本机 HTTP。
        // 失败页重放保持原来的 http，避免升级成 TLS 后隧道里不再是那次请求。
        if localOrInternal || (attempt.recoveryOperationID != nil && requestURL.scheme == "http") {
            webPreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        }
        webPreferences.preferredContentMode = (site.desktop ?? preferences.values.desktop) ? .desktop : .recommended
        webPreferences.allowsContentJavaScript = site.javaScript ?? preferences.values.javaScript
        let decision = navigationDecision(requestURL, method: navigationAction.request.httpMethod ?? "GET")
        // A blocked action never commits a navigation or changes registry membership.
        if decision.kind == .blocked {
            blockNavigation(decision)
            lastPolicyIntervention = decision
            pendingNavigation = nil
            isLoading = false
            finish(.cancel)
            return
        }
        let previousLanding = (proxyLandingParent, proxyLandingTarget)
        if decision.kind != .blocked, navigationAction.navigationType == .other,
           boundHostName != nil, let parent = proxyLandingParent ?? boundHostName, let target = requestURL.host?.lowercased(),
           requestedURL?.scheme == "https", requestURL.scheme == "https",
           requestURL.port == nil || requestURL.port == 443,
           (navigationAction.request.httpMethod ?? "GET") == "GET",
           !BrowserMainFrameFailure.requestHasUnsafeReplaySurface(navigationAction.request),
           RegisteredDomain.isCanonicalLandingHost(target, for: parent) {
            proxyLandingParent = parent
            proxyLandingTarget = target
        }
        let method = navigationAction.request.httpMethod ?? "GET"
        let body = navigationAction.request.httpBody
        let hostMismatch = requestedURL.map { $0.host?.lowercased() != requestURL.host?.lowercased() } ?? false
        if ["POST", "PATCH"].contains(method.uppercased()), body == nil,
           hostCoordinator?.wouldSwitchStore(tab: self, url: requestURL) == true {
            (proxyLandingParent, proxyLandingTarget) = previousLanding
            loadingErrorPresentation = .resource("无法在切换连接时保留这次提交，请返回后重新提交。")
            loadingErrorAllowsProxyRetry = false
            finish(.cancel)
            return
        }
        let routedStore = hostCoordinator?.dataStoreForMainFrame(tab: self, url: requestURL)
        if decision.kind != .blocked, rejectUnavailableLanding(requestURL, store: routedStore) {
            (proxyLandingParent, proxyLandingTarget) = previousLanding
            finish(.cancel)
            return
        }
        let storeMismatch = (routedStore ?? originalWebsiteDataStore) !== websiteDataStore
        if decision.kind != .blocked,
           navigationAction.targetFrame?.isMainFrame != false,
           storeMismatch || (hostMismatch && !["POST", "PATCH"].contains(method.uppercased())),
           realignedNavigationURL != requestURL {
            realignedNavigationURL = requestURL
            finish(.cancel)
            var request = navigationAction.request
            request.url = URL(string: decision.effectiveURL) ?? requestURL
            request.httpMethod = method
            request.httpBody = body
            commitPreservingMethod(request, continuesAttempt: attempt.recoveryOperationID != nil)
            return
        }
        if decision.kind != .blocked, ["http", "https"].contains(requestURL.scheme ?? ""), (contentRuleList == nil || securityLists.count < 2) {
            finish(.cancel)
            guard contentRulesNavigationURL != requestURL else { return }
            contentRulesNavigationURL = requestURL
            if attempt.recoveryOperationID != nil {
                scheduleRecoveryAfterRules(requestURL)
            } else {
                load(requestURL)
            }
            return
        }
        realignedNavigationURL = nil
        contentRulesNavigationURL = nil
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
            let method = navigationAction.request.httpMethod ?? "GET"
            // Server redirects update identity in `didReceiveServerRedirect`.
            // `.other` also covers script-driven jumps, which must mint a fresh attempt.
            let continuesExisting = Self.continuesExistingMainFrameNavigation(navigationAction)
            adoptMainFrameNavigation(
                url: requestURL,
                method: method,
                continuesExistingNavigation: continuesExisting,
                hasReplayableBody: BrowserMainFrameFailure.requestHasUnsafeReplaySurface(
                    navigationAction.request
                ),
                policyType: navigationAction.navigationType
            )
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
            let method = cleanedRequest.httpMethod ?? "GET"
            adoptMainFrameNavigation(
                url: cleanedURL,
                method: method,
                continuesExistingNavigation: false,
                hasReplayableBody: BrowserMainFrameFailure.requestHasUnsafeReplaySurface(
                    cleanedRequest
                )
            )
            finish(.cancel)
            issueDocumentLoad(cleanedRequest)
        }
    }

    /// Link / form / history / script / `.other` activations mint a distinct attempt.
    /// Confirmed HTTP redirects update the mapped identity in
    /// `didReceiveServerRedirectForProvisionalNavigation` instead.
    private static func continuesExistingMainFrameNavigation(
        _ action: WKNavigationAction
    ) -> Bool {
        switch action.navigationType {
        case .linkActivated, .formSubmitted, .backForward, .reload, .formResubmitted, .other:
            return false
        @unknown default:
            return false
        }
    }

    /// Unit tests cover the production classifier without synthesizing WKAction objects.
    public static func continuesExistingMainFrameNavigationTypeForTests(
        _ navigationType: WKNavigationType
    ) -> Bool {
        switch navigationType {
        case .linkActivated, .formSubmitted, .backForward, .reload, .formResubmitted, .other:
            return false
        @unknown default:
            return false
        }
    }

    public func webView(
        _ webView: WKWebView,
        didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
    ) {
        guard webView === loadedWebView, let navigation else { return }
        guard var recorded = attemptsByNavigation[ObjectIdentifier(navigation)] else { return }
        guard let redirected = webView.url else { return }
        recorded.url = redirected
        // This callback exposes a URL, not the redirected request or HTTP status.
        // 307/308 preserve methods. Retain the original method and replay restrictions
        // rather than inventing GET eligibility for an unsafe request.
        // WebKit may deliver the redirected request policy before this confirmation.
        // Fold its one matching unbound action back into this confirmed chain,
        // preserving the failure/recovery identity and all unsafe replay surfaces.
        let redirectedAllows = unboundAttempts.filter {
            recorded.acceptsRedirectPolicy($0.policyType) && $0.url == redirected
                && $0.allowSequence == recorded.allowSequence &+ 1 && isLatestAttempt($0)
        }
        if navigation === pendingNavigation, unboundAttempts.count == 1,
           let allowed = redirectedAllows.first {
            recorded.allowSequence = allowed.allowSequence
            if recorded.method != allowed.method { recorded.hasReplayableBody = true }
            recorded.hasReplayableBody = recorded.hasReplayableBody || allowed.hasReplayableBody
            retireUnboundAttempt(navigationID: allowed.navigationID)
            attempt = recorded
            confirmedRedirectPolicy = nil
        } else if isLatestAttempt(recorded) {
            // Otherwise the policy callback can supply the actual redirected method next.
            confirmedRedirectPolicy = (recorded.navigationID, redirected)
        }
        attemptsByNavigation[ObjectIdentifier(navigation)] = recorded
        if isLatestAttempt(recorded) {
            attempt = recorded
            requestedURL = redirected
            failExpiredProvisionalNavigation(navigation)
        }
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === loadedWebView else { return }
        if let navigation {
            let recorded: MainFrameAttempt
            if let existing = attemptsByNavigation[ObjectIdentifier(navigation)] {
                // Programmatic load already bound this navigation.
                recorded = existing
            } else if let next = dequeueUnboundAttempt() {
                recorded = next
                bindNavigation(navigation, to: recorded)
            } else {
                // No approved request owns this callback. Never borrow the newest identity.
                return
            }
            guard isLatestAttempt(recorded) else { return }
            attempt = recorded
            pendingNavigation = navigation
        }
        isLoading = true
        userScripts?.navigated()
        inspectionEnabled = false; webView.isInspectable = false
        navigationEpoch &+= 1
        structureTask?.cancel()
        refreshState()
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === loadedWebView, isCurrent(navigation) else { return }
        provisionalNavigation = nil
        provisionalDeadline?.cancel()
        confirmedRedirectPolicy = nil
        if let navigation, let recorded = attemptsByNavigation[ObjectIdentifier(navigation)] {
            let scheme = recorded.url.scheme?.lowercased() ?? ""
            if ["http", "https"].contains(scheme) {
                committedMainFrameURL = recorded.url
                url = recorded.url
                if attempt.recoveryOperationID != nil {
                    proxyRecoveryCommitted = true
                }
            }
        }
        // 新文档不继承前页的结构或接口提示；当前页面的检查会重新生成提示。
        protectionNoticePresentation = nil
        fingerprintSignals = []
        startStructureChecks(webView)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === loadedWebView else { return }
        guard isCurrent(navigation) else {
            retireNavigationIdentity(navigation)
            return
        }
        retireNavigationIdentity(navigation)
        retireUnboundAttempt(navigationID: attempt.navigationID)
        if deferredDocumentNavigationID == attempt.navigationID {
            invalidateDeferredDocumentLoad()
        }
        pendingNavigation = nil
        isLoading = false
        loadingErrorPresentation = nil
        loadingErrorAllowsProxyRetry = false
        lastMainFrameFailure = nil
        attempt.recoveryOperationID = nil
        attempt.failureID = nil
        attempt.hasReplayableBody = false
        refreshState()
        // History can restore a start document whose DOM predates the current
        // language; a newly loaded document may also finish after a selection.
        // Reuse the owned-document guards with the latest runtime snapshot.
        refreshLocalizedPresentation()
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
        guard webView === loadedWebView else { return }
        let nsError = error as NSError
        let recorded: MainFrameAttempt
        if let navigation {
            guard let match = attemptsByNavigation.removeValue(forKey: ObjectIdentifier(navigation)) else {
                // Unknown / retired callbacks cannot replace the current page or failure.
                return
            }
            if programmaticPolicyNavigationID == match.navigationID { programmaticPolicyNavigationID = nil }
            if confirmedRedirectPolicy?.navigationID == match.navigationID { confirmedRedirectPolicy = nil }
            guard isLatestAttempt(match) else {
                if navigation === pendingNavigation { pendingNavigation = nil }
                return
            }
            recorded = match
        } else if pendingNavigation == nil, isLoading {
            // A nil callback is only attributable when exactly one approved request
            // is outstanding. Suite order or the newest URL is not evidence of ownership.
            guard attemptsByNavigation.isEmpty, unboundAttempts.count == 1,
                  let unique = unboundAttempts.first, isLatestAttempt(unique) else {
                noteUnidentifiedMainFrameFailure(nsError, for: nil)
                return
            }
            recorded = unique
        } else {
            guard isLoading else { return }
            noteUnidentifiedMainFrameFailure(nsError, for: nil)
            return
        }
        pendingNavigation = nil
        isLoading = false
        invalidateDeferredDocumentLoad()
        retireUnboundAttempt(navigationID: recorded.navigationID)
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            loadingErrorAllowsProxyRetry = false
            refreshState()
            return
        }
        let method = recorded.method.uppercased()
        let failedURL = recorded.url
        let failureID = recorded.failureID
            ?? (lastMainFrameFailure?.navigationID == recorded.navigationID ? lastMainFrameFailure?.failureID : nil)
            ?? UUID()
        attempt.navigationID = recorded.navigationID
        attempt.url = failedURL
        attempt.method = method
        attempt.hasReplayableBody = recorded.hasReplayableBody
        attempt.failureID = failureID
        attempt.recoveryOperationID = recorded.recoveryOperationID
        let failure = BrowserMainFrameFailure(
            failureID: failureID,
            navigationID: recorded.navigationID,
            url: failedURL,
            method: method,
            hasReplayableBody: recorded.hasReplayableBody,
            recoveryOperationID: recorded.recoveryOperationID
        )
        lastMainFrameFailure = failure
        loadingErrorPresentation = .error(error)
        let scheme = failedURL.scheme?.lowercased() ?? ""
        loadingErrorAllowsProxyRetry = BrowserNavigationFailure.isRecoverableNetworkFailure(nsError)
            && ["http", "https"].contains(scheme)
            && (method == "GET" || method == "HEAD")
            && !recorded.hasReplayableBody
        hostCoordinator?.mainFrameFailed(tab: self, failure: failure, error: nsError)
        refreshState()
    }

    /// A callback for a different in-flight navigation is not a proxy-retry ticket.
    private func noteUnidentifiedMainFrameFailure(_ error: NSError, for navigation: WKNavigation?) {
        // Late A must not clear B's pending identity, loading bit, or recovery eligibility.
        if let pendingNavigation, navigation == nil || navigation !== pendingNavigation, isLoading {
            return
        }
        pendingNavigation = nil
        isLoading = false
        loadingErrorPresentation = .error(error)
        if lastMainFrameFailure?.navigationID == attempt.navigationID {
            refreshState()
            return
        }
        loadingErrorAllowsProxyRetry = false
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
        titlePresentation = .resource("已阻止风险页面")
        loadingErrorAllowsProxyRetry = false
        lastMainFrameFailure = nil
        hostCoordinator?.pendingRecoveryInvalidated(tab: self)
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
        var notice: AegisLocalizedMessage?
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
                notice = .resource("此页面有登录风险信号，请核对网址和提交目的地。")
            }
        }
        if let counts = try? await view.callAsyncJavaScript("return globalThis.__aegisProtectionCounts || {};", arguments: [:], in: nil, contentWorld: .page) as? [String: Int],
           view === loadedWebView, epoch == navigationEpoch, !Task.isCancelled {
            // 页面世界数据可伪造，只用于提示，不据此授权、封禁或调用原生操作。
            let observed = ["canvas", "webgl", "audio"].filter { (counts[$0] ?? 0) > 0 }
            if fingerprintSignals != observed { fingerprintSignals = observed }
            if (counts["worker"] ?? 0) > 0, (counts["wasm"] ?? 0) > 0 {
                notice = .resource("页面使用了 Worker 和 WASM；这些也是正常计算能力，尚不能据此判断挖矿。")
            }
        }
        guard view === loadedWebView, epoch == navigationEpoch, !Task.isCancelled else { return false }
        if protectionNotice != notice?.text { protectionNoticePresentation = notice }
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
            loadingErrorPresentation = .resource("页面连续停止运行，已暂停自动重载。请手动重试或关闭此标签。")
            return
        }
        isLoading = true
        pendingNavigation = webView.reload()
    }

    private func isCurrent(_ navigation: WKNavigation?) -> Bool {
        guard let navigation else {
            return pendingNavigation == nil && isLoading
                && unboundAttempts.count == 1
                && unboundAttempts.first.map(isLatestAttempt) == true
        }
        guard let recorded = attemptsByNavigation[ObjectIdentifier(navigation)] else { return false }
        return isLatestAttempt(recorded)
    }

    private func isLatestAttempt(_ recorded: MainFrameAttempt) -> Bool {
        recorded.navigationID == attempt.navigationID && recorded.allowSequence == attempt.allowSequence
    }

    private func updateTitle(_ title: String?, url: URL?) {
        if let title, !title.isEmpty { titlePresentation = .verbatim(title) }
        else if let host = url?.host { titlePresentation = .verbatim(host) }
        else { titlePresentation = .resource("新标签页") }
    }

    private var languageRevision = 0

    /// Presentation refresh never creates a resident WebView or navigates a page.
    func refreshLocalizedPresentation(snapshot: AegisLocalizationSnapshot = AegisLocalization.current) {
        objectWillChange.send()
        guard let view = loadedWebView else { return }
        guard view.url?.absoluteString == "aegis://start" else { return }
        languageRevision &+= 1
        let revision = languageRevision
        let epoch = navigationEpoch
        Task { @MainActor [weak self, weak view] in
            guard let self, let view,
                  let documentID = try? await view.callAsyncJavaScript(
                    FixtureSchemeHandler.documentIdentityScript,
                    arguments: ["expectedURL": "aegis://start"], in: nil, contentWorld: .defaultClient) as? String,
                  view === self.loadedWebView, view.url?.absoluteString == "aegis://start",
                  self.navigationEpoch == epoch, self.languageRevision == revision else { return }
            _ = try? await view.callAsyncJavaScript(FixtureSchemeHandler.refreshScript, arguments: [
                "expectedURL": "aegis://start", "documentID": documentID, "revision": revision,
                "labels": FixtureSchemeHandler.startPageText(snapshot: snapshot),
                "language": snapshot.family.rawValue,
            ], in: nil, contentWorld: .defaultClient)
        }
    }

    private func refreshState() {
        updateTitle(webView.title, url: webView.url)
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

    public static func openTabs() -> [BrowserTab] {
        // SwiftUI may retain a discarded window's session and ordinary snapshot.
        // Those tabs must no longer participate in live recovery or registry work.
        sessions.compactMap(\.value).filter { !$0.isWindowClosed }
            .flatMap { $0.standardTabs + $0.privateTabs }
    }
    @Published public private(set) var standardTabs: [BrowserTab] = []
    @Published public private(set) var privateTabs: [BrowserTab] = []
    /// Bumps when a private `WKWebsiteDataStore` is retired and waiting to be released.
    @Published public private(set) var retiredPrivateWebsiteDataStoreRevision: UInt64 = 0
    private var retiredPrivateWebsiteDataStores: [WKWebsiteDataStore] = []
    private var pendingPrivateTabClosures: [String: Int] = [:]
    private var endingPrivateSessions: [String: () -> Void] = [:]
    @Published public var activeTabID: UUID?
    @Published public var profile: BrowserProfile = .standard
    @Published public private(set) var extensionStatus = "WebExtension 正在初始化"
    @Published public private(set) var bookmarkIsActive = false
    @Published private var sessionErrorPresentation: AegisLocalizedMessage?
    public private(set) var sessionError: String? {
        get { sessionErrorPresentation?.text }
        set { sessionErrorPresentation = newValue.map(AegisLocalizedMessage.verbatim) }
    }
    public private(set) var pendingAccessDownload: BrowserAccessDownload?
    public func ownsAccessDownload(_ request: BrowserAccessDownload) -> Bool {
        guard pendingAccessDownload == request, let tab = activeTab, tab.id == request.tab,
              tab.profile.isPrivate == request.privateMode, tab.accessSelectionID == request.selectionID,
              tab.selectedAccessHost == request.host else { return false }
        return BrowserAccessDownload.canonicalHost(of: tab.url) == request.host
    }
    @Published public var pendingDownloadURL: URL? {
        didSet { if pendingDownloadURL == nil { pendingAccessDownload = nil } }
    }
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
    public private(set) var isWindowClosed = false
    private let windowStore: BrowserWindowStore?

    public let standardProfileID = UUID()
    public let privateProfileID = UUID()
    public private(set) var privateSessionID = UUID()
    public weak var hostCoordinator: BrowserHostStoreCoordinating? {
        didSet { (standardTabs + privateTabs).forEach { $0.hostCoordinator = hostCoordinator } }
    }
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
    public func refreshLocalizedPresentation() {
        refreshLocalizedPresentation(snapshot: AegisLocalization.current)
    }

    func refreshLocalizedPresentation(snapshot: AegisLocalizationSnapshot) {
        objectWillChange.send()
        // Rebuild command menus without disturbing the current first responder.
        UIMenuSystem.main.setNeedsRebuild()
        for tab in standardTabs + privateTabs { tab.refreshLocalizedPresentation(snapshot: snapshot) }
    }

    public var selectedGroupName: String { groups.first { $0.id == selectedGroupID }?.name ?? AegisLocalization.string("所有标签") }
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

    /// Ends this window's live bindings while retaining its ordinary snapshot.
    /// Call only for explicit closure or release of the root window owner.
    public func closeWindow() {
        guard !isWindowClosed else { return }
        persistSession()
        isWindowClosed = true
        disposeTabs(standardTabs + privateTabs, endingPrivateScopeID: privateSessionID.uuidString)
        // Do not switch profile: that would activate and reload a suspended
        // ordinary tab. A closed session is a restoration snapshot only.
        privateTabs = []; privateGroups = []; privateGroupID = nil
        privateSessionID = UUID()

        windowStore?.unregister(windowID)
    }

    public func discardPrivateSession() {
        let endingScope = privateSessionID.uuidString
        disposeTabs(privateTabs, endingPrivateScopeID: endingScope)
        privateTabs = []; privateGroups = []; privateGroupID = nil
        privateSessionID = UUID()
        if profile.isPrivate { switchProfile(to: .standard) }
    }

    /// Every terminal entry point shares the document-confirmed cleanup. A
    /// private scope also waits for tabs removed by earlier close calls.
    private func disposeTabs(_ tabs: [BrowserTab], endingPrivateScopeID: String? = nil) {
        let tabs = tabs.filter { !$0.isDisposed }
        let coordinator = hostCoordinator
        for tab in tabs where tab.profile.isPrivate {
            pendingPrivateTabClosures[tab.browsingScopeID, default: 0] += 1
        }
        if let scope = endingPrivateScopeID {
            endingPrivateSessions[scope] = { coordinator?.endPrivateSession(scopeID: scope) }
        }
        for tab in tabs {
            let store = tab.websiteDataStore
            tab.dispose { [self] in
                coordinator?.tabClosed(tab)
                if tab.profile.isPrivate {
                    retirePrivateWebsiteDataStore(store)
                    let scope = tab.browsingScopeID
                    pendingPrivateTabClosures[scope, default: 0] -= 1
                    finishPrivateSessionIfReady(scope)
                }
            }
        }
        if let scope = endingPrivateScopeID { finishPrivateSessionIfReady(scope) }
    }

    private func finishPrivateSessionIfReady(_ scope: String) {
        guard pendingPrivateTabClosures[scope, default: 0] == 0 else { return }
        pendingPrivateTabClosures[scope] = nil
        let finish = endingPrivateSessions.removeValue(forKey: scope)
        finish?()
    }

    /// Hands retired private data stores to the Access registry. Ordinary
    /// `WKWebsiteDataStore.default()` is never included.
    public func consumeRetiredPrivateWebsiteDataStores() -> [WKWebsiteDataStore] {
        let stores = retiredPrivateWebsiteDataStores
        retiredPrivateWebsiteDataStores = []
        return stores
    }

    private func retirePrivateWebsiteDataStore(_ dataStore: WKWebsiteDataStore) {
        retiredPrivateWebsiteDataStores.append(dataStore)
        retiredPrivateWebsiteDataStoreRevision &+= 1
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
        let closingPrivate = profile == .privateMode
        let endingScope = privateSessionID.uuidString
        guard let tab = visibleTabs.first(where: { $0.id == tabID }) else { return }
        disposeTabs([tab], endingPrivateScopeID: closingPrivate && privateTabs.count == 1 ? endingScope : nil)
        if profile == .standard {
            standardTabs.removeAll { $0.id == tabID }
            if standardTabs.isEmpty { standardTabs = [makeTab(profile: .standard)] }
        } else {
            privateTabs.removeAll { $0.id == tabID }
            if privateTabs.isEmpty {
                privateEnhancements = WebsiteEnhancementStore()
                privateSessionID = UUID()
                privateTabs = [makeTab(profile: .privateMode)]
            }
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
            session.standardTabs.forEach { $0.onAccessContextClosed?(); $0.stop() }
            session.standardGroups = []; session.standardGroupID = nil
            session.standardTabs = [session.makeTab(profile: .standard)]
            session.standardActiveID = session.standardTabs.first?.id
            if !session.profile.isPrivate { session.activeTabID = session.standardActiveID }
            session.persistSession(); session.refreshBookmarkState()
        }
        let stores = [WKWebsiteDataStore.default()] + (hostCoordinator?.ordinaryHostStores() ?? [])
        if let records {
            for store in stores {
                let hosted = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
                let names = Set(records.map(\.displayName))
                let matching = hosted.filter { names.contains($0.displayName) }
                await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching.isEmpty ? records : matching)
            }
        } else {
            for store in stores {
                await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            }
        }
    }

    public func persistSession() {
        // The final close snapshot is immutable. A retained old window must not
        // overwrite a new session restoring the same window ID.
        guard !isWindowClosed else { return }
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
                sessionErrorPresentation = .resource("尚未启用搜索引擎，请输入网址，或在浏览设置中恢复搜索引擎。")
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
        let runtime = profile.isPrivate ? privateRuntime : standardRuntime
        let initialStore: WKWebsiteDataStore = profile.isPrivate ? .nonPersistent() : .default()
        let factory: (WKWebsiteDataStore) -> WKWebViewConfiguration = { [preferences] store in
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = store
            configuration.userContentController = WKUserContentController()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = preferences.values.allowPopups
            configuration.mediaTypesRequiringUserActionForPlayback = preferences.values.requireMediaGesture ? .all : []
            configuration.setURLSchemeHandler(FixtureSchemeHandler(), forURLScheme: "aegis")
            runtime.apply(to: configuration)
            return configuration
        }
        let configuration = factory(initialStore)

        #if DEBUG
        let rules = ProcessInfo.processInfo.arguments.contains("--ui-testing-security") ? SecurityRuleStore(fixtureRules: true) : .shared
        #else
        let rules = SecurityRuleStore.shared
        #endif
        let tab = BrowserTab(id: id, profile: profile, configuration: configuration, preferences: preferences, securityRuleStore: rules,
                             enhancementStore: profile.isPrivate ? privateEnhancements : standardEnhancements)
        tab.configurationFactory = factory
        tab.hostCoordinator = hostCoordinator
        tab.browsingScopeID = profile.isPrivate ? privateSessionID.uuidString : "ordinary"
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
        tab.onDownload = { [weak self, weak tab] url in
            guard let self, let tab, self.profile == profile else { return }
            let pageHost = BrowserAccessDownload.canonicalHost(of: tab.url)
            let targetHost = BrowserAccessDownload.canonicalHost(of: url)
            self.pendingAccessDownload = nil
            if let host = tab.selectedAccessHost,
               (pageHost == nil || pageHost == host), (targetHost == nil || targetHost == host) {
                self.pendingAccessDownload = BrowserAccessDownload(selectionID: tab.accessSelectionID, tab: tab.id,
                    privateMode: profile.isPrivate, target: url, host: host)
            }
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
        guard !isWindowClosed else { return }
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
