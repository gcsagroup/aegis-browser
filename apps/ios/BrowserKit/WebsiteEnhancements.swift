import Combine
import CryptoKit
import Foundation

public enum EnhancementError: LocalizedError {
  case invalid(String)
  public var errorDescription: String? {
    if case .invalid(let message) = self { return message }
    return nil
  }
}

public struct ScriptMetadata: Codable, Equatable, Sendable {
  public var name = ""
  public var namespace = ""
  public var version = "1.0"
  public var description = ""
  public var matches: [String] = []
  public var excludes: [String] = []
  public var grants: [String] = []
  public var runAt = "document-end"
  public var noframes = false
  public static let supportedGrants = [
    "GM_addStyle", "GM.getValue", "GM.setValue", "GM.deleteValue", "GM_registerMenuCommand",
  ]

  public static func parse(_ source: String) throws -> ScriptMetadata {
    guard source.utf8.count <= 65_536 else { throw EnhancementError.invalid("脚本超过 64 KiB。") }
    let lines = source.components(separatedBy: .newlines)
    guard
      let start = lines.firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces) == "// ==UserScript=="
      }),
      lines[..<start].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }),
      let end = lines[(start + 1)...].firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces) == "// ==/UserScript=="
      })
    else { throw EnhancementError.invalid("请在脚本开头提供完整的 UserScript 元数据。") }
    var result = ScriptMetadata()
    for line in lines[(start + 1)..<end] {
      let text = line.trimmingCharacters(in: .whitespaces)
      guard text.hasPrefix("//") else { continue }
      let item = text.dropFirst(2).trimmingCharacters(in: .whitespaces)
      guard item.hasPrefix("@") else { continue }
      let parts = item.dropFirst().split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
      guard let key = parts.first.map(String.init) else { continue }
      let value = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
      switch key {
      case "name", "namespace", "version", "description":
        guard value.utf8.count <= (key == "description" ? 4000 : 800) else {
          throw EnhancementError.invalid("元数据字段过长：" + key)
        }
        if key == "name" {
          result.name = value
        } else if key == "namespace" {
          result.namespace = value
        } else if key == "version" {
          result.version = value
        } else {
          result.description = value
        }
      case "match", "exclude":
        guard ScriptMatch.valid(value) else {
          throw EnhancementError.invalid("@\(key) 只支持 HTTP/HTTPS 匹配规则。")
        }
        if key == "match" { result.matches.append(value) } else { result.excludes.append(value) }
      case "grant":
        guard value == "none" || supportedGrants.contains(value) else {
          throw EnhancementError.invalid("不支持的权限：\(value)")
        }
        if value != "none", !result.grants.contains(value) { result.grants.append(value) }
      case "run-at":
        guard ["document-start", "document-end", "document-idle"].contains(value) else {
          throw EnhancementError.invalid("执行时机无效。")
        }
        result.runAt = value
      case "noframes": result.noframes = true
      default: throw EnhancementError.invalid("第一版尚不支持 @\(key)，请移除该依赖或改写脚本。")
      }
    }
    guard !result.name.isEmpty, (1...32).contains(result.matches.count), result.excludes.count <= 32
    else {
      throw EnhancementError.invalid("脚本需要名称与 1–32 条 @match 规则。")
    }
    return result
  }

  public func applies(to url: URL, mainFrame: Bool = true, allFrames: Bool = false) -> Bool {
    (mainFrame || (allFrames && !noframes)) && matches.contains { ScriptMatch.matches($0, url) }
      && !excludes.contains { ScriptMatch.matches($0, url) }
  }
}

public enum ScriptMatch {
  private static let expression =
    #"^(https?|\*)://(\*|\*\.[a-z0-9.-]+|[a-z0-9.-]+|\[[a-f0-9:]+\])(:\d{1,5})?(/[^\s]*)$"#
  private static func parts(_ pattern: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: expression, options: .caseInsensitive),
      let found = regex.firstMatch(in: pattern, range: NSRange(pattern.startIndex..., in: pattern))
    else { return nil }
    let parts = (1...4).map { i -> String in
      guard let r = Range(found.range(at: i), in: pattern) else { return "" }
      return String(pattern[r])
    }
    guard !parts[1].contains(".."),
      parts[2].isEmpty || (1...65535).contains(Int(parts[2].dropFirst()) ?? 0)
    else { return nil }
    return parts
  }
  public static func valid(_ pattern: String) -> Bool { parts(pattern) != nil }
  public static func matches(_ pattern: String, _ url: URL) -> Bool {
    guard let p = parts(pattern), let u = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme), u.user == nil,
      u.password == nil,
      let host = u.host?.lowercased()
    else { return false }
    guard p[0] == "*" || p[0].lowercased() == scheme else { return false }
    let desired = p[1].lowercased()
    if desired != "*" {
      if desired.hasPrefix("*.") {
        guard host == String(desired.dropFirst(2)) || host.hasSuffix(String(desired.dropFirst()))
        else { return false }
      } else if host != desired {
        return false
      }
    }
    if !p[2].isEmpty, Int(p[2].dropFirst()) != (u.port ?? (scheme == "https" ? 443 : 80)) {
      return false
    }
    let path =
      (u.percentEncodedPath.isEmpty ? "/" : u.percentEncodedPath)
      + (u.percentEncodedQuery.map { "?" + $0 } ?? "")
    let regex =
      "^"
      + p[3].components(separatedBy: "*").map(NSRegularExpression.escapedPattern(for:)).joined(
        separator: ".*") + "$"
    return path.range(of: regex, options: .regularExpression) != nil
  }
  public static func origin(_ url: URL) -> String? {
    guard var value = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = value.scheme?.lowercased(),
      ["http", "https"].contains(scheme), value.host != nil, value.user == nil,
      value.password == nil
    else { return nil }
    value.scheme = scheme
    value.host = value.host?.lowercased()
    if value.port == (scheme == "https" ? 443 : 80) { value.port = nil }
    value.path = ""
    value.query = nil
    value.fragment = nil
    return value.string
  }
}

