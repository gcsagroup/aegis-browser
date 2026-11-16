import AgentKit
import BrowserKit
import SwiftUI
import UIKit

struct AegisRootView: View {
    @EnvironmentObject private var browser: BrowserSession
    @EnvironmentObject private var accountSession: AccessAccountSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var address = ""
    @StateObject private var presentation = BrowserPresentationCoordinator()
    @StateObject private var closeCommand = BrowserWindowCloseCommand()

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        let presented = presentation.current
        Group {
            if let tab = browser.activeTab {
                BrowserPane(
                    tab: tab,
                    address: $address,
                    presentation: presentation
                )
            } else {
                ContentUnavailableView {
                    Label("没有标签页", systemImage: "rectangle.stack")
                } actions: {
                    Button { _ = browser.newTab() } label: {
                        Label("新建标签页", systemImage: "plus")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("new-tab-button")
                    Button { presentation.request(.tabs) } label: {
                        Label("标签 \(browser.displayedTabs.count)", systemImage: "rectangle.stack")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }.buttonStyle(.bordered)
                        .accessibilityValue(browser.selectedGroupName)
                        .accessibilityIdentifier("tabs-button")
                }
                .focusedSceneValue(\.browserKeyboardActions, BrowserKeyboardActions.forWindow(browser, presentation: presentation))
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .background(BrowserWindowCloseAttachment(browser: browser, presentation: presentation, owner: closeCommand)
            .frame(width: 0, height: 0))
        .sheet(item: Binding(
            get: { presentation.isDismissing || presented?.route.isAlert == true ? nil : presented },
            set: { if $0 == nil, let presented { presentation.dismiss(presented.id) } }
        ), onDismiss: {
            if let presented {
                if case let .downloads(_, access) = presented.route { browser.releasePresentedAccessDownload(access) }
                presentation.didDismiss(presented.id)
            }
        }) { request in
            presentationContent(request.route).onAppear { presentation.didPresent(request.id) }
        }
#if DEBUG
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--ui-testing"), arguments.contains("--ui-testing-settings") {
                presentation.request(.settings)
            }
        }
#endif
        .onReceive(browser.markdownRequests) { event in
            guard let document = browser.consumePendingMarkdown(documentID: event.id) else { return }
            presentation.request(.markdown(document))
        }
        .onReceive(browser.downloadRequests) { event in
            guard let download = browser.consumePendingDownload(eventID: event.id) else { return }
            presentation.request(.downloads(download.url, download.access))
        }
        .onChange(of: browser.activeTabID) { _, _ in
            updateAddress()
            presentation.invalidate { if case .find = $0 { true } else { false } }
        }
        .onChange(of: browser.isWindowClosed) { _, closed in
            if closed { presentation.closeWindow() }
        }
        .onChange(of: browser.profile) { _, _ in
            updateAddress()
            presentation.invalidate { $0.isProfileBound }
            browser.pendingDownloadURL = nil
        }
        .onOpenURL { input in
            if input.isFileURL, MarkdownDocument.accepts(input) {
                if let document = try? MarkdownDocument.read(input) { presentation.request(.markdown(document)) }
                return
            }
            guard let url = ExternalPageLink.destination(input) else { return }
            presentation.request(.external(url))
        }
        .background(BrowserRouteAlert(request: presented, isDismissing: presentation.isDismissing,
                                      makeAlert: makeAlert, onDismiss: { id in
            presentation.dismiss(id)
            presentation.didDismiss(id)
        }).frame(width: 0, height: 0))
        .onAppear {
            updateAddress()
            consumeSharedURLIfPresent()
            while let document = browser.consumePendingMarkdown() { presentation.request(.markdown(document)) }
            while let download = browser.consumePendingDownload() { presentation.request(.downloads(download.url, download.access)) }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active, !browser.profile.isPrivate else { return }
            let protection = TrackingProtection.shared
            _ = try? await protection.ruleList()
            if browser.preferences.claimFilterUpdate(lastSuccess: protection.updatedAt) {
                await protection.update()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                browser.persistSession()
                presentation.invalidate { $0.isDocumentBound }
                return
            }
            consumeSharedURLIfPresent()
        }
    }

