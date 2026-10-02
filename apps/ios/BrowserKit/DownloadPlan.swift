import Foundation

/// 一个文件对应一组完整镜像；失败后从下一镜像重新下载，不混接不同服务器的字节。
public struct DownloadPlan: Equatable, Sendable {
    public var urls: [URL]
    public var filename: String?
    public var size: Int64?
    public var sha256: String?
    public var sha512: String?

    public init(urls: [URL], filename: String? = nil, size: Int64? = nil, sha256: String? = nil, sha512: String? = nil) {
        self.urls = urls; self.filename = filename; self.size = size; self.sha256 = sha256; self.sha512 = sha512
    }

    @MainActor public static func metalink(_ data: Data) throws -> DownloadPlan {
        guard data.count <= 1_048_576, let xml = String(data: data, encoding: .utf8),
              !xml.uppercased().contains("<!DOCTYPE"), !xml.uppercased().contains("<!ENTITY") else { throw DownloadPlanError.invalidMetalink }
        let reader = MetalinkReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), !reader.invalid, reader.files == 1, reader.stack.isEmpty,
              let filename = reader.filename, !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\"), filename == DownloadManager.safeFilename(filename),
              !reader.mirrors.isEmpty, reader.mirrors.count <= 16 else { throw DownloadPlanError.invalidMetalink }
        let urls = try reader.mirrors.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map { entry in
            let url = try DownloadManager.validatedURL(entry.2)
            guard let host = url.host?.lowercased(), url.fragment == nil, host != "localhost",
                  !host.hasSuffix(".localhost"), !host.hasSuffix(".local"), !host.contains(":"),
                  host.split(separator: ".").contains(where: { Int($0) == nil }) else { throw DownloadPlanError.invalidMetalink }
            return url
        }
        guard reader.sha256 != nil || reader.sha512 != nil else { throw DownloadPlanError.invalidMetalink }
        return DownloadPlan(urls: urls, filename: filename, size: reader.size, sha256: reader.sha256, sha512: reader.sha512)
    }
}

public enum DownloadPlanError: LocalizedError {
    case invalidMetalink, invalidMirrors, sizeMismatch
    public var errorDescription: String? {
        switch self {
        case .invalidMetalink: String(localized: "Metalink 无效：需要单个文件、公开 HTTP(S) 镜像及 SHA-256 或 SHA-512 校验值。")
        case .invalidMirrors: String(localized: "请提供 1 至 16 个不同的文件镜像地址。")
        case .sizeMismatch: String(localized: "文件大小与 Metalink 不一致，已丢弃本次文件。")
        }
    }
}

private final class MetalinkReader: NSObject, XMLParserDelegate {
    var stack: [String] = []
    var invalid = false
    var files = 0
    var filename: String?
    var mirrors: [(Int, Int, String)] = []
    var size: Int64?
    var sha256: String?
    var sha512: String?
    private var text = ""
    private var attributes: [String: String] = [:]
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard namespaceURI == "urn:ietf:params:xml:ns:metalink", stack.count < 8 else { invalid = true; parser.abortParsing(); return }
        if let parent = stack.last, ["url", "size", "hash"].contains(parent) { invalid = true }
        if stack.isEmpty && name != "metalink" { invalid = true }
        if name == "file" { files += 1; filename = attributes["name"]; if stack != ["metalink"] { invalid = true } }
        if ["url", "size", "hash"].contains(name) && stack != ["metalink", "file"] { invalid = true }
        stack.append(name); self.attributes = attributes; text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stack == ["metalink", "file", "url"] {
            let priority = Int(attributes["priority"] ?? "999999") ?? 0
            if priority < 1 || mirrors.count >= 16 { invalid = true }
            mirrors.append((priority, mirrors.count, value))
        } else if stack == ["metalink", "file", "size"] {
            if size != nil || Int64(value) == nil || Int64(value)! < 0 || Int64(value)! > 1_000_000_000 { invalid = true }
            size = Int64(value)
        } else if stack == ["metalink", "file", "hash"] {
            let hash = value.lowercased()
            if attributes["type"] == "sha-256" {
                if sha256 != nil || hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) == nil { invalid = true }
                sha256 = hash
            } else if attributes["type"] == "sha-512" {
                if sha512 != nil || hash.range(of: "^[a-f0-9]{128}$", options: .regularExpression) == nil { invalid = true }
                sha512 = hash
            }
        }
        stack.removeLast(); text = ""
    }
}
