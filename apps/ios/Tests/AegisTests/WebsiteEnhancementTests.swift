import Foundation
import PDFKit
import WebKit
import XCTest

@testable import BrowserKit

@MainActor
final class WebsiteEnhancementTests: XCTestCase {
  private var directory: URL!
  private var tabs: [BrowserTab] = []
  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  override func tearDown() async throws {
    tabs.forEach { $0.stop() }
    tabs = []
    try? FileManager.default.removeItem(at: directory)
  }
  private func source(
    _ code: String = "", match: String = "http://127.0.0.1:8768/enhancements/*",
    grants: String = "none", when: String = "document-end"
  ) -> String {
    "// ==UserScript==\n// @name 验收脚本\n// @match \(match)\n// @run-at \(when)\n"
      + grants.components(separatedBy: ",").map { "// @grant \($0)\n" }.joined()
      + "// ==/UserScript==\n" + code
  }
  private func wait(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(15)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertTrue(predicate())
  }
  private func load(_ tab: BrowserTab, _ path: String = "/enhancements/page") async throws {
    tab.load(URL(string: "http://127.0.0.1:8768" + path)!)
    try await wait { !tab.isLoading && tab.url?.path == path }
    XCTAssertNil(tab.loadingError)
  }
  private func makeTab(_ store: WebsiteEnhancementStore) -> BrowserTab {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let tab = BrowserTab(profile: .standard, configuration: configuration, enhancementStore: store)
    tabs.append(tab)
    return tab
  }
  private func js(_ tab: BrowserTab, _ code: String) async throws -> Any? {
    try await tab.webView.callAsyncJavaScript(code, arguments: [:], in: nil, contentWorld: .page)
  }