    private func makeAlert(_ request: BrowserPresentationCoordinator.Request, finished: @escaping @MainActor () -> Void) -> UIAlertController {
        presentation.didPresent(request.id)
        let title: String
        let message: String
        switch request.route {
        case let .external(url):
            title = AegisLocalization.string("在普通浏览中打开分享页面？")
            message = url.absoluteString
        case let .privateBookmark(_, url, _):
            title = AegisLocalization.string("修改已保存的收藏？")
            message = AegisLocalization.string("此操作会在普通收藏中添加或移除下面的网址，退出私密浏览后仍然保留。") + "\n\n" + url.absoluteString
        case let .windowError(error):
            title = AegisLocalization.string("无法新建窗口"); message = error.text
        default: return UIAlertController()
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        switch request.route {
        case let .external(url):
            alert.addAction(UIAlertAction(title: AegisLocalization.string("用普通标签打开"), style: .default) { _ in
                presentation.dismiss(request.id)
                browser.switchProfile(to: .standard)
                browser.newTab().load(url)
                finished()
            })
        case let .privateBookmark(id, url, epoch):
            alert.addAction(UIAlertAction(title: AegisLocalization.string("确认修改"), style: .default) { _ in
                if browser.profile.isPrivate, let tab = browser.activeTab,
                   tab.id == id, tab.url == url, tab.navigationEpoch == epoch { browser.toggleBookmark(privateSaveConfirmed: true) }
                presentation.dismiss(request.id); finished()
            })
        case .windowError:
            alert.addAction(UIAlertAction(title: AegisLocalization.string("完成"), style: .default) { _ in
                presentation.dismiss(request.id); finished()
            })
        default: break
        }
        if case .windowError = request.route { return alert }
        alert.addAction(UIAlertAction(title: AegisLocalization.string("取消"), style: .cancel) { _ in
            presentation.dismiss(request.id); finished()
        })
        return alert
    }

    @ViewBuilder private func presentationContent(_ route: BrowserPresentationCoordinator.Route) -> some View {
        switch route {
        case .tabs: TabSwitcher()
        case .assistant: PageAssistantView().presentationDetents([.large]).presentationDragIndicator(.visible)
        case .library: BrowserLibraryView(dataStore: browser.dataStore, workspaces: browser.workspaceStore)
        case .settings: BrowserSettingsView()
        case .website: CurrentWebsiteView().environmentObject(accountSession)
        case let .downloads(url, access): DownloadsView(initialURL: url, protectedContext: access)
        case let .find(id, instance):
            if let tab = browser.activeTab, tab.id == id, tab.instanceID == instance { FindInPageView(tab: tab).id(tab.instanceID) }
        case .reading: ReadingLibraryView()
        case let .markdown(document): MarkdownReaderView(initial: document)
        case .windows: BrowserWindowsView()
        case .external, .privateBookmark, .windowError: EmptyView()
        }
    }

    private func updateAddress() {
        address = browser.activeTab?.addressBarURL?.absoluteString ?? "aegis://start"
    }

    private func consumeSharedURLIfPresent() {
        if let inbox = try? MarkdownShareInbox(), let value = try? inbox.consume() {
            presentation.request(.markdown(MarkdownDocument(title: value.title, text: value.text)))
            return
        }
        guard let inbox = try? ShareInbox(),
              let envelope = try? inbox.consume()
        else { return }
        presentation.request(.external(envelope.url))
    }
}

private struct BrowserPane: View {
    @EnvironmentObject private var hostStores: AccessHostStoreCoordinator
    @EnvironmentObject private var browser: BrowserSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var tab: BrowserTab
    @State private var toolbarCollapsed = false
    @Binding var address: String
    @ObservedObject var presentation: BrowserPresentationCoordinator
    @State private var addressFocused = false
    @State private var addressSelectionRequest = 0

