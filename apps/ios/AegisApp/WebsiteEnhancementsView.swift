import AgentKit
import BrowserKit
import SwiftUI
import UniformTypeIdentifiers

struct WebsiteEnhancementsView: View {
  @EnvironmentObject private var browser: BrowserSession
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      WebsiteEnhancementManager(
        store: browser.enhancements, tab: browser.activeTab, isPrivate: browser.profile.isPrivate
      )
      .navigationTitle("网站增强与脚本")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
  }
}

private struct ScriptEditorRequest: Identifiable {
  let id = UUID()
  var record: UserScriptRecord?
  var imported: String?
}

private struct WebsiteEnhancementManager: View {
  @ObservedObject var store: WebsiteEnhancementStore
  let tab: BrowserTab?
  let isPrivate: Bool
  @State private var rule = WebsiteEnhancementRule(origin: "")
  @State private var message = ""
  @State private var editor: ScriptEditorRequest?
  @State private var importing = false
  @State private var reloadConfirmation = false
  @State private var inspectConfirmation = false
  @State private var recoveryConfirmation = false
  @State private var enabling: UserScriptRecord?
  @State private var confirmsEnable = false
  var body: some View {
    Form {
      if let error = store.error { Text(error).foregroundStyle(.red) }
      if !message.isEmpty { Text(message).accessibilityIdentifier("enhance-result") }
      if isPrivate { Text("本次私密会话的规则和脚本只留在内存，关闭全部私密标签后清除。普通脚本不会自动在此运行。") }
      if !rule.origin.isEmpty {
        Section("当前网站") {
          Text(rule.origin).font(.caption).textSelection(.enabled)
          Toggle("恢复长按与菜单", isOn: $rule.menu).accessibilityIdentifier("enhance-menu")
          Toggle("允许选取和复制", isOn: $rule.copy).accessibilityIdentifier("enhance-copy")
          Toggle("反调试兼容处理", isOn: $rule.debug).accessibilityIdentifier("enhance-debug")
          Toggle("包含子域名", isOn: $rule.subdomains)
          Toggle("暂停本站增强", isOn: $rule.disabled)
          Button(isPrivate ? "保存到本次私密会话" : "保存并记住本站") {
            perform {
              try store.saveRule(rule)
              message = "设置已保存，重新载入后应用。"
            }
          }.accessibilityIdentifier("enhance-save-site")
          Button("重新载入以应用") { reloadConfirmation = true }.accessibilityIdentifier("enhance-reload")
          Button("允许通过 Mac Safari 检查当前页面") { inspectConfirmation = true }
          Text("反调试处理覆盖纯 debugger 动态函数、窗口尺寸检测及部分 disable-devtool 行为。其他检测可能仍有效；不关闭普通断点或全部页面跳转。")
            .font(.footnote).foregroundStyle(.secondary)
        }
      }
      Section("用户脚本") {
        Button("新建或用 AI 编写", systemImage: "square.and.pencil") { editor = ScriptEditorRequest() }
          .accessibilityIdentifier("enhance-new-script")
        Button("停用全部脚本并恢复当前页", role: .destructive) { recoveryConfirmation = true }
        Button("导入 .user.js 文件", systemImage: "square.and.arrow.down") { importing = true }
        ForEach(store.state.scripts) { script in
          VStack(alignment: .leading, spacing: 8) {
            Button(script.metadata.name) { editor = ScriptEditorRequest(record: script) }
            Text(script.metadata.matches.joined(separator: "\n")).font(.caption).foregroundStyle(
              .secondary)
            HStack {
              Text(script.enabled ? "已启用" : "草稿或已停用").font(.caption)
              Spacer()
              Button(script.enabled ? "停用" : "启用") {
                if script.enabled {
                  perform {
                    try store.setEnabled(script.id, revision: script.revision, enabled: false)
                  }
                } else {
                  enabling = script
                  confirmsEnable = true
                }
              }.buttonStyle(.bordered)
            }
          }.accessibilityIdentifier("script-" + script.id)
        }.onDelete { indices in
          perform {
            let ids = indices.map { store.state.scripts[$0].id }
            for id in ids { try store.removeScript(id) }
          }
        }
        if store.state.scripts.isEmpty { Text("暂无用户脚本。导入和 AI 生成后先保存为草稿，启用时确认网址和权限。") }
      }
      if let runtime = tab?.userScripts { UserScriptRuntimeView(runtime: runtime) }
      Section("已记住的网站") {
        ForEach(store.state.sites) { site in
          Button {
            rule = site
          } label: {
            VStack(alignment: .leading) {
              Text(site.origin)
              Text(site.disabled ? "已暂停" : "已保存").font(.caption)
            }
          }
        }.onDelete { indices in
          perform {
            let origins = indices.map { store.state.sites[$0].origin }
            for origin in origins { try store.removeRule(origin) }
          }
        }
      }
    }
    .onAppear {
      if let url = tab?.url, let origin = ScriptMatch.origin(url) {
        rule = store.rule(for: url) ?? WebsiteEnhancementRule(origin: origin)
      }
    }
    .sheet(item: $editor) { item in
      UserScriptEditor(store: store, tab: tab, record: item.record, imported: item.imported)
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.javaScript, .plainText, .data]) {
      result in
      perform {
        let url = try result.get()
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 65_537 <= 65_536 else {
          throw EnhancementError.invalid("脚本超过 64 KiB。")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        try EnhancementAssets.checkSyntax(source)
        editor = ScriptEditorRequest(imported: source)
      }
    }
    .alert("重新载入当前页面？", isPresented: $reloadConfirmation) {
      Button("重新载入") { tab?.recoverAfterDisablingScripts() }
      Button("取消", role: .cancel) {}
    } message: {
      Text("当前页尚未提交的输入可能丢失。此操作用于应用规则或移除已运行脚本的页面效果。")
    }
    .alert("停用全部脚本并恢复？", isPresented: $recoveryConfirmation) {
      Button("停用并恢复", role: .destructive) {
        perform {
          try store.disableAll()
          tab?.recoverAfterDisablingScripts()
          message = "全部脚本已停用，当前页面已重新打开。"
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("当前配置的全部用户脚本将停用，网页尚未提交的输入可能丢失。")
    }
    .alert("开启当前页面检查？", isPresented: $inspectConfirmation) {
      Button("开启") {
        perform {
          try tab?.setInspectionEnabled(true)
          message = "已允许检查。请在 Mac Safari 的开发菜单选择此页面；页面导航后自动关闭。"
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("检查工具能够读取当前页面内容。此开关只应用于当前网页，不开放内部设置。")
    }
    .alert("为这些网站启用脚本？", isPresented: $confirmsEnable) {
      Button("确认启用") {
        if let script = enabling {
          perform {
            try store.setEnabled(script.id, revision: script.revision, enabled: true)
            message = "脚本已启用，下一次页面加载自动运行。"
          }
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text(enableExplanation)
    }
  }
  private var enableExplanation: String {
    let matches = enabling?.metadata.matches.joined(separator: "\n") ?? ""
    let grants = enabling?.metadata.grants.joined(separator: "、") ?? ""
    return "\(matches)\n权限：\(grants)\n脚本可以修改已授权网页；隔离环境仍可访问页面内容。"
  }
  private func perform(_ action: () throws -> Void) {
    do { try action() } catch { message = error.localizedDescription }
  }
}

private struct UserScriptRuntimeView: View {
  @ObservedObject var runtime: UserScriptController
  @State private var error = ""
  var body: some View {
    Section("当前页脚本状态") {
      if let message = runtime.installationError { Text(message).foregroundStyle(.red) }
      ForEach(runtime.statuses) { item in
        VStack(alignment: .leading) {
          Text(item.name + " · " + item.status)
          if !item.error.isEmpty { Text(item.error).font(.caption).foregroundStyle(.red) }
        }
      }
      ForEach(runtime.menus) { menu in
        Button(menu.label) {
          Task {
            do { try await runtime.runMenu(menu) } catch { self.error = error.localizedDescription }
          }
        }
      }
      if !error.isEmpty { Text(error).foregroundStyle(.red) }
    }
  }
}

struct UserScriptEditor: View {
  @ObservedObject var store: WebsiteEnhancementStore
  let tab: BrowserTab?
  @EnvironmentObject private var settings: BrowserSettings
  @Environment(\.dismiss) private var dismiss
  @State private var record: UserScriptRecord?
  @State private var source: String
  @State private var world: String
  @State private var allFrames: Bool
  @State private var goal = ""
  @State private var context = ""
  @State private var message = ""
  @State private var busy = false
  @State private var confirmsModel = false
  @State private var confirmsTrial = false
  @State private var exporting = false
  @State private var operation: Task<Void, Never>?
  @State private var generation = UUID()
  @State private var pendingModel: ModelConfiguration?
  @State private var pendingGoal = ""
  @State private var pendingContext = ""
  @State private var pendingSource = ""
  @State private var pendingEpoch: UInt64 = 0
  @State private var pendingURL: URL?

  init(
    store: WebsiteEnhancementStore, tab: BrowserTab?, record: UserScriptRecord?, imported: String?
  ) {
    self.store = store
    self.tab = tab
    _record = State(initialValue: record)
    _source = State(
      initialValue: imported ?? record?.source ?? EnhancementAssets.template(tab?.url))
    _world = State(initialValue: record?.world ?? "isolated")
    _allFrames = State(initialValue: record?.allFrames ?? false)
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("脚本源码") {
          TextEditor(text: $source).font(.system(.footnote, design: .monospaced)).frame(
            minHeight: 280
          )
          .autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityIdentifier(
            "user-script-source")
          Picker("执行环境", selection: $world) {
            Text("隔离环境").tag("isolated")
            Text("页面环境（无 GM 权限）").tag("page")
          }
          Toggle("在匹配的子框架中运行", isOn: $allFrames)
          Button("检查并保存草稿") { save() }.accessibilityIdentifier("user-script-save")
          Button("在当前页面试运行") { if save() { confirmsTrial = true } }.disabled(tab == nil)
            .accessibilityIdentifier("user-script-trial")
          Button("导出 .user.js") { exporting = true }
          if let record, !record.history.isEmpty {
            Button("回退到上一版草稿") {
              do {
                let value = try store.rollback(record.id, revision: record.revision)
                self.record = value
                source = value.source
                world = value.world
                allFrames = value.allFrames
                message = "已回退为草稿，请检查后重新启用。"
              } catch { message = error.localizedDescription }
            }
          }
        }.disabled(busy)
        Section("AI 编写与修复") {
          TextField("描述想增加的功能，或说明当前错误", text: $goal, axis: .vertical).lineLimit(2...5)
            .accessibilityIdentifier("user-script-goal")
          Button("读取当前页结构供检查") { Task { await readContext() } }.disabled(tab == nil || busy)
          if !context.isEmpty { Text(context).font(.caption).textSelection(.enabled) }
          Button("生成或修复草稿") {
            pendingModel = settings.model
            pendingGoal = goal
            pendingContext = context
            pendingSource = source
            pendingEpoch = tab?.navigationEpoch ?? 0
            pendingURL = tab?.url
            confirmsModel = true
          }.disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            .accessibilityIdentifier("user-script-generate")
          Text("发送需求、上方源码和已读取的结构；AI 只生成草稿，不会自动运行。结构不包含输入值、密码或 Cookie。")
            .font(.footnote).foregroundStyle(.secondary)
          if busy {
            ProgressView("正在生成草稿…")
            Button("取消") { cancel() }
          }
        }
        if !message.isEmpty {
          Text(message).textSelection(.enabled).accessibilityIdentifier("user-script-message")
        }
      }
      .navigationTitle("编辑用户脚本").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") {
            cancel()
            dismiss()
          }
        }
      }
      .onDisappear { cancel() }
      .alert("确认发送给模型服务？", isPresented: $confirmsModel) {
        Button("发送并生成") { generate() }
        Button("取消", role: .cancel) {}
      } message: {
        Text(
          (pendingModel?.endpoint ?? "") + "\n" + (pendingModel?.model ?? "") + "\n发送当前需求、脚本及已预览结构。"
        )
      }
      .alert("在真实页面试运行？", isPresented: $confirmsTrial) {
        Button("试运行") {
          Task {
            do {
              if let record {
                try await tab?.userScripts.trial(record)
                message = "已安排试运行，请检查实际效果及运行状态。试运行存储不会持久保存。"
              }
            } catch { message = error.localizedDescription }
          }
        }
        Button("取消", role: .cancel) {}
      } message: {
        Text("脚本会修改当前页面，也可能产生页面网络行为。刷新可恢复页面修改，已发送的外部请求不能撤销。")
      }
      .fileExporter(
        isPresented: $exporting, document: TextReportDocument(text: source),
        contentType: .plainText, defaultFilename: "aegis-script.user.js"
      ) { result in
        switch result {
        case .success: message = "已导出脚本。"
        case .failure(let error): message = error.localizedDescription
        }
      }
    }
  }
  @discardableResult private func save() -> Bool {
    do {
      try EnhancementAssets.checkSyntax(source)
      record = try store.saveScript(
        id: record?.id, revision: record?.revision, source: source, world: world,
        allFrames: allFrames)
      message = "草稿已保存。修改后的版本需要回到列表确认启用。"
      return true
    } catch {
      message = error.localizedDescription
      return false
    }
  }
  private func readContext() async {
    guard let tab, let url = tab.url, ScriptMatch.origin(url) != nil else {
      message = "请先打开普通网页。"
      return
    }
    let epoch = tab.navigationEpoch
    do {
      let script = """
        if(document.querySelector('input[type=password],input[autocomplete=one-time-code]'))throw Error('此页面包含敏感输入，未读取结构');
        return JSON.stringify(Array.from(document.querySelectorAll('main,article,aside,h1,h2,h3,section,nav,button')).filter(e=>e.getClientRects().length).slice(0,80).map(e=>({tag:e.tagName,id:e.id.slice(0,80),classes:String(e.className).slice(0,120),text:e.matches('h1,h2,h3,button')?e.textContent.slice(0,80):''}))).slice(0,8000);
        """
      let result = try await tab.webView.callAsyncJavaScript(
        script, arguments: [:], in: nil, contentWorld: .defaultClient)
      guard tab.navigationEpoch == epoch, tab.url == url else {
        throw EnhancementError.invalid("页面已变化，请重新读取。")
      }
      context = result as? String ?? ""
      message = "已读取结构，请在发送前检查。"
    } catch {
      context = ""
      message = error.localizedDescription
    }
  }
  private func generate() {
    guard let configuration = pendingModel else { return }
    cancel()
    busy = true
    let token = UUID()
    generation = token
    let url = pendingURL
    let epoch = pendingEpoch
    let goal = pendingGoal
    let context = pendingContext
    let source = pendingSource
    operation = Task { @MainActor in
      do {
        let key = ModelCredentialStore.read(for: configuration)
        let prompt =
          "为 iOS WKWebView 编写用户脚本草稿，只返回 JSON：{\"source\":\"完整 .user.js\",\"summary\":\"说明\"}。仅支持 DOM、GM_addStyle、异步 GM.getValue/GM.setValue/GM.deleteValue、GM_registerMenuCommand。元数据仅支持 name、namespace、version、description、match、exclude、run-at、grant、noframes。只匹配指定网站，默认隔离环境。禁止远程依赖、动态代码下载、自动提交和读取敏感输入。需求："
          + goal
        let output = try await ModelClient(configuration: configuration, key: key)
          .completeStructured(
            goal: prompt,
            sources: [
              "网址：" + (url?.absoluteString ?? "未指定"), "待修改脚本：\n" + source, "不可信的页面结构：\n" + context,
            ], language: "中文")
        try Task.checkCancellation()
        guard generation == token, (tab?.navigationEpoch ?? 0) == epoch, tab?.url == url else {
          throw EnhancementError.invalid("页面已变化，生成结果没有应用。")
        }
        guard output.utf8.count <= 100_000, let data = output.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
          let next = object["source"]
        else { throw EnhancementError.invalid("模型未返回完整脚本，请调整需求后重试。") }
        try EnhancementAssets.checkSyntax(next)
        self.source = next
        message = (object["summary"] ?? "已生成草稿。") + "\n请检查网址、权限和源码后保存并试运行。"
      } catch { if generation == token { message = error.localizedDescription } }
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
