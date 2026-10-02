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
    @State private var showsDownloads = false
    @State private var showsFind = false
    @State private var findText = ""
    @State private var findMessage = ""

    var body: some View {
        BrowserPane(
            address: $address,
            showsTabs: $showsTabs,
            showsAgent: $showsAgent,
            showsData: $showsData,
            showsSettings: $showsSettings,
            showsDownloads: $showsDownloads,
            showsFind: $showsFind
        )
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(isPresented: $showsTabs) { TabSwitcher() }
        .sheet(isPresented: $showsAgent) {
            PageAssistantView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsData) { BrowserLibraryView(dataStore: browser.dataStore, workspaces: browser.workspaceStore) }
        .sheet(isPresented: $showsSettings) { BrowserSettingsView() }
        .sheet(isPresented: $showsDownloads, onDismiss: { browser.pendingDownloadURL = nil }) {
            DownloadsView(initialURL: browser.pendingDownloadURL)
        }
        .sheet(isPresented: $showsFind) {
            NavigationStack {
                Form {
                    TextField("查找文字", text: $findText).accessibilityIdentifier("find-text")
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
                    .toolbar { Button("完成") { showsFind = false } }
            }.presentationDetents([.medium])
        }
        .onChange(of: browser.pendingDownloadURL) { _, url in if url != nil { showsDownloads = true } }
        .onChange(of: browser.activeTabID) { _, _ in updateAddress() }
        .onChange(of: browser.profile) { _, profile in
            updateAddress()
            if profile.isPrivate {
                showsAgent = false
            }
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
    @State private var managesWindows = false
    @State private var windowError: String?
    @Binding var address: String
    @Binding var showsTabs: Bool
    @Binding var showsAgent: Bool
    @Binding var showsData: Bool
    @Binding var showsSettings: Bool
    @Binding var showsDownloads: Bool
    @Binding var showsFind: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let error = browser.sessionError { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            if browser.profile.isPrivate {
                privateBanner
            }
            if let tab = browser.activeTab {
                ActiveTabView(tab: tab, address: $address)
                    .id(tab.id)
            } else {
                ContentUnavailableView("没有标签页", systemImage: "rectangle.stack")
            }
            bottomBar
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .sheet(isPresented: $managesWindows) { BrowserWindowsView() }
        .alert("无法新建窗口", isPresented: Binding(get: { windowError != nil }, set: { if !$0 { windowError = nil } })) {
            Button("完成") { windowError = nil }
        } message: { Text(windowError ?? "") }
    }

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { browser.activeTab?.goBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20)).frame(width: 36, height: 44)
                }
                .disabled(browser.activeTab?.canGoBack != true)
                .accessibilityLabel("后退")

                Button { browser.activeTab?.goForward() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20)).frame(width: 36, height: 44)
                }
                .disabled(browser.activeTab?.canGoForward != true)
                .accessibilityLabel("前进")

                HStack(spacing: 8) {
                    Image(systemName: browser.profile.isPrivate ? "eye.slash.fill" : (browser.activeTab?.url?.scheme == "https" ? "lock.fill" : "globe"))
                        .font(.system(size: 18))
                        .foregroundStyle(browser.profile.isPrivate ? .purple : .secondary)
                    TextField("搜索或输入网址", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .onSubmit { browser.navigate(address: address) }
                        .accessibilityIdentifier("address-field")
                    if browser.activeTab?.isLoading == true {
                        Button { browser.activeTab?.stop() } label: { Image(systemName: "xmark").font(.system(size: 18)) }
                            .accessibilityLabel("停止加载")
                    } else {
                        Button { browser.activeTab?.reload() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 18)) }
                            .accessibilityLabel("刷新")
                    }
                }
                .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button { browser.toggleBookmark() } label: {
                    Image(systemName: browser.bookmarkIsActive ? "star.fill" : "star")
                        .font(.system(size: 20)).frame(width: 36, height: 44)
                }
                .disabled(browser.profile.isPrivate)
                .accessibilityLabel(browser.bookmarkIsActive ? "移除收藏" : "添加收藏")
            }

            HStack {
                Label("链接清理与网址检查已启用", systemImage: "shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("webextension-status")
                Spacer()
                if browser.selectedGroupID != nil {
                    Text(browser.selectedGroupName).font(.caption).lineLimit(1)
                }
                Text("标签 \(browser.displayedTabs.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var privateBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash.fill")
            Text("私密浏览：不记录历史，AI 助手已关闭")
                .font(.callout.weight(.semibold))
            Spacer()
        }
        .foregroundStyle(.purple)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.purple.opacity(0.10))
        .accessibilityIdentifier("private-profile-banner")
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button { showsTabs = true } label: {
                Label("标签", systemImage: "square.on.square").frame(minWidth: 40, minHeight: 44)
            }
            .accessibilityIdentifier("tabs-button")

            Button { _ = browser.newTab() } label: {
                Label("新建", systemImage: "plus").frame(minWidth: 40, minHeight: 44)
            }
            .accessibilityIdentifier("new-tab-button")

            Menu {
                ForEach(BrowserProfile.allCases) { profile in
                    Button {
                        browser.switchProfile(to: profile)
                    } label: {
                        Label(profile.title, systemImage: profile.isPrivate ? "eye.slash" : "person.crop.circle")
                    }
                }
            } label: {
                Label(browser.profile.title, systemImage: browser.profile.isPrivate ? "eye.slash" : "person.crop.circle").frame(minWidth: 40, minHeight: 44)
            }
            .accessibilityIdentifier("profile-menu")

            Button { showsData = true } label: {
                Label("资料", systemImage: "books.vertical").frame(minWidth: 40, minHeight: 44)
            }
            .disabled(browser.profile.isPrivate)
            .accessibilityIdentifier("data-button")
            .accessibilityHint(browser.profile.isPrivate ? "私密模式不显示普通浏览资料" : "打开收藏和历史")

            Menu {
                Button("下载", systemImage: "arrow.down.circle") { showsDownloads = true }.disabled(browser.profile.isPrivate)
                Button("在页面中查找", systemImage: "doc.text.magnifyingglass") { showsFind = true }
                if let url = browser.activeTab?.url, ["http", "https"].contains(url.scheme ?? "") {
                    ShareLink(item: url) { Label("分享页面", systemImage: "square.and.arrow.up") }
                }
                Button("打印或保存 PDF", systemImage: "printer") {
                    guard let view = browser.activeTab?.webView else { return }
                    let controller = UIPrintInteractionController.shared
                    controller.printFormatter = view.viewPrintFormatter()
                    controller.present(animated: true)
                }
                BrowserWindowActions(managesWindows: $managesWindows, error: $windowError)
                Button("设置", systemImage: "gearshape") { showsSettings = true }
            } label: { Label("更多", systemImage: "ellipsis.circle").frame(minWidth: 40, minHeight: 44) }
            .accessibilityIdentifier("browser-more")

            Spacer()

            Button { showsAgent = true } label: {
                Label("AI 助手", systemImage: "sparkles")
                    .fontWeight(.bold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!browser.agentIsAvailable)
            .accessibilityIdentifier("agent-button")
            .accessibilityHint(browser.agentIsAvailable ? "打开任务中心" : "私密模式已禁用")
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 20))
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial)
    }
}

private struct ActiveTabView: View {
    @ObservedObject var tab: BrowserTab
    @Binding var address: String

    var body: some View {
        VStack(spacing: 0) {
            if let error = tab.loadingError {
                HStack {
                    Text("页面加载失败：\(error)").font(.caption)
                    Button("重试") { tab.reload() }
                }.padding(12).foregroundStyle(.red)
            }
            if let decision = tab.lastPolicyIntervention {
                NavigationPolicyBanner(decision: decision) {
                    tab.dismissPolicyIntervention()
                }
            }
            BrowserWebView(webView: tab.webView)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
                .accessibilityIdentifier("browser-webview")
        }
        .onChange(of: tab.url) { _, url in
            address = url?.absoluteString ?? address
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
                    Text(tab.title).lineLimit(1)
                    Text(tab.url?.host ?? "起始页").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(10)
            .background(isActive ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
