import AgentKit
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

    var body: some View {
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
                    Text("默认浏览器、App 语言及系统相机、麦克风权限由 iOS 管理；可用选项取决于安装资格和系统版本。")
                        .font(.footnote).foregroundStyle(.secondary)
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
                }
                Section("外观") {
                    SettingsPicker("主题", selection: $settings.appearance,
                                   value: settings.appearance == "dark" ? "深色" : settings.appearance == "light" ? "浅色" : "跟随系统") {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    Text("界面语言跟随系统的 App 语言设置。支持简体中文、繁體中文和 English。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("应用", value: "GCSA Aegis")
                    LabeledContent("版本", value: version)
                    LabeledContent("网页引擎", value: "系统 WebKit")
#if DEBUG
                    Text("开发测试版")
#endif
                    Text("私密浏览不自动保存历史和会话。主动保存的收藏、工作区、下载和分析结果会继续保留。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
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

    var body: some View {
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
                    }.navigationTitle("阅读与 Markdown").navigationBarTitleDisplayMode(.inline)
                } label: { row("阅读与 Markdown", "阅读外观、图片权限与自动预览", "doc.text") }
                    .accessibilityIdentifier("aegis-reading-settings")
                NavigationLink {
                    Form { Section { Text("鼠标手势适用于桌面版。iOS 使用系统触控操作，暂无独立手势配置。") } }
                        .navigationTitle("鼠标手势").navigationBarTitleDisplayMode(.inline)
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
                        .navigationTitle("本机工具连接").navigationBarTitleDisplayMode(.inline)
                } label: { row("本机工具连接", "iOS 版暂未提供", "network") }
                    .accessibilityIdentifier("aegis-tools-settings")
                NavigationLink {
                    Form {
                        Section("网站实验选项") {
                            NavigationLink("网站设置与权限") { WebsiteSettingsView(preferences: browser.preferences) }
                            Text("严格指纹限制可在单个网站的设置中开启，可能影响网站正常显示。iOS 版暂未提供桌面的本机实验模型。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }.navigationTitle("实验功能").navigationBarTitleDisplayMode(.inline)
                } label: { row("实验功能", "网站实验选项与平台说明", "flask") }
                    .accessibilityIdentifier("aegis-experiments-settings")
            }
        }
        .navigationTitle("Aegis 设置")
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
    @State private var message: String?

    var body: some View {
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
                        message = String(localized: "已更新当前网站的设置并重新加载。")
                    }
                    Text(url.host ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Text("网址检查基于本地规则，不能保证识别所有风险。网页内容仍由系统 WebKit 加载。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("清除浏览历史", role: .destructive) { clearing = true }
                Button("清除网站数据", role: .destructive) { clearingWebsites = true }
                    .disabled(browser.profile.isPrivate || deletingWebsites)
            }
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .navigationTitle("隐私与防护")
        .navigationBarTitleDisplayMode(.inline)
        .alert("清除网站数据？", isPresented: $clearingWebsites) {
            Button("清除并关闭普通标签", role: .destructive) {
                deletingWebsites = true
                Task { @MainActor in
                    await browser.clearWebsiteData()
                    deletingWebsites = false
                    message = String(localized: "网站数据已清除。")
                }
            }
            Button("取消", role: .cancel) { }
        } message: { Text("将关闭普通标签并清除 Cookie、网站存储和缓存。网站登录会退出，收藏和工作区会保留。") }
        .confirmationDialog("清除全部浏览历史？", isPresented: $clearing, titleVisibility: .visible) {
            Button("清除历史", role: .destructive) {
                guard !browser.profile.isPrivate else { return }
                browser.dataStore.clearHistory()
                message = browser.dataStore.history.isEmpty ? "浏览历史已清除。" : "浏览历史未能清除，请重启后重试。"
            }
        }
    }
}

struct ModelSettingsView: View {
    @EnvironmentObject private var settings: BrowserSettings
    @State private var configuration = ModelConfiguration()
    @State private var key = ""
    @State private var models: [String] = []
    @State private var message: String?
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @FocusState private var editing: Bool

    var body: some View {
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
                        message = String(localized: "模型设置已保存。")
                    } catch { message = error.localizedDescription }
                }.disabled(busy).accessibilityIdentifier("save-model")
                if let message { Text(message).font(.callout).textSelection(.enabled).accessibilityIdentifier("model-status") }
            }
        }
        .navigationTitle("模型服务")
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
                message = String(localized: "连接成功，请选择模型并保存。")
            } catch is CancellationError { } catch { message = error.localizedDescription }
        }
    }
}
