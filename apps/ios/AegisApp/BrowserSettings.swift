import AgentKit
import AccessKit
import BrowserKit
import SwiftUI

@MainActor
final class BrowserSettings: ObservableObject {
    @Published var model: ModelConfiguration {
        didSet { if let data = try? JSONEncoder().encode(model) { defaults.set(data, forKey: "model.configuration.v1") } }
    }
    @Published var appearance: String { didSet { defaults.set(appearance, forKey: "browser.appearance") } }
    let browserPreferences: BrowserPreferences
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        browserPreferences = BrowserPreferences(defaults: defaults)
        model = defaults.data(forKey: "model.configuration.v1").flatMap { try? JSONDecoder().decode(ModelConfiguration.self, from: $0) } ?? ModelConfiguration()
        appearance = defaults.string(forKey: "browser.appearance") ?? "system"
    }
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }
}

struct BrowserSettingsView: View {
    @EnvironmentObject private var settings: BrowserSettings
    @EnvironmentObject private var browser: BrowserSession
    @Environment(\.dismiss) private var dismiss

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        NavigationStack {
            Form {
                Section("浏览") {
                    NavigationLink("搜索、主页与浏览方式") { BrowserGeneralSettingsView(preferences: browser.preferences) }
                        .accessibilityIdentifier("general-browser-settings")
                    NavigationLink("网站设置与权限") { WebsiteSettingsView(preferences: browser.preferences) }
                        .accessibilityIdentifier("website-settings")
                    NavigationLink("网站数据管理") { WebsiteDataSettingsView() }
                        .accessibilityIdentifier("website-data-settings")
                    Button("打开系统 App 设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section("Aegis 功能") {
                    NavigationLink { AegisFeatureSettingsView() } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Aegis 设置").font(.headline)
                            Text("隐私防护、网站增强、阅读、AI 与下载")
                                .font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }.padding(.vertical, 5)
                    }.accessibilityIdentifier("aegis-feature-settings")
                    NavigationLink("代理诊断日志") { AccessDiagnosticsView() }
                        .accessibilityIdentifier("access-diagnostics-settings")
                }
                Section("外观") {
                    SettingsPicker("主题", selection: $settings.appearance,
                                   value: settings.appearance == "dark" ? "深色" : settings.appearance == "light" ? "浅色" : "跟随系统") {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    NavigationLink("语言") { LanguageSettingsView() }
                        .accessibilityIdentifier("language-settings-link")
                }
                Section("关于") {
                    LabeledContent(
                        "应用",
                        value: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Aegis Browser"
                    )
                    LabeledContent("版本", value: version)
                    LabeledContent("网页引擎") { Text("系统 WebKit") }
                    NavigationLink("开源许可与鸣谢") { ThirdPartyNoticesView() }
                        .accessibilityIdentifier("third-party-notices-link")
                    if let website = URL(string: "https://browser.erjinyi.com/") {
                        Link("官方网站", destination: website)
                            .accessibilityIdentifier("aegis-website-link")
                        Link("技术支持", destination: website.appendingPathComponent("support"))
                            .accessibilityIdentifier("aegis-support-link")
                        Link("隐私政策", destination: website.appendingPathComponent("privacy"))
                            .accessibilityIdentifier("aegis-privacy-policy-link")
                    }
#if DEBUG
                    Text("开发测试版")
#endif
                    Text("私密浏览不自动保存历史和会话。主动保存的收藏、工作区、下载和分析结果会继续保留。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .localizedNavigationTitle("设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("settings-done") } }
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "Ver \(info["CFBundleShortVersionString"] as? String ?? "2.0") (\(info["CFBundleVersion"] as? String ?? "0"))"
    }
}


// 功能名称与桌面一致，使用 iOS 的导航、触控尺寸和动态字号。
private struct AegisFeatureSettingsView: View {
    @EnvironmentObject private var browser: BrowserSession
    @State private var showsDownloads = false

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        Form {
            Section {
                NavigationLink { AegisProtectionSettingsView() } label: {
                    row("隐私与防护", "保护选项、广告过滤与网站数据", "hand.raised")
                }.accessibilityIdentifier("aegis-privacy-settings")
                NavigationLink { WebsiteEnhancementsView(embedded: true) } label: {
                    row("网站增强与脚本", "网站规则与已安装脚本", "puzzlepiece.extension")
                }.accessibilityIdentifier("enhancement-settings")
                NavigationLink {
                    Form {
                        Section {
                            NavigationLink("阅读外观与图片权限") { ReadingPreferencesView() }
                                .accessibilityIdentifier("reading-preferences-settings")
                            NavigationLink("Markdown 自动预览网站") { WebsiteSettingsView(preferences: browser.preferences) }
                        }
                    }.localizedNavigationTitle("阅读与 Markdown").navigationBarTitleDisplayMode(.inline)
                } label: { row("阅读与 Markdown", "阅读外观、图片权限与自动预览", "doc.text") }
                    .accessibilityIdentifier("aegis-reading-settings")
                NavigationLink {
                    Form { Section { Text("鼠标手势适用于桌面版。iOS 使用系统触控操作，暂无独立手势配置。") } }
                        .localizedNavigationTitle("鼠标手势").navigationBarTitleDisplayMode(.inline)
                } label: { row("鼠标手势", "此功能适用于桌面版", "hand.draw") }
                    .accessibilityIdentifier("aegis-gestures-settings")
                NavigationLink { ModelSettingsView() } label: {
                    row("AI 与模型", "模型服务与连接设置", "sparkles")
                }.accessibilityIdentifier("model-service-settings")
                Button { showsDownloads = true } label: {
                    HStack {
                        row("下载增强", "下载任务、网络选项与存储", "arrow.down.circle")
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.secondary).accessibilityHidden(true)
                    }
                }.accessibilityIdentifier("aegis-downloads-settings")
                NavigationLink {
                    Form { Section { Text("iOS 版暂未提供本机工具连接服务。网页操作通过应用内的 AI 助手发起，并在需要时确认。") } }
                        .localizedNavigationTitle("本机工具连接").navigationBarTitleDisplayMode(.inline)
                } label: { row("本机工具连接", "iOS 版暂未提供", "network") }
                    .accessibilityIdentifier("aegis-tools-settings")
                NavigationLink {
                    Form {
                        Section("网站实验选项") {
                            NavigationLink("网站设置与权限") { WebsiteSettingsView(preferences: browser.preferences) }
                            Text("严格指纹限制可在单个网站的设置中开启，可能影响网站正常显示。iOS 版暂未提供桌面的本机实验模型。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }.localizedNavigationTitle("实验功能").navigationBarTitleDisplayMode(.inline)
                } label: { row("实验功能", "网站实验选项与平台说明", "flask") }
                    .accessibilityIdentifier("aegis-experiments-settings")
            }
        }
        .localizedNavigationTitle("Aegis 设置")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsDownloads) { DownloadsView() }
    }

