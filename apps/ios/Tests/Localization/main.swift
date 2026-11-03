import Foundation
import WebKit

// Run in a fresh process for each -AppleLanguages value: Bundle caches language choices.
let bundle = Bundle(path: CommandLine.arguments[1])!
let locale = CommandLine.arguments[2]
let expected: [String: String] = ["en-GB": "en", "en-HK": "en", "zh-Hant-HK": "zh-Hant"]
let resolved = expected[locale] ?? locale
precondition(bundle.preferredLocalizations.first == resolved,
             "Unexpected selection for \(locale): \(bundle.preferredLocalizations)")
precondition(Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: [locale]).first == resolved)

let tableURL = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: resolved)!
let table = try PropertyListSerialization.propertyList(from: Data(contentsOf: tableURL), format: nil) as! [String: String]
let source = try JSONDecoder().decode([String: [String: String]].self,
    from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
let expectedTable = source[resolved]!
precondition(table == expectedTable, "Compiled catalog differs from source for \(locale)")
for (key, literal) in expectedTable {
    precondition(bundle.localizedString(forKey: key, value: "MISSING", table: nil) == literal,
                 "Failed resource lookup for \(locale): \(key)")
}
let probes = try JSONDecoder().decode([String: [String: String]].self,
    from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[7])))
for (key, translations) in probes {
    precondition(bundle.localizedString(forKey: key, value: "MISSING", table: nil) == translations[resolved],
                 "Consent/data-boundary literal changed for \(locale): \(key)")
}
print("PASS \(locale): \(expectedTable.count) source/compiled lookups; \(probes.count) consent/data-boundary literals")
for target in ["AegisApp", "ShareExtension", "SafariWebExtension"] {
    let native = Bundle(path: CommandLine.arguments[4] + "/\(target).bundle")!
    precondition(native.preferredLocalizations.first == resolved)
    let key = target == "AegisApp" ? "NSCameraUsageDescription" : "CFBundleDisplayName"
    let value = native.object(forInfoDictionaryKey: key) as? String
    precondition(value != nil && value != "UNLOCALIZED", "System strings failed: \(target)/\(locale)")
    let expectedInfo = native.localizedString(forKey: key, value: "MISSING", table: "InfoPlist")
    precondition(value == expectedInfo)
    if target == "AegisApp" {
        for extra in ["NSMicrophoneUsageDescription", "Markdown 文档"] {
            precondition(native.localizedString(forKey: extra, value: "MISSING", table: "InfoPlist") != "MISSING")
        }
    }
}

let number = String(format: bundle.localizedString(forKey: "标签 %lld", value: nil, table: nil), Int64(7))
precondition(number.contains("7") && !number.contains("%"))
let failure = String(format: bundle.localizedString(forKey: "页面加载失败：%@", value: nil, table: nil), "example.test")
precondition(failure.contains("example.test") && !failure.contains("%@"))
let html = FixtureSchemeHandler.html(for: URL(string: "aegis://start")!, bundle: bundle)
precondition(html.contains("<html lang=\"\(resolved)\""))
let title = table["安心浏览，清楚掌控。"]!
precondition(html.contains(title), "Localized start page is missing its heading")

// A separate fixture checks that translated content cannot become markup.
let hostile = Bundle(path: CommandLine.arguments[5])!
let hostileHTML = FixtureSchemeHandler.html(for: URL(string: "aegis://start")!, bundle: hostile)
precondition(hostileHTML.contains("&lt;script&gt; &amp; &quot; &#39;"))
precondition(!hostileHTML.contains("<script>"))

// Localization must not change URL acceptance, payload limits, or expiration.
let inbox = try ShareInbox(baseURL: URL(fileURLWithPath: CommandLine.arguments[4]))
for input in ["file:///private/file", "javascript:alert(1)", "https://user:secret@example.test/"] {
    do { _ = try inbox.makeEnvelope(from: input); preconditionFailure("Accepted unsafe URL") }
    catch { precondition(error as? ShareInboxError == .unsupportedScheme) }
}
do { _ = try inbox.makeEnvelope(from: String(repeating: "a", count: 8193)); preconditionFailure("Accepted oversized content") }
catch { precondition(error as? ShareInboxError == .payloadTooLarge) }
let now = Date(timeIntervalSince1970: 1_800_000_000)
let envelope = try inbox.makeEnvelope(from: "https://example.test/", now: now)
precondition(envelope.expiresAt.timeIntervalSince(now) == 60)
for (error, key) in [
    (ShareInboxError.unsupportedScheme, "只接受 HTTP(S) 链接"), (.payloadTooLarge, "分享内容超过 8 KiB"),
    (.invalidEnvelope, "分享内容格式无效"), (.expired, "分享内容已过期"),
    (.unavailableContainer, "专用 Share Inbox 不可用"),
] {
    precondition(error.errorDescription == bundle.localizedString(forKey: key, value: nil, table: nil))
}
if #available(macOS 15.4, *) {
    let extensionRoot = URL(fileURLWithPath: CommandLine.arguments[6])
    let webExtension = try await WKWebExtension(resourceBaseURL: extensionRoot)
    let extensionLocale = ["zh-Hans": "zh_CN", "zh-Hant": "zh_TW", "pt": "pt_PT"][resolved] ?? resolved
    let messagesURL = extensionRoot.appendingPathComponent("_locales/\(extensionLocale)/messages.json")
    let messages = try JSONSerialization.jsonObject(with: Data(contentsOf: messagesURL)) as! [String: [String: String]]
    precondition(webExtension.displayName == messages["extensionName"]?["message"], "WebExtension name mismatch: \(locale), \(webExtension.displayName ?? "nil")")
    precondition(webExtension.displayDescription == messages["extensionDescription"]?["message"])
    precondition(webExtension.displayActionLabel == messages["extensionAction"]?["message"])
    precondition(webExtension.errors.isEmpty, "Manifest errors: \(webExtension.errors)")
} else {
    preconditionFailure("WebKit metadata checks require macOS 15.4 or later")
}
print("PASS \(locale) -> \(resolved): lookup, system strings, formatting, HTML, share validation, WebKit metadata")
