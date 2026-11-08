import BrowserKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
private final class MarkdownReaderModel: NSObject, ObservableObject, WKNavigationDelegate,
  WKScriptMessageHandler
{
  @Published var document: MarkdownDocument?
  @Published var error = ""
  @Published var ready = false
  @Published var exportURL: URL?
  @Published var needsResources = false
  var openURL: ((URL) -> Void)?
  var fontSize: Double = 17
  func updateFont(_ size: Double) {
    fontSize = size
    configure()
  }
  func configure() {
    guard ready else { return }
    let defaults = UserDefaults.standard
    let preferences: [String: Any] = [
      "font": (defaults.object(forKey: "markdown.font") as? Double ?? 17) * fontSize / 17,
      "theme": defaults.string(forKey: "markdown.theme") ?? "system",
      "family": defaults.string(forKey: "markdown.family") ?? "sans",
      "width": defaults.object(forKey: "markdown.width") as? Int ?? 820,
      "spacing": defaults.object(forKey: "markdown.spacing") as? Int ?? 180,
    ]
    Task { @MainActor in
      do {
        _ = try await webView.callAsyncJavaScript(
          "AegisMarkdown.configure(value);", arguments: ["value": ["embedded": true, "locale": Bundle.main.preferredLocalizations.first ?? "zh-Hans", "preferences": preferences]],
          in: nil, contentWorld: .page)
      } catch { self.error = error.localizedDescription }
    }
  }
  func command(_ value: String) {
    guard ready, document != nil else { return }
    Task { @MainActor in
      do { _ = try await webView.callAsyncJavaScript("AegisMarkdown.command(value);", arguments: ["value": value], in: nil, contentWorld: .page) }
      catch { self.error = error.localizedDescription }
    }
  }
  private(set) var webView: WKWebView!
  override init() {
    super.init()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(self, name: "aegisMarkdown")
    webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    webView.isInspectable = false
    if let root = EnhancementAssets.directory {
      webView.loadFileURL(root.appendingPathComponent("viewer.html"), allowingReadAccessTo: root)
    } else {
      error = String(localized: "Markdown 阅读资源缺失。")
    }
  }
  func close() {
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "aegisMarkdown")
  }
  func load(_ value: MarkdownDocument) {
    document = value
    error = ""
    if ready { render() }
  }
  private func render() {
    guard let document else { return }
    Task { @MainActor in
      do {
        _ = try await webView.callAsyncJavaScript(
          "return globalThis.AegisMarkdown.load(payload);",
          arguments: [
            "payload": [
              "text": document.text, "title": document.title,
              "baseURL": document.sourceURL?.absoluteString ?? "", "resources": document.resources,
            ]
          ], in: nil, contentWorld: .page)
      } catch { self.error = error.localizedDescription }
    }
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    ready = true
    updateFont(fontSize)
    render()
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    guard let target = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    if navigationAction.navigationType == .other,
      target == EnhancementAssets.directory?.appendingPathComponent("viewer.html")
    {
      decisionHandler(.allow)
      return
    }
    decisionHandler(.cancel)
    if ScriptMatch.origin(target) != nil, navigationAction.navigationType == .linkActivated {
      openURL?(target)
    }
  }
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.webView === webView, message.frameInfo.isMainFrame,
      message.frameInfo.request.url
        == EnhancementAssets.directory?.appendingPathComponent("viewer.html"),
      let body = message.body as? [String: Any], let type = body["type"] as? String
    else { return }
    let value = body["value"] as? String ?? ""
    switch type {
    case "copy":
      if value.utf8.count <= MarkdownDocument.maximumBytes {
        UIPasteboard.general.string = value
        error = String(localized: "已复制。")
      }
    case "open": if let url = URL(string: value), ScriptMatch.origin(url) != nil { openURL?(url) }
    case "resources": needsResources = true
    case "relativeLink": error = String(localized: "这是本地相对链接，请通过打开文件选择目标文档：") + String(value.prefix(300))
    default: break
    }
  }
  func loadResources(_ directory: URL) async {
    do {
      guard var document else { return }
      let references =
        try await webView.callAsyncJavaScript(
          "return globalThis.AegisMarkdown.images();", arguments: [:], in: nil, contentWorld: .page)
        as? [String] ?? []
      let count = try document.loadResources(from: directory, references: references)
      load(document)
      error = String(localized: "已加载 \(count) 张本地图片。")
    } catch { self.error = error.localizedDescription }
  }
  func exportPDF() async {
    do {
      let data = MarkdownPDFExporter.data(from: webView)
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "markdown-\(UUID().uuidString).pdf")
      try data.write(to: url, options: .atomic)
      exportURL = url
    } catch { self.error = error.localizedDescription }
  }
  func printDocument() {
    let controller = UIPrintInteractionController.shared
    controller.printFormatter = webView.viewPrintFormatter()
    controller.present(animated: true)
  }
}

