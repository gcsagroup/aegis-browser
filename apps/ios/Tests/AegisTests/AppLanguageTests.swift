import XCTest
import WebKit
import SwiftUI
@testable import Aegis
@testable import BrowserKit
@testable import AgentKit

@MainActor
final class AppLanguageTests: XCTestCase {
    private var streamedText = ""
    private final class Defaults: Aegis.AegisLanguageDefaults {
        var values: [String: Any] = ["unrelated": "keep"]
        func string(forKey key: String) -> String? { values[key] as? String }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    }

    private struct PolicyCase: Decodable {
        let name: String
        let selected: String?
        let preferences: [String]
        let systemLocale: String
        let family: String
        let dialect: String
        let appResource: String
        let agentResource: String
        let nativeDialect: String?
        let nativeAgentResource: String?
    }

    func testIndependentPolicyFixturesAndResourceOwners() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "language-policy", withExtension: "json",
                                                         subdirectory: "Fixtures/Localization"))
        let cases = try JSONDecoder().decode([PolicyCase].self, from: Data(contentsOf: url))
        XCTAssertEqual(cases.count, 51)
        let agent = try XCTUnwrap(Bundle(identifier: "com.gcsa.aegis.agentkit"))
        for item in cases {
            let snapshot = Aegis.AegisLocalizationSnapshot.resolve(
                choice: item.selected.flatMap(Aegis.AegisLanguageChoice.init(rawValue:)),
                preferences: item.preferences, systemLocale: Locale(identifier: item.systemLocale))
            XCTAssertEqual(snapshot.family.rawValue, item.family, item.name)
            XCTAssertEqual(snapshot.dialect, item.dialect, item.name)
            XCTAssertEqual(Aegis.AegisLocalization.resourceLocalization(in: .main, snapshot: snapshot), item.appResource, item.name)
            XCTAssertEqual(Aegis.AegisLocalization.resourceLocalization(in: agent, snapshot: snapshot), item.agentResource, item.name)
            let selectedDefaults = Defaults()
            selectedDefaults.set(item.selected, forKey: Aegis.AegisLanguagePreferenceStore.key)
            let native = Aegis.AegisLocalization.snapshot(store: .init(defaults: selectedDefaults),
                preferences: item.preferences, systemLocale: Locale(identifier: item.systemLocale))
            XCTAssertEqual(native.dialect, item.nativeDialect ?? item.dialect, item.name)
            XCTAssertEqual(Aegis.AegisLocalization.resourceLocalization(in: agent, snapshot: native),
                           item.nativeAgentResource ?? item.agentResource, item.name)
        }
    }

    func testSortedChoicesAndExplicitTaiwanPersistWithoutChangingSystemFormats() {
        let choices = Aegis.AegisLanguageChoice.displayOrder
        XCTAssertEqual(choices.map(\.id), ["zh-Hans", "zh-Hant-TW", "zh-Hant-HK", "en-US", "en-GB", "id", "th", "ja", "ko", "vi", "ms", "de", "fr", "es", "it", "pt"])
        XCTAssertEqual(Set(choices.map(\.id)).count, choices.count)

        let defaults = Defaults()
        let store = Aegis.AegisLanguagePreferenceStore(defaults: defaults)
        let controller = AppLanguageSettings(store: store)
        controller.selectChoice(.traditionalChineseTaiwan)
        XCTAssertEqual(AppLanguageSettings(store: store).choice, .traditionalChineseTaiwan)
        XCTAssertEqual(defaults.string(forKey: Aegis.AegisLanguagePreferenceStore.key), "zh-Hant-TW")
        let system = Locale(identifier: "th-TH-u-ca-buddhist-hc-h23-nu-thai-tz-usnyc")
        let snapshot = Aegis.AegisLocalization.snapshot(store: store, preferences: ["zh-HK"], systemLocale: system)
        XCTAssertEqual(snapshot.dialect, "zh-Hant-TW")
        XCTAssertEqual(snapshot.resourceCandidates, ["zh-Hant-TW", "zh-Hant", "en"])
        XCTAssertEqual(snapshot.locale.language.region?.identifier, "TW")
        XCTAssertEqual(snapshot.locale.region, system.region)
        XCTAssertEqual(snapshot.locale.calendar.identifier, system.calendar.identifier)
        XCTAssertEqual(snapshot.locale.numberingSystem, system.numberingSystem)
        let revision = controller.revision
        controller.selectChoice(.traditionalChineseHongKong)
        XCTAssertEqual(controller.choice, .traditionalChineseHongKong)
        XCTAssertGreaterThan(controller.revision, revision)
        XCTAssertEqual(Aegis.AegisLocalization.snapshot(store: store, preferences: ["zh-HK"], systemLocale: system).dialect, "zh-Hant-HK")
        controller.selectChoice(nil)
        XCTAssertNil(controller.choice)
        XCTAssertEqual(defaults.values.count, 1)
    }

    func testControllerPersistsSelectionsAndKeepsUnrelatedPreferences() {
        let defaults = Defaults()
        let store = Aegis.AegisLanguagePreferenceStore(defaults: defaults)
        let controller = AppLanguageSettings(store: store)
        for family in Aegis.AegisLanguageFamily.allCases {
            controller.select(family)
            XCTAssertEqual(controller.family, family)
            XCTAssertEqual(defaults.string(forKey: Aegis.AegisLanguagePreferenceStore.key), Aegis.AegisLanguageChoice.family(family).selectableChoice.rawValue)
            XCTAssertEqual(AppLanguageSettings(store: store).family, family)
        }
        controller.select(.en)
        for region in ["en_GB", "en_HK"] {
            let resolved = Aegis.AegisLocalization.snapshot(store: store, preferences: ["en"], systemLocale: Locale(identifier: region))
            XCTAssertEqual(resolved.dialect, "en-US")
            XCTAssertEqual(store.family, .en)
        }
        defaults.set("en-GB", forKey: Aegis.AegisLanguagePreferenceStore.key)
        controller.refresh()
        XCTAssertEqual(controller.choice, .englishUnitedKingdom)
        defaults.set("unsupported-language", forKey: Aegis.AegisLanguagePreferenceStore.key)
        controller.refresh()
        XCTAssertNil(controller.family)
        controller.select(nil)
        XCTAssertEqual(defaults.values.count, 1)
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
    }

    func testFormattingOverridesStayIndependentOfDialect() {
        let system = Locale(identifier: "th-TH-u-ca-buddhist-hc-h23-nu-thai-tz-usnyc")
        let snapshot = Aegis.AegisLocalizationSnapshot.resolve(family: .en, preferences: ["en-GB"], systemLocale: system)
        XCTAssertEqual(snapshot.locale.language.region?.identifier, "GB")
        XCTAssertEqual(snapshot.locale.region, system.region)
        XCTAssertEqual(snapshot.locale.calendar.identifier, system.calendar.identifier)
        XCTAssertEqual(snapshot.locale.hourCycle, system.hourCycle)
        XCTAssertEqual(snapshot.locale.numberingSystem, system.numberingSystem)
        XCTAssertEqual(snapshot.locale.timeZone, system.timeZone)
    }

    func testRuntimeRefreshPreservesWindowsWebViewsAndExternalForm() async throws {
        let data = BrowserDataStore(persistenceURL: nil)
        let windows = BrowserWindowStore(persistenceURL: nil)
        let preferences = BrowserPreferences(defaults: UserDefaults(suiteName: "com.gcsa.aegis.ios.ui-tests")!)
        let first = BrowserSession(dataStore: data, workspaceStore: WorkspaceStore(persistenceURL: nil),
                                   windowID: windows.defaultWindowID(), windowStore: windows, preferences: preferences)
        let second = BrowserSession(dataStore: data, workspaceStore: WorkspaceStore(persistenceURL: nil),
                                    windowID: try windows.createWindow(), windowStore: windows, preferences: preferences)
        let start = try XCTUnwrap(first.activeTab)
        let external = try XCTUnwrap(second.activeTab)
        start.load(URL(string: "aegis://start")!)
        // The existing integration server supplies a real external HTTP document.
        external.load(URL(string: "http://127.0.0.1:8768/article")!)
        defer { start.stop(); external.stop() }
        try await waitUntil { !start.isLoading && start.url?.absoluteString == "aegis://start" &&
            !external.isLoading && external.url?.path == "/article" }
        let startView = start.webView, externalView = external.webView
        _ = try await externalView.evaluateJavaScript("window.languageSentinel=41;document.querySelector('main').insertAdjacentHTML('beforeend','<input id=language-draft value=KEEP_DRAFT>')")
        let epoch = external.navigationEpoch
        let backCount = externalView.backForwardList.backList.count
        let history = data.history
        let ids = (first.activeTabID, second.activeTabID)
        let snapshot = BrowserKit.AegisLocalizationSnapshot.resolve(family: .de, preferences: ["en-US"], systemLocale: Locale(identifier: "en_US"))
        first.refreshLocalizedPresentation(snapshot: snapshot)
        second.refreshLocalizedPresentation(snapshot: snapshot)
        try await waitUntil {
            (try? await startView.evaluateJavaScript("document.documentElement.lang") as? String) == "de"
        }
        XCTAssertTrue(first.activeTab === start && second.activeTab === external)
        XCTAssertTrue(start.webView === startView && external.webView === externalView)
        XCTAssertEqual(first.activeTabID, ids.0)
        XCTAssertEqual(second.activeTabID, ids.1)
        XCTAssertEqual(external.navigationEpoch, epoch)
        XCTAssertEqual(externalView.backForwardList.backList.count, backCount)
        XCTAssertEqual(data.history, history)
        let draft = try await externalView.evaluateJavaScript("document.getElementById('language-draft').value") as? String
        XCTAssertEqual(draft, "KEEP_DRAFT")
        let sentinel = try await externalView.evaluateJavaScript("window.languageSentinel") as? Int
        XCTAssertEqual(sentinel, 41)
        let original = try await startView.evaluateJavaScript("document.querySelector('[data-aegis-start=heading]').textContent") as? String
        let changed = try await startView.callAsyncJavaScript(FixtureSchemeHandler.refreshScript, arguments: [
            "expectedURL": "aegis://start", "documentID": "wrong-document", "revision": 100,
            "labels": ["heading": "WRONG_DOCUMENT"], "language": "en",
        ], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(changed as? Bool, false)
        let afterRejectedUpdate = try await startView.evaluateJavaScript("document.querySelector('[data-aegis-start=heading]').textContent") as? String
        XCTAssertEqual(afterRejectedUpdate, original)
    }

    func testHistoryRestoredStartPageUsesLatestLanguageWithoutTouchingExternalPage() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              !ProcessInfo.processInfo.arguments.contains("-browser.languageFamily.v1") else {
            throw XCTSkip("Requires isolated --ui-testing host without a fixed argument-domain family")
        }
        let suite = "com.gcsa.aegis.ios.ui-tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let key = Aegis.AegisLanguagePreferenceStore.key
        let old = defaults.persistentDomain(forName: suite)?[key]
        defer { if let old { defaults.set(old, forKey: key) } else { defaults.removeObject(forKey: key) } }
        let language = AppLanguageSettings(store: .init(defaults: defaults))
        language.select(.en)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil),
                                     workspaceStore: WorkspaceStore(persistenceURL: nil),
                                     preferences: BrowserPreferences(defaults: defaults))
        let tab = try XCTUnwrap(browser.activeTab)
        let view = tab.webView
        defer { tab.stop() }
        let headingScript = "document.querySelector('[data-aegis-start=heading]').textContent"
        let tokenScript = "document.querySelector('meta[name=aegis-start-document]').content"
        tab.load(URL(string: "aegis://start")!)
        try await waitUntil {
            let heading = try? await view.evaluateJavaScript(headingScript) as? String
            return !tab.isLoading && heading == "Browse with clarity and control."
        }
        let originalToken = try await view.evaluateJavaScript(tokenScript) as? String
        XCTAssertNotNil(originalToken)
        tab.load(URL(string: "http://127.0.0.1:8768/article")!)
        try await waitUntil { !tab.isLoading && tab.url?.path == "/article" && view.canGoBack }
        _ = try await view.evaluateJavaScript("window.languageHistorySentinel=41;document.querySelector('input').value='KEEP_HISTORY_DRAFT'")
        let externalHTML = try await view.evaluateJavaScript("document.documentElement.outerHTML") as? String
        let epoch = tab.navigationEpoch
        let historyCount = view.backForwardList.backList.count
        language.select(.de)
        browser.refreshLocalizedPresentation()
        let unchangedHTML = try await view.evaluateJavaScript("document.documentElement.outerHTML") as? String
        let draft = try await view.evaluateJavaScript("document.querySelector('input').value") as? String
        let sentinel = try await view.evaluateJavaScript("window.languageHistorySentinel") as? Int
        XCTAssertEqual(unchangedHTML, externalHTML)
        XCTAssertEqual(draft, "KEEP_HISTORY_DRAFT")
        XCTAssertEqual(sentinel, 41)
        XCTAssertEqual(tab.navigationEpoch, epoch)
        XCTAssertEqual(view.backForwardList.backList.count, historyCount)
        XCTAssertFalse(tab.isLoading)

        tab.goBack()
        try await waitUntil {
            let heading = try? await view.evaluateJavaScript(headingScript) as? String
            return !tab.isLoading && tab.url?.absoluteString == "aegis://start"
                && heading == "Sicher surfen. Die Kontrolle behalten."
        }
        let restoredToken = try await view.evaluateJavaScript(tokenScript) as? String
        let restoredLanguage = try await view.evaluateJavaScript("document.documentElement.lang") as? String
        // Prove this exercised the cached document, not a fresh scheme response.
        XCTAssertEqual(restoredToken, originalToken)
        XCTAssertEqual(restoredLanguage, "de")
        XCTAssertTrue(browser.activeTab === tab)
        XCTAssertTrue(tab.webView === view)
        XCTAssertTrue(view.canGoForward)
    }

    func testRefreshWhileDownloadAndModelStreamAreActive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "com.gcsa.aegis.ios.ui-tests")!
        let downloads = DownloadManager(directory: directory, background: false, defaults: defaults)
        await downloads.retryStorage()
        try await waitUntil { downloads.isReady }
        let id = try downloads.start("http://127.0.0.1:8768/slow.bin")
        defer { downloads.cancel(id) }
        let client = ModelClient(configuration: ModelConfiguration(endpoint: "http://127.0.0.1:8768/v1", model: "stream-slow"), key: "")
        let task = Task { @MainActor in
            try await client.streamComplete(goal: "Summarize", sources: ["城市绿地观察"], language: "en-US") { [weak self] text in
                self?.streamedText = text
            }
        }
        defer { task.cancel() }
        try await waitUntil { !self.streamedText.isEmpty && (downloads.items.first { $0.id == id }?.received ?? 0) > 0 }
        let received = try XCTUnwrap(downloads.items.first { $0.id == id }).received
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), workspaceStore: WorkspaceStore(persistenceURL: nil),
                                     preferences: BrowserPreferences(defaults: defaults))
        let tab = try XCTUnwrap(browser.activeTab)
        for family in [BrowserKit.AegisLanguageFamily.de, .traditionalChinese, .en] {
            browser.refreshLocalizedPresentation(snapshot: .resolve(family: family, preferences: ["en-US"], systemLocale: Locale(identifier: "en_US")))
        }
        let output = try await task.value
        XCTAssertFalse(output.isEmpty)
        XCTAssertTrue(browser.activeTab === tab)
        try await waitUntil { downloads.items.first { $0.id == id }?.state == .completed }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(downloads.items.first { $0.id == id }).received, received)
    }

    func testExistingUIKitFieldsRefreshWithoutLosingMarkedTextOrFocus() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              !ProcessInfo.processInfo.arguments.contains("-browser.languageFamily.v1") else {
            throw XCTSkip("Requires isolated --ui-testing host without a fixed argument-domain family")
        }
        let defaults = UserDefaults(suiteName: "com.gcsa.aegis.ios.ui-tests")!
        let key = Aegis.AegisLanguagePreferenceStore.key
        let old = defaults.persistentDomain(forName: "com.gcsa.aegis.ios.ui-tests")?[key]
        defer { if let old { defaults.set(old, forKey: key) } else { defaults.removeObject(forKey: key) } }
        let language = AppLanguageSettings(store: .init(defaults: defaults))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        // These controls normally own focus in separate browser/find surfaces.
        // Do not mount two competing autofocus adapters in one artificial form.
        for showsFind in [false, true] {
            language.select(.en)
            let host = FieldHostingController(rootView: FieldHarness(language: language, showsFind: showsFind))
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; previous?.makeKeyAndVisible() }
            let identifier = showsFind ? "find-text" : "address-field"
            let initialText = showsFind ? "KEEP_FIND" : "draft"
            try await waitUntil {
                guard host.didAppear, let field = self.field(identifier, in: host.view),
                      field.window === window, field.isFirstResponder else { return false }
                if showsFind { return true }
                // Address autofocus schedules selection after layout. Wait for
                // that actual selection, not merely for UITextField creation.
                guard let range = field.selectedTextRange else { return false }
                return field.offset(from: field.beginningOfDocument, to: range.start) == 0
                    && field.offset(from: range.start, to: range.end) == initialText.utf16.count
            }
            let field = try XCTUnwrap(field(identifier, in: host.view))
            XCTAssertTrue(host.didAppear)
            XCTAssertTrue(field.isFirstResponder)
            XCTAssertEqual(field.text, initialText)
            let expectedLabel = showsFind ? "Suchtext" : "Suchen oder Adresse eingeben"
            field.selectAll(nil)
            field.setMarkedText("草稿", selectedRange: NSRange(location: 2, length: 0))
            // Explicit preconditions distinguish setup failures from switching.
            XCTAssertEqual(field.text, "草稿")
            XCTAssertNotNil(field.markedTextRange)
            XCTAssertTrue(field.isFirstResponder)
            let text = field.text
            language.select(.de)
            try await waitUntil { field.placeholder == expectedLabel && field.accessibilityLabel == expectedLabel }
            XCTAssertTrue(self.field(identifier, in: host.view) === field)
            XCTAssertEqual(field.text, text)
            XCTAssertNotNil(field.markedTextRange)
            XCTAssertTrue(field.isFirstResponder)
        }
    }

    private final class FieldHostingController: UIHostingController<FieldHarness> {
        private(set) var didAppear = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            didAppear = true
        }
    }

    private struct FieldHarness: View {
        @ObservedObject var language: AppLanguageSettings
        let showsFind: Bool
        @State private var address = "draft"
        @State private var focused = true
        @State private var find = "KEEP_FIND"
        var body: some View {
            Group {
                if showsFind {
                    FindQueryField(text: $find)
                } else {
                    BrowserAddressField(address: $address, focused: $focused, displayText: "draft", selectionRequest: 0, submit: { _ in })
                }
            }.environment(\.locale, language.snapshot.locale)
        }
    }

    private func field(_ identifier: String, in view: UIView) -> UITextField? {
        if let field = view as? UITextField, field.accessibilityIdentifier == identifier { return field }
        return view.subviews.lazy.compactMap { self.field(identifier, in: $0) }.first
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Timed out waiting for language/document state")
        throw URLError(.timedOut)
    }
}
