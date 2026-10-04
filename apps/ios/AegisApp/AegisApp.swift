import BrowserKit
import AgentKit
import SwiftUI

final class AegisAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == "com.gcsa.aegis.ios.downloads.v1" else { completionHandler(); return }
        DownloadManager.backgroundCompletion = completionHandler
    }
}

@main
struct AegisApp: App {
    @UIApplicationDelegateAdaptor(AegisAppDelegate.self) private var appDelegate
    @StateObject private var windows: BrowserWindowStore
    private let dataStore: BrowserDataStore
    private let workspaceStore: WorkspaceStore
    @StateObject private var settings: BrowserSettings
    @StateObject private var downloads: DownloadManager
    @StateObject private var assistantTasks: AssistantTaskStore

    init() {
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
#if DEBUG
        let isTest = ProcessInfo.processInfo.arguments.contains("--ui-testing")
#else
        let isTest = false
#endif
        // UI 验收数据与用户配置、下载目录分开。
        let defaults = isTest ? UserDefaults(suiteName: "com.gcsa.aegis.ios.ui-tests")! : .standard
        if isTest { defaults.removePersistentDomain(forName: "com.gcsa.aegis.ios.ui-tests") }
        if isTest && ProcessInfo.processInfo.arguments.contains("--ui-testing-dark") { defaults.set("dark", forKey: "browser.appearance") }
        _settings = StateObject(wrappedValue: BrowserSettings(defaults: defaults))
        let downloadDirectory = isTest ? FileManager.default.temporaryDirectory.appendingPathComponent("ui-downloads-" + UUID().uuidString) : nil
#if DEBUG
        if isTest, arguments.contains("--ui-testing-damaged-records"), let downloadDirectory {
            try? FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
            try? Data("合成损坏记录".utf8).write(to: downloadDirectory.appendingPathComponent("downloads.json"))
        }
#endif
        _downloads = StateObject(wrappedValue: DownloadManager(directory: downloadDirectory, background: !isTest || ProcessInfo.processInfo.arguments.contains("--ui-testing-background-download")))
        let historyURL = isTest ? FileManager.default.temporaryDirectory.appendingPathComponent("ui-assistant-tasks.aes") : AssistantTaskStore.defaultURL
        if isTest && !ProcessInfo.processInfo.arguments.contains("--ui-testing-assistant-history-keep") {
            try? FileManager.default.removeItem(at: historyURL)
        }
        _assistantTasks = StateObject(wrappedValue: AssistantTaskStore(url: historyURL,
            keyAccount: isTest ? "assistant-tasks-ui-v1" : "assistant-tasks-v1"))
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
    }

    var body: some Scene {
        WindowGroup(id: "browser", for: UUID.self) { $windowID in
            AegisWindowView(id: windowID, dataStore: dataStore, workspaces: workspaceStore, windows: windows)
                .environmentObject(windows)
                .environmentObject(settings)
                .environmentObject(downloads)
                .environmentObject(assistantTasks)
                .preferredColorScheme(settings.colorScheme)
                .tint(Color(red: 0.09, green: 0.47, blue: 0.37))
        } defaultValue: {
            windows.defaultWindowID()
        }
        .commands { BrowserKeyboardCommands() }
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
    @StateObject private var browser: BrowserSession
    @ObservedObject var windows: BrowserWindowStore
    init(id: UUID, dataStore: BrowserDataStore, workspaces: WorkspaceStore, windows: BrowserWindowStore) {
        self.windows = windows
        _browser = StateObject(wrappedValue: BrowserSession(dataStore: dataStore, workspaceStore: workspaces,
            windowID: id, windowStore: windows))
    }
    var body: some View {
        AegisRootView()
            .environmentObject(browser)
            .onAppear {
                windows.register(browser.windowID)
                browser.persistSession()
            }
            .onDisappear {
                browser.persistSession(); browser.discardPrivateSession()
                windows.unregister(browser.windowID)
            }
    }
}
