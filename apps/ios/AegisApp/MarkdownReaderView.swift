import BrowserKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The operation retains this lease until actual I/O returns, even after cancellation.
final class MarkdownSecurityScope: Sendable {
  private let url: URL
  private let accessed: Bool
  private let onRelease: @Sendable () -> Void
  init(_ url: URL, onRelease: @escaping @Sendable () -> Void = {}) {
    self.url = url; accessed = url.startAccessingSecurityScopedResource(); self.onRelease = onRelease
  }
  deinit { if accessed { url.stopAccessingSecurityScopedResource() }; onRelease() }
}

actor MarkdownIO {
  static let shared = MarkdownIO()
  func read(_ url: URL) throws -> MarkdownDocument {
    try Task.checkCancellation()
    return try MarkdownDocument.read(url)
  }
  func resources(_ document: MarkdownDocument, directory: URL, references: [String]) throws -> MarkdownDocument {
    try Task.checkCancellation()
    var result = document
    _ = try result.loadResources(from: directory, references: references)
    return result
  }
  func writePDF(_ data: Data) throws -> URL {
    try Task.checkCancellation()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-\(UUID().uuidString).pdf")
    try data.write(to: url, options: .atomic)
    return url
  }
  func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

@MainActor
final class MarkdownReaderModel: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
  typealias Read = @Sendable (URL) async throws -> MarkdownDocument
  typealias Resources = @Sendable (MarkdownDocument, URL, [String]) async throws -> MarkdownDocument
  typealias Images = @MainActor (WKWebView, String) async throws -> [String]
  typealias Capture = @MainActor (BrowserTab) async throws -> MarkdownDocument
  @Published private(set) var document: MarkdownDocument?
  @Published private(set) var errorPresentation: AegisLocalizedMessage = .verbatim("")
  var error: String {
    get { errorPresentation.text }
    set { if !closed { errorPresentation = .verbatim(newValue) } }
  }
  @Published private(set) var ready = false
  @Published private(set) var rendered = false
  @Published var exportURL: URL?
  @Published var needsResources = false
  private(set) var openURL: ((URL) -> Void)?
  private(set) var renderID = UUID().uuidString
  private var revision = 0
  private var importID = UUID()
  private var resourceID = UUID()
  private var importTask: Task<Void, Never>?
  private var resourceTask: Task<Void, Never>?
  private var exportTask: Task<Void, Never>?
  private var exportID = UUID()
  private var javascriptTasks: [UUID: Task<Void, Never>] = [:]
  private var closed = false
  var isOpen: Bool { !closed }
  private var initialized = false
  private weak var browser: BrowserSession?
  private var observers: Set<AnyCancellable> = []
  private let read: Read
  private let resources: Resources
  private let images: Images
  private let capturePage: Capture
  private let makeScope: @Sendable (URL) -> MarkdownSecurityScope
  var fontSize: Double = 17
  private(set) var webView: WKWebView!

  init(read: @escaping Read = { try await MarkdownIO.shared.read($0) },
       resources: @escaping Resources = { try await MarkdownIO.shared.resources($0, directory: $1, references: $2) },
       capture: @escaping Capture = { try await MarkdownDocument.capture($0) },
       makeScope: @escaping @Sendable (URL) -> MarkdownSecurityScope = { MarkdownSecurityScope($0) },
       images: @escaping Images = { web, token in
         try await web.callAsyncJavaScript(
           "if(AegisMarkdown.token() !== token) return []; return AegisMarkdown.images();",
           arguments: ["token": token], in: nil, contentWorld: .page) as? [String] ?? []
       }) {
    self.read = read; self.resources = resources; self.images = images; self.makeScope = makeScope; self.capturePage = capture
    super.init()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(self, name: "aegisMarkdown")
    webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    webView.isInspectable = false
    if let root = EnhancementAssets.directory {
      webView.loadFileURL(root.appendingPathComponent("viewer.html"), allowingReadAccessTo: root)
    } else { errorPresentation = .resource("Markdown 阅读资源缺失。") }
  }

  func bind(browser: BrowserSession, openURL: @escaping (URL) -> Void) {
    guard !closed, self.browser !== browser else { return }
    self.browser = browser; self.openURL = openURL
    browser.$profile.dropFirst().sink { [weak self] _ in self?.close() }.store(in: &observers)
    browser.$isWindowClosed.sink { [weak self] value in if value { self?.close() } }.store(in: &observers)
  }
  func initialize(_ initial: MarkdownDocument?) {
    guard !closed, !initialized else { return }
    initialized = true
    if let initial { load(initial) }
  }
  private func current(_ token: String) -> Bool {
    !closed && renderID == token && browser?.isWindowClosed != true
  }
  private func beginImport() -> UUID? {
    guard !closed else { return nil }
    importID = UUID(); resourceID = UUID(); renderID = UUID().uuidString
    importTask?.cancel(); resourceTask?.cancel(); exportTask?.cancel(); exportTask = nil; exportID = UUID()
    javascriptTasks.values.forEach { $0.cancel() }; javascriptTasks.removeAll()
    exportURL = nil; needsResources = false; rendered = false; errorPresentation = .verbatim("")
    return importID
  }
  private func apply(_ value: MarkdownDocument) {
    document = value
    rendered = false
    errorPresentation = .verbatim("")
    renderID = UUID().uuidString
    if ready { render() }
  }
  func load(_ value: MarkdownDocument) {
    guard beginImport() != nil else { return }
    apply(value)
  }
  @discardableResult func importFile(_ url: URL) -> Task<Void, Never>? {
    guard let id = beginImport() else { return nil }
    let scope = makeScope(url), read = read
    let task = Task { [weak self] in
      defer { withExtendedLifetime(scope) {} }
      guard self?.importID == id, self?.closed == false, !Task.isCancelled else { return }
      do {
        let value = try await read(url)
        guard let self, !self.closed, self.importID == id, !Task.isCancelled else { return }
        self.apply(value); self.importTask = nil
      } catch {
        guard let self, !self.closed, self.importID == id, !Task.isCancelled else { return }
        self.errorPresentation = .error(error); self.importTask = nil
        if self.ready { self.render() }
      }
    }
    importTask = task
    return task
  }
  @discardableResult func capture(_ tab: BrowserTab) -> Task<Void, Never>? {
    guard let id = beginImport() else { return nil }
    let capturePage = capturePage
    let task = Task { [weak self] in
      guard self?.importID == id, self?.closed == false, !Task.isCancelled else { return }
      do {
        let value = try await capturePage(tab)
        guard let self, !self.closed, self.importID == id, !Task.isCancelled else { return }
        self.apply(value); self.importTask = nil
      } catch {
        guard let self, !self.closed, self.importID == id, !Task.isCancelled else { return }
        self.errorPresentation = .error(error); self.importTask = nil
        if self.ready { self.render() }
      }
    }
    importTask = task
    return task
  }
  func reportImportError(_ error: Error) {
    guard beginImport() != nil else { return }
    errorPresentation = .error(error)
    if ready { render() }
  }
  func reportNotice(_ value: AegisLocalizedMessage) {
    guard !closed else { return }
    errorPresentation = value
  }
  func updateFont(_ size: Double) { guard !closed else { return }; fontSize = size; configure() }
  private func javascript(token: String, _ body: @escaping @MainActor () async throws -> Void) {
    let id = UUID()
    javascriptTasks[id] = Task { [weak self] in
      defer { self?.javascriptTasks[id] = nil }
      guard self?.current(token) == true, !Task.isCancelled else { return }
      do { try await body() }
      catch { if self?.current(token) == true, !Task.isCancelled { self?.errorPresentation = .error(error) } }
    }
  }
  private func viewerConfiguration() -> [String: Any] {
    let defaults = UserDefaults.standard
    let preferences: [String: Any] = [
      "font": (defaults.object(forKey: "markdown.font") as? Double ?? 17) * fontSize / 17,
      "theme": defaults.string(forKey: "markdown.theme") ?? "system",
      "family": defaults.string(forKey: "markdown.family") ?? "sans",
      "width": defaults.object(forKey: "markdown.width") as? Int ?? 820,
      "spacing": defaults.object(forKey: "markdown.spacing") as? Int ?? 180]
    return ["embedded": true, "locale": Bundle.main.preferredLocalizations.first ?? "zh-Hans", "preferences": preferences]
  }
  func configure() {
    guard ready, !closed else { return }
    let token = renderID, web = webView!, value = viewerConfiguration()
    javascript(token: token) {
      _ = try await web.callAsyncJavaScript(
        "if(!AegisMarkdown.token() || AegisMarkdown.token() === token) AegisMarkdown.configure(value);",
        arguments: ["token": token, "value": value],
        in: nil, contentWorld: .page)
    }
  }
  func command(_ value: String) {
    guard ready, rendered, document != nil, !closed else { return }
    let token = renderID, web = webView!
    javascript(token: token) {
      _ = try await web.callAsyncJavaScript(
        "if(AegisMarkdown.token() === token) AegisMarkdown.command(value);",
        arguments: ["token": token, "value": value], in: nil, contentWorld: .page)
    }
  }
  private func render() {
    guard let document, !closed else { return }
    revision += 1
    let token = renderID, web = webView!
    let payload: [String: Any] = ["text": document.text, "title": document.title,
      "baseURL": document.sourceURL?.absoluteString ?? "", "resources": document.resources,
      "iosToken": token, "iosRevision": revision]
    let configuration = viewerConfiguration()
    javascript(token: token) { [weak self] in
      let loaded = try await web.callAsyncJavaScript(
        "const loaded = AegisMarkdown.load(payload); if(loaded) AegisMarkdown.configure(configuration); return loaded;",
        arguments: ["payload": payload, "configuration": configuration], in: nil, contentWorld: .page)
      if self?.current(token) == true, loaded as? Bool == true { self?.rendered = true }
    }
  }
  func close() {
    guard !closed else { return }
    closed = true; importID = UUID(); resourceID = UUID(); renderID = UUID().uuidString
    importTask?.cancel(); resourceTask?.cancel(); exportTask?.cancel()
    importTask = nil; resourceTask = nil; exportTask = nil; exportID = UUID()
    javascriptTasks.values.forEach { $0.cancel() }; javascriptTasks.removeAll()
    observers.removeAll(); openURL = nil; ready = false; rendered = false; exportURL = nil; needsResources = false
    webView.stopLoading(); webView.navigationDelegate = nil
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "aegisMarkdown")
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !closed, webView === self.webView else { return }
    ready = true; updateFont(fontSize); render()
  }
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
    guard !closed, let target = navigationAction.request.url else { decisionHandler(.cancel); return }
    if navigationAction.navigationType == .other,
       target == EnhancementAssets.directory?.appendingPathComponent("viewer.html") { decisionHandler(.allow); return }
    decisionHandler(.cancel)
    if ScriptMatch.origin(target) != nil, navigationAction.navigationType == .linkActivated { openURL?(target) }
  }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.webView === webView, message.frameInfo.isMainFrame,
      message.frameInfo.request.url == EnhancementAssets.directory?.appendingPathComponent("viewer.html"),
      let body = message.body as? [String: Any], let type = body["type"] as? String,
      let token = body["iosToken"] as? String else { return }
    receive(type: type, value: body["value"] as? String ?? "", token: token)
  }
  func receive(type: String, value: String, token: String) {
    guard current(token) else { return }
    switch type {
    case "copy":
      if value.utf8.count <= MarkdownDocument.maximumBytes {
        UIPasteboard.general.string = value; errorPresentation = .resource("已复制。")
      }
    case "open": if let url = URL(string: value), ScriptMatch.origin(url) != nil { openURL?(url) }
    case "resources": needsResources = true
    case "relativeLink": errorPresentation = .joined(.resource("这是本地相对链接，请通过打开文件选择目标文档："), .verbatim(String(value.prefix(300))))
    default: break
    }
  }
  @discardableResult func loadResources(_ directory: URL) -> Task<Void, Never>? {
    guard !closed, let original = document, ready, rendered else { return nil }
    resourceTask?.cancel(); resourceID = UUID()
    let id = resourceID, token = renderID, scope = makeScope(directory)
    let images = images, resources = resources, web = webView!
    let task = Task { [weak self] in
      defer { withExtendedLifetime(scope) {} }
      guard self?.current(token) == true, self?.resourceID == id, !Task.isCancelled else { return }
      do {
        let references = try await images(web, token)
        guard let self, self.current(token), self.document?.id == original.id, self.resourceID == id, !Task.isCancelled else { return }
        let result = try await resources(original, directory, references)
        guard self.current(token), self.document?.id == original.id, self.resourceID == id, !Task.isCancelled else { return }
        self.document?.resources = result.resources
        self.errorPresentation = .resource("已加载 \(result.resources.count) 张本地图片。")
        self.resourceTask = nil
        self.renderID = UUID().uuidString; self.rendered = false; self.render()
      } catch {
        guard let self, self.current(token), self.document?.id == original.id, self.resourceID == id, !Task.isCancelled else { return }
        self.errorPresentation = .error(error); self.resourceTask = nil
      }
    }
    resourceTask = task
    return task
  }
  @discardableResult func exportPDF() -> Task<Void, Never>? {
    let token = renderID
    guard current(token), ready, rendered, document != nil else { return nil }
    exportTask?.cancel(); exportID = UUID()
    let id = exportID
    let task = Task { [weak self] in
      guard let self, self.current(token), !Task.isCancelled else { return }
      defer { if self.exportID == id { self.exportTask = nil } }
      do {
        let data = MarkdownPDFExporter.data(from: self.webView)
        let url = try await MarkdownIO.shared.writePDF(data)
        guard self.current(token), self.exportID == id, !Task.isCancelled else { await MarkdownIO.shared.remove(url); return }
        self.exportURL = url
      } catch { if self.current(token), !Task.isCancelled { self.errorPresentation = .error(error) } }
    }
    exportTask = task
    return task
  }
  func printDocument() {
    guard !closed, ready, rendered, document != nil else { return }
    let controller = UIPrintInteractionController.shared
    controller.printFormatter = webView.viewPrintFormatter(); controller.present(animated: true)
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
  @Environment(\.locale) private var localizationLocale
  var body: some View {
      let _ = localizationLocale
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
          Button("读取当前原始页面") { capture() }.padding()
        }
        MarkdownWebView(webView: model.webView).accessibilityIdentifier("markdown-webview")
          .frame(height: model.document == nil ? 0 : nil)
          .accessibilityHidden(model.document == nil)
          .allowsHitTesting(model.rendered)
          .overlay { if model.document != nil, !model.rendered { ProgressView() } }
      }
      .navigationTitle(model.document?.title ?? AegisLocalization.string("Markdown 阅读")).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("markdown-reader-done") }
        ToolbarItem(placement: .topBarLeading) {
          Menu {
            Button("打开文件", systemImage: "doc") { importingResources = false; importing = true }
            Button("读取当前原始页面", systemImage: "globe") { capture() }
            if model.document != nil {
              Section("文档操作") {
                Button("查看源码", systemImage: "chevron.left.forwardslash.chevron.right") { model.command("source-toggle") }.disabled(!model.rendered)
                Button("复制原文", systemImage: "doc.on.doc") { model.command("copy-source") }.disabled(!model.rendered)
                Button("保存到阅读库", systemImage: "books.vertical") { confirmsSave = true }
                Button("文档来源与预览设置", systemImage: "info.circle") { sourceInfo = true }
                Button("打印", systemImage: "printer") { model.printDocument() }.disabled(!model.rendered)
                Button("导出 PDF", systemImage: "square.and.arrow.up") { model.exportPDF() }.disabled(!model.rendered)
              }
              Section("图片权限") {
                if model.document?.sourceURL?.isFileURL != false {
                  Button("选择本地图片目录") { importingResources = true; importing = true }.disabled(!model.rendered)
                }
                Button("加载或停用外部图片") { model.command("remote-images") }.disabled(!model.rendered)
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
            Section("文档来源") { Text(model.document?.sourceURL?.absoluteString ?? AegisLocalization.string("本地导入 · 只读")).textSelection(.enabled) }
            if let url = model.document?.sourceURL, ScriptMatch.origin(url) != nil {
              Toggle("本站自动预览 Markdown", isOn: $automatic)
                .onChange(of: automatic) { _, value in
                  guard model.isOpen else { return }
                  do { var site = browser.preferences.site(for: url); site.markdownPreview = value; try browser.preferences.setSite(site, for: url) }
                  catch { model.reportNotice(.error(error)) }
                }
            }
          }.localizedNavigationTitle("文档来源").toolbar { Button("完成") { sourceInfo = false }.accessibilityIdentifier("markdown-source-done") }
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
            model.loadResources(url)
          } else {
            model.importFile(url)
          }
        case .failure(let error): model.reportImportError(error)
        }
      }
      .onAppear {
        model.updateFont(fontSize)
        model.bind(browser: browser) { url in
          browser.newTab().load(url)
          dismiss()
        }
        if let initial {
          model.initialize(initial)
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
        model.importFile(url)
        return true
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
            }.localizedNavigationTitle("PDF 已生成").toolbar { Button("完成") { model.exportURL = nil } }
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
  private func capture() {
    guard let tab = browser.activeTab else { return }
    model.capture(tab)
  }
  private func saveDocument() {
    guard model.isOpen, let document = model.document else { return }
    do {
      guard document.text.count <= 24_000 else {
        throw EnhancementError.invalid("本文超过资料库单条 24,000 字限制，未保存截断副本。请导出原文或 PDF。")
      }
      try library.save(
        ReadingRecord(
          title: document.title,
          sourceURL: document.sourceURL?.isFileURL == true ? nil : document.sourceURL,
          text: document.text))
      model.reportNotice(.resource("已保存完整原文到阅读资料库。"))
    } catch { model.reportNotice(.error(error)) }
  }
}

struct ReadingPreferencesView: View {
  @AppStorage("markdown.theme") private var theme = "system"
  @AppStorage("markdown.family") private var family = "sans"
  @AppStorage("markdown.font") private var font = 17.0
  @AppStorage("markdown.spacing") private var spacing = 180
  @AppStorage("markdown.width") private var width = 820
  @Environment(\.locale) private var localizationLocale
  var body: some View {
      let _ = localizationLocale
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
    }.localizedNavigationTitle("阅读外观").navigationBarTitleDisplayMode(.inline)
  }
}