    private var toolbarAtTop: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }
    private var canCollapse: Bool {
        !toolbarAtTop && !addressFocused && !dynamicTypeSize.isAccessibilitySize && !voiceOverEnabled
    }
    private var isCollapsed: Bool { toolbarCollapsed && canCollapse }

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 0) {
            if let error = browser.sessionError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
            ActiveTabView(tab: tab, address: $address, addressIsEditing: addressFocused,
                          onFind: { keyboardActions?.find() }, onScroll: updateToolbar)
                .id(tab.id)
        }
        .safeAreaInset(edge: toolbarAtTop ? .top : .bottom, spacing: 0) { toolbar }
        .background(Color(uiColor: .systemBackground))
        .focusedSceneValue(\.browserKeyboardActions, keyboardActions)
        .onChange(of: tab.id) { _, _ in toolbarCollapsed = false; addressFocused = false }
        .onChange(of: tab.navigationEpoch) { _, _ in toolbarCollapsed = false }

    }

    private func updateToolbar(_ collapsed: Bool) {
        guard canCollapse, toolbarCollapsed != collapsed else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { toolbarCollapsed = collapsed }
    }

    private func editAddress() {
        guard let current = browser.activeTab, !current.isDisposed else { return }
        toolbarCollapsed = false
        address = current.addressBarURL?.absoluteString ?? address
        addressFocused = true
        addressSelectionRequest += 1
    }

    private var keyboardActions: BrowserKeyboardActions? {
        BrowserKeyboardActions.forWindow(browser, presentation: presentation, editAddress: editAddress)

    }

    /// 浏览时只显示主机名；输入和辅助功能始终可取得完整网址。
    private var displayedAddress: String {
        guard let url = tab.addressBarURL, url.scheme != "aegis" else { return AegisLocalization.string("起始页") }
        guard let host = url.host(percentEncoded: true) else { return url.absoluteString }
        if AccessLocalSite.classify(host) == .loopback {
            return AccessSiteDisplayName.title(host)
        }
        return host
    }

    private var filterStatus: String {
        if !TrackingProtection.enabled { return AegisLocalization.string("广告过滤已关闭") }
        if let url = tab.url, TrackingProtection.isExcepted(url) { return AegisLocalization.string("此网站已暂停过滤") }
        return AegisLocalization.string("广告过滤已启用")
    }

    @ViewBuilder
    private var locationPrivacyButton: some View {
        let snapshot = hostStores.snapshot(for: tab, forLocationControl: true)
        if let host = snapshot.host {
            Button {
                hostStores.setSiteProxyEnabled(!snapshot.toggleOn, for: tab, displayedHost: host, forLocationControl: true)
            } label: {
                Image(systemName: snapshot.toggleOn ? "location.slash.fill" : "location")
                    .foregroundStyle(snapshot.toggleOn && snapshot.attachment == .ready ? Color.accentColor : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("隐藏地理位置")
            .accessibilityValue(Text(LocalizedStringKey(AccessSiteProxyToggleModel.connectionLine(for: snapshot.connectionStatus))))
            .accessibilityAddTraits(snapshot.toggleOn ? .isSelected : [])
            .accessibilityIdentifier("address-location-privacy")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if isCollapsed { Spacer(minLength: 0) }
            if !isCollapsed && !addressFocused {
                Button { tab.goBack() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .disabled(!tab.canGoBack)
                    .accessibilityLabel("后退")
                    .background(.regularMaterial, in: Circle())
            }
            HStack(spacing: 0) {
                if !isCollapsed && !addressFocused {
                    Button { presentation.request(.website) } label: {
                        Image(systemName: browser.profile.isPrivate ? "eye.slash.fill" : "shield.lefthalf.filled")
                            .foregroundStyle(browser.profile.isPrivate ? Color.purple : Color.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("当前网站")
                    .accessibilityValue(browser.profile.isPrivate ? AegisLocalization.string("私密浏览：不记录历史，保存和发送资料前需确认") : filterStatus)
                    .accessibilityIdentifier("page-protection")
                }
                BrowserAddressField(address: $address, focused: $addressFocused,
                                    displayText: displayedAddress, displayAddress: tab.addressBarURL?.absoluteString,
                                    selectionRequest: addressSelectionRequest) { destination in
                    browser.navigate(address: destination)
                    browser.activeTab?.webView.becomeFirstResponder()
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, addressFocused || isCollapsed ? 14 : 0)
                .onChange(of: addressFocused) { _, focused in
                    if focused { toolbarCollapsed = false }
                }
                if !addressFocused { locationPrivacyButton }
                if !isCollapsed && !addressFocused {
                    Button {
                        if tab.isLoading { tab.stop() } else { tab.reload() }
                    } label: {
                        Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(tab.isLoading ? "停止加载" : "刷新")
                }
            }
            .frame(maxWidth: isCollapsed ? 240 : .infinity, minHeight: 44)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(browser.profile.isPrivate ? Color.purple.opacity(0.35) : Color.primary.opacity(0.08), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
            if addressFocused {
                Button("取消") {
                    address = tab.addressBarURL?.absoluteString ?? "aegis://start"
                    addressFocused = false
                    tab.webView.becomeFirstResponder()
                }.frame(minWidth: 44, minHeight: 44)
            } else {
                Button { presentation.request(.tabs) } label: {
                    ZStack {
                        Image(systemName: "square.on.square")
                        Text(browser.displayedTabs.count.formatted())
                            .font(.caption2.bold()).padding(2)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                    }.frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text("标签 \(browser.displayedTabs.count)"))
                .accessibilityIdentifier("tabs-button")
                moreMenu
            }
            if isCollapsed { Spacer(minLength: 0) }
        }
        .font(.system(size: 18, weight: .regular))
        .tint(browser.profile.isPrivate ? .purple : .primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: toolbarAtTop ? 1100 : .infinity)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemBackground).opacity(0.94))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isCollapsed ? "browser-toolbar-collapsed" : "browser-toolbar-expanded")
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button("新建标签页", systemImage: "plus") { _ = browser.newTab() }
                    .accessibilityIdentifier("new-tab-button")
                Menu {
                    ForEach(BrowserProfile.allCases) { profile in
                        Button { browser.switchProfile(to: profile) } label: {
                            Label(profile.title, systemImage: profile.isPrivate ? "eye.slash" : "person.crop.circle")
                        }
                    }
                } label: {
                    Label(browser.profile.title, systemImage: browser.profile.isPrivate ? "eye.slash" : "person.crop.circle")
                }.accessibilityIdentifier("profile-menu")
            }
            Section {
                Button("资料", systemImage: "books.vertical") { presentation.request(.library) }
                    .accessibilityIdentifier("data-button")
                Button("AI 助手", systemImage: "sparkles") { presentation.request(.assistant) }
                    .disabled(!browser.agentIsAvailable)
                    .accessibilityIdentifier("agent-button")
                Button("下载", systemImage: "arrow.down.circle") { presentation.request(.downloads(nil, nil)) }.accessibilityIdentifier("downloads-button")
                Button("阅读库", systemImage: "text.book.closed") { presentation.request(.reading) }
                    .accessibilityIdentifier("reading-library-button")
            }
            Menu {
                Button(browser.bookmarkIsActive ? "移除收藏" : "添加收藏", systemImage: browser.bookmarkIsActive ? "star.fill" : "star") {
                    if browser.profile.isPrivate, let url = tab.url {
                        presentation.request(.privateBookmark(tab.id, url, tab.navigationEpoch))
                    } else { browser.toggleBookmark() }
                }.accessibilityIdentifier("toggle-bookmark")
                Button("前进", systemImage: "chevron.right") { tab.goForward() }.disabled(!tab.canGoForward)
                Button("编辑网址", systemImage: "text.cursor", action: editAddress)
                Button("打开主页", systemImage: "house") { tab.load(browser.preferences.homeURL) }
                if tab.securityResourcesTemporarilyAllowed {
                    Button("恢复安全资源拦截", systemImage: "shield.fill") { tab.restoreSecurityResourceProtection() }
                } else if tab.url?.host != nil {
                    Button("临时允许本站安全资源（10 分钟）", systemImage: "shield.slash") { tab.temporarilyRestoreSecurityResources() }
                }
                Button("在页面中查找", systemImage: "doc.text.magnifyingglass") { presentation.request(.find(tab.id, tab.instanceID)) }
                    .accessibilityIdentifier("find-in-page")
                if let url = tab.url, ["http", "https"].contains(url.scheme ?? "") {
                    ShareLink(item: url) { Label("分享页面", systemImage: "square.and.arrow.up") }
                }
                Button("打印或保存 PDF", systemImage: "printer") {
                    let controller = UIPrintInteractionController.shared
                    controller.printFormatter = tab.webView.viewPrintFormatter()
                    controller.present(animated: true)
                }
                Button("关闭当前标签", systemImage: "xmark") { browser.close(tab.id) }
            } label: { Label("页面操作", systemImage: "doc.text") }
                .accessibilityIdentifier("page-actions")
            Section {
                BrowserWindowActions(managesWindows: Binding(get: { false }, set: { if $0 { presentation.request(.windows) } }), error: Binding(get: { nil }, set: { if let error = $0 { presentation.request(.windowError(error)) } }))
                Button("设置", systemImage: "gearshape") { presentation.request(.settings) }
                    .accessibilityIdentifier("open-browser-settings")
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel("更多")
        .accessibilityValue(AegisLocalization.string("标签 \(browser.displayedTabs.count)"))
        .accessibilityIdentifier("browser-more")
    }
}

struct ProxyRetryButton: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    var title: String
    var action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.isEnabled = isEnabled
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
        button.accessibilityIdentifier = "page-load-proxy-retry"
        var configuration = UIButton.Configuration.tinted()
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        button.configuration = configuration
        button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { [weak coordinator = context.coordinator] _ in coordinator?.action() }, for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.setTitle(title, for: .normal)
        button.isEnabled = isEnabled
        context.coordinator.action = action
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.intrinsicContentSize.width
        let content = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(44, content.height))
    }

    final class Coordinator {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
    }
}

