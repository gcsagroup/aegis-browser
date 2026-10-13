import Combine
import Foundation

public enum SearchEngine: String, CaseIterable, Codable, Sendable {
    case duckDuckGo, google, bing, baidu, custom
    public var title: String {
        switch self {
        case .duckDuckGo: "DuckDuckGo"
        case .google: "Google"
        case .bing: "Bing"
        case .baidu: "百度"
        case .custom: String(localized: "自定义搜索")
        }
    }
}

public enum BrowserStartup: String, CaseIterable, Codable, Sendable {
    case restore, startPage, homePage
    public var title: String {
        switch self {
        case .restore: String(localized: "恢复上次普通标签")
        case .startPage: String(localized: "打开起始页")
        case .homePage: String(localized: "打开主页")
        }
    }
}

public enum SitePermission: String, CaseIterable, Codable, Sendable {
    case ask, deny
    public var title: String { self == .ask ? String(localized: "每次询问") : String(localized: "阻止") }
}

public struct SitePreferences: Codable, Equatable, Sendable {
    public var zoom: Double? = nil
    public var desktop: Bool? = nil
    public var javaScript: Bool? = nil
    public var markdownPreview: Bool? = nil
    public var hardenedSecurity: Bool? = nil
    public var strictFingerprinting: Bool? = nil
    public var camera: SitePermission = .ask
    public var microphone: SitePermission = .ask
    public init() { }
}

public struct BrowserPreferenceValues: Codable, Equatable, Sendable {
    public var searchEngine: SearchEngine? = .duckDuckGo
    // 旧版没有此字段，nil 表示全部可用；空的可用列表则明确关闭搜索。
    public var removedSearchEngines: [SearchEngine]? = nil
    public var customSearch = "https://www.google.com/search?q={searchTerms}"
    public var startup: BrowserStartup = .restore
    public var homepage = "https://www.apple.com/"
    public var newTabsUseHomepage = false
    public var zoom = 1.0
    public var desktop = false
    public var javaScript = true
    public var allowPopups = false
    public var requireMediaGesture = true
    public var saveHistory = true
    public var linkSanitization = true
    public var phishingProtection = true
    public var miningProtection: Bool? = nil
    public var fingerprintProtection: Bool? = nil
    public var hardenedSecurity: Bool? = nil
    public var strictFingerprinting: Bool? = nil
    public var automaticFilterUpdates = false
    public var sites: [String: SitePreferences] = [:]
    public init() { }

    public var availableSearchEngines: [SearchEngine] {
        SearchEngine.allCases.filter { !(removedSearchEngines ?? []).contains($0) }
    }

    public mutating func removeSearchEngine(_ engine: SearchEngine) {
        if !(removedSearchEngines ?? []).contains(engine) {
            removedSearchEngines = (removedSearchEngines ?? []) + [engine]
        }
        if searchEngine == engine { searchEngine = availableSearchEngines.first }
    }

    public mutating func restoreSearchEngines() {
        removedSearchEngines = nil
        if searchEngine == nil { searchEngine = .duckDuckGo }
    }
}

public enum BrowserPreferenceError: LocalizedError {
    case invalidSearch, invalidHomepage, invalidSite, tooManySites
    public var errorDescription: String? {
        switch self {
        case .invalidSearch: String(localized: "搜索模板必须是 HTTPS 地址，并在查询参数中包含一次 {searchTerms}。")
        case .invalidHomepage: String(localized: "主页必须是有效的 HTTP 或 HTTPS 地址，不能包含账号或密码。")
        case .invalidSite: String(localized: "只能为 HTTP 或 HTTPS 网站保存设置。")
        case .tooManySites: String(localized: "网站设置已达到 200 项，请先移除不用的设置。")
        }
    }
}

