import AgentKit
import BrowserKit
import SwiftUI

struct AegisRootView: View {
    @EnvironmentObject private var browser: BrowserSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var address = ""
    @State private var showsTabs = false
    @State private var showsAgent = false
    @State private var showsData = false

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                if proxy.size.width >= 760 {
                    BrowserSidebar(showsAgent: $showsAgent)
                        .frame(width: min(300, proxy.size.width * 0.30))
                        .transition(.move(edge: .leading))
                }
                BrowserPane(
                    address: $address,
                    showsTabs: $showsTabs,
                    showsAgent: $showsAgent,
                    showsData: $showsData,
                    hasPersistentSidebar: proxy.size.width >= 760
                )
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .sheet(isPresented: $showsTabs) { TabSwitcher() }
        .sheet(isPresented: $showsAgent) {
            AgentCenterView(
                currentURL: browser.activeTab?.url,
                profileID: browser.activeProfileID,
                isPrivateProfile: browser.profile.isPrivate,
                dataStore: browser.dataStore
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsData) { BrowserDataView() }
        .onChange(of: browser.activeTabID) { _, _ in updateAddress() }
        .onChange(of: browser.profile) { _, profile in
            updateAddress()
            if profile.isPrivate {
                showsAgent = false
            }
        }
        .onAppear {
            updateAddress()
            consumeSharedURLIfPresent()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
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
        browser.switchProfile(to: .standard)
        browser.navigate(address: envelope.url.absoluteString)
        address = envelope.url.absoluteString
    }
}

private struct BrowserPane: View {
    @EnvironmentObject private var browser: BrowserSession
    @Binding var address: String
    @Binding var showsTabs: Bool
    @Binding var showsAgent: Bool
    @Binding var showsData: Bool
    let hasPersistentSidebar: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
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
    }

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if !hasPersistentSidebar {
                    BrandMark(compact: true)
                }
                Button { browser.activeTab?.goBack() } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(browser.activeTab?.canGoBack != true)
                .accessibilityLabel("后退")

                Button { browser.activeTab?.goForward() } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(browser.activeTab?.canGoForward != true)
                .accessibilityLabel("前进")

