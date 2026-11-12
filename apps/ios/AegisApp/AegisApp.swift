import AccessKit
import AgentKit
import BrowserKit
import SwiftUI

final class AegisAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        AegisFirebase.shared.start()
        return true
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        AegisWindowLifetime.discardScenes(Set(sceneSessions.map(\.persistentIdentifier)))
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == "com.gcsa.aegis.ios.downloads.v1" else { completionHandler(); return }
        DownloadManager.backgroundCompletion = completionHandler
    }
}

@main
struct AegisApp: App {
    @UIApplicationDelegateAdaptor(AegisAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var windows: BrowserWindowStore
    private let dataStore: BrowserDataStore
    private let workspaceStore: WorkspaceStore
    @StateObject private var language: AppLanguageSettings
    @StateObject private var settings: BrowserSettings
    @StateObject private var downloads: DownloadManager
    @StateObject private var assistantTasks: AssistantTaskStore
    @StateObject private var accountSession = AccessAccountSession.product()
    @StateObject private var readingLibrary: ReadingLibrary
    @StateObject private var accessSiteProxyRegistry: AccessSiteProxyStoreRegistry
    @StateObject private var hostStores: AccessHostStoreCoordinator

    init() {
#if DEBUG
        let isTest = ProcessInfo.processInfo.arguments.contains("--ui-testing")
#else
        let isTest = false
#endif
        // UI 验收数据与用户配置、下载目录分开。
        let defaults = isTest ? UserDefaults(suiteName: "com.gcsa.aegis.ios.ui-tests")! : .standard
        if isTest && !ProcessInfo.processInfo.arguments.contains("--ui-testing-preferences-keep") { defaults.removePersistentDomain(forName: "com.gcsa.aegis.ios.ui-tests") }
        if isTest && ProcessInfo.processInfo.arguments.contains("--ui-testing-dark") { defaults.set("dark", forKey: "browser.appearance") }
        _language = StateObject(wrappedValue: AppLanguageSettings())
        let store: BrowserDataStore
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let persistenceStore = Self.persistentUITestStore(arguments: arguments) {
            store = persistenceStore
        } else if arguments.contains("--ui-testing") {
            store = BrowserDataStore(persistenceURL: nil, initialBookmarks: Self.uiTestBookmarks)
        } else {
            store = BrowserDataStore()
        }
#else
        store = BrowserDataStore()
#endif
        _settings = StateObject(wrappedValue: BrowserSettings(defaults: defaults))
        let downloadDirectory = isTest ? FileManager.default.temporaryDirectory.appendingPathComponent("ui-downloads-" + UUID().uuidString) : nil
#if DEBUG
        if isTest, arguments.contains("--ui-testing-damaged-records"), let downloadDirectory {
            try? FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
            try? Data("合成损坏记录".utf8).write(to: downloadDirectory.appendingPathComponent("downloads.json"))
        }
#endif
        _downloads = StateObject(wrappedValue: DownloadManager(directory: downloadDirectory,
            background: !isTest || ProcessInfo.processInfo.arguments.contains("--ui-testing-background-download"), defaults: defaults))
        let historyURL = isTest ? FileManager.default.temporaryDirectory.appendingPathComponent("ui-assistant-tasks.aes") : AssistantTaskStore.defaultURL
        if isTest && !ProcessInfo.processInfo.arguments.contains("--ui-testing-assistant-history-keep") {
            try? FileManager.default.removeItem(at: historyURL)
        }
        _assistantTasks = StateObject(wrappedValue: AssistantTaskStore(url: historyURL,
            keyAccount: isTest ? "assistant-tasks-ui-v1" : "assistant-tasks-v1"))
        let readingURL = isTest ? FileManager.default.temporaryDirectory.appendingPathComponent("ui-reading-library-v1.aes") : ReadingLibrary.defaultURL
        if isTest && !ProcessInfo.processInfo.arguments.contains("--ui-testing-reading-keep") {
            try? FileManager.default.removeItem(at: readingURL)
        }
        _readingLibrary = StateObject(wrappedValue: ReadingLibrary(url: readingURL,
            keyAccount: isTest ? "reading-library-ui-v1" : "reading-library-v1"))
        dataStore = store
        var workspaceURL: URL? = isTest ? nil : WorkspaceStore.defaultURL
#if DEBUG
        if isTest, arguments.contains("--ui-testing-damaged-records") {
            workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent("ui-workspaces-" + UUID().uuidString + ".json")
            try? Data("合成损坏记录".utf8).write(to: workspaceURL!)
        }
#endif
        let workspaceStore = WorkspaceStore(persistenceURL: workspaceURL)
        self.workspaceStore = workspaceStore
        let windowsURL = isTest ? FileManager.default.temporaryDirectory.appendingPathComponent("ui-browser-windows.json") : BrowserWindowStore.defaultURL
        if isTest && !ProcessInfo.processInfo.arguments.contains("--ui-testing-windows-keep") {
            try? FileManager.default.removeItem(at: windowsURL)
        }
        _windows = StateObject(wrappedValue: BrowserWindowStore(persistenceURL: windowsURL, legacyURLs: workspaceStore.sessionURLs))
        let registry = AccessSiteProxyStoreRegistry()
        let publisher = AccessEmbeddedProxyEntryFactory.makeProductPublisher()
        let hostStores = AccessHostStoreCoordinator(
            publisher: publisher,
            channel: AccessProductChannel.resolve()
        )
        registry.hostRouting = hostStores
        hostStores.startForegroundSweep()
        _accessSiteProxyRegistry = StateObject(wrappedValue: registry)
        _hostStores = StateObject(wrappedValue: hostStores)
    }

    var body: some Scene {
        WindowGroup(id: "browser", for: UUID.self) { $windowID in
            AegisWindowView(id: windowID, dataStore: dataStore, workspaces: workspaceStore, windows: windows,
                            preferences: settings.browserPreferences)
                .environmentObject(language)
                .environment(\.locale, language.snapshot.locale)
                .environment(\.calendar, Calendar.autoupdatingCurrent)
                .environment(\.timeZone, TimeZone.autoupdatingCurrent)
                .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in language.refresh() }
                .environmentObject(windows)
                .environmentObject(settings)
                .environmentObject(downloads)
                .environmentObject(assistantTasks)
                .environmentObject(readingLibrary)
                .environmentObject(accountSession)
                .environmentObject(accessSiteProxyRegistry)
                .environmentObject(hostStores)
                .preferredColorScheme(settings.colorScheme)
                .tint(Color(red: 0.09, green: 0.47, blue: 0.37))
        } defaultValue: {
            windows.defaultWindowID()
        }
        .commands { BrowserKeyboardCommands(language: language) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { language.refresh(); AegisFirebase.shared.refreshOnForeground() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { accountSession.refresh() }
            else { accountSession.suspend() }
        }
    }

#if DEBUG
    private static let uiTestBookmarks: [BrowserBookmark] = [
        BrowserBookmark(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            title: "Z",
            url: "https://z.example?utm_source=feed",
            createdAt: Date(timeIntervalSince1970: 300)
        ),
        BrowserBookmark(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            title: "重复项",
            url: "https://EXAMPLE.com/item?utm_source=feed&keep=1",
            createdAt: Date(timeIntervalSince1970: 200)
        ),
        BrowserBookmark(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            title: "保留项",
            url: "https://example.com/item?keep=1",
            createdAt: Date(timeIntervalSince1970: 100)
        ),
        BrowserBookmark(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!,
            title: "A",
            url: "https://a.example?fbclid=tracking",
            createdAt: Date(timeIntervalSince1970: 400)
        ),
    ]

    private static func persistentUITestStore(arguments: [String]) -> BrowserDataStore? {
        guard arguments.contains("--ui-testing-persistence") else { return nil }
        let persistenceURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ui-test-browser-data-v1.json")
        if arguments.contains("--ui-testing-persistence-reset") {
            try? FileManager.default.removeItem(at: persistenceURL)
            try? FileManager.default.removeItem(at: URL(
                fileURLWithPath: persistenceURL.path + ".bookmark-undo-journal-v1.json"
            ))
            BrowserDataStore.resetBookmarkSecurityStateForTesting(
                persistenceURL: persistenceURL
            )
        }
        return BrowserDataStore(
            persistenceURL: persistenceURL,
            initialBookmarks: uiTestBookmarks
        )
    }
#endif
}

/// 浏览会话的生命周期跟随窗口，公共资料与下载仍由 App 持有。
private struct AegisWindowView: View {
    @EnvironmentObject private var language: AppLanguageSettings
    @EnvironmentObject private var accessRegistry: AccessSiteProxyStoreRegistry
    @EnvironmentObject private var hostStores: AccessHostStoreCoordinator
    @StateObject private var browser: BrowserSession
    @StateObject private var lifetime = AegisWindowLifetime()
    @ObservedObject var windows: BrowserWindowStore
    init(id: UUID, dataStore: BrowserDataStore, workspaces: WorkspaceStore, windows: BrowserWindowStore,
         preferences: BrowserPreferences) {
        self.windows = windows
        _browser = StateObject(wrappedValue: BrowserSession(dataStore: dataStore, workspaceStore: workspaces,
            windowID: id, windowStore: windows, preferences: preferences))
    }
    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        AegisRootView()
            .environmentObject(browser)
            .onChange(of: language.revision) { _, _ in browser.refreshLocalizedPresentation() }
            .background(WindowSceneAttachment(lifetime: lifetime))
            .onAppear {
                guard !browser.isWindowClosed else { return }
                lifetime.browser = browser
                lifetime.accessRegistry = accessRegistry
                windows.register(browser.windowID)
                browser.hostCoordinator = hostStores
                hostStores.tabs = { [weak browser] in
                    guard let browser else { return [] }
                    return browser.standardTabs + browser.privateTabs
                }
                browser.persistSession()
            }
            .onChange(of: browser.retiredPrivateWebsiteDataStoreRevision) { _, _ in
                accessRegistry.release(browser.consumeRetiredPrivateWebsiteDataStores())
            }
            .onDisappear {
                browser.persistSession()
            }
    }
}

