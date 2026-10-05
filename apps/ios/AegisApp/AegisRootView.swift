import AgentKit
import BrowserKit
import SwiftUI

struct AegisRootView: View {
    @EnvironmentObject private var browser: BrowserSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var externalURL: URL?
    @State private var showsExternalConfirmation = false
    @State private var address = ""
    @State private var showsTabs = false
    @State private var showsAgent = false
    @State private var showsData = false
    @State private var showsSettings = false
    @State private var showsFilters = false
    @State private var showsDownloads = false
    @State private var showsFind = false
    @State private var findText = ""
    @State private var findMessage = ""

    var body: some View {
        Group {
            if let tab = browser.activeTab {
                BrowserPane(
                    tab: tab,
                    address: $address,
                    showsTabs: $showsTabs,
                    showsAgent: $showsAgent,
                    showsData: $showsData,
                    showsSettings: $showsSettings,
                    showsFilters: $showsFilters,
                    showsDownloads: $showsDownloads,
                    showsFind: $showsFind
                )
            } else {
                ContentUnavailableView("没有标签页", systemImage: "rectangle.stack")
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(isPresented: $showsTabs) { TabSwitcher() }
        .sheet(isPresented: $showsAgent) {
            PageAssistantView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsData) { BrowserLibraryView(dataStore: browser.dataStore, workspaces: browser.workspaceStore) }
        .sheet(isPresented: $showsSettings) { BrowserSettingsView() }
        .sheet(isPresented: $showsFilters) {
            NavigationStack {
                ContentFilterSettingsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsFilters = false } } }
            }
        }
        .sheet(isPresented: $showsDownloads, onDismiss: { browser.pendingDownloadURL = nil }) {
            DownloadsView(initialURL: browser.pendingDownloadURL)
        }
        .sheet(isPresented: $showsFind) {
            NavigationStack {
                Form {
                    FindQueryField(text: $findText)
                    Button("查找下一个") {
                        Task { @MainActor in
                            do {
                                let result = try await browser.activeTab?.webView.find(findText, configuration: .init())
                                findMessage = result?.matchFound == true ? "已找到匹配内容。" : "未找到匹配内容。"
                            } catch { findMessage = error.localizedDescription }
                        }
                    }.disabled(findText.isEmpty)
                    Text(findMessage)
                }.navigationTitle("在页面中查找")
                    .toolbar { Button("完成") { showsFind = false }.keyboardShortcut(.escape, modifiers: []) }
            }.presentationDetents([.medium])
        }
        .onChange(of: browser.pendingDownloadURL) { _, url in if url != nil { showsDownloads = true } }
        .onChange(of: browser.activeTabID) { _, _ in updateAddress() }
        .onChange(of: browser.profile) { _, profile in
            updateAddress()
            showsAgent = false
            showsData = false
            showsDownloads = false
            browser.pendingDownloadURL = nil
        }
        .onOpenURL { input in
            guard let url = ExternalPageLink.destination(input) else { return }
            externalURL = url
            showsExternalConfirmation = true
        }
        .alert("在普通浏览中打开分享页面？", isPresented: $showsExternalConfirmation) {
            Button("用普通标签打开") {
                guard let externalURL else { return }
                browser.switchProfile(to: .standard)
                browser.newTab().load(externalURL)
            }
            Button("取消", role: .cancel) { externalURL = nil }
        } message: { Text(externalURL?.absoluteString ?? "") }
        .onAppear {
            updateAddress()
            consumeSharedURLIfPresent()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                browser.persistSession()
                showsAgent = false
                return
            }
            consumeSharedURLIfPresent()
        }
    }

    private func updateAddress() {
        address = browser.activeTab?.url?.absoluteString ?? "aegis://start"
    }

    private func consumeSharedURLIfPresent() {
        guard let inbox = try? ShareInbox(),
              let envelope = try? inbox.consume()
        else { return }
        externalURL = envelope.url
        showsExternalConfirmation = true
    }
}

private struct BrowserPane: View {
    @EnvironmentObject private var browser: BrowserSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var tab: BrowserTab
    @State private var managesWindows = false
    @State private var windowError: String?
    @State private var toolbarCollapsed = false
    @Binding var address: String
    @Binding var showsTabs: Bool
    @Binding var showsAgent: Bool
    @Binding var showsData: Bool
    @Binding var showsSettings: Bool
    @Binding var showsFilters: Bool
    @Binding var showsDownloads: Bool
    @Binding var showsFind: Bool
    @State private var addressFocused = false
    @State private var addressSelectionRequest = 0
    @State private var confirmsPrivateBookmark = false
    @State private var pendingBookmark: (id: UUID, url: URL, epoch: UInt64)?