                HStack(spacing: 8) {
                    Image(systemName: browser.profile.isPrivate ? "eye.slash.fill" : "lock.shield.fill")
                        .foregroundStyle(browser.profile.isPrivate ? .purple : .green)
                    TextField("搜索或输入网址", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { browser.navigate(address: address) }
                        .accessibilityIdentifier("address-field")
                    if browser.activeTab?.isLoading == true {
                        Button { browser.activeTab?.stop() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("停止加载")
                    } else {
                        Button { browser.activeTab?.reload() } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("刷新")
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 42)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button { browser.toggleBookmark() } label: {
                    Image(systemName: browser.bookmarkIsActive ? "star.fill" : "star")
                }
                .disabled(browser.profile.isPrivate)
                .accessibilityLabel(browser.bookmarkIsActive ? "移除收藏" : "添加收藏")
            }

            HStack {
                Label(browser.extensionStatus, systemImage: "puzzlepiece.extension")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("webextension-status")
                Spacer()
                Text("标签 \(browser.visibleTabs.count)")
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
            Text("私密 Profile：不记录历史，Agent 与任务恢复已禁用")
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
        HStack(spacing: 22) {
            Button { showsTabs = true } label: {
                Label("标签", systemImage: "square.on.square")
            }
            .accessibilityIdentifier("tabs-button")

            Button { _ = browser.newTab() } label: {
                Label("新建", systemImage: "plus")
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
                Label(browser.profile.title, systemImage: browser.profile.isPrivate ? "eye.slash" : "person.crop.circle")
            }
            .accessibilityIdentifier("profile-menu")

            Button { showsData = true } label: {
                Label("资料", systemImage: "books.vertical")
            }
            .disabled(browser.profile.isPrivate)
            .accessibilityIdentifier("data-button")
            .accessibilityHint(browser.profile.isPrivate ? "私密模式不显示普通浏览资料" : "打开收藏和历史")

            Spacer()

            Button { showsAgent = true } label: {
                Label("Agent", systemImage: "sparkles")
                    .fontWeight(.bold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!browser.agentIsAvailable)
            .accessibilityIdentifier("agent-button")
            .accessibilityHint(browser.agentIsAvailable ? "打开任务中心" : "私密模式已禁用")
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial)
    }
}

private struct ActiveTabView: View {
    @ObservedObject var tab: BrowserTab
    @Binding var address: String

    var body: some View {
        VStack(spacing: 0) {
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
            return "已阻止不受支持的链接"
        }
        if decision.reasonCodes.contains("unsafe_sanitization_method")
            || decision.reasonCodes.contains("invalid_sanitized_target") {
            return "已阻止无法安全清理的请求"
        }
        if decision.reasonCodes.contains("credentialed_url") {
            return "已阻止含凭据的 URL"
        }
        return "已阻止高风险导航"
    }

    private var blockedDetail: String {
        if decision.reasonCodes.contains("unsupported_top_level_scheme") {
            return "仅允许 HTTP(S) 与 Aegis 内部页面 · 请求未加载"
        }
        if decision.reasonCodes.contains("unsafe_sanitization_method")
            || decision.reasonCodes.contains("invalid_sanitized_target") {
            return "非 GET/HEAD 请求含追踪参数 · 请求未发送"
        }
        if decision.reasonCodes.contains("credentialed_url") {
            return "URL 中包含 user/password · 请求未加载"
        }
        return "本地钓鱼评分 \(decision.phishingScore) · 请求未加载"
    }
}

private struct BrowserSidebar: View {
    @EnvironmentObject private var browser: BrowserSession
    @Binding var showsAgent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BrandMark(compact: false)
                .padding(.top, 18)
            Picker("Profile", selection: Binding(
                get: { browser.profile },
                set: { browser.switchProfile(to: $0) }
            )) {
                ForEach(BrowserProfile.allCases) { profile in Text(profile.title).tag(profile) }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 7) {
                Text("标签页").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                ForEach(browser.visibleTabs) { tab in
                    TabRow(tab: tab, isActive: tab.id == browser.activeTabID) {
                        browser.activate(tab.id)
                    }
                }
            }

            Divider()
            Text("智能工作流").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            ForEach(AgentWorkflowKind.allCases) { workflow in
                Button { showsAgent = true } label: {
                    Label(workflow.title, systemImage: workflow.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(!browser.agentIsAvailable)
            }
            Spacer()
            Label("策略本地生效", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .background(.regularMaterial)
        .accessibilityIdentifier("ipad-sidebar")
    }
}

private struct BrandMark: View {
    let compact: Bool
    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(
                    LinearGradient(colors: [.green, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            if !compact {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Aegis").font(.title2.bold())
                    Text("PRIVATE WEB").font(.caption2.weight(.bold)).tracking(1.4).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Aegis 私密浏览器")
    }
}

private struct TabRow: View {
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

private struct TabSwitcher: View {
    @EnvironmentObject private var browser: BrowserSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(browser.visibleTabs) { tab in
                    Button {
                        browser.activate(tab.id)
                        dismiss()
                    } label: {
                        TabRow(tab: tab, isActive: tab.id == browser.activeTabID, action: {})
                    }
                    .swipeActions {
                        Button(role: .destructive) { browser.close(tab.id) } label: {
                            Label("关闭", systemImage: "xmark")
                        }
                    }
                }
            }
            .navigationTitle("标签页")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct BrowserDataView: View {
    @EnvironmentObject private var browser: BrowserSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if browser.profile.isPrivate {
                    ContentUnavailableView(
                        "私密资料隔离",
                        systemImage: "eye.slash",
                        description: Text("私密 Profile 不显示普通浏览的收藏或历史。")
                    )
                } else {
                    List {
                        Section("收藏") {
                            if browser.dataStore.bookmarks.isEmpty {
                                Text("暂无收藏").foregroundStyle(.secondary)
                            }
                            ForEach(browser.dataStore.bookmarks) { item in
                                VStack(alignment: .leading) {
                                    Text(item.title)
                                    Text(item.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        Section("最近历史") {
                            if browser.dataStore.history.isEmpty {
                                Text("暂无历史").foregroundStyle(.secondary)
                            }
                            ForEach(browser.dataStore.history.prefix(20)) { item in
                                VStack(alignment: .leading) {
                                    Text(item.title)
                                    Text(item.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("浏览资料")
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}