/// A root WindowGroup state owner survives temporary view disappearance. Its
/// release closes live bindings even when no explicit in-app close was used.
@MainActor
final class AegisWindowLifetime: ObservableObject {
    var browser: BrowserSession?
    var accessRegistry: AccessSiteProxyStoreRegistry?

    private final class WeakOwner {
        weak var value: AegisWindowLifetime?
        init(_ value: AegisWindowLifetime) { self.value = value }
    }
    private static var sceneOwners: [String: WeakOwner] = [:]

    init(browser: BrowserSession? = nil) { self.browser = browser }

    func attach(sceneID: String) {
        Self.sceneOwners = Self.sceneOwners.filter { $0.value.value != nil }
        Self.sceneOwners[sceneID] = WeakOwner(self)
    }

    /// UIKit calls this only for discarded sessions, not backgrounding or a
    /// temporary scene disconnect. Root-state release is the fallback below.
    static func discardScenes(_ identifiers: Set<String>) {
        for id in identifiers {
            guard let owner = sceneOwners.removeValue(forKey: id)?.value,
                  let browser = owner.browser else { continue }
            browser.closeWindow()
            owner.accessRegistry?.release(browser.consumeRetiredPrivateWebsiteDataStores())
        }
    }

    deinit {
        let browser = browser
        let registry = accessRegistry
        Task { @MainActor in
            guard let browser else { return }
            browser.closeWindow()
            registry?.release(browser.consumeRetiredPrivateWebsiteDataStores())
        }
    }
}

/// Resolves only the owning scene's identity. A view moving offscreen does not
/// close anything; permanent session disposal comes from UIApplicationDelegate.
private struct WindowSceneAttachment: UIViewRepresentable {
    let lifetime: AegisWindowLifetime
    func makeUIView(context: Context) -> SceneView { SceneView(lifetime: lifetime) }
    func updateUIView(_ view: SceneView, context: Context) { view.attach() }

    final class SceneView: UIView {
        private weak var lifetime: AegisWindowLifetime?
        init(lifetime: AegisWindowLifetime) {
            self.lifetime = lifetime
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() { super.didMoveToWindow(); attach() }
        func attach() {
            guard let scene = window?.windowScene else { return }
            lifetime?.attach(sceneID: scene.session.persistentIdentifier)
        }
    }
}