struct PageLoadFailureBanner: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var tab: BrowserTab
    var locationPrivacyOn = false
    var offersLocationService = true
    var autoRecoveryOn: Bool = false
    var autoRecoveryLine: String? = nil
    var setAutoRecovery: ((BrowserTab, Bool) -> Void)? = nil
    var addressProxyPreparing = false
    var openAddressViaProxy: ((BrowserTab, BrowserPendingAddressNavigation) -> Void)? = nil
    var proxyRetry: (BrowserTab) -> Void

    var body: some View {
        let _ = localizationLocale
        if let error = tab.loadingError {
            VStack(alignment: .leading, spacing: 8) {
                if let failure = tab.lastMainFrameFailure {
                    Text(verbatim: AccessSiteDisplayName.title(failure.url.host(percentEncoded: true)))
                        .font(.callout.weight(.semibold))
                        .accessibilityIdentifier("page-load-failed-host")
                }
                Label("页面暂时无法打开", systemImage: "exclamationmark.circle")
                    .font(.headline)
                if tab.loadingErrorAllowsProxyRetry && (locationPrivacyOn || offersLocationService) {
                    ProxyRetryButton(title: AegisLocalization.string(locationPrivacyOn ? "重试" : "隐藏位置并重试")) { proxyRetry(tab) }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                if !locationPrivacyOn || !tab.loadingErrorAllowsProxyRetry {
                    Button("重试") { tab.reload() }.frame(minHeight: 44)
                }
                if let autoRecoveryLine {
                    Text(LocalizedStringKey(autoRecoveryLine))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("page-load-auto-recovery-status")
                }
                DisclosureGroup("错误详情") {
                    if let host = tab.lastMainFrameFailure?.url.host,
                       AccessSiteDisplayName.localLabel(for: host) != nil {
                        Text("请检查本地服务是否可用。").font(.caption)
                    } else {
                        Text("页面加载失败：\(error)").font(.caption).textSelection(.enabled)
                    }
                    if setAutoRecovery != nil {
                        Toggle(LocalizedStringKey(AccessAutoRecoveryCopy.toggleTitle), isOn: Binding(
                            get: { autoRecoveryOn },
                            set: { setAutoRecovery?(tab, $0) }
                        ))
                        .accessibilityIdentifier("page-load-auto-recovery")
                        Text(LocalizedStringKey(AccessAutoRecoveryCopy.explanation)).font(.caption)
                        Text(LocalizedStringKey(AccessAutoRecoveryCopy.scopeWarning)).font(.caption)
                    }
                }

            }
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("page-load-error")
        } else if (offersLocationService || addressProxyPreparing), let pending = tab.pendingAddressNavigation,
                  tab.matchesPendingAddressNavigation(pending),
                  let openAddressViaProxy {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: AccessSiteDisplayName.title(pending.url.host(percentEncoded: true)))
                    .font(.callout.weight(.semibold))
                    .accessibilityIdentifier("page-load-pending-host")
                Text(AegisLocalization.string(addressProxyPreparing ? "正在准备连接…" : "正在连接…"))
                    .font(.caption)
                    .accessibilityIdentifier("page-load-pending-status")
                if !addressProxyPreparing {
                    ProxyRetryButton(title: AegisLocalization.string("隐藏位置并打开")) { openAddressViaProxy(tab, pending) }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
            .padding(12)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("page-load-pending-proxy")
        }
    }
}