    private func row(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, _ icon: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            // 装饰图标固定尺寸；辅助字号放大文字时不挤占文本或越出卡片。
            Image(systemName: icon).font(.system(size: 20)).frame(width: 24)
                .foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).foregroundStyle(Color.primary)
                Text(subtitle).font(.footnote).foregroundStyle(Color.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AegisProtectionSettingsView: View {
    @EnvironmentObject private var browser: BrowserSession
    @State private var clearing = false
    @State private var clearingWebsites = false
    @State private var deletingWebsites = false
    @State private var message: AegisLocalizedMessage?

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        Form {
            Section("隐私与保护") {
                NavigationLink("保护选项") { ProtectionOptionsView(preferences: browser.preferences) }
                    .accessibilityIdentifier("protection-options")
                NavigationLink("广告与跟踪过滤") { ContentFilterSettingsView() }
                    .accessibilityIdentifier("content-filter-settings")
                if let url = browser.activeTab?.url, ["http", "https"].contains(url.scheme ?? ""), !browser.profile.isPrivate {
                    Button(TrackingProtection.isExcepted(url) ? "恢复当前网站的跟踪拦截" : "为当前网站暂停跟踪拦截") {
                        TrackingProtection.setException(!TrackingProtection.isExcepted(url), for: url)
                        browser.activeTab?.reload()
                        message = .resource("已更新当前网站的设置并重新加载。")
                    }
                    Text(url.host ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Text("网址检查基于本地规则，不能保证识别所有风险。网页内容仍由系统 WebKit 加载。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("清除浏览历史", role: .destructive) { clearing = true }
                Button("清除网站数据", role: .destructive) { clearingWebsites = true }
                    .disabled(browser.profile.isPrivate || deletingWebsites)
            }
            Section {
                NavigationLink {
                    Form { FirebaseControlsView() }
                        .localizedNavigationTitle("诊断与使用分析")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("诊断与使用分析")
                        Text("崩溃报告、使用分析与远程诊断配置默认开启，可随时关闭。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("firebase-data-collection-details")
            } header: {
                Text("诊断与使用分析")
            }
            if let message { Text(message.text).foregroundStyle(.secondary) }
        }
        .localizedNavigationTitle("隐私与防护")
        .navigationBarTitleDisplayMode(.inline)
        .alert("清除网站数据？", isPresented: $clearingWebsites) {
            Button("清除并关闭普通标签", role: .destructive) {
                deletingWebsites = true
                Task { @MainActor in
                    await browser.clearWebsiteData()
                    deletingWebsites = false
                    message = .resource("网站数据已清除。")
                }
            }
            Button("取消", role: .cancel) { }
        } message: { Text("将关闭普通标签并清除 Cookie、网站存储和缓存。网站登录会退出，收藏和工作区会保留。") }
        .confirmationDialog("清除全部浏览历史？", isPresented: $clearing, titleVisibility: .visible) {
            Button("清除历史", role: .destructive) {
                guard !browser.profile.isPrivate else { return }
                browser.dataStore.clearHistory()
                message = .verbatim(browser.dataStore.history.isEmpty ? "浏览历史已清除。" : "浏览历史未能清除，请重启后重试。")
            }
        }
    }
}

struct ModelSettingsView: View {
    @EnvironmentObject private var settings: BrowserSettings
    @State private var configuration = ModelConfiguration()
    @State private var key = ""
    @State private var models: [String] = []
    @State private var message: AegisLocalizedMessage?
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @FocusState private var editing: Bool

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        Form {
            Section("连接设置") {
                SettingsPicker("接口类型", selection: $configuration.provider, value: configuration.provider.title) {
                    ForEach(ModelProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                SettingsField("服务地址（包含 API 版本路径）") {
                    TextField("服务地址（包含 API 版本路径）", text: $configuration.endpoint)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("model-endpoint")
                        .focused($editing)
                }
                SettingsField("API 密钥（本机服务可留空）") {
                    SecureField("API 密钥（本机服务可留空）", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($editing)
                }
                SettingsField("模型名称") {
                    TextField("模型名称", text: $configuration.model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("model-name")
                        .focused($editing)
                }
                Text("兼容接口示例：https://服务地址/v1。密钥保存在系统钥匙串，仅用于当前服务。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button(busy ? "正在连接…" : "检测可用模型") { detect() }.disabled(busy)
                    .accessibilityIdentifier("detect-models")
                ForEach(models, id: \.self) { name in
                    Button { configuration.model = name } label: {
                        HStack { Text(name); Spacer(); if name == configuration.model { Image(systemName: "checkmark") } }
                    }
                }
                Button("保存设置") {
                    editing = false
                    do {
                        _ = try configuration.validatedURL()
                        guard !configuration.model.isEmpty else { throw ModelClientError.missingModel }
                        try ModelCredentialStore.save(key, for: configuration)
                        settings.model = configuration
                        message = .resource("模型设置已保存。")
                    } catch { message = .error(error) }
                }.disabled(busy).accessibilityIdentifier("save-model")
                if let message { Text(message.text).font(.callout).textSelection(.enabled).accessibilityIdentifier("model-status") }
            }
        }
        .localizedNavigationTitle("模型服务")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { configuration = settings.model; key = ModelCredentialStore.read(for: configuration) }
        .onChange(of: configuration.endpoint) { _, _ in key = ModelCredentialStore.read(for: configuration); models = []; message = nil }
        .onChange(of: configuration.provider) { _, _ in key = ModelCredentialStore.read(for: configuration); models = []; message = nil }
        .onDisappear { operation?.cancel() }
    }

    private func detect() {
        editing = false
        busy = true
        message = nil
        let client = ModelClient(configuration: configuration, key: key)
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let values = try await client.models()
                try Task.checkCancellation()
                models = values
                if configuration.model.isEmpty { configuration.model = values[0] }
                message = .resource("连接成功，请选择模型并保存。")
            } catch is CancellationError { } catch { message = .error(error) }
        }
    }
}

private struct AccessDiagnosticsView: View {
    @AppStorage(AccessDiagnosticLog.preferenceKey) private var level = AccessDiagnosticLog.defaultLevel.rawValue
    @State private var log = ""
    @State private var unavailable = false
    @State private var persistenceProblem = false
    @State private var clearing = false
    @State private var storageClearing = false
    @State private var clearMessage: String?
    @State private var share: AccessDiagnosticShare?
    @State private var showShareConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("日志级别") {
                Picker("级别", selection: $level) {
                    Text("调试 (debug)").tag(AccessLogLevel.debug.rawValue)
                    Text("信息 (info)").tag(AccessLogLevel.info.rawValue)
                    Text("警告 (warning)").tag(AccessLogLevel.warning.rawValue)
                    Text("错误 (error)").tag(AccessLogLevel.error.rawValue)
                    Text("关闭 (none)").tag(AccessLogLevel.none.rawValue)
                }
                Text("关闭立即生效并清空日志；其他级别在代理核心下次启动时生效。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("诊断日志") {
                Text("日志保存在本机，重启后可查看，保留最近约 256 KB。为保护凭据，仅显示部分诊断信息和访问目标；普通和私密会话的目标都可能写入磁盘，分享前请确认接收方可信。")
                    .font(.footnote).foregroundStyle(.secondary)
                if persistenceProblem {
                    Text("磁盘日志读取或保存失败；当前内存日志仍可查看。清理后可重试。")
                        .foregroundStyle(.secondary)
                }
                if !AccessDiagnosticArchive.recoveredTemporaryArchives {
                    Text("上次分享的临时文件清理失败，压缩分享暂不可用。请重启后重试。")
                        .foregroundStyle(.secondary)
                }
                if unavailable {
                    Text("日志接收器不可用；代理仍可使用。请重新启动代理后重试。")
                        .foregroundStyle(.secondary)
                }
                if log.isEmpty {
                    Text("暂无日志").foregroundStyle(.secondary)
                } else {
                    Text(log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .accessibilityIdentifier("access-diagnostics-log")
                }
                Button(clearing || storageClearing ? "正在清理…" : "清理内存和磁盘日志", action: clearLogs)
                    .disabled(clearing || storageClearing)
                    .accessibilityIdentifier("access-diagnostics-clear")
                if let clearMessage { Text(clearMessage).font(.footnote).foregroundStyle(.secondary) }
                Button("压缩并分享") { showShareConfirmation = true }
                    .disabled(log.isEmpty)
                    .accessibilityIdentifier("access-diagnostics-share")
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .localizedNavigationTitle("代理诊断日志")
        .onChange(of: level) { _, value in
            if value == AccessLogLevel.none.rawValue { AccessDiagnosticLog.shared.disableAndClear(); log = "" }
        }
        .task {
            while !Task.isCancelled {
                log = AccessDiagnosticLog.shared.snapshot()
                unavailable = AccessDiagnosticLog.shared.unavailable
                persistenceProblem = AccessDiagnosticLog.shared.persistenceUnavailable
                storageClearing = AccessDiagnosticLog.shared.isClearingStorage
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .confirmationDialog("日志可能包含普通和私密会话的访问目标，确认压缩并分享？", isPresented: $showShareConfirmation, titleVisibility: .visible) {
            Button("继续分享") { prepareShare() }
            Button("取消", role: .cancel) { }
        }
        .sheet(item: $share) { item in
            AccessDiagnosticShareSheet(url: item.url)
        }
    }

    private func prepareShare() {
        do {
            let url = try AccessDiagnosticArchive.createTemporary(snapshot: AccessDiagnosticLog.shared.snapshot())
            errorMessage = nil
            share = AccessDiagnosticShare(url: url)
        } catch {
            errorMessage = "无法生成压缩日志，请重试。"
        }
    }

    private func clearLogs() {
        clearing = true
        clearMessage = nil
        errorMessage = nil
        Task {
            do {
                try await AccessDiagnosticLog.shared.clearStoredLogs()
                log = AccessDiagnosticLog.shared.snapshot()
                clearMessage = "已清理历史日志；新日志仍会继续记录。"
            } catch {
                errorMessage = "未能删除磁盘日志，请重试。"
            }
            clearing = false
        }
    }
}

private struct AccessDiagnosticShare: Identifiable {
    let id = UUID()
    let url: URL
}

private struct AccessDiagnosticShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            AccessDiagnosticArchive.removeTemporary(url)
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
