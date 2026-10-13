import Combine
import Foundation
import JavaScriptCore
import WebKit

public enum EnhancementAssets {
  public static var directory: URL? {
    Bundle(for: UserScriptController.self).url(
      forResource: "enhancements_shared", withExtension: nil)
  }
  public static func text(_ name: String) throws -> String {
    guard let directory else { throw EnhancementError.invalid("网页增强资源缺失，请重新安装完整版本。") }
    return try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
  }
  public static func json<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(data: (try? encoder.encode(value)) ?? Data("null".utf8), encoding: .utf8)
      ?? "null"
  }
  public static func checkSyntax(_ source: String) throws {
    _ = try ScriptMetadata.parse(source)
    guard let context = JSContext() else { throw EnhancementError.invalid("无法启动脚本语法检查。") }
    let result = context.evaluateScript(
      "new Function(" + json("return (async function(){\n" + source + "\n});") + "); true;")
    guard context.exception == nil, result?.toBool() == true else {
      throw EnhancementError.invalid("脚本语法错误：" + (context.exception?.toString() ?? "无法解析"))
    }
  }
  public static func template(_ url: URL?) -> String {
    let pattern = url.flatMap(ScriptMatch.origin) ?? "https://example.com"
    return
      "// ==UserScript==\n// @name 我的网页增强\n// @namespace aegis.local\n// @version 1.0\n// @match \(pattern)/*\n// @run-at document-end\n// @grant GM_addStyle\n// ==/UserScript==\n\nGM_addStyle(\"body { line-height: 1.7; }\");\n"
  }
}

public struct ScriptRunStatus: Identifiable, Equatable {
  public let id: String
  public var name: String
  public var status: String
  public var error: String
  public var trial = false
  public var mainFrame = true
}

public struct UserScriptMenu: Identifiable {
  public let id: String
  public let label: String
  public let scriptID: String
  fileprivate let binding: String
  fileprivate let key: String
  fileprivate let frame: WKFrameInfo
  fileprivate let nonce: String
}

/// 注册在单个内容世界中的窄接口。网页上下文从来没有存储桥接。
@MainActor
public final class UserScriptController: NSObject, ObservableObject, WKScriptMessageHandlerWithReply
{
  @Published public private(set) var statuses: [ScriptRunStatus] = []
  @Published public private(set) var menus: [UserScriptMenu] = []
  @Published public private(set) var installationError: String?
  public let store: WebsiteEnhancementStore
  weak var tab: BrowserTab?
  private weak var content: WKUserContentController?
  private var managed: [WKUserScript] = []
  private var changes: AnyCancellable?
  private struct Binding {
    let script: UserScriptRecord
    let world: WKContentWorld
    let trial: Bool
  }
  private var bindings: [String: Binding] = [:]
  private var trialValues: [String: [String: ScriptValue]] = [:]

