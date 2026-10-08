import AgentKit
import BrowserKit
import SwiftUI

@MainActor
final class BrowserSettings: ObservableObject {
    @Published var model: ModelConfiguration {
        didSet { if let data = try? JSONEncoder().encode(model) { defaults.set(data, forKey: "model.configuration.v1") } }
    }
    @Published var appearance: String { didSet { defaults.set(appearance, forKey: "browser.appearance") } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        model = defaults.data(forKey: "model.configuration.v1").flatMap { try? JSONDecoder().decode(ModelConfiguration.self, from: $0) } ?? ModelConfiguration()
        appearance = defaults.string(forKey: "browser.appearance") ?? "system"
    }
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }
}

struct BrowserSettingsView: View {
    @EnvironmentObject private var settings: BrowserSettings
    @EnvironmentObject private var browser: BrowserSession
    @Environment(\.dismiss) private var dismiss
    @State private var clearing = false
    @State private var clearingWebsites = false
    @State private var deletingWebsites = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("AI 助手") {
                    NavigationLink("模型服务") { ModelSettingsView() }
                    Text("读取网页前会确认范围，发送给模型前会再次确认。私密浏览中不启用助手。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("隐私与保护") {
                    Label("链接追踪参数清理", systemImage: "checkmark.shield")
                    Label("高风险网址检查", systemImage: "checkmark.shield")
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
                Section("外观") {
                    Picker("主题", selection: $settings.appearance) {
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
                    Text("工作区保存普通标签网址。私密浏览不会保存历史、工作区或助手任务。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
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

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "Ver \(info["CFBundleShortVersionString"] as? String ?? "2.0") (\(info["CFBundleVersion"] as? String ?? "0"))"
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
                Picker("接口类型", selection: $configuration.provider) {
                    ForEach(ModelProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("服务地址（包含 API 版本路径）", text: $configuration.endpoint)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("model-endpoint")
                    .focused($editing)
                SecureField("API 密钥（本机服务可留空）", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($editing)
                TextField("模型名称", text: $configuration.model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("model-name")
                    .focused($editing)
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