    private var toolbarAtTop: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }
    private var canCollapse: Bool {
        !toolbarAtTop && !addressFocused && !dynamicTypeSize.isAccessibilitySize && !voiceOverEnabled
    }
    private var isCollapsed: Bool { toolbarCollapsed && canCollapse }

    var body: some View {
        VStack(spacing: 0) {
            if let error = browser.sessionError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
            ActiveTabView(tab: tab, address: $address, addressIsEditing: addressFocused,
                          onFind: { showsFind = true }, onScroll: updateToolbar)
                .id(tab.id)
        }
        .safeAreaInset(edge: toolbarAtTop ? .top : .bottom, spacing: 0) { toolbar }
        .background(Color(uiColor: .systemBackground))
        .focusedSceneValue(\.browserKeyboardActions, keyboardActions)
        .onChange(of: tab.id) { _, _ in toolbarCollapsed = false; addressFocused = false }
        .onChange(of: tab.navigationEpoch) { _, _ in toolbarCollapsed = false }
        .sheet(isPresented: $managesWindows) { BrowserWindowsView() }
        .alert("无法新建窗口", isPresented: Binding(get: { windowError != nil }, set: { if !$0 { windowError = nil } })) {
            Button("完成") { windowError = nil }
        } message: { Text(windowError ?? "") }
        .alert("修改已保存的收藏？", isPresented: $confirmsPrivateBookmark) {
            Button("确认修改") {
                guard let pendingBookmark, browser.profile.isPrivate,
                      tab.id == pendingBookmark.id, tab.url == pendingBookmark.url,
                      tab.navigationEpoch == pendingBookmark.epoch else { return }
                browser.toggleBookmark(privateSaveConfirmed: true)
                self.pendingBookmark = nil
            }
            Button("取消", role: .cancel) { pendingBookmark = nil }
        } message: {
            Text(String(localized: "此操作会在普通收藏中添加或移除下面的网址，退出私密浏览后仍然保留。")
                 + "\n\n" + (pendingBookmark?.url.absoluteString ?? ""))
        }
    }

    private func updateToolbar(_ collapsed: Bool) {
        guard canCollapse, toolbarCollapsed != collapsed else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { toolbarCollapsed = collapsed }
    }

    private func editAddress() {
        toolbarCollapsed = false
        addressFocused = true
        addressSelectionRequest += 1
    }

    private var keyboardActions: BrowserKeyboardActions? {
        guard !showsTabs, !showsAgent, !showsData, !showsSettings, !showsFilters,
              !showsDownloads, !showsFind, !managesWindows else { return nil }
        return BrowserKeyboardActions(
            newTab: { _ = browser.newTab() },
            closeTab: { browser.close(tab.id) },
            editAddress: editAddress,
            find: { showsFind = true },
            reload: { tab.reload() },
            back: { tab.goBack() },
            forward: { tab.goForward() })
    }

    /// 浏览时只显示主机名；输入和辅助功能始终可取得完整网址。
    private var displayedAddress: String {
        guard let url = tab.url, url.scheme != "aegis" else { return String(localized: "起始页") }
        return url.host(percentEncoded: true) ?? url.absoluteString
    }

    private var filterStatus: String {
        if !TrackingProtection.enabled { return String(localized: "广告过滤已关闭") }
        if let url = tab.url, TrackingProtection.isExcepted(url) { return String(localized: "此网站已暂停过滤") }
        return String(localized: "广告过滤已启用")
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
                    Button { showsFilters = true } label: {
                        Image(systemName: browser.profile.isPrivate ? "eye.slash.fill" : "shield.lefthalf.filled")
                            .foregroundStyle(browser.profile.isPrivate ? Color.purple : Color.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("广告与跟踪过滤")
                    .accessibilityValue(browser.profile.isPrivate ? String(localized: "私密浏览：不记录历史，保存和发送资料前需确认") : filterStatus)
                    .accessibilityIdentifier("page-protection")
                }
                BrowserAddressField(address: $address, focused: $addressFocused,
                                    displayText: displayedAddress, selectionRequest: addressSelectionRequest) { destination in
                    browser.navigate(address: destination)
                    tab.webView.becomeFirstResponder()
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, addressFocused || isCollapsed ? 14 : 0)
                .onChange(of: addressFocused) { _, focused in
                    if focused { toolbarCollapsed = false }
                }
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
                    address = tab.url?.absoluteString ?? "aegis://start"
                    addressFocused = false
                    tab.webView.becomeFirstResponder()
                }.frame(minWidth: 44, minHeight: 44)
            } else {
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
                Button { showsTabs = true } label: {
                    Label("标签 \(browser.displayedTabs.count)", systemImage: "square.on.square")
                }.accessibilityIdentifier("tabs-button")
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
                Button("资料", systemImage: "books.vertical") { showsData = true }
                    .accessibilityIdentifier("data-button")
                Button("AI 助手", systemImage: "sparkles") { showsAgent = true }
                    .disabled(!browser.agentIsAvailable)
                    .accessibilityIdentifier("agent-button")
                Button("下载", systemImage: "arrow.down.circle") { showsDownloads = true }.accessibilityIdentifier("downloads-button")
            }
            Menu {
                Button(browser.bookmarkIsActive ? "移除收藏" : "添加收藏", systemImage: browser.bookmarkIsActive ? "star.fill" : "star") {
                    if browser.profile.isPrivate, let url = tab.url {
                        pendingBookmark = (tab.id, url, tab.navigationEpoch)
                        confirmsPrivateBookmark = true
                    } else { browser.toggleBookmark() }
                }.accessibilityIdentifier("toggle-bookmark")
                Button("前进", systemImage: "chevron.right") { tab.goForward() }.disabled(!tab.canGoForward)
                Button("编辑网址", systemImage: "text.cursor", action: editAddress)
                Button("在页面中查找", systemImage: "doc.text.magnifyingglass") { showsFind = true }
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
                BrowserWindowActions(managesWindows: $managesWindows, error: $windowError)
                Button("设置", systemImage: "gearshape") { showsSettings = true }
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel("更多")
        .accessibilityValue(String(localized: "标签 \(browser.displayedTabs.count)"))
        .accessibilityIdentifier("browser-more")
    }
}