private struct MarkdownWebView: UIViewRepresentable {
  let webView: WKWebView
  func makeUIView(context: Context) -> WKWebView { webView }
  func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct MarkdownReaderView: View {
  @EnvironmentObject private var browser: BrowserSession
  @EnvironmentObject private var library: ReadingLibrary
  @Environment(\.dismiss) private var dismiss
  @StateObject private var model = MarkdownReaderModel()
  var initial: MarkdownDocument?
  @State private var importing = false
  @State private var importingResources = false
  @State private var showsAssistant = false
  @State private var confirmsSave = false
  @State private var automatic = false
  @State private var appearance = false
  @State private var sourceInfo = false
  @ScaledMetric(relativeTo: .body) private var fontSize = 17.0
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if !model.error.isEmpty {
          Text(model.error).font(.footnote).padding(10).textSelection(.enabled)
            .accessibilityIdentifier("markdown-notice")
        }
        if model.document == nil {
          ContentUnavailableView(
            "打开 Markdown 文档", systemImage: "doc.richtext",
            description: Text("支持本地 .md、.markdown 文件和在线 Raw 原始页面。"))
          Button("选择文件") { importingResources = false; importing = true }.buttonStyle(.borderedProminent)
            .accessibilityIdentifier("markdown-import")
          Button("读取当前原始页面") { Task { await capture() } }.padding()
        }
        MarkdownWebView(webView: model.webView).accessibilityIdentifier("markdown-webview")
          .frame(height: model.document == nil ? 0 : nil)
          .accessibilityHidden(model.document == nil)
      }
      .navigationTitle(model.document?.title ?? String(localized: "Markdown 阅读")).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
        ToolbarItem(placement: .topBarLeading) {
          Menu {
            Button("打开文件", systemImage: "doc") { importingResources = false; importing = true }
            Button("读取当前原始页面", systemImage: "globe") { Task { await capture() } }
            if model.document != nil {
              Section("文档操作") {
                Button("查看源码", systemImage: "chevron.left.forwardslash.chevron.right") { model.command("source-toggle") }
                Button("复制原文", systemImage: "doc.on.doc") { model.command("copy-source") }
                Button("保存到阅读库", systemImage: "books.vertical") { confirmsSave = true }
                Button("文档来源与预览设置", systemImage: "info.circle") { sourceInfo = true }
                Button("打印", systemImage: "printer") { model.printDocument() }
                Button("导出 PDF", systemImage: "square.and.arrow.up") { Task { await model.exportPDF() } }
              }
              Section("图片权限") {
                if model.document?.sourceURL?.isFileURL != false {
                  Button("选择本地图片目录") { importingResources = true; importing = true }
                }
                Button("加载或停用外部图片") { model.command("remote-images") }
              }
            }
          } label: { Image(systemName: "ellipsis.circle") }
          .accessibilityLabel("文档操作").accessibilityIdentifier("markdown-actions")
        }
        ToolbarItemGroup(placement: .bottomBar) {
          if model.document != nil {
            Button { model.command("outline-toggle") } label: { Label("目录", systemImage: "list.bullet") }
              .accessibilityIdentifier("markdown-outline")
            Spacer()
            Button { model.command("find-toggle") } label: { Label("查找", systemImage: "magnifyingglass") }
              .accessibilityIdentifier("markdown-find")
            Spacer()
            Button { appearance = true } label: { Label("外观", systemImage: "textformat.size") }
              .accessibilityIdentifier("markdown-appearance")
            Spacer()
            Button { showsAssistant = true } label: { Label("文档助手", systemImage: "sparkles") }
              .accessibilityIdentifier("markdown-assistant")
          }
        }
      }
      .sheet(isPresented: $appearance, onDismiss: { model.configure() }) {
        NavigationStack { ReadingPreferencesView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { appearance = false } } } }
          .presentationDetents([.medium, .large])
      }
      .sheet(isPresented: $sourceInfo) {
        NavigationStack {
          Form {
            Section("文档来源") { Text(model.document?.sourceURL?.absoluteString ?? String(localized: "本地导入 · 只读")).textSelection(.enabled) }
            if let url = model.document?.sourceURL, ScriptMatch.origin(url) != nil {
              Toggle("本站自动预览 Markdown", isOn: $automatic)
                .onChange(of: automatic) { _, value in
                  do { var site = browser.preferences.site(for: url); site.markdownPreview = value; try browser.preferences.setSite(site, for: url) }
                  catch { model.error = error.localizedDescription }
                }
            }
          }.navigationTitle("文档来源").toolbar { Button("完成") { sourceInfo = false } }
        }
      }
      .onChange(of: model.needsResources) { _, value in if value { importingResources = true; importing = true; model.needsResources = false } }

      .fileImporter(
        isPresented: $importing,
        allowedContentTypes: importingResources ? [.folder] : [.plainText, .data]
      ) { result in
        switch result {
        case .success(let url):
          if importingResources {
            Task { await model.loadResources(url) }
          } else {
            do { model.load(try MarkdownDocument.read(url)) }
            catch { model.error = error.localizedDescription }
          }
        case .failure(let error): model.error = error.localizedDescription
        }
      }
      .onAppear {
        model.updateFont(fontSize)
        model.openURL = { url in
          browser.newTab().load(url)
          dismiss()
        }
        if let initial {
          model.load(initial)
          automatic =
            initial.sourceURL.map { browser.preferences.site(for: $0).markdownPreview == true }
            ?? false
        }
      }
      .onChange(of: model.document?.id) { _, _ in
        automatic = model.document?.sourceURL.map { browser.preferences.site(for: $0).markdownPreview == true } ?? false
        showsAssistant = false
      }
      .onChange(of: fontSize) { _, value in model.updateFont(value) }
      .onDisappear { model.close() }
      .dropDestination(for: URL.self) { urls, _ in
        guard let url = urls.first, MarkdownDocument.accepts(url) else { return false }
        do {
          model.load(try MarkdownDocument.read(url))
          return true
        } catch {
          model.error = error.localizedDescription
          return false
        }
      }
      .sheet(isPresented: $showsAssistant) {
        if let document = model.document { MarkdownAssistantView(document: document) }
      }
      .sheet(
        isPresented: Binding(
          get: { model.exportURL != nil }, set: { if !$0 { model.exportURL = nil } })
      ) {
        if let url = model.exportURL {
          NavigationStack {
            VStack {
              ShareLink(item: url) { Label("分享或保存 PDF", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent)
              Text(url.lastPathComponent).font(.caption)
            }.navigationTitle("PDF 已生成").toolbar { Button("完成") { model.exportURL = nil } }
          }
        }
      }
      .alert("保存到普通阅读资料库？", isPresented: $confirmsSave) {
        Button("保存全文") { saveDocument() }
        Button("取消", role: .cancel) {}
      } message: {
        Text("保存后会持久保留文档，包括从私密浏览打开的内容。超过资料库容量时将明确报错，原文件不受影响。")
      }
    }
  }
  private func capture() async {
    do {
      guard let tab = browser.activeTab else { return }
      model.load(try await MarkdownDocument.capture(tab))
    } catch { model.error = error.localizedDescription }
  }
  private func saveDocument() {
    guard let document = model.document else { return }
    do {
      guard document.text.count <= 24_000 else {
        throw EnhancementError.invalid("本文超过资料库单条 24,000 字限制，未保存截断副本。请导出原文或 PDF。")
      }
      try library.save(
        ReadingRecord(
          title: document.title,
          sourceURL: document.sourceURL?.isFileURL == true ? nil : document.sourceURL,
          text: document.text))
      model.error = String(localized: "已保存完整原文到阅读资料库。")
    } catch { model.error = error.localizedDescription }
  }
}