public struct WebsiteEnhancementRule: Codable, Equatable, Identifiable, Sendable {
  public var origin: String
  public var subdomains = false
  public var menu = false
  public var copy = false
  public var debug = false
  public var disabled = false
  public var id: String { origin }
  public init(origin: String) { self.origin = origin }
  public func matches(_ url: URL) -> Bool {
    guard let target = ScriptMatch.origin(url), let a = URLComponents(string: origin),
      let b = URLComponents(string: target),
      a.scheme == b.scheme, a.port == b.port, let host = a.host, let other = b.host
    else { return false }
    return host == other || (subdomains && other.hasSuffix("." + host))
  }
}

public struct UserScriptVersion: Codable, Equatable, Sendable {
  public var source: String
  public var world: String
  public var allFrames: Bool
}

public struct UserScriptRecord: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var revision: Int
  public var source: String
  public var metadata: ScriptMetadata
  public var enabled: Bool
  public var world: String
  public var allFrames: Bool
  public var history: [UserScriptVersion]
  public var digest: String {
    SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

public struct ScriptValue: Codable, Equatable, Sendable {
  // 存储标准 JSON 字节，避免 Any 跨并发边界及类型丢失。
  public var json: String
  public init(json: String) throws {
    guard json.utf8.count <= 4096, let data = json.data(using: .utf8),
      (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil
    else { throw EnhancementError.invalid("存储值需要为 4 KiB 以内的 JSON。") }
    self.json = json
  }
}

public struct WebsiteEnhancementState: Codable, Equatable, Sendable {
  public var schema = 1
  public var revision = 0
  public var sites: [WebsiteEnhancementRule] = []
  public var scripts: [UserScriptRecord] = []
  public var values: [String: [String: ScriptValue]] = [:]
  public init() {}
}

/// 普通窗口共用一个实例；私密会话传入无文件实例，绝不读取普通脚本。
@MainActor
public final class WebsiteEnhancementStore: ObservableObject {
  public static let shared: WebsiteEnhancementStore = {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
          "ui-website-enhancements-v1.json")
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-enhancements-reset") {
          try? FileManager.default.removeItem(at: file)
        }
        return WebsiteEnhancementStore(fileURL: file)
      }
    #endif
    return WebsiteEnhancementStore(
      fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("website-enhancements-v1.json"))
  }()
  @Published public private(set) var state = WebsiteEnhancementState()
  @Published public private(set) var error: String?
  public let fileURL: URL?
  private var diskHash: Data?
  private var readable = true
  public init(fileURL: URL? = nil) {
    self.fileURL = fileURL
    guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      let bytes = try Data(contentsOf: fileURL)
      guard bytes.count <= 8_388_608 else { throw EnhancementError.invalid("脚本存储超过容量限制。") }
      let value = try JSONDecoder().decode(WebsiteEnhancementState.self, from: bytes)
      try Self.validate(value)
      state = value
      diskHash = Data(SHA256.hash(data: bytes))
    } catch {
      self.error = "无法读取脚本存储，原文件已保留：" + error.localizedDescription
      readable = false
    }
  }
  private static func validate(_ state: WebsiteEnhancementState) throws {
    guard state.schema == 1, state.sites.count <= 200, state.scripts.count <= 64,
      Set(state.scripts.map(\.id)).count == state.scripts.count,
      Set(state.sites.map(\.origin)).count == state.sites.count
    else { throw EnhancementError.invalid("脚本存储格式无效或超过容量限制。") }
    for site in state.sites {
      guard let url = URL(string: site.origin), ScriptMatch.origin(url) == site.origin else {
        throw EnhancementError.invalid("网站范围无效。")
      }
    }
    for script in state.scripts {
      guard UUID(uuidString: script.id) != nil, script.revision > 0,
        ["isolated", "page"].contains(script.world),
        try ScriptMetadata.parse(script.source) == script.metadata, script.history.count <= 5,
        script.world != "page" || script.metadata.grants.isEmpty
      else { throw EnhancementError.invalid("脚本内容或授权范围无效。") }
    }
    for (id, values) in state.values {
      guard state.scripts.contains(where: { $0.id == id }), values.count <= 128,
        (try JSONEncoder().encode(values)).count <= 65_536
      else { throw EnhancementError.invalid("脚本存储超限。") }
      for (key, value) in values {
        guard !key.isEmpty, key.utf8.count <= 200 else { throw EnhancementError.invalid("存储键无效。") }
        _ = try ScriptValue(json: value.json)
      }
    }
  }
  private func commit(_ value: WebsiteEnhancementState) throws {
    guard readable else { throw EnhancementError.invalid(error ?? "脚本存储不可读。") }
    var next = value
    next.revision += 1
    try Self.validate(next)
    let data = try JSONEncoder().encode(next)
    guard data.count <= 8_388_608 else {
      throw EnhancementError.invalid("脚本及历史版本合计超过 8 MiB，请先移除不用的内容。")
    }
    if let fileURL {
      let current =
        try FileManager.default.fileExists(atPath: fileURL.path)
        ? Data(SHA256.hash(data: Data(contentsOf: fileURL))) : nil
      guard current == diskHash else {
        throw EnhancementError.invalid("脚本存储已被另一处修改，请重新打开 App 后再操作。")
      }
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
      diskHash = Data(SHA256.hash(data: data))
    }
    state = next
    error = nil
  }
  public func rule(for url: URL) -> WebsiteEnhancementRule? {
    state.sites.filter { $0.matches(url) }.sorted { $0.origin.count > $1.origin.count }.first
  }
  public func saveRule(_ rule: WebsiteEnhancementRule) throws {
    var next = state
    next.sites.removeAll { $0.origin == rule.origin }
    next.sites.append(rule)
    try commit(next)
  }
  public func removeRule(_ origin: String) throws {
    var next = state
    next.sites.removeAll { $0.origin == origin }
    try commit(next)
  }
  @discardableResult
  public func saveScript(
    id: String? = nil, revision: Int? = nil, source: String, world: String = "isolated",
    allFrames: Bool = false
  ) throws -> UserScriptRecord {
    let metadata = try ScriptMetadata.parse(source)
    guard world != "page" || metadata.grants.isEmpty else {
      throw EnhancementError.invalid("页面环境不提供 GM 权限，请使用 @grant none。")
    }
    var next = state
    var history: [UserScriptVersion] = []
    var newRevision = 1
    if let id {
      guard let old = next.scripts.first(where: { $0.id == id }), old.revision == revision else {
        throw EnhancementError.invalid("脚本已在另一处修改，请重新打开后再保存。")
      }
      history = Array(
        (old.history + [
          UserScriptVersion(source: old.source, world: old.world, allFrames: old.allFrames)
        ]).suffix(5))
      newRevision = old.revision + 1
      next.scripts.removeAll { $0.id == id }
    }
    let record = UserScriptRecord(
      id: id ?? UUID().uuidString.lowercased(), revision: newRevision, source: source,
      metadata: metadata, enabled: false, world: world, allFrames: allFrames, history: history)
    next.scripts.append(record)
    try commit(next)
    return record
  }
  public func setEnabled(_ id: String, revision: Int, enabled: Bool) throws {
    var next = state
    guard let i = next.scripts.firstIndex(where: { $0.id == id && $0.revision == revision }) else {
      throw EnhancementError.invalid("脚本版本已变化。")
    }
    next.scripts[i].enabled = enabled
    next.scripts[i].revision += 1
    try commit(next)
  }
  public func disableAll() throws {
    var next = state
    for index in next.scripts.indices {
      next.scripts[index].enabled = false
      next.scripts[index].revision += 1
    }
    try commit(next)
  }
  public func removeScript(_ id: String) throws {
    var next = state
    next.scripts.removeAll { $0.id == id }
    next.values.removeValue(forKey: id)
    try commit(next)
  }
  @discardableResult
  public func rollback(_ id: String, revision: Int) throws -> UserScriptRecord {
    guard let script = state.scripts.first(where: { $0.id == id && $0.revision == revision }),
      let old = script.history.last
    else { throw EnhancementError.invalid("没有可回退的版本。") }
    return try saveScript(
      id: id, revision: revision, source: old.source, world: old.world, allFrames: old.allFrames)
  }
  public func value(_ key: String, script: String) -> ScriptValue? { state.values[script]?[key] }
  public func setValue(_ value: ScriptValue?, key: String, script: String) throws {
    var next = state
    var values = next.values[script] ?? [:]
    if let value { values[key] = value } else { values.removeValue(forKey: key) }
    next.values[script] = values
    try commit(next)
  }
}