/// 应用和全部窗口共用同一实例；测试注入独立 defaults，避免覆盖日常配置。
@MainActor
public final class BrowserPreferences: ObservableObject {
    @Published public private(set) var values: BrowserPreferenceValues
    @Published public private(set) var error: String?
    private let defaults: UserDefaults
    private let key = "browser.preferences.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            do {
                let decoded = try JSONDecoder().decode(BrowserPreferenceValues.self, from: data)
                values = try Self.validated(decoded)
            } catch {
                values = BrowserPreferenceValues()
                self.error = String(localized: "浏览设置无法读取，暂用默认值。原设置已保留，保存新设置前请先检查。")
            }
        } else { values = BrowserPreferenceValues() }
    }

    public func save(_ proposed: BrowserPreferenceValues) throws {
        let next = try Self.validated(proposed)
        defaults.set(try JSONEncoder().encode(next), forKey: key)
        values = next; error = nil
    }

    public func setSite(_ site: SitePreferences?, for url: URL) throws {
        guard let origin = Self.origin(url) else { throw BrowserPreferenceError.invalidSite }
        var next = values
        next.sites[origin] = site
        try save(next)
    }

    public func site(for url: URL?) -> SitePreferences {
        guard let url, let origin = Self.origin(url) else { return SitePreferences() }
        return values.sites[origin] ?? SitePreferences()
    }

    /// 设置按来源隔离，HTTP、HTTPS 和不同端口不共享相机、麦克风及脚本规则。
    public nonisolated static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        var parts = URLComponents()
        parts.scheme = scheme; parts.host = host
        if let port = url.port, port != (scheme == "https" ? 443 : 80) { parts.port = port }
        return parts.string
    }

    public nonisolated static func searchURL(_ query: String, values: BrowserPreferenceValues) -> URL? {
        guard let engine = values.searchEngine, values.availableSearchEngines.contains(engine) else { return nil }
        var address: String
        var parameter: String
        switch engine {
        case .duckDuckGo: address = "https://duckduckgo.com/"; parameter = "q"
        case .google: address = "https://www.google.com/search"; parameter = "q"
        case .bing: address = "https://www.bing.com/search"; parameter = "q"
        case .baidu: address = "https://www.baidu.com/s"; parameter = "wd"
        case .custom:
            guard let components = try? validatedSearch(values.customSearch) else { return nil }
            var result = components
            result.queryItems = components.queryItems?.map {
                URLQueryItem(name: $0.name, value: $0.value?.replacingOccurrences(of: "{searchTerms}", with: query))
            }
            return result.url
        }
        var parts = URLComponents(string: address)
        parts?.queryItems = [URLQueryItem(name: parameter, value: query)]
        return parts?.url
    }

    public var homeURL: URL { URL(string: values.homepage) ?? URL(string: "aegis://start")! }

    /// 失败后的检查也记账，前后台切换不会形成规则服务请求风暴。
    public func claimFilterUpdate(lastSuccess: Date?, now: Date = Date()) -> Bool {
        guard values.automaticFilterUpdates,
              lastSuccess.map({ now.timeIntervalSince($0) >= 86_400 }) ?? true,
              (defaults.object(forKey: "browser.filter.lastAttempt") as? Date).map({ now.timeIntervalSince($0) >= 3_600 }) ?? true else { return false }
        defaults.set(now, forKey: "browser.filter.lastAttempt")
        return true
    }

    private nonisolated static func validatedSearch(_ template: String) throws -> URLComponents {
        guard template.components(separatedBy: "{searchTerms}").count == 2,
              let parts = URLComponents(string: template), parts.scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil, parts.fragment == nil,
              let query = parts.queryItems, query.filter({ $0.value?.contains("{searchTerms}") == true }).count == 1,
              !host.contains("searchTerms"), !parts.path.contains("searchTerms"),
              !query.contains(where: { $0.name.contains("searchTerms") }) else { throw BrowserPreferenceError.invalidSearch }
        return parts
    }

    private nonisolated static func validated(_ value: BrowserPreferenceValues) throws -> BrowserPreferenceValues {
        var next = value
        if next.searchEngine.map({ !next.availableSearchEngines.contains($0) }) ?? true {
            next.searchEngine = next.availableSearchEngines.first
        }
        if next.searchEngine == .custom { _ = try validatedSearch(next.customSearch) }
        next.homepage = next.homepage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let home = URL(string: next.homepage), origin(home) != nil else { throw BrowserPreferenceError.invalidHomepage }
        guard next.sites.count <= 200 else { throw BrowserPreferenceError.tooManySites }
        next.zoom = next.zoom.isFinite ? min(2, max(0.5, next.zoom)) : 1
        for (originKey, var site) in next.sites {
            guard let url = URL(string: originKey), origin(url) == originKey else { throw BrowserPreferenceError.invalidSite }
            if let zoom = site.zoom { site.zoom = zoom.isFinite ? min(2, max(0.5, zoom)) : 1 }
            next.sites[originKey] = site
        }
        return next
    }
}
