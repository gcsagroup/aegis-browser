import Foundation

struct MarkdownShareEnvelope: Codable {
  let nonce: UUID
  let title: String
  let text: String
  let expiresAt: Date
}

/// 分享扩展只传递用户选定的文档内容，不把提供方的临时文件路径交给主程序。
struct MarkdownShareInbox {
  private let root: URL
  init(
    root: URL? = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.com.gcsa.aegis.ios.share-inbox")
  ) throws {
    guard let root else { throw ShareInboxError.unavailableContainer }
    self.root = root
  }
  func store(title: String, data: Data, now: Date = Date()) throws {
    guard data.count <= 2_097_152, let text = String(data: data, encoding: .utf8),
      !text.contains("\0")
    else { throw ShareInboxError.invalidEnvelope }
    let envelope = MarkdownShareEnvelope(
      nonce: UUID(), title: String(title.prefix(300)), text: text,
      expiresAt: now.addingTimeInterval(60))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONEncoder().encode(envelope).write(
      to: root.appendingPathComponent("markdown-inbox-v1.json"),
      options: [.atomic, .completeFileProtection])
  }
  func consume(now: Date = Date()) throws -> MarkdownShareEnvelope? {
    let file = root.appendingPathComponent("markdown-inbox-v1.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 3_000_000 else {
      throw ShareInboxError.payloadTooLarge
    }
    let data = try Data(contentsOf: file)
    let envelope = try JSONDecoder().decode(MarkdownShareEnvelope.self, from: data)
    guard envelope.text.utf8.count <= 2_097_152, envelope.title.count <= 300 else {
      throw ShareInboxError.invalidEnvelope
    }
    if (try? Data(contentsOf: file)) == data { try FileManager.default.removeItem(at: file) }
    guard envelope.expiresAt > now, envelope.expiresAt.timeIntervalSince(now) <= 60 else {
      throw ShareInboxError.expired
    }
    return envelope
  }
}
