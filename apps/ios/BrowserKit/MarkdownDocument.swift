import Foundation
import UIKit
import WebKit

/// 与系统打印共用版式，避免把阅读工具栏和屏幕高度写入 PDF。
@MainActor
public enum MarkdownPDFExporter {
  public static func data(from webView: WKWebView) -> Data {
    let renderer = MarkdownPrintRenderer()
    renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
    renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
    return UIGraphicsPDFRenderer(bounds: renderer.paperRect).pdfData { context in
      for page in 0..<renderer.numberOfPages {
        context.beginPage()
        renderer.drawPage(at: page, in: renderer.paperRect)
      }
    }
  }
}

@MainActor
private final class MarkdownPrintRenderer: UIPrintPageRenderer {
  override var paperRect: CGRect { CGRect(x: 0, y: 0, width: 595.2, height: 841.8) }
  override var printableRect: CGRect { paperRect.insetBy(dx: 36, dy: 36) }
}

public struct MarkdownDocument: Identifiable, Sendable {
  public let id: UUID
  public var title: String
  public var text: String
  public var sourceURL: URL?
  public var resources: [String: String]
  public init(title: String, text: String, sourceURL: URL? = nil, resources: [String: String] = [:])
  {
    id = UUID()
    self.title = title
    self.text = text
    self.sourceURL = sourceURL
    self.resources = resources
  }
  public static let maximumBytes = 2_097_152
  public static func accepts(_ url: URL) -> Bool {
    ["md", "markdown"].contains(url.pathExtension.lowercased())
  }
  public static func read(_ url: URL) throws -> MarkdownDocument {
    guard url.isFileURL else { throw EnhancementError.invalid("请选择本地 Markdown 文件。") }
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= maximumBytes else {
      throw EnhancementError.invalid("文档超过 2 MiB 或不是普通文件。")
    }
    let bytes = try Data(contentsOf: url)
    guard bytes.count <= maximumBytes, let text = String(data: bytes, encoding: .utf8),
      !text.contains("\0")
    else { throw EnhancementError.invalid("请使用不含二进制内容的 UTF-8 Markdown 文件。") }
    return MarkdownDocument(title: url.lastPathComponent, text: text, sourceURL: url)
  }
  @MainActor public static func capture(_ tab: BrowserTab) async throws -> MarkdownDocument {
    guard let url = tab.url, ScriptMatch.origin(url) != nil else {
      throw EnhancementError.invalid("当前页面不是在线 Markdown 原始文件。")
    }
    let epoch = tab.navigationEpoch
    let text = try await tab.webView.callAsyncJavaScript(
      """
      if(!['text/plain','text/markdown','text/x-markdown'].includes(document.contentType))throw Error('当前页面已经由网站排版，请打开 Raw 原始文件');
      const text=(document.querySelector('body>pre')||document.body)?.textContent||'';
      if(new TextEncoder().encode(text).length>2097152)throw Error('文档超过 2 MiB，请下载查看原文件');
      return text;
      """, arguments: [:], in: nil, contentWorld: .defaultClient)
    guard tab.navigationEpoch == epoch, tab.url == url, let source = text as? String else {
      throw EnhancementError.invalid("页面已变化，请重新打开文档。")
    }
    return MarkdownDocument(
      title: url.lastPathComponent.isEmpty ? "Markdown" : url.lastPathComponent, text: source,
      sourceURL: url)
  }
  public mutating func loadResources(from directory: URL, references: [String]) throws -> Int {
    guard sourceURL == nil || sourceURL?.isFileURL == true else {
      throw EnhancementError.invalid("在线文档不能读取本地图片目录。")
    }
    guard directory.isFileURL else { throw EnhancementError.invalid("请选择本地资源目录。") }
    let access = directory.startAccessingSecurityScopedResource()
    defer { if access { directory.stopAccessingSecurityScopedResource() } }
    let root = directory.standardizedFileURL.resolvingSymlinksInPath()
    let documentDirectory =
      sourceURL?.isFileURL == true
      ? sourceURL!.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() : root
    let base =
      documentDirectory.path == root.path || documentDirectory.path.hasPrefix(root.path + "/")
      ? documentDirectory : root
    var result: [String: String] = [:]
    var total = 0
    for reference in references.prefix(100) {
      guard !reference.hasPrefix("/"),
        let url = URL(string: reference, relativeTo: base.appendingPathComponent("/"))?.absoluteURL,
        url.isFileURL
      else { continue }
      let path = url.standardizedFileURL.resolvingSymlinksInPath()
      guard path.path.hasPrefix(root.path + "/") else { continue }
      let types = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp",
      ]
      guard let mime = types[path.pathExtension.lowercased()],
        let values = try? path.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
        values.isRegularFile == true, (values.fileSize ?? Int.max) <= 4_194_304
      else { continue }
      let bytes = try Data(contentsOf: path)
      total += bytes.count
      guard bytes.count <= 4_194_304, total <= 10_485_760 else {
        throw EnhancementError.invalid("所选图片合计超过 10 MiB。")
      }
      result[reference] = "data:\(mime);base64," + bytes.base64EncodedString()
    }
    resources = result
    return result.count
  }
}
