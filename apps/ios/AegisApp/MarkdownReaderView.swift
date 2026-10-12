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
  var openURL: ((URL) -> Void)?
  var fontSize: Double = 17
  func updateFont(_ size: Double) {
    fontSize = size
    guard ready else { return }
    Task {
      _ = try? await webView.callAsyncJavaScript(
        "AegisMarkdown.setFont(size);", arguments: ["size": size], in: nil, contentWorld: .page)
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
      error = "Markdown 阅读资源缺失。"
    }
  }
  func close() {
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "aegisMarkdown")
  }
  func load(_ value: MarkdownDocument) {
    document = value
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
        error = "已复制。"
      }
    case "open": if let url = URL(string: value), ScriptMatch.origin(url) != nil { openURL?(url) }
    case "relativeLink": error = "这是本地相对链接，请通过打开文件选择目标文档：" + String(value.prefix(300))
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
      error = "已加载 \(count) 张本地图片。"
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
  @State private var resources = false
  @State private var showsAssistant = false
  @State private var confirmsSave = false
  @State private var automatic = false
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
          Button("选择文件") { importing = true }.buttonStyle(.borderedProminent)
            .accessibilityIdentifier("markdown-import")
          Button("读取当前原始页面") { Task { await capture() } }.padding()
        }
        MarkdownWebView(webView: model.webView).accessibilityIdentifier("markdown-webview")
      }
      .navigationTitle("Markdown 阅读").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
        ToolbarItem(placement: .topBarLeading) {
          Menu {
            Button("打开文件") { importing = true }
            Button("读取当前原始页面") { Task { await capture() } }
            Button("选择本地图片目录") { resources = true }.disabled(model.document == nil)
            Button("保存到阅读资料库") { confirmsSave = true }.disabled(model.document == nil)
            Button("AI 总结与翻译") { showsAssistant = true }.disabled(model.document == nil)
            Button("打印") { model.printDocument() }.disabled(model.document == nil)
            Button("导出 PDF") { Task { await model.exportPDF() } }.disabled(model.document == nil)
            if let url = model.document?.sourceURL, ScriptMatch.origin(url) != nil {
              Toggle("本站自动预览 Markdown", isOn: $automatic)
                .onChange(of: automatic) { _, value in
                  do {
                    var site = browser.preferences.site(for: url)
                    site.markdownPreview = value
                    try browser.preferences.setSite(site, for: url)
                  } catch { model.error = error.localizedDescription }
                }
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
        }
      }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .data]) { result in
        do { model.load(try MarkdownDocument.read(result.get())) } catch {
          model.error = error.localizedDescription
        }
      }
      .fileImporter(isPresented: $resources, allowedContentTypes: [.folder]) { result in
        switch result {
        case .success(let url): Task { await model.loadResources(url) }
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
      model.error = "已保存完整原文到阅读资料库。"
    } catch { model.error = error.localizedDescription }
  }
}
