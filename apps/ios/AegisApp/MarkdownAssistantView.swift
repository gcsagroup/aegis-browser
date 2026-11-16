import AgentKit
import BrowserKit
import SwiftUI

struct MarkdownAssistantView: View {
  let document: MarkdownDocument
  @EnvironmentObject private var settings: BrowserSettings
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var goal = "总结文档要点，并保留必要来源引用。"
  @State private var input = ""
  @State private var output = ""
  @State private var error: AegisLocalizedMessage = .verbatim("")
  @State private var confirms = false
  @State private var busy = false
  @StateObject private var lifetime = AssistantOperationLifetime()
  @State private var consentToken: UUID?
  @State private var destination: ModelConfiguration?
  @State private var pendingInput = ""
  @State private var pendingGoal = ""
  private var modelConsentMessage: String {
    let endpoint = destination?.endpoint ?? ""
    let model = destination?.model ?? ""
    return "\(endpoint)\n\(model)\n发送已预览文本，不发送本地文件路径。"
  }
  @Environment(\.locale) private var localizationLocale
  var body: some View {
      let _ = localizationLocale
    NavigationStack {
      Form {
        Section("处理范围") {
          Text(document.title)
          Text("只发送下方可编辑的文本；最多 32 KiB。文档过长时，请保留需要处理的部分。原文件不会改写。")
          TextEditor(text: $input).frame(minHeight: 220).font(.body)
          TextField("任务", text: $goal, axis: .vertical)
          Button("总结要点") { goal = "总结文档要点，并保留必要来源引用。" }
          Button("翻译成中文") { goal = "将提供的文档完整翻译为简体中文，保留 Markdown 格式和代码，引用来源 [1]。" }
          Button("确认范围并发送") {
            guard lifetime.isCurrent(lifetime.generation) else { return }
            destination = settings.model
            pendingInput = input
            pendingGoal = goal
            consentToken = lifetime.generation
            confirms = true
          }.disabled(busy || input.isEmpty || input.utf8.count > 32_768)
        }.disabled(busy)
        if busy {
          ProgressView("正在处理…")
          Button("取消") { cancel() }
        }
        if !error.text.isEmpty { Text(error.text).foregroundStyle(.red) }
        if !output.isEmpty {
          Section("结果") {
            Text(output).textSelection(.enabled)
            Button("复制结果") { UIPasteboard.general.string = output }
          }
        }
      }
      .localizedNavigationTitle("文档助手").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        Button("完成") {
          cancel()
          dismiss()
        }
      }
      .onAppear { input = document.text }
      .onDisappear { cancel() }
      .background(AssistantSceneAttachment(lifetime: lifetime))
      .onReceive(lifetime.sceneDeactivated) { _ in cancel() }
      .onChange(of: scenePhase) { _, phase in if phase != .active { cancel() } }
      .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in cancel() }
      .alert("发送所选文档内容？", isPresented: $confirms) {
        Button("发送") { generate() }
        Button("取消", role: .cancel) { cancel() }
      } message: {
        Text(modelConsentMessage)
      }
    }
  }
  private func generate() {
    guard let destination, lifetime.isCurrent(consentToken), scenePhase == .active else { cancel(); return }
    let goal = pendingGoal
    let input = pendingInput
    cancel()
    busy = true
    error = .verbatim("")
    let token = lifetime.generation
    lifetime.operation = Task { @MainActor in
      guard lifetime.isCurrent(token), !Task.isCancelled else { return }
      do {
        let result = try await ModelClient(
          configuration: destination, key: ModelCredentialStore.read(for: destination)
        ).complete(goal: goal, sources: [input], language: AegisLocalization.current.dialect)
        try Task.checkCancellation()
        if lifetime.isCurrent(token), scenePhase == .active { output = result }
      } catch { if lifetime.isCurrent(token) { self.error = .error(error) } }
      if lifetime.isCurrent(token) {
        busy = false
        lifetime.operation = nil
      }
    }
  }
  private func cancel() {
    lifetime.invalidate()
    confirms = false; destination = nil; consentToken = nil
    pendingInput = ""; pendingGoal = ""
    busy = false
  }
}