private struct ActiveTabView: View {
    @ObservedObject var tab: BrowserTab
    @Binding var address: String
    let addressIsEditing: Bool
    let onFind: () -> Void
    let onScroll: (Bool) -> Void
    @EnvironmentObject private var hostStores: AccessHostStoreCoordinator

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 0) {
            PageLoadFailureBanner(
                tab: tab,
                locationPrivacyOn: hostStores.snapshot(for: tab, forLocationControl: true).toggleOn,
                offersLocationService: hostStores.offersLocationService,
                autoRecoveryOn: hostStores.snapshot(for: tab).autoRecoveryEnabled,
                autoRecoveryLine: hostStores.snapshot(for: tab).autoRecoveryLine,
                setAutoRecovery: { failed, enabled in
                    _ = hostStores.setAutoRecoveryEnabled(enabled, for: failed)
                },
                addressProxyPreparing: hostStores.isPreparingAddressProxy(tab: tab),
                openAddressViaProxy: { pendingTab, pending in
                    _ = hostStores.openPendingAddressViaProxy(tab: pendingTab, pending: pending)
                },
                proxyRetry: { failed in
                    _ = hostStores.retryViaProxy(tab: failed)
                }
            )
            if let decision = tab.lastPolicyIntervention {
                NavigationPolicyBanner(decision: decision) {
                    tab.dismissPolicyIntervention()
                }
            }
            if let incident = tab.protectionIncident {
                ScrollView {
                  VStack(alignment: .leading, spacing: 18) {
                    Label("已阻止风险页面", systemImage: "exclamationmark.shield.fill").font(.title2.bold()).accessibilityIdentifier("page-protection-blocked")
                    Text(incident.url.host ?? "").font(.headline).textSelection(.enabled)
                    Text(incident.fromPage ? AegisLocalization.string("页面结构检查发现高风险，已卸载该页面。检查发生在页面开始加载之后。") : AegisLocalization.string("本地网址检查已阻止此次导航。"))
                    Text(incident.reasons.contains("known_phishing_host") ? AegisLocalization.string("命中本地已知钓鱼主机规则。") : AegisLocalization.string("网址或登录表单包含多项风险信号。"))
                    ForEach(incident.explanations, id: \.self) { Text($0).font(.callout) }
                    Text("评分：\(incident.score)").font(.caption)
                    Button("返回起始页") { tab.load(URL(string: "aegis://start")!) }.buttonStyle(.borderedProminent)
                    Button("仍然访问此网址（10 分钟）") { tab.continueProtectedPageOnce() }
                        .accessibilityIdentifier("protection-continue-once")
                    Text("临时允许仅限当前标签和此完整网址，切换网址即失效；不会关闭挖矿与指纹资源规则。")
                        .font(.footnote).foregroundStyle(.secondary)
                  }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
            } else {
                if let notice = tab.protectionNotice { Text(notice).font(.caption).padding(8).accessibilityIdentifier("page-protection-notice") }
                if tab.fingerprintSignals.count >= 2 {
                    Text("观察到多种指纹读取接口；正常绘图与音频也可能使用这些接口。")
                        .font(.caption).padding(8).accessibilityIdentifier("fingerprint-observation")
                }
                BrowserWebView(webView: tab.webView, onFind: onFind, onScroll: onScroll)
                    .id("\(tab.webViewGeneration)-\(ObjectIdentifier(tab.webView))")
                    .accessibilityIdentifier("browser-webview")
            }
        }
        .onChange(of: tab.addressBarURL) { _, url in
            if !addressIsEditing, let url { address = url.absoluteString }
        }
    }
}

