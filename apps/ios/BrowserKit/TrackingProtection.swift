import Combine
import CryptoKit
import Foundation
import WebKit

private struct SavedContentFilters: Codable {
    let compilation: ContentFilterCompilation
    let updatedAt: Date
}

private final class FilterRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
public final class TrackingProtection: ObservableObject {
    public static let shared = TrackingProtection()
    public static let sources = [URL(string: "https://easylist.to/easylist/easylist.txt")!, URL(string: "https://easylist.to/easylist/easyprivacy.txt")!]
    @Published public private(set) var networkCount = 31
    @Published public private(set) var cosmeticCount = 0
    @Published public private(set) var skippedCount = 0
    @Published public private(set) var updatedAt: Date?
    @Published public private(set) var updating = false
    @Published public private(set) var failure: String?
    @Published public private(set) var revision = 0
    public private(set) var currentList: WKContentRuleList?
    private var loading: Task<WKContentRuleList, Error>?
    private let persistenceURL: URL

    public init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("content-filters-v1.json")
    }
    public static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "tracking.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tracking.enabled") }
    }
    public static var exceptionHosts: [String] { UserDefaults.standard.stringArray(forKey: "tracking.exceptions") ?? [] }
    public static func isExcepted(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return exceptionHosts.contains(host)
    }
    public static func removeException(host: String) {
        UserDefaults.standard.set(exceptionHosts.filter { $0 != host }, forKey: "tracking.exceptions")
    }
    public static func setException(_ value: Bool, for url: URL) {
        guard let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme ?? "") else { return }
        var hosts = Set(exceptionHosts)
        if value { hosts.insert(host) } else { hosts.remove(host) }
        UserDefaults.standard.set(hosts.sorted(), forKey: "tracking.exceptions")
    }

    public func ruleList() async throws -> WKContentRuleList {
        if let currentList { return currentList }
        if let loading { return try await loading.value }
        let task = Task { @MainActor in
            if let data = try? Data(contentsOf: persistenceURL), data.count <= 40_000_000,
               let saved = try? JSONDecoder().decode(SavedContentFilters.self, from: data),
               let list = try? await compile(saved.compilation.json) {
                accept(saved.compilation, list: list, date: saved.updatedAt)
                return list
            }
            let bundle = Bundle(for: BrowserSession.self)
            let texts = try ["easylist", "easyprivacy"].map { name in
                guard let url = bundle.url(forResource: name, withExtension: "txt") else { throw CocoaError(.fileNoSuchFile) }
                return try String(contentsOf: url, encoding: .utf8)
            }
            let compiled = try await Task.detached(priority: .utility) { try ContentFilterCompiler.compile(texts) }.value
            let list = try await compile(compiled.json)
            accept(compiled, list: list, date: nil)
            return list
        }
        loading = task
        do { let value = try await task.value; loading = nil; return value }
        catch { failure = error.localizedDescription; loading = nil; throw error }
    }

    /// 两份列表全部下载、转换及 WebKit 编译成功后才原子替换；失败保留旧规则。
    public func update() async {
        guard !updating else { return }
        updating = true; failure = nil
        defer { updating = false }
        do {
            _ = try await ruleList()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 90
            let session = URLSession(configuration: configuration, delegate: FilterRedirectGuard(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var texts: [String] = []
            for url in Self.sources {
                let (bytes, response) = try await session.bytes(from: url)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.url == url,
                      response.expectedContentLength <= 6_000_000 else { throw ContentFilterError.invalidResponse }
                var data = Data()
                for try await byte in bytes {
                    if data.count >= 6_000_000 { throw ContentFilterError.tooLarge }
                    data.append(byte)
                }
                guard let text = String(data: data, encoding: .utf8), text.hasPrefix("[Adblock") else { throw ContentFilterError.invalidResponse }
                texts.append(text)
            }
            let compilation = try await Task.detached(priority: .utility) { try ContentFilterCompiler.compile(texts) }.value
            let list = try await compile(compilation.json)
            try Task.checkCancellation()
            let saved = SavedContentFilters(compilation: compilation, updatedAt: Date())
            let data = try JSONEncoder().encode(saved)
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: persistenceURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            accept(compilation, list: list, date: saved.updatedAt)
        } catch { failure = error.localizedDescription }
    }
    private func compile(_ json: String) async throws -> WKContentRuleList {
        let version = SHA256.hash(data: Data(json.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let identifier = "aegis-trackers-\(version)"
        if let existing = try? await WKContentRuleListStore.default().contentRuleList(forIdentifier: identifier) { return existing }
        guard let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) else { throw CocoaError(.coderInvalidValue) }
        return list
    }
    private func accept(_ value: ContentFilterCompilation, list: WKContentRuleList, date: Date?) {
        currentList = list; networkCount = value.networkCount; cosmeticCount = value.cosmeticCount
        skippedCount = value.skippedCount; updatedAt = date; revision += 1; failure = nil
    }
}
