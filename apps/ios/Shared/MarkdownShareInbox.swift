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
  // 二进制属性列表的 UTF-16 字符串最多占原 UTF-8 字节数的两倍。
  private static let maximumEnvelopeBytes = MarkdownDocumentLimits.maximumBytes * 2 + 4096
  // 保留同一个原子更新的文件，旧版本留下的 JSON 仍可接收。
  private var file: URL { root.appendingPathComponent("markdown-inbox-v1.json") }
  init(
    root: URL? = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.com.gcsa.aegis.ios.share-inbox")
  ) throws {
    guard let root else { throw ShareInboxError.unavailableContainer }
    self.root = root
  }
  func store(title: String, data: Data, now: Date = Date()) throws {
    guard data.count <= MarkdownDocumentLimits.maximumBytes else { throw MarkdownDocumentLimits.TooLarge() }
    guard let text = String(data: data, encoding: .utf8),
      !text.contains("\0")
    else { throw ShareInboxError.invalidEnvelope }
    let envelope = MarkdownShareEnvelope(
      nonce: UUID(), title: String(title.prefix(300)), text: text,
      expiresAt: now.addingTimeInterval(60))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let data = try encoder.encode(envelope)
    guard data.count <= Self.maximumEnvelopeBytes else { throw ShareInboxError.invalidEnvelope }
    try data.write(to: file, options: [.atomic, .completeFileProtection])
  }
  func consume(now: Date = Date()) throws -> MarkdownShareEnvelope? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: Self.maximumEnvelopeBytes + 1) ?? Data()
    guard data.count <= Self.maximumEnvelopeBytes else { throw ShareInboxError.invalidEnvelope }
    let envelope = if data.starts(with: "bplist00".utf8) {
      try PropertyListDecoder().decode(MarkdownShareEnvelope.self, from: data)
    } else {
      try JSONDecoder().decode(MarkdownShareEnvelope.self, from: data)
    }
    guard envelope.text.utf8.count <= MarkdownDocumentLimits.maximumBytes,
      !envelope.text.contains("\0"), envelope.title.count <= 300
    else { throw ShareInboxError.invalidEnvelope }
    if (try? Data(contentsOf: file)) == data { try FileManager.default.removeItem(at: file) }
    guard envelope.expiresAt > now, envelope.expiresAt.timeIntervalSince(now) <= 60 else {
      throw ShareInboxError.expired
    }
    return envelope
  }
}
