import Foundation

struct MarkdownShareEnvelope: Codable, Sendable {
  let nonce: UUID
  let title: String
  let text: String
  let expiresAt: Date
}

/// File moves provide cross-process ownership; the actor below only isolates local I/O.
struct MarkdownShareInbox: Sendable {
  static let maximumTextBytes = MarkdownDocumentLimits.maximumBytes
  static let maximumTitleBytes = 1_200
  static let maximumEnvelopeBytes = 6 * (maximumTextBytes + maximumTitleBytes) + 1_024
  private let root: URL
  init(root: URL? = FileManager.default.containerURL(
    forSecurityApplicationGroupIdentifier: "group.com.gcsa.aegis.ios.share-inbox")) throws {
    guard let root else { throw ShareInboxError.unavailableContainer }
    self.root = root
  }
  func store(title: String, data: Data, now: Date = Date()) throws {
    guard data.count <= Self.maximumTextBytes else { throw MarkdownDocumentLimits.TooLarge() }
    guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
      throw ShareInboxError.invalidEnvelope
    }
    var boundedTitle = ""
    for character in title.prefix(300) {
      guard boundedTitle.utf8.count + String(character).utf8.count <= Self.maximumTitleBytes else { break }
      boundedTitle.append(character)
    }
    let envelope = MarkdownShareEnvelope(nonce: UUID(), title: boundedTitle, text: text,
      expiresAt: now.addingTimeInterval(60))
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let encoded = try encoder.encode(envelope)
    guard encoded.count <= Self.maximumEnvelopeBytes else { throw MarkdownDocumentLimits.TooLarge() }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try encoded.write(to: root.appendingPathComponent("markdown-inbox-v1.json"),
      options: [.atomic, .completeFileProtection])
  }
  func consume(now: Date = Date(), afterClaim: () throws -> Void = {}) throws -> MarkdownShareEnvelope? {
    removeExpiredClaims(now: now)
    let source = root.appendingPathComponent("markdown-inbox-v1.json")
    // Keep this namespace distinct from link-inbox crash cleanup.
    let claimed = root.appendingPathComponent(".markdown-claim-\(UUID().uuidString).json")
    do { try FileManager.default.moveItem(at: source, to: claimed) }
    catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
    defer { try? FileManager.default.removeItem(at: claimed) }
    try afterClaim()
    let values = try claimed.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ShareInboxError.invalidEnvelope }
    let stream = try FileHandle(forReadingFrom: claimed)
    defer { try? stream.close() }
    var data = Data()
    while let chunk = try stream.read(upToCount: min(65_536, Self.maximumEnvelopeBytes + 1 - data.count)), !chunk.isEmpty {
      data.append(chunk)
      guard data.count <= Self.maximumEnvelopeBytes else { throw MarkdownDocumentLimits.TooLarge() }
    }
    let envelope = if data.starts(with: "bplist00".utf8) {
      try PropertyListDecoder().decode(MarkdownShareEnvelope.self, from: data)
    } else {
      try JSONDecoder().decode(MarkdownShareEnvelope.self, from: data)
    }
    guard envelope.text.utf8.count <= Self.maximumTextBytes,
      !envelope.text.contains("\0"), envelope.title.count <= 300,
      envelope.title.utf8.count <= Self.maximumTitleBytes else { throw ShareInboxError.invalidEnvelope }
    let remaining = envelope.expiresAt.timeIntervalSince(now)
    guard remaining.isFinite, remaining > 0, remaining <= 60 else { throw ShareInboxError.expired }
    return envelope
  }

  private func removeExpiredClaims(now: Date) {
    guard let files = try? FileManager.default.contentsOfDirectory(at: root,
      includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]) else { return }
    for file in files where file.lastPathComponent.hasPrefix(".markdown-claim-") {
      guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
        values.isRegularFile == true, values.isSymbolicLink != true,
        let modified = values.contentModificationDate, modified < now.addingTimeInterval(-65) else { continue }
      try? FileManager.default.removeItem(at: file)
    }
  }
}

actor ShareInboxIO {
  static let shared = ShareInboxIO()
  func markdown(root: URL? = nil) throws -> MarkdownShareEnvelope? {
    try Task.checkCancellation()
    if let root { return try MarkdownShareInbox(root: root).consume() }
    return try MarkdownShareInbox().consume()
  }
  func link(root: URL? = nil) throws -> URL? {
    try Task.checkCancellation()
    if let root { return try ShareInbox(baseURL: root).consume()?.url }
    return try ShareInbox().consume()?.url
  }
  func storeMarkdown(title: String, data: Data) throws {
    try Task.checkCancellation()
    try MarkdownShareInbox().store(title: title, data: data)
  }
  func storeLink(_ value: String) throws {
    try Task.checkCancellation()
    let inbox = try ShareInbox()
    try inbox.store(inbox.makeEnvelope(from: value))
  }
}