struct ReadingPreferencesView: View {
  @AppStorage("markdown.theme") private var theme = "system"
  @AppStorage("markdown.family") private var family = "sans"
  @AppStorage("markdown.font") private var font = 17.0
  @AppStorage("markdown.spacing") private var spacing = 180
  @AppStorage("markdown.width") private var width = 820
  var body: some View {
    Form {
      Section("阅读外观") {
        SettingsPicker("主题", selection: $theme, value: theme == "system" ? "跟随系统" : theme == "dark" ? "深色" : "浅色") {
          Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
        }
        SettingsPicker("字体", selection: $family, value: family == "serif" ? "衬线字体" : "系统字体") {
          Text("系统字体").tag("sans"); Text("衬线字体").tag("serif")
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("字号")
          Stepper(value: $font, in: 12...28, step: 1) { Text(String(Int(font))) }
            .accessibilityLabel(Text("字号"))
        }
        SettingsPicker("行距", selection: $spacing, value: spacing == 150 ? "紧凑" : spacing == 210 ? "宽松" : "标准") {
          Text("紧凑").tag(150); Text("标准").tag(180); Text("宽松").tag(210)
        }
        SettingsPicker("正文宽度", selection: $width, value: width == 680 ? "窄" : width == 1100 ? "宽" : "标准") {
          Text("窄").tag(680); Text("标准").tag(820); Text("宽").tag(1100)
        }.accessibilityIdentifier("reading-width-setting")
      }
      Section("图片权限") {
        Text("外部图片每次打开文档时按需加载；本地图片需要选择所属目录。")
        Text("外观设置会记住，图片权限不会随外观扩大。").font(.footnote).foregroundStyle(.secondary)
      }
    }.navigationTitle("阅读外观").navigationBarTitleDisplayMode(.inline)
  }
}