private struct NavigationPolicyBanner: View {
    let decision: BrowserNavigationPolicyDecision
    let dismiss: () -> Void

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: decision.kind == .blocked ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
            VStack(alignment: .leading, spacing: 3) {
                Text(decision.kind == .blocked ? blockedTitle : AegisLocalization.string("已清理追踪参数"))
                    .font(.callout.weight(.semibold))
                    .accessibilityIdentifier(
                        decision.kind == .blocked
                            ? "navigation-policy-blocked"
                            : "navigation-policy-sanitized"
                    )
                if decision.kind == .blocked {
                    Text(blockedDetail)
                } else {
                    Text("已移除：\(decision.removedQueryParameters.joined(separator: "、"))")
                }
            }
            .font(.caption)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("关闭策略提示")
        }
        .foregroundStyle(decision.kind == .blocked ? Color.red : Color.green)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            (decision.kind == .blocked ? Color.red : Color.green).opacity(0.10)
        )
    }

    private var blockedTitle: String {
        if decision.reasonCodes.contains("unsupported_top_level_scheme") {
            return AegisLocalization.string("已阻止不受支持的链接")
        }
        if decision.reasonCodes.contains("unsafe_sanitization_method")
            || decision.reasonCodes.contains("invalid_sanitized_target") {
            return AegisLocalization.string("已阻止无法安全清理的请求")
        }
        if decision.reasonCodes.contains("credentialed_url") {
            return AegisLocalization.string("已阻止含凭据的 URL")
        }
        return AegisLocalization.string("已阻止高风险导航")
    }

    private var blockedDetail: String {
        if decision.reasonCodes.contains("unsupported_top_level_scheme") {
            return AegisLocalization.string("仅允许 HTTP(S) 与 Aegis 内部页面 · 请求未加载")
        }
        if decision.reasonCodes.contains("unsafe_sanitization_method")
            || decision.reasonCodes.contains("invalid_sanitized_target") {
            return AegisLocalization.string("非 GET/HEAD 请求含追踪参数 · 请求未发送")
        }
        if decision.reasonCodes.contains("credentialed_url") {
            return AegisLocalization.string("URL 中包含 user/password · 请求未加载")
        }
        return AegisLocalization.string("本地钓鱼评分 \(decision.phishingScore) · 请求未加载")
    }
}

struct TabRow: View {
    @ObservedObject var tab: BrowserTab
    let isActive: Bool
    let action: () -> Void

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        Button(action: action) {
            HStack {
                Image(systemName: tab.profile.isPrivate ? "eye.slash" : "globe")
                VStack(alignment: .leading) {
                    Text(tab.title).lineLimit(2)
                    Text(tab.url?.host ?? AegisLocalization.string("起始页")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if tab.isSuspended { Text("已休眠，切换时加载").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .padding(10)
            .background(isActive ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