  func testSharedMatchingVectors() throws {
    struct Vector: Decodable {
      let pattern: String
      let url: String
      let matches: Bool
    }
    let data = try XCTUnwrap(
      EnhancementAssets.text("tests/matching-vectors.json").data(using: .utf8))
    for vector in try JSONDecoder().decode([Vector].self, from: data) {
      XCTAssertEqual(
        ScriptMatch.matches(vector.pattern, URL(string: vector.url)!), vector.matches, vector.url)
    }
    XCTAssertThrowsError(try ScriptMetadata.parse(source(grants: "GM_xmlhttpRequest")))
    XCTAssertThrowsError(try EnhancementAssets.checkSyntax(source("const = ;")))
    XCTAssertThrowsError(try ScriptMetadata.parse("alert(1);\n" + source()))
  }
  func testPersistenceDraftRevisionRollbackAndPrivateIsolation() throws {
    let file = directory.appendingPathComponent("store.json")
    let store = WebsiteEnhancementStore(fileURL: directory.appendingPathComponent("store.json"))
    var rule = WebsiteEnhancementRule(origin: "https://example.com")
    rule.copy = true
    rule.subdomains = true
    try store.saveRule(rule)
    let first = try store.saveScript(source: source("document.body.dataset.version='one';"))
    XCTAssertFalse(first.enabled)
    try store.setEnabled(first.id, revision: first.revision, enabled: true)
    XCTAssertThrowsError(try store.setEnabled(first.id, revision: first.revision, enabled: false))
    try store.setValue(ScriptValue(json: "42"), key: "value", script: first.id)
    let second = try store.saveScript(
      id: first.id, revision: 2, source: source("document.body.dataset.version='two';"))
    XCTAssertFalse(second.enabled)
    XCTAssertEqual(second.history.count, 1)
    let restored = try store.rollback(second.id, revision: second.revision)
    XCTAssertEqual(restored.source, first.source)
    XCTAssertFalse(restored.enabled)
    let reloaded = WebsiteEnhancementStore(fileURL: file)
    XCTAssertNil(reloaded.error)
    XCTAssertEqual(reloaded.state, store.state)
    XCTAssertEqual(reloaded.value("value", script: first.id)?.json, "42")
    XCTAssertNotNil(reloaded.rule(for: URL(string: "https://a.example.com/")!))
    XCTAssertNil(reloaded.rule(for: URL(string: "https://example.com.evil.test/")!))
    let privateStore = WebsiteEnhancementStore()
    XCTAssertTrue(privateStore.state.scripts.isEmpty)
    XCTAssertTrue(privateStore.state.values.isEmpty)
  }
  func testExternalWriteAndCorruptDataArePreserved() throws {
    let file = directory.appendingPathComponent("store.json")
    let store = WebsiteEnhancementStore(fileURL: directory.appendingPathComponent("store.json"))
    _ = try store.saveScript(source: source())
    try Data("corrupt".utf8).write(to: file)
    XCTAssertThrowsError(try store.saveRule(WebsiteEnhancementRule(origin: "https://example.com")))
    let unreadable = WebsiteEnhancementStore(fileURL: file)
    XCTAssertNotNil(unreadable.error)
    XCTAssertThrowsError(try unreadable.saveScript(source: source()))
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "corrupt")
  }
  func testRealWebKitEarlyRulesStorageMenuAndDisable() async throws {
    let store = WebsiteEnhancementStore()
    var rule = WebsiteEnhancementRule(origin: "http://127.0.0.1:8768")
    rule.menu = true
    rule.copy = true
    rule.debug = true
    try store.saveRule(rule)
    let early = try store.saveScript(
      source: source("document.documentElement.dataset.early='yes';", when: "document-start"))
    try store.setEnabled(early.id, revision: early.revision, enabled: true)
    let script = try store.saveScript(
      source: source(
        """
        const count=await GM.getValue('count',0); await GM.setValue('count',count+1);
        document.body.dataset.count=String(count+1); GM_addStyle('aside { display:none !important }');
        GM_registerMenuCommand('验收菜单',()=>{document.body.dataset.menu='called';});
        globalThis.scriptSecret='isolated';
        """, grants: "GM.getValue,GM.setValue,GM_addStyle,GM_registerMenuCommand"))
    try store.setEnabled(script.id, revision: script.revision, enabled: true)
    let tab = makeTab(store)
    try await load(tab)
    try await wait { tab.userScripts.menus.count == 1 }
    let values =
      try await js(
        tab,
        "return {early:window.aegisOrder,count:document.body.dataset.count,hidden:getComputedStyle(document.querySelector('aside')).display,secret:typeof window.scriptSecret,blocked:!window.dispatchEvent(new MouseEvent('contextmenu',{cancelable:true})),normal:Function('return 42')(),debugger:Function('debugger;').toString().includes('debugger')};"
      ) as? [String: Any]
    XCTAssertEqual(values?["early"] as? Bool, true)
    XCTAssertEqual(values?["count"] as? String, "1")
    XCTAssertEqual(values?["hidden"] as? String, "none")
    XCTAssertEqual(values?["secret"] as? String, "undefined")
    XCTAssertEqual(values?["blocked"] as? Bool, false)
    XCTAssertEqual(values?["normal"] as? Int, 42)
    XCTAssertEqual(values?["debugger"] as? Bool, false)
    try await tab.userScripts.runMenu(XCTUnwrap(tab.userScripts.menus.first))
    let menu = try await js(tab, "return document.body.dataset.menu;") as? String
    XCTAssertEqual(menu, "called")
    XCTAssertEqual(store.value("count", script: script.id)?.json, "1")
    let oldMenu = try XCTUnwrap(tab.userScripts.menus.first)
    try store.setEnabled(script.id, revision: 2, enabled: false)
    do {
      try await tab.userScripts.runMenu(oldMenu)
      XCTFail("停用立即撤销菜单权限")
    } catch {}
    try await Task.sleep(for: .milliseconds(100))
    try await load(tab)
    let after =
      try await js(tab, "return getComputedStyle(document.querySelector('aside')).display;")
      as? String
    XCTAssertNotEqual(after, "none")
    XCTAssertTrue(tab.userScripts.menus.isEmpty)
  }
  func testTrialStorageIsTemporaryAndWrongURLDoesNotRun() async throws {
    let store = WebsiteEnhancementStore()
    let tab = makeTab(store)
    try await load(tab)
    let draft = try store.saveScript(
      source: source(
        "await GM.setValue('trial',12);document.body.dataset.trial='yes';", grants: "GM.setValue"))
    try await tab.userScripts.trial(draft)
    try await wait { !tab.userScripts.statuses.isEmpty }
    XCTAssertNil(store.value("trial", script: draft.id))
    XCTAssertFalse(store.state.scripts[0].enabled)
    let applied = try await js(tab, "return document.body.dataset.trial;") as? String
    XCTAssertEqual(applied, "yes")
    try await load(tab, "/article")
    do {
      try await tab.userScripts.trial(draft)
      XCTFail("不应在未授权网址运行")
    } catch {}
  }
  func testMarkdownFileLimitsContainmentAndRawResponse() async throws {
    let file = directory.appendingPathComponent("article.md")
    try Data("# 标题\n中文全文".utf8).write(to: file)
    var document = try MarkdownDocument.read(file)
    XCTAssertEqual(document.text, "# 标题\n中文全文")
    let image = directory.appendingPathComponent("image.png")
    try Data([137, 80, 78, 71]).write(to: image)
    XCTAssertEqual(
      try document.loadResources(
        from: directory, references: ["image.png", "../outside.png", "https://example.com/a.png"]),
      1)
    try Data(repeating: 65, count: MarkdownDocument.maximumBytes + 1).write(to: file)
    XCTAssertThrowsError(try MarkdownDocument.read(file))
    var remote = MarkdownDocument(
      title: "Remote", text: "", sourceURL: URL(string: "https://example.com/a.md"))
    XCTAssertThrowsError(try remote.loadResources(from: directory, references: ["image.png"]))
    let tab = makeTab(WebsiteEnhancementStore())
    try await load(tab, "/enhancements/document.md")
    let captured = try await MarkdownDocument.capture(tab)
    XCTAssertTrue(captured.text.contains("Markdown 验收"))
    XCTAssertTrue(captured.text.contains("window.markdownExecuted"))
    try await load(tab, "/enhancements/fake.md")
    do {
      _ = try await MarkdownDocument.capture(tab)
      XCTFail("不能将 HTML 页面当作原始 Markdown")
    } catch {}
  }
  func testSharedMarkdownRendererUsesPackagedAssetsAndEscapesExecutableContent() async throws {
    let web = WKWebView(
      frame: CGRect(x: 0, y: 0, width: 800, height: 1000), configuration: WKWebViewConfiguration())
    let root = try XCTUnwrap(EnhancementAssets.directory)
    web.loadFileURL(root.appendingPathComponent("viewer.html"), allowingReadAccessTo: root)
    try await wait { !web.isLoading && web.url != nil }
    let text =
      "# 重复标题\n\n# 重复标题\n\n- [x] 任务\n\n|名称|数值|\n|---|---|\n|甲|42|\n\n```js\nconst count=42;\n```\n\n<script>window.mdUnsafe=1</script>\n\n![图片](https://invalid.local/image.png)\n"
    let rendered =
      try await web.callAsyncJavaScript(
        "return AegisMarkdown.load({text:source,title:'验收'});", arguments: ["source": text],
        in: nil, contentWorld: .page) as? Bool
    XCTAssertEqual(rendered, true)
    let result =
      try await web.callAsyncJavaScript(
        "return {headings:document.querySelectorAll('#outline a').length,tables:document.querySelectorAll('#document table').length,tasks:document.querySelectorAll('#document input:disabled').length,scripts:document.querySelectorAll('#document script').length,unsafe:typeof window.mdUnsafe,src:document.querySelector('#document img').getAttribute('src'),source:AegisMarkdown.text(),unique:new Set([...document.querySelectorAll('#document h1')].map(x=>x.id)).size};",
        arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(result?["headings"] as? Int, 2)
    XCTAssertEqual(result?["tables"] as? Int, 1)
    XCTAssertEqual(result?["tasks"] as? Int, 1)
    XCTAssertEqual(result?["scripts"] as? Int, 0)
    XCTAssertEqual(result?["unsafe"] as? String, "undefined")
    XCTAssertEqual(result?["src"] as? String, "")
    XCTAssertEqual(result?["source"] as? String, text)
    XCTAssertEqual(result?["unique"] as? Int, 2)
    let pdf = MarkdownPDFExporter.data(from: web)
    XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
    XCTAssertTrue(PDFDocument(data: pdf)?.string?.contains("重复标题") == true)
    XCTAssertTrue(PDFDocument(data: pdf)?.string?.contains("count") == true)
    XCTAssertFalse(PDFDocument(data: pdf)?.string?.contains("加载外部图片") == true)
    _ = try await web.callAsyncJavaScript(
      "return AegisMarkdown.load({text:('# 分页内容\\n\\n'+('正文段落。'.repeat(20))+'\\n\\n').repeat(80)+'AEGISPDFEND 最后一页验收标记',title:'长文'});",
      arguments: [:], in: nil, contentWorld: .page)
    let longPDF = try XCTUnwrap(PDFDocument(data: MarkdownPDFExporter.data(from: web)))
    XCTAssertGreaterThan(longPDF.pageCount, 1)
    XCTAssertTrue(longPDF.string?.contains("AEGISPDFEND") == true, String((longPDF.string ?? "").suffix(500)))
    _ = try await web.callAsyncJavaScript(
      "return AegisMarkdown.load({text:text,title:'验收'});",
      arguments: ["text": text], in: nil, contentWorld: .page)
    _ = try await web.callAsyncJavaScript(
      "document.getElementById('query').value='重复标题';document.getElementById('find').click();document.getElementById('find').click();",
      arguments: [:], in: nil, contentWorld: .page)
    let found =
      try await web.callAsyncJavaScript(
        "return document.getElementById('notice').textContent;", arguments: [:], in: nil,
        contentWorld: .page) as? String
    XCTAssertEqual(found, "第 2 / 2 处匹配")
    web.stopLoading()
  }

  func testAllFramesMatchesIndividuallyAndStaleMenuIsRejected() async throws {
    let store = WebsiteEnhancementStore()
    let script = try store.saveScript(
      source: source(
        "document.body.dataset.frame='allowed';GM_registerMenuCommand(window===top?'顶层菜单':'子框架菜单',()=>document.body.dataset.oldMenu='bad');",
        grants: "GM_registerMenuCommand"), allFrames: true)
    try store.setEnabled(script.id, revision: script.revision, enabled: true)
    let tab = makeTab(store)
    try await load(tab)
    try await wait { tab.userScripts.menus.count == 2 }
    let matched =
      try await js(
        tab, "return document.querySelector('iframe').contentDocument.body.dataset.frame;")
      as? String
    XCTAssertEqual(matched, "allowed")
    let menu = try XCTUnwrap(tab.userScripts.menus.first { $0.label == "顶层菜单" })
    _ = try await js(tab, "history.pushState(null,'','/outside');")
    do {
      try await tab.userScripts.runMenu(menu)
      XCTFail("同一文档离开授权路径后不能执行旧菜单")
    } catch {}
    try store.disableAll()
    XCTAssertTrue(store.state.scripts.allSatisfy { !$0.enabled })
  }

}
