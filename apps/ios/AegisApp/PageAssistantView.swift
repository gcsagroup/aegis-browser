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
    @State private var selected: Set<UUID> = []
    @State private var goal = String(localized: "总结主要内容，并给出来源引用。")
    @State private var snapshots: [PageSnapshot] = []
    @State private var output = ""
    @State private var outputComplete = false
    @State private var status = String(localized: "准备中")
    @State private var error: String?
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var showingBookmarks = false
    @State private var showingSendConfirmation = false
    @State private var export = false
    @State private var pendingConfiguration: ModelConfiguration?
    @State private var pendingGoal = ""
    @State private var taskID: UUID?
    @State private var showingHistory = false
    @State private var confirmsPrivateSave = false
    @State private var confirmsPrivateExport = false
    @State private var resultGoal = ""
    @FocusState private var goalFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label(status, systemImage: busy ? "hourglass" : "sparkles")
                        .font(.headline).accessibilityIdentifier("assistant-status")
                    Text("用当前页面或选中的标签页完成摘要、翻译、研究和商品比较。")
                        .foregroundStyle(.secondary)
                    Button("任务记录与继续", systemImage: "clock.arrow.circlepath") { goalFocused = false; showingHistory = true }
                        .accessibilityIdentifier("assistant-history")
                    if let storageError = tasks.storageError { Text(storageError).foregroundStyle(.red) }
                    if browser.profile.isPrivate {
                        Text("私密分析只在本次界面保留，不自动保存任务、来源网址或回答。发送前会说明模型服务；主动保存或导出后，结果会保留在设备上。")
                            .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("private-assistant-notice")
                    }
                    presets
                    TextField("你想了解什么？", text: $goal, axis: .vertical)
                        .lineLimit(3...6).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("assistant-goal")
                        .focused($goalFocused)
                        .disabled(busy)
                    sourceSelection
                    Button("读取所选页面") { readPages() }
                        .buttonStyle(.borderedProminent).disabled(busy || selected.isEmpty || !browser.agentIsAvailable)
                        .accessibilityIdentifier("read-pages")
                    Text("只读取所选页面的正文，不读取输入框、密码或 Cookie。此步骤不联系模型服务。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !snapshots.isEmpty { preview }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).accessibilityIdentifier("assistant-error")
                        if !snapshots.isEmpty, !busy {
                            Button("重新确认并重试") {
                                pendingConfiguration = settings.model; pendingGoal = goal; showingSendConfirmation = true
                            }.accessibilityIdentifier("retry-model-request")
                        }
                    }
                    if !output.isEmpty { result }
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
            .navigationTitle("AI 助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { cancel(); dismiss() } }
                if busy {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消任务", role: .cancel) { cancel() }.accessibilityIdentifier("cancel-assistant")
                    }
                }
            }
            .sheet(isPresented: $showingHistory) {
                AssistantHistoryView { record in
                    cancel(); goal = record.goal; snapshots = []; output = ""; outputComplete = false; selected = []
                    for url in record.sources.prefix(5) {
                        if let tab = browser.visibleTabs.first(where: { $0.url == url }) { selected.insert(tab.id) }
                        else if browser.visibleTabs.count < 50 {
                            let tab = browser.newTab(); tab.load(url); selected.insert(tab.id)
                        }
                    }
                    status = String(localized: "任务已恢复，请重新读取页面并确认发送。")
                    showingHistory = false
                }
            }
            .sheet(isPresented: $showingBookmarks) {
                // 整理的是已保存的普通收藏，不把私密页面或私密任务身份交给持久化执行器。
                AgentCenterView(currentURL: browser.profile.isPrivate ? nil : browser.activeTab?.url,
                                profileID: browser.standardProfileID, isPrivateProfile: false, dataStore: browser.dataStore)
            }
            .sheet(isPresented: $showingSendConfirmation) {
                NavigationStack {
                    Form {
                        Section("模型服务") {
                            Text(pendingConfiguration?.endpoint ?? "")
                            Text(pendingConfiguration?.model ?? "")
                        }
                        Section("资料范围（最多 5 个页面）") {
                            ForEach(snapshots) { source in
                                VStack(alignment: .leading) {
                                    Text(source.title)
                                    Text(source.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(pendingGoal)
                        }
                        Section {
                            if browser.profile.isPrivate {
                                Text("你正在私密浏览。确认后，所选页面内容会离开本机，模型服务可能保留请求或回答。Aegis 不会自动保存此次任务记录。")
                                    .accessibilityIdentifier("private-model-send-notice")
                            }
                            Text("所选页面的标题和脱敏正文将发送到 \(pendingConfiguration?.endpoint ?? "")，使用模型 \(pendingConfiguration?.model ?? "")。服务可能按用量收费。")
                            Button("确认发送") { showingSendConfirmation = false; send() }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("confirm-model-send")
                        }
                    }
                    .navigationTitle("将资料发送给模型？")
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showingSendConfirmation = false; pendingConfiguration = nil }
                    } }
                }
            }
            .alert("保存私密分析结果？", isPresented: $confirmsPrivateSave) {
                Button("确认保存") { saveResult() }
                Button("取消", role: .cancel) { }
            } message: { Text("任务目标、来源网址和回答会加密保存在任务记录中，退出私密浏览后仍然保留。") }
            .alert("导出私密分析结果？", isPresented: $confirmsPrivateExport) {
                Button("继续导出") { export = true }
                Button("取消", role: .cancel) { }
            } message: { Text("回答和来源网址会写入你选择的文件，退出私密浏览后仍然保留。") }
            .fileExporter(isPresented: $export, document: TextReportDocument(text: report), contentType: .plainText,
                          defaultFilename: "Aegis 研究结果") { result in
                if case let .failure(failure) = result { error = failure.localizedDescription }
            }
        }
        .onAppear { if let id = browser.activeTab?.id { selected = [id] } }
        .onDisappear { cancel() }
        .onChange(of: browser.profile) { _, _ in cancel(); snapshots = []; output = ""; outputComplete = false; dismiss() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { cancel() } }
        .onChange(of: status) { _, value in
            if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .announcement, argument: value) }
        }
    }

    private var presets: some View {
        ViewThatFits(in: .horizontal) {
            HStack { presetButtons }
            VStack(alignment: .leading) { presetButtons }
        }
        .disabled(busy)
    }
    @ViewBuilder private var presetButtons: some View {
        Button("摘要") { goal = String(localized: "总结主要内容，并给出来源引用。") }
        Button("翻译") { goal = String(localized: "将正文完整翻译为简体中文；如果篇幅过长，请明确标注未完成的范围。") }
        Button("研究比较") { goal = String(localized: "比较所选来源的观点、证据和分歧，逐项引用，说明资料不足之处。") }
        Button("商品比较") { goal = String(localized: "比较所选页面的商品、价格和规格，列出来源；说明未知的运费、库存和时效。") }
    }
    private var sourceSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("资料范围（最多 5 个页面）").font(.headline)
            ForEach(browser.visibleTabs) { tab in
                Toggle(isOn: Binding(get: { selected.contains(tab.id) }, set: { value in
                    if value && selected.count < 5 { selected.insert(tab.id) } else { selected.remove(tab.id) }
                    snapshots = []; output = ""; outputComplete = false
                    browser.protectAssistantTabs([])
                })) {
                    VStack(alignment: .leading) {
                        Text(tab.title).lineLimit(2)
                        Text(tab.url?.host ?? "起始页").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(busy)
            }
        }
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("发送前预览").font(.headline)
            ForEach(snapshots) { source in
                DisclosureGroup(source.title) {
                    if source.truncated { Text("此页面正文较长，仅使用前 24,000 个字符。").font(.caption).foregroundStyle(.orange) }
                    Text(PIIScanner.scan(source.text).redacted).font(.callout).textSelection(.enabled)
                }
            }
            Text("检测到的个人信息会脱敏；发现密钥或登录令牌会停止发送。请仍检查预览内容。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("使用模型分析") {
                pendingConfiguration = settings.model
                pendingGoal = goal
                showingSendConfirmation = true
            }.buttonStyle(.borderedProminent).disabled(busy).accessibilityIdentifier("analyze-pages")
        }
    }
    private var result: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(outputComplete ? "分析结果" : "尚未完成的回答").font(.headline)
            Text(output).textSelection(.enabled).accessibilityIdentifier("assistant-output")
            Text(outputComplete ? "AI 生成内容，请结合下方原文核对。" : "当前内容尚未完成核对，不能保存为完成结果。")
                .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("assistant-output-status")
            ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, source in
                Button {
                    browser.navigate(address: source.url.absoluteString)
                    dismiss()
                } label: { Label("[\(index + 1)] \(source.title)", systemImage: "link") }
            }
            if outputComplete {
                Button("加密保存研究结果") {
                    if browser.profile.isPrivate { confirmsPrivateSave = true } else { saveResult() }
                }.accessibilityIdentifier("save-assistant-report")
            }
            Button("导出结果与来源") {
                if browser.profile.isPrivate { confirmsPrivateExport = true } else { export = true }
            }.disabled(!outputComplete)
        }
    }
    private func saveResult() {
        guard outputComplete else { return }
        do {
            if let taskID { try tasks.saveReport(report, for: taskID) }
            else if browser.profile.isPrivate {
                taskID = try tasks.saveCompletedReport(goal: resultGoal, sources: snapshots.map(\.url), report: report)
            } else { return }
            status = String(localized: "研究结果已加密保存。")
        } catch { self.error = error.localizedDescription }
    }

    private var report: String {
        output + "\n\n" + snapshots.enumerated().map { "[\($0.offset + 1)] \($0.element.title)\n\($0.element.url.absoluteString)\n\($0.element.capturedAt.formatted())" }.joined(separator: "\n\n")
    }

    private func readPages() {
        goalFocused = false
        cancel()
        error = nil; output = ""; outputComplete = false; snapshots = []; busy = true; status = String(localized: "正在读取页面")
        let current = generation
        let profile = browser.profile
        let tabs = browser.visibleTabs.filter { selected.contains($0.id) }
        browser.protectAssistantTabs(Set(tabs.map(\.id)))
        let approved = tabs.map { ($0.id, $0.url, $0.navigationEpoch) }
        operation = Task { @MainActor in
            do {
                var values: [PageSnapshot] = []
                for (index, tab) in tabs.enumerated() {
                    try Task.checkCancellation()
                    guard generation == current, browser.profile == profile, browser.agentIsAvailable,
                          tab.url == approved[index].1, tab.navigationEpoch == approved[index].2 else { throw PageSnapshotError.changed }
                    values.append(try await tab.snapshot(privateReadConfirmed: profile.isPrivate))
                }
                guard generation == current, browser.profile == profile else { return }
                snapshots = values; busy = false; status = String(localized: "等待确认发送")
            } catch {
                guard generation == current else { return }
                self.error = error.localizedDescription; busy = false; status = String(localized: "读取失败")
            }
        }
    }

    private func send() {
        guard let config = pendingConfiguration, !snapshots.isEmpty, browser.agentIsAvailable else { return }
        let sources = snapshots
        // 请求发送前重新核对页面身份。用户确认的是这些页面，不是之后的新导航。
        guard sources.allSatisfy({ source in browser.visibleTabs.contains {
            $0.id == source.id && $0.url == source.url && $0.navigationEpoch == source.navigationEpoch && !$0.isLoading
        } }) else { error = PageSnapshotError.changed.localizedDescription; return }
        let profile = browser.profile
        do {
            taskID = nil
            if !profile.isPrivate { taskID = try tasks.begin(goal: pendingGoal, sources: sources.map(\.url)) }
        }
        catch { self.error = error.localizedDescription; return }
        let recordID = taskID
        busy = true; error = nil; output = ""; outputComplete = false; status = String(localized: "正在连接模型服务")
        let current = generation
        let client = ModelClient(configuration: config, key: ModelCredentialStore.read(for: config))
        let requestedGoal = pendingGoal
        resultGoal = requestedGoal
        pendingConfiguration = nil
        operation = Task { @MainActor in
            do {
                let sourceTexts = sources.enumerated().map { "来源 [\($0.offset + 1)]：\($0.element.title)\n\($0.element.text)" }
                let text = try await client.streamComplete(goal: requestedGoal, sources: sourceTexts,
                    language: Locale.preferredLanguages.first ?? "zh-Hans") { partial in
                    guard generation == current, browser.profile == profile, browser.agentIsAvailable else { return }
                    output = partial; status = String(localized: "正在生成回答")
                }
                try Task.checkCancellation()
                guard generation == current, browser.profile == profile, browser.agentIsAvailable else { return }
                if let recordID { try tasks.finish(recordID, state: .completed) }
                output = text; outputComplete = true; busy = false; status = String(localized: "已完成")
            } catch {
                guard generation == current else { return }
                if let recordID { try? tasks.finish(recordID, state: .failed) }
                if let failure = error as? ModelClientError,
                   [.invalidCitation, .invalidResponse, .sensitiveData].contains(failure) { output = "" }
                self.error = error.localizedDescription; busy = false; status = String(localized: "分析失败")
            }
        }
    }

    private func cancel() {
        operation?.cancel(); operation = nil; generation = UUID()
        browser.protectAssistantTabs([])
        if busy, let taskID { try? tasks.finish(taskID, state: .interrupted) }
        taskID = nil
        if busy { outputComplete = false; status = String(localized: "已暂停，可重新运行") }
        busy = false; pendingConfiguration = nil
    }
}
