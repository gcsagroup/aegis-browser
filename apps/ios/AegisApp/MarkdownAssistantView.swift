import AgentKit
import BrowserKit
import SwiftUI

struct MarkdownAssistantView: View {
  let document: MarkdownDocument
  @EnvironmentObject private var settings: BrowserSettings
  @Environment(\.dismiss) private var dismiss
  @State private var goal = "总结文档要点，并保留必要来源引用。"
  @State private var input = ""
  @State private var output = ""
  @State private var error = ""
  @State private var confirms = false
  @State private var busy = false
  @State private var operation: Task<Void, Never>?
  @State private var generation = UUID()
  @State private var destination: ModelConfiguration?
  @State private var pendingInput = ""
  @State private var pendingGoal = ""
  private var modelConsentMessage: String {
    let endpoint = destination?.endpoint ?? ""
    let model = destination?.model ?? ""
    return "\(endpoint)\n\(model)\n发送已预览文本，不发送本地文件路径。"
  }
  var body: some View {
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
            destination = settings.model
            pendingInput = input
            pendingGoal = goal
            confirms = true
          }.disabled(busy || input.isEmpty || input.utf8.count > 32_768)
        }.disabled(busy)
        if busy {
          ProgressView("正在处理…")
          Button("取消") { cancel() }
        }
        if !error.isEmpty { Text(error).foregroundStyle(.red) }
        if !output.isEmpty {
          Section("结果") {
            Text(output).textSelection(.enabled)
            Button("复制结果") { UIPasteboard.general.string = output }
          }
        }
      }
      .navigationTitle("文档助手").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        Button("完成") {
          cancel()
          dismiss()
        }
      }
      .onAppear { input = document.text }
      .onDisappear { cancel() }
      .alert("发送所选文档内容？", isPresented: $confirms) {
        Button("发送") { generate() }
        Button("取消", role: .cancel) {}
      } message: {
        Text(modelConsentMessage)
      }
    }
  }
  private func generate() {
    guard let destination else { return }
    cancel()
    busy = true
    error = ""
    let token = UUID()
    generation = token
    let goal = pendingGoal
    let input = pendingInput
    operation = Task { @MainActor in
      do {
        let result = try await ModelClient(
          configuration: destination, key: ModelCredentialStore.read(for: destination)
        ).complete(goal: goal, sources: [input], language: "中文")
        try Task.checkCancellation()
        if generation == token { output = result }
      } catch { if generation == token { self.error = error.localizedDescription } }
      if generation == token {
        busy = false
        operation = nil
      }
    }
  }
  private func cancel() {
    generation = UUID()
    operation?.cancel()
    operation = nil
    busy = false
  }
}
