import BrowserKit
import SwiftUI

@main
struct AegisApp: App {
    @StateObject private var browser: BrowserSession

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
        _browser = StateObject(wrappedValue: BrowserSession(dataStore: store))
    }

    var body: some Scene {
        WindowGroup {
            AegisRootView()
                .environmentObject(browser)
                .tint(Color(red: 0.09, green: 0.47, blue: 0.37))
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