  init(store: WebsiteEnhancementStore, controller: WKUserContentController) {
    self.store = store
    content = controller
    super.init()
    rebuild(store.state)
    changes = store.$state.sink { [weak self] state in
      // 已保存状态在发布完成后更新注入，避免观察器读到旧版本。
      Task { @MainActor [weak self] in self?.update(state) }
    }
  }
  private func update(_ state: WebsiteEnhancementState) {
    // GM 值更新不重建执行环境，否则一次 setValue 会撤销脚本自身。
    let policy =
      state.scripts.map { "\($0.id):\($0.revision):\($0.enabled)" }.joined(separator: ",")
      + EnhancementAssets.json(state.sites)
    if policySignature != policy { rebuild(state) }

  }
  private var policySignature = ""
  private func rebuild(_ state: WebsiteEnhancementState) {
    guard let content else { return }
    policySignature =
      state.scripts.map { "\($0.id):\($0.revision):\($0.enabled)" }.joined(separator: ",")
      + EnhancementAssets.json(state.sites)
    let preserved = content.userScripts.filter { script in !managed.contains { $0 === script } }
    content.removeAllUserScripts()
    preserved.forEach(content.addUserScript)
    managed = []
    for (name, binding) in bindings {
      content.removeScriptMessageHandler(forName: name, contentWorld: binding.world)
    }
    bindings = [:]
    menus = []
    statuses = []
    trialValues = [:]
    do {
      let core = try EnhancementAssets.text("core.js")
      let rules = try EnhancementAssets.text("site_rules.js")
      if !state.sites.isEmpty {
        let source =
          core + "\n" + rules + "\n(() => {const r=AegisEnhancementsCore.siteRule("
          + EnhancementAssets.json(state.sites)
          + ",location.href);if(r&&!r.disabled)AegisInstallSiteRules(r);})();"
        add(
          WKUserScript(
            source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
      }
      for script in state.scripts where script.enabled {
        let (binding, world) = register(script, trial: false)
        add(
          WKUserScript(
            source: try source(script, binding: binding, trial: false),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: !script.allFrames || script.metadata.noframes, in: world))
      }
      installationError = nil
    } catch { installationError = error.localizedDescription }
  }
  private func add(_ script: WKUserScript) {
    managed.append(script)
    content?.addUserScript(script)
  }
  private func register(_ script: UserScriptRecord, trial: Bool) -> (String, WKContentWorld) {
    let name = "aegis_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let world = script.world == "page" ? WKContentWorld.page : WKContentWorld.world(name: name)
    if script.world != "page" {
      bindings[name] = Binding(script: script, world: world, trial: trial)
      content?.addScriptMessageHandler(self, contentWorld: world, name: name)
    }
    return (name, world)
  }
  private func source(_ script: UserScriptRecord, binding: String, trial: Bool) throws -> String {
    let core = try EnhancementAssets.text("core.js")
    let runtime = try EnhancementAssets.text("script_runtime.js")
    let metadata = EnhancementAssets.json(script.metadata)
    let sender: String
    if script.world == "page" {
      sender = "const runtime={api:{},report:(s,e)=>{if(e)console.warn('Aegis script: '+e);}};"
    } else {
      // getRandomValues 也能用于普通 HTTP；randomUUID 仅适用于安全上下文。
      sender = """
        const random=crypto.getRandomValues(new Uint8Array(16));random[6]=(random[6]&15)|64;random[8]=(random[8]&63)|128;
        const hex=Array.from(random,x=>x.toString(16).padStart(2,'0')).join('');
        const nonce=[hex.slice(0,8),hex.slice(8,12),hex.slice(12,16),hex.slice(16,20),hex.slice(20)].join('-');globalThis.__aegisDocumentNonce=nonce;
        const runtime=AegisCreateScriptRuntime(\(metadata),text=>{const p=JSON.parse(text);p.nonce=nonce;window.webkit.messageHandlers[\(EnhancementAssets.json(binding))].postMessage(JSON.stringify(p)).then(r=>runtime.receive(r),e=>runtime.receive({request:p.request,error:String(e)}));});
        globalThis.__aegisRunMenu=id=>runtime.runMenu(id);
        """
    }
    return core + "\n" + runtime + "\n" + """
      (()=>{'use strict';if(!AegisEnhancementsCore.applies(\(metadata),location.href,window===window.top,\(script.allFrames)))return 'unmatched';
      if(\(EnhancementAssets.json(script.disabledOrigins ?? [])).some(origin=>[location.origin,...Array.from(location.ancestorOrigins||[])].includes(origin)))return 'paused';
      if(globalThis[\(EnhancementAssets.json("__aegisRan_" + binding))])return 'duplicate';globalThis[\(EnhancementAssets.json("__aegisRan_" + binding))]=true;
      \(sender)
      const {GM,GM_addStyle,GM_registerMenuCommand}=runtime.api;
      const run=async()=>{runtime.report('running');try{await(async()=>{\n\(script.source)\n})();runtime.report('completed');}catch(error){runtime.report('failed',String(error));}};
      \(trial || script.metadata.runAt == "document-start" ? "void run();" : "const ready=()=>{\(script.metadata.runAt == "document-idle" ? "setTimeout(()=>void run(),0);" : "void run();")};if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',ready,{once:true});else ready();")
      return 'scheduled';})();
      """
  }
  public func trial(_ script: UserScriptRecord) async throws {
    update(store.state)
    guard let tab, let current = tab.webView.url, script.metadata.applies(to: current),
      !script.paused(at: current) else {
      throw EnhancementError.invalid("当前页面不在脚本授权范围内。")
    }
    try EnhancementAssets.checkSyntax(script.source)
    let epoch = tab.navigationEpoch
    let (binding, world) = register(script, trial: true)
    let code = try source(script, binding: binding, trial: true)
    _ = try await tab.webView.callAsyncJavaScript(
      code, arguments: [:], in: nil, contentWorld: world)
    guard tab.navigationEpoch == epoch else { throw EnhancementError.invalid("页面已经变化，请重新检查脚本。") }
    if script.world == "page" { setStatus(script, status: "已试运行，请检查页面效果", error: "页面环境不提供原生运行回报。") }
  }
  func navigated() {
    menus = []
    statuses = []
    trialValues = [:]
    for (name, binding) in bindings.filter({ $0.value.trial }) {
      content?.removeScriptMessageHandler(forName: name, contentWorld: binding.world)
      bindings.removeValue(forKey: name)
    }
  }
  public func runMenu(_ menu: UserScriptMenu) async throws {
    guard let tab, let binding = bindings[menu.binding],
      let actual = store.state.scripts.first(where: { $0.id == binding.script.id }),
      actual.revision == binding.script.revision, binding.trial || actual.enabled,
      !actual.paused(at: tab.url)
    else { throw EnhancementError.invalid("脚本菜单已过期。") }
    let address =
      try await tab.webView.callAsyncJavaScript(
        "return location.href;", arguments: [:], in: menu.frame, contentWorld: binding.world)
      as? String
    guard let address, let url = URL(string: address), !actual.paused(at: url),
      binding.script.metadata.applies(
        to: url, mainFrame: menu.frame.isMainFrame, allFrames: binding.script.allFrames)
    else { throw EnhancementError.invalid("页面已超出脚本授权范围。") }
    guard store.state.scripts.first(where: { $0.id == actual.id })?.revision == actual.revision,
      bindings[menu.binding] != nil
    else { throw EnhancementError.invalid("脚本授权已变化。") }
    _ = try await tab.webView.callAsyncJavaScript(
      "if(globalThis.__aegisDocumentNonce!==nonce)throw Error('菜单已过期');return globalThis.__aegisRunMenu(key);",
      arguments: ["nonce": menu.nonce, "key": menu.key], in: menu.frame, contentWorld: binding.world
    )
  }
  private func setStatus(_ script: UserScriptRecord, status: String, error: String,
                         trial: Bool = false, mainFrame: Bool = true) {
    statuses.removeAll { $0.id == script.id }
    statuses.append(
      ScriptRunStatus(
        id: script.id, name: script.metadata.name, status: status, error: String(error.prefix(1000)),
        trial: trial, mainFrame: mainFrame
      ))
    if statuses.count > 64 { statuses.removeFirst() }
  }

  public func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
    replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
  ) {
    guard let text = message.body as? String, text.utf8.count <= 8192,
      let data = text.data(using: .utf8),
      let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let request = body["request"] as? String, request.count <= 30,
      let nonce = body["nonce"] as? String, UUID(uuidString: nonce) != nil,
      let binding = bindings[message.name], binding.world.name == message.world.name,
      let tab, message.webView === tab.webView,
      let url = message.frameInfo.request.url,
      binding.script.metadata.applies(
        to: url, mainFrame: message.frameInfo.isMainFrame, allFrames: binding.script.allFrames),
      !message.frameInfo.securityOrigin.host.isEmpty,
      let op = body["op"] as? String
    else {
      replyHandler(nil, "脚本调用范围无效。")
      return
    }
    let epoch = tab.navigationEpoch
    Task { @MainActor [weak self, weak tab] in
      guard let self, let tab else {
        replyHandler(nil, "页面已关闭。")
        return
      }
      do {
        let current = try await tab.webView.callAsyncJavaScript(
          "return globalThis.__aegisDocumentNonce === nonce && location.href === address;",
          arguments: ["nonce": nonce, "address": url.absoluteString], in: message.frameInfo,
          contentWorld: binding.world)
        guard current as? Bool == true, tab.navigationEpoch == epoch,
          self.bindings[message.name] != nil,
          let actual = self.store.state.scripts.first(where: { $0.id == binding.script.id }),
          actual.revision == binding.script.revision, binding.trial || actual.enabled,
          !actual.paused(at: tab.url), !actual.paused(at: url)
        else { throw EnhancementError.invalid("页面或脚本授权已变化。") }
        var value: Any = NSNull()
        let key = body["key"] as? String ?? ""
        switch op {
        case "get", "set", "delete":
          let grant = op == "get" ? "GM.getValue" : op == "set" ? "GM.setValue" : "GM.deleteValue"
          guard actual.metadata.grants.contains(grant), !key.isEmpty, key.utf8.count <= 200 else {
            throw EnhancementError.invalid("未授权的存储操作。")
          }
          if op == "get" {
            let saved =
              binding.trial
              ? self.trialValues[actual.id]?[key] : self.store.value(key, script: actual.id)
            if let saved {
              value = try JSONSerialization.jsonObject(
                with: Data(saved.json.utf8), options: .fragmentsAllowed)
            }
          } else {
            let item =
              op == "set"
              ? try ScriptValue(
                json: String(
                  decoding: JSONSerialization.data(
                    withJSONObject: body["value"] ?? NSNull(), options: .fragmentsAllowed),
                  as: UTF8.self)) : nil
            if binding.trial {
              var entries = self.trialValues[actual.id] ?? [:]
              entries[key] = item
              guard entries.count <= 128, try JSONEncoder().encode(entries).count <= 65_536 else {
                throw EnhancementError.invalid("试运行存储超过容量限制。")
              }
              self.trialValues[actual.id] = entries
            } else {
              try self.store.setValue(item, key: key, script: actual.id)
            }
          }
        case "menu":
          guard actual.metadata.grants.contains("GM_registerMenuCommand"),
            let label = body["label"] as? String, !label.isEmpty, label.count <= 100,
            (1...16).contains(Int(key) ?? 0), self.menus.count < 128
          else { throw EnhancementError.invalid("脚本菜单无效。") }
          let menuID = message.name + ":" + nonce + ":" + key
          self.menus.removeAll { $0.id == menuID }
          self.menus.append(
            UserScriptMenu(
              id: menuID, label: label, scriptID: actual.id, binding: message.name, key: key, frame: message.frameInfo,
              nonce: nonce))
        case "report":
          self.setStatus(
            actual, status: body["status"] as? String ?? "unknown",
            error: body["error"] as? String ?? "", trial: binding.trial,
            mainFrame: message.frameInfo.isMainFrame)
        default: throw EnhancementError.invalid("不支持的脚本操作。")
        }
        replyHandler(["request": request, "value": value], nil)
      } catch { replyHandler(["request": request, "error": error.localizedDescription], nil) }
    }
  }
}
