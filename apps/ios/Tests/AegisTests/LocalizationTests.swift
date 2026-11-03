import XCTest
import WebKit
@testable import Aegis
@testable import BrowserKit

final class LocalizationTests: XCTestCase {
    private let locales = ["de", "en", "es", "fr", "id", "it", "ja", "ko", "ms", "pt", "th", "vi", "zh-Hans", "zh-Hant"]

    func testRegionalLanguagesSelectExistingTranslations() {
        for (preferred, resource) in [("en-GB", "en"), ("en-HK", "en"), ("zh-Hant-HK", "zh-Hant")] {
            XCTAssertEqual(Bundle.preferredLocalizations(from: Bundle.main.localizations,
                                                        forPreferences: [preferred]).first, resource)
        }
    }

    func testBuiltAppAndExtensionsContainLocalizedResources() throws {
        for locale in locales {
            let path = try XCTUnwrap(Bundle.main.path(forResource: locale, ofType: "lproj"))
            let localized = try XCTUnwrap(Bundle(path: path))
            for key in ["完成", "搜索或输入网址", "安心浏览，清楚掌控。", "正在验证分享链接…", "分享内容已过期"] {
                XCTAssertNotEqual(localized.localizedString(forKey: key, value: "MISSING", table: nil), "MISSING", "\(locale)/\(key)")
            }
            for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription", "Markdown 文档"] {
                XCTAssertNotEqual(localized.localizedString(forKey: key, value: "MISSING", table: "InfoPlist"), "MISSING")
            }
            for name in ["ShareExtension", "SafariWebExtension"] {
                let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
                let ext = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("\(name).appex")))
                let directory = try XCTUnwrap(ext.path(forResource: locale, ofType: "lproj"))
                let resources = try XCTUnwrap(Bundle(path: directory))
                XCTAssertNotEqual(resources.localizedString(forKey: "CFBundleDisplayName", value: "MISSING", table: "InfoPlist"), "MISSING")
                if name == "ShareExtension" {
                    XCTAssertNotEqual(resources.localizedString(forKey: "分享内容已过期", value: "MISSING", table: nil), "MISSING")
                }
            }
        }
    }

    func testShareErrorsUseTheActiveAppLanguage() {
        let cases: [(ShareInboxError, String)] = [
            (.unsupportedScheme, "只接受 HTTP(S) 链接"), (.payloadTooLarge, "分享内容超过 8 KiB"),
            (.invalidEnvelope, "分享内容格式无效"), (.expired, "分享内容已过期"),
            (.unavailableContainer, "专用 Share Inbox 不可用"),
        ]
        for (error, key) in cases {
            XCTAssertEqual(error.errorDescription, Bundle.main.localizedString(forKey: key, value: nil, table: nil))
        }
    }

    func testStartPageUsesTheAppLanguage() {
        let html = FixtureSchemeHandler.html(for: URL(string: "aegis://start")!)
        let language = Bundle.main.preferredLocalizations.first ?? "zh-Hans"
        XCTAssertTrue(html.contains("<html lang=\"\(language)\""))
        XCTAssertTrue(html.contains(String(localized: "安心浏览，清楚掌控。")))
    }

    @MainActor
    func testWebExtensionMetadataUsesTheAppLanguage() async throws {
        let locale = Bundle.main.preferredLocalizations.first ?? "zh-Hans"
        let extensionLocale = ["zh-Hans": "zh_CN", "zh-Hant": "zh_TW", "pt": "pt_PT"][locale] ?? locale
        let root = try XCTUnwrap(Bundle.main.resourceURL)
        let messagesURL = root.appendingPathComponent("_locales/\(extensionLocale)/messages.json")
        let messages = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: messagesURL)) as? [String: [String: String]])
        let webExtension = try await WKWebExtension(resourceBaseURL: root)
        XCTAssertEqual(webExtension.displayName, messages["extensionName"]?["message"])
        XCTAssertEqual(webExtension.displayDescription, messages["extensionDescription"]?["message"])
        XCTAssertEqual(webExtension.displayActionLabel, messages["extensionAction"]?["message"])
        XCTAssertTrue(webExtension.errors.isEmpty)
    }
}