private struct ActiveTabView: View {
    @ObservedObject var tab: BrowserTab
    @Binding var address: String
    let addressIsEditing: Bool
    let onFind: () -> Void
    let onScroll: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let error = tab.loadingError {
                VStack(alignment: .leading, spacing: 8) {
                    Text("页面加载失败：\(error)").font(.caption)
                    Button("重试") { tab.reload() }
                }.padding(12).foregroundStyle(.red).accessibilityIdentifier("page-load-error")
            }
            if let decision = tab.lastPolicyIntervention {
                NavigationPolicyBanner(decision: decision) {
                    tab.dismissPolicyIntervention()
                }
            }
            BrowserWebView(webView: tab.webView, onFind: onFind, onScroll: onScroll)
                .accessibilityIdentifier("browser-webview")
        }
        .onChange(of: tab.url) { _, url in
            if !addressIsEditing { address = url?.absoluteString ?? address }
        }
    }
}

private struct NavigationPolicyBanner: View {
    let decision: BrowserNavigationPolicyDecision
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: decision.kind == .blocked ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
            VStack(alignment: .leading, spacing: 3) {
                Text(decision.kind == .blocked ? blockedTitle : "已清理追踪参数")
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
            return String(localized: "已阻止不受支持的链接")
        }
        if decision.reasonCodes.contains("unsafe_sanitization_method")
            || decision.reasonCodes.contains("invalid_sanitized_target") {
            return String(localized: "已阻止无法安全清理的请求")
        }
        if decision.reasonCodes.contains("credentialed_url") {
            return String(localized: "已阻止含凭据的 URL")
        }
        return String(localized: "已阻止高风险导航")
    }

    private var blockedDetail: String {
        if decision.reasonCodes.contains("unsupported_top_level_scheme") {
            return String(localized: "仅允许 HTTP(S) 与 Aegis 内部页面 · 请求未加载")
        }
        if decision.reasonCodes.contains("unsafe_sanitization_method")
            || decision.reasonCodes.contains("invalid_sanitized_target") {
            return String(localized: "非 GET/HEAD 请求含追踪参数 · 请求未发送")
        }
        if decision.reasonCodes.contains("credentialed_url") {
            return String(localized: "URL 中包含 user/password · 请求未加载")
        }
        return String(localized: "本地钓鱼评分 \(decision.phishingScore) · 请求未加载")
    }
}

struct TabRow: View {
    @ObservedObject var tab: BrowserTab
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: tab.profile.isPrivate ? "eye.slash" : "globe")
                VStack(alignment: .leading) {
                    Text(tab.title).lineLimit(2)
                    Text(tab.url?.host ?? "起始页").font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
