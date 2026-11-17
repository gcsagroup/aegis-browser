import AegisPolicyKit
import AgentKit
import BrowserKit
import SwiftUI
import UniformTypeIdentifiers

struct TextReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? "" }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

struct PageAssistantView: View {
    @EnvironmentObject private var browser: BrowserSession
    @EnvironmentObject private var settings: BrowserSettings
    @EnvironmentObject private var tasks: AssistantTaskStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = PageAssistantModel()
    @State private var showingBookmarks = false
    @State private var export = false
    @State private var showingHistory = false
    @State private var showingOperations = false
    @State private var showingScripts = false
    @State private var confirmsPrivateSave = false
    @State private var confirmsPrivateExport = false
    @FocusState private var goalFocused: Bool

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label(AegisLocalization.string(model.status), systemImage: model.busy ? "hourglass" : "sparkles")
                        .font(.headline).accessibilityIdentifier("assistant-status")
                    Text("用当前页面或选中的标签页完成摘要、翻译、研究和商品比较。")
                        .foregroundStyle(.secondary)
                    Button("任务记录与继续", systemImage: "clock.arrow.circlepath") { goalFocused = false; showingHistory = true }
                        .accessibilityIdentifier("assistant-history")
                    Button("浏览器操作与工作流", systemImage: "list.bullet.clipboard") { showingOperations = true }
                        .disabled(model.busy).accessibilityIdentifier("browser-operations")
                    Button("为当前网站编写脚本", systemImage: "curlybraces") { showingScripts = true }
                    if let storageError = tasks.storageError { Text(storageError).foregroundStyle(.red) }
                    if browser.profile.isPrivate {
                        Text("私密分析只在本次界面保留，不自动保存任务、来源网址或回答。发送前会说明模型服务；主动保存或导出后，结果会保留在设备上。")
                            .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("private-assistant-notice")
                    }
                    presets
                    TextField("你想了解什么？", text: $model.goal, axis: .vertical)
                        .lineLimit(3...6).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("assistant-goal")
                        .focused($goalFocused)
                        .disabled(model.busy)
                    sourceSelection
                    Button("读取所选页面") { goalFocused = false; model.readPages() }
                        .buttonStyle(.borderedProminent).disabled(model.busy || model.selected.isEmpty || !browser.agentIsAvailable)
                        .accessibilityIdentifier("read-pages")
                    Text("只读取所选页面的正文，不读取输入框、密码或 Cookie。此步骤不联系模型服务。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !model.snapshots.isEmpty { preview }
                    if let error = model.error {
                        Label(error.localizedDescription, systemImage: "exclamationmark.triangle").foregroundStyle(.red).accessibilityIdentifier("assistant-error")
                        if !model.snapshots.isEmpty, !model.busy {
                            Button("重新确认并重试") {
                                model.requestConsent()
                            }.accessibilityIdentifier("retry-model-request")
                        }
                    }
                    if !model.output.isEmpty { result }
                    Divider()
                    Button { showingBookmarks = true } label: { Label("整理收藏与撤销", systemImage: "books.vertical") }
                        .accessibilityIdentifier("bookmark-organizer")
                    NavigationLink { ModelSettingsView() } label: { Label("模型服务设置", systemImage: "slider.horizontal.3") }
                }
                .padding(20)
            }
            .accessibilityIdentifier("assistant-scroll")
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .localizedNavigationTitle("AI 助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { model.cancel(); dismiss() } }
                if model.busy {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消任务", role: .cancel) { model.cancel() }.accessibilityIdentifier("cancel-assistant")
                    }
                }
            }
            .sheet(isPresented: $showingHistory) {
                AssistantHistoryView { record in
                    model.restore(record)
                    showingHistory = false
                }
            }
            .sheet(isPresented: $showingBookmarks) {
                // 整理的是已保存的普通收藏，不把私密页面或私密任务身份交给持久化执行器。
                AgentCenterView(currentURL: browser.profile.isPrivate ? nil : browser.activeTab?.url,
                                profileID: browser.standardProfileID, isPrivateProfile: false, dataStore: browser.dataStore)
            }
            .sheet(isPresented: $showingOperations) { BrowserOperationsView() }
            .sheet(isPresented: $showingScripts) { WebsiteEnhancementsView() }
            .sheet(isPresented: Binding(get: { model.consent != nil }, set: { if !$0 { model.dismissConsent() } })) {
                NavigationStack {
                    Form {
                        Section("模型服务") {
                            Text(model.consent?.configuration.endpoint ?? "")
                            Text(model.consent?.configuration.model ?? "")
                        }
                        Section("资料范围（最多 5 个页面）") {
                            ForEach(model.snapshots) { source in
                                VStack(alignment: .leading) {
                                    Text(source.title)
                                    Text(source.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(model.consent?.goal ?? "")
                        }
                        Section {
                            if browser.profile.isPrivate {
                                Text("你正在私密浏览。确认后，所选页面内容会离开本机，模型服务可能保留请求或回答。Aegis 不会自动保存此次任务记录。")
                                    .accessibilityIdentifier("private-model-send-notice")
                            }
                            Text("所选页面的标题和脱敏正文将发送到 \(model.consent?.configuration.endpoint ?? "")，使用模型 \(model.consent?.configuration.model ?? "")。服务可能按用量收费。")
                            Button("确认发送") { model.send() }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("confirm-model-send")
                        }
                    }
                    .localizedNavigationTitle("将资料发送给模型？")
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { model.dismissConsent() }
                    } }
                }
            }
            .alert("保存私密分析结果？", isPresented: $confirmsPrivateSave) {
                Button("确认保存") { model.saveResult() }
                Button("取消", role: .cancel) { }
            } message: { Text("任务目标、来源网址和回答会加密保存在任务记录中，退出私密浏览后仍然保留。") }
            .alert("导出私密分析结果？", isPresented: $confirmsPrivateExport) {
                Button("继续导出") { export = true }
                Button("取消", role: .cancel) { }
            } message: { Text("回答和来源网址会写入你选择的文件，退出私密浏览后仍然保留。") }
            .fileExporter(isPresented: $export, document: TextReportDocument(text: model.report), contentType: .plainText,
                          defaultFilename: "Aegis 研究结果") { result in
                if case let .failure(failure) = result { model.error = failure }
            }
        }
        .background(AssistantSceneAttachment(lifetime: model.lifetime).frame(width: 0, height: 0))
        .onAppear { model.attach(browser: browser, settings: settings, tasks: tasks) }
        .onDisappear { model.revoke(clearSources: true) }
        .onChange(of: browser.profile) { _, _ in model.revoke(clearSources: true); dismiss() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.revoke(clearSources: true) } }
        .onChange(of: model.status) { _, value in
            if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .announcement, argument: AegisLocalization.string(value)) }
        }
    }

    private var presets: some View {
        ViewThatFits(in: .horizontal) {
            HStack { presetButtons }
            VStack(alignment: .leading) { presetButtons }
        }
        .disabled(model.busy)
    }
    @ViewBuilder private var presetButtons: some View {
        Button("摘要") { model.goal = AegisLocalization.string("总结主要内容，并给出来源引用。") }
        Button("翻译") { model.goal = AegisLocalization.string("将正文完整翻译为简体中文；如果篇幅过长，请明确标注未完成的范围。") }
        Button("研究比较") { model.goal = AegisLocalization.string("比较所选来源的观点、证据和分歧，逐项引用，说明资料不足之处。") }
        Button("商品比较") { model.goal = AegisLocalization.string("比较所选页面的商品、价格和规格，列出来源；说明未知的运费、库存和时效。") }
    }
    private var sourceSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("资料范围（最多 5 个页面）").font(.headline)
            ForEach(browser.visibleTabs) { tab in
                Toggle(isOn: Binding(get: { model.selected.contains(tab.id) }, set: { value in
                    model.select(tab.id, included: value)
                })) {
                    VStack(alignment: .leading) {
                        Text(tab.title).lineLimit(2)
                        Text(tab.url?.host ?? "起始页").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(model.busy)
            }
        }
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("发送前预览").font(.headline)
            ForEach(model.snapshots) { source in
                DisclosureGroup(source.title) {
                    if source.truncated { Text("此页面正文较长，仅使用前 24,000 个字符。").font(.caption).foregroundStyle(.orange) }
                    Text(PIIScanner.scan(source.text).redacted).font(.callout).textSelection(.enabled)
                }
            }
            Text("检测到的个人信息会脱敏；发现密钥或登录令牌会停止发送。请仍检查预览内容。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("使用模型分析") {
                model.requestConsent()
            }.buttonStyle(.borderedProminent).disabled(model.busy).accessibilityIdentifier("analyze-pages")
        }
    }
    private var result: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.outputComplete ? "分析结果" : "尚未完成的回答").font(.headline)
            Text(model.output).textSelection(.enabled).accessibilityIdentifier("assistant-output")
            Text(model.outputComplete ? "AI 生成内容，请结合下方原文核对。" : "当前内容尚未完成核对，不能保存为完成结果。")
                .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("assistant-output-status")
            ForEach(Array(model.snapshots.enumerated()), id: \.element.id) { index, source in
                Button {
                    browser.navigate(address: source.url.absoluteString)
                    dismiss()
                } label: { Label("[\(index + 1)] \(source.title)", systemImage: "link") }
            }
            if model.outputComplete {
                Button("加密保存研究结果") {
                    if browser.profile.isPrivate { confirmsPrivateSave = true } else { model.saveResult() }
                }.accessibilityIdentifier("save-assistant-report")
            }
            Button("导出结果与来源") {
                if browser.profile.isPrivate { confirmsPrivateExport = true } else { export = true }
            }.disabled(!model.outputComplete)
        }
    }
}
