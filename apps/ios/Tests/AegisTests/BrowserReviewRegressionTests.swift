import UIKit
import Combine
import WebKit
import XCTest
@testable import Aegis
@testable import BrowserKit

@MainActor
final class BrowserPreferenceMergeTests: XCTestCase {
    func testStaleWindowDraftSavesOnlyEditedFieldsInPersistedRepresentation() throws {
        let suite = "aegis-preference-merge-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BrowserPreferences(defaults: defaults)
        let firstBaseline = preferences.values, secondBaseline = preferences.values
        var first = firstBaseline, second = secondBaseline
        first.zoom = 1.25
        second.desktop = true; second.saveHistory = false
        try preferences.saveChanges(second, since: secondBaseline)
        let siteURL = URL(string: "http://127.0.0.1:8768/fixture")!
        var permission = SitePreferences(); permission.camera = .deny; permission.microphone = .deny
        try preferences.setSite(permission, for: siteURL)
        var protection = preferences.values; protection.linkSanitization = false
        try preferences.save(protection)
        try preferences.saveChanges(first, since: firstBaseline)
        let reopened = BrowserPreferences(defaults: defaults)
        XCTAssertEqual(reopened.values.zoom, 1.25)
        XCTAssertTrue(reopened.values.desktop)
        XCTAssertFalse(reopened.values.saveHistory)
        XCTAssertFalse(reopened.values.linkSanitization)
        XCTAssertEqual(reopened.site(for: siteURL).camera, .deny)
        XCTAssertEqual(reopened.site(for: siteURL).microphone, .deny)
        let bytes = try XCTUnwrap(defaults.data(forKey: "browser.preferences.v1"))
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(stored["zoom"] as? Double, 1.25)
        XCTAssertEqual(stored["desktop"] as? Bool, true)
        let sites = try XCTUnwrap(stored["sites"] as? [String: [String: Any]])
        XCTAssertEqual(sites["http://127.0.0.1:8768"]?["camera"] as? String, "deny")
    }

    func testConcurrentSiteDraftsMergeFieldsAndInvalidSaveRollsBackBytesAndPublishedState() throws {
        let suite = "aegis-preference-rollback-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BrowserPreferences(defaults: defaults)
        let url = URL(string: "http://localhost:8768/fixture")!
        let siteBaseline = preferences.site(for: url)
        var zoom = siteBaseline; zoom.zoom = 1.5
        var permission = siteBaseline; permission.camera = .deny
        try preferences.saveSiteChanges(permission, since: siteBaseline, for: url)
        try preferences.saveSiteChanges(zoom, since: siteBaseline, for: url)
        XCTAssertEqual(preferences.site(for: url).camera, .deny)
        XCTAssertEqual(BrowserPreferences(defaults: defaults).site(for: url).zoom, 1.5)

        let baseline = preferences.values
        var invalid = baseline; invalid.searchEngine = .custom; invalid.customSearch = "http://localhost/?q={searchTerms}"
        var concurrent = preferences.values; concurrent.requireMediaGesture = false
        try preferences.save(concurrent)
        let before = preferences.values, bytes = defaults.data(forKey: "browser.preferences.v1")
        XCTAssertThrowsError(try preferences.saveChanges(invalid, since: baseline))
        XCTAssertEqual(preferences.values, before)
        XCTAssertEqual(defaults.data(forKey: "browser.preferences.v1"), bytes)
        XCTAssertEqual(BrowserPreferences(defaults: defaults).values, before)
        var invalidSite = zoom; invalidSite.desktop = true
        XCTAssertThrowsError(try preferences.saveSiteChanges(invalidSite, since: zoom, for: URL(string: "file:///synthetic")!))
        XCTAssertEqual(defaults.data(forKey: "browser.preferences.v1"), bytes)
    }
}

@MainActor
final class FindInPageLifecycleTests: XCTestCase {
    func testQueryChangeDismissAndDocumentReplacementRejectLateReplies() async throws {
        for change in 0..<3 {
            let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
            defer { browser.closeWindow() }
            let tab = try XCTUnwrap(browser.activeTab)
            tab.stop()
            var reply: CheckedContinuation<Bool, Never>?
            let model = FindInPageModel { _, _ in await withCheckedContinuation { reply = $0 } }
            model.text = "synthetic private term"
            model.find(in: tab)
            try await waitForReviewCondition { reply != nil }
            switch change {
            case 0: model.text = "a different query"
            case 1: model.invalidate()
            default: browser.close(tab.id)
            }
            reply?.resume(returning: true)
            for _ in 0..<10 { await Task.yield() }
            XCTAssertNil(model.message)
            let nextPresentation = FindInPageModel()
            XCTAssertTrue(nextPresentation.text.isEmpty)
            XCTAssertNil(nextPresentation.message)
        }
    }

    func testOlderReplyCannotReplaceNewerQueryResult() async throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab)
        tab.stop()
        var replies: [String: CheckedContinuation<Bool, Never>] = [:]
        let model = FindInPageModel { _, query in await withCheckedContinuation { replies[query] = $0 } }
        model.text = "first"; model.find(in: tab)
        try await waitForReviewCondition { replies["first"] != nil }
        model.text = "second"; model.find(in: tab)
        try await waitForReviewCondition { replies["second"] != nil }
        replies["second"]?.resume(returning: false)
        for _ in 0..<10 { await Task.yield() }
        let latest = model.message?.text
        XCTAssertNotNil(latest)
        replies["first"]?.resume(returning: true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.message?.text, latest)
    }
}

@MainActor
final class AssistantOperationLifetimeTests: XCTestCase {
    func testDeactivatingOneWindowPreservesOtherWindowOperationAndBusyState() async {
        let first = AssistantOperationLifetime(applicationIsActive: { true })
        let second = AssistantOperationLifetime(applicationIsActive: { true })
        first.attach(sceneID: "first", isActive: true)
        second.attach(sceneID: "second", isActive: true)
        let firstConsent = first.generation, secondConsent = second.generation
        var firstBusy = true, secondBusy = true
        let firstReset = first.sceneDeactivated.sink { firstBusy = false }
        let secondReset = second.sceneDeactivated.sink { secondBusy = false }
        defer { firstReset.cancel(); secondReset.cancel(); first.invalidate(); second.invalidate() }
        let firstTask = Task { _ = try? await Task.sleep(for: .seconds(60)) }
        let secondTask = Task { _ = try? await Task.sleep(for: .seconds(60)) }
        first.operation = firstTask; second.operation = secondTask
        // Both observers receive the same event, but only its owner may react.
        first.deactivateScene("first"); second.deactivateScene("first")
        XCTAssertTrue(firstTask.isCancelled)
        XCTAssertNil(first.operation)
        XCTAssertFalse(first.isCurrent(firstConsent))
        XCTAssertFalse(firstBusy)
        XCTAssertFalse(secondTask.isCancelled)
        XCTAssertNotNil(second.operation)
        XCTAssertTrue(second.isCurrent(secondConsent))
        XCTAssertTrue(secondBusy)
        first.activateScene("first"); second.activateScene("first")
        XCTAssertFalse(first.isCurrent(firstConsent))
        XCTAssertTrue(first.isCurrent(first.generation))
        XCTAssertTrue(second.isCurrent(secondConsent))
    }

    func testInactiveThenImmediateForegroundRevokesConfirmationAndIgnoresUncancellableReply() async throws {
        let lifetime = AssistantOperationLifetime(applicationIsActive: { true })
        let consent = lifetime.generation
        var reply: CheckedContinuation<String, Never>?
        var published = ""
        lifetime.operation = Task { @MainActor in
            let result = await withCheckedContinuation { reply = $0 }
            if lifetime.isCurrent(consent) { published = result }
        }
        try await waitForReviewCondition { reply != nil }
        let task = lifetime.operation
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(task?.isCancelled == true)
        XCTAssertFalse(lifetime.isCurrent(consent))
        XCTAssertNil(lifetime.operation)
        reply?.resume(returning: "synthetic stale model reply")
        await task?.value
        XCTAssertTrue(published.isEmpty)
    }

    func testCloseRevokesConsentAndCancelsEvenBeforeTaskStarts() async {
        let lifetime = AssistantOperationLifetime(applicationIsActive: { true })
        let consent = lifetime.generation
        var sent = false
        let task = Task { @MainActor in
            if lifetime.isCurrent(consent), !Task.isCancelled { sent = true }
        }
        lifetime.operation = task
        lifetime.invalidate() // Both assistants use this on close and disappearance.
        await task.value
        XCTAssertFalse(sent)
        XCTAssertFalse(lifetime.isCurrent(consent))
        XCTAssertTrue(task.isCancelled)
    }
}

@MainActor
final class BrowserJavaScriptDialogTests: XCTestCase {
    func testReleasedDialogCompletesWithSafeDefault() async throws {
        var count = 0
        var dialog: BrowserJavaScriptDialog? = BrowserJavaScriptDialog(origin: "http://localhost", message: "Synthetic", kind: .confirm) {
            XCTAssertFalse($0); XCTAssertNil($1); count += 1
        }
        weak var released = dialog
        dialog = nil
        try await waitForReviewCondition { count == 1 }
        XCTAssertNil(released)
        XCTAssertEqual(count, 1)
    }
    func testEveryCompletionIsExactlyOnceAndDismissalUsesSafeDefaults() {
        for kind in [BrowserJavaScriptDialog.Kind.alert, .confirm, .prompt("initial")] {
            var results: [(Bool, String?)] = []
            let dialog = BrowserJavaScriptDialog(origin: "http://127.0.0.1:8768", message: "Synthetic dialog", kind: kind) {
                results.append(($0, $1))
            }
            dialog.finish(accept: false)
            dialog.finish(accept: true, text: "late reply")
            XCTAssertEqual(results.count, 1)
            XCTAssertFalse(results[0].0)
            XCTAssertNil(results[0].1)
            XCTAssertEqual(dialog.controller.title, "http://127.0.0.1:8768")
        }
    }

    func testBackgroundNotificationCompletesOnceAndAcceptedPromptKeepsEmptyInput() {
        var cancelled = 0
        let pending = BrowserJavaScriptDialog(origin: "http://localhost:8768", message: "Synthetic confirm", kind: .confirm) { accepted, _ in
            XCTAssertFalse(accepted); cancelled += 1
        }
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        pending.finish(accept: true)
        XCTAssertEqual(cancelled, 1)
        var input: String?
        let prompt = BrowserJavaScriptDialog(origin: "http://localhost:8768", message: "Synthetic prompt", kind: .prompt("default")) {
            XCTAssertTrue($0); input = $1
        }
        XCTAssertEqual(prompt.controller.textFields?.first?.text, "default")
        prompt.finish(accept: true, text: "")
        XCTAssertEqual(input, "")
    }
}

@MainActor
final class BrowserWebsiteDataClearingTests: XCTestCase {
    func testClearWaitsForDisposalAndCapturesAllOrdinaryStoresBeforeProfileAndRegistryChanges() async throws {
        let first = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        let second = BrowserSession(dataStore: first.dataStore)
        defer { first.closeWindow(); second.closeWindow() }
        let firstStore = WKWebsiteDataStore.nonPersistent(), secondStore = WKWebsiteDataStore.nonPersistent()
        let firstCoordinator = ClearingStoreCoordinator(stores: [firstStore])
        let secondCoordinator = ClearingStoreCoordinator(stores: [secondStore])
        first.hostCoordinator = firstCoordinator; second.hostCoordinator = secondCoordinator
        let oldTab = try XCTUnwrap(first.activeTab)
        let oldView = oldTab.webView
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        window.rootViewController?.view.addSubview(oldView)
        defer { window.isHidden = true }
        first.switchProfile(to: .privateMode)
        let privateTab = try XCTUnwrap(first.activeTab), privateStore = privateTab.websiteDataStore
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "localhost", .path: "/", .name: "synthetic", .value: "retained-private-value"
        ]))
        for store in [firstStore, secondStore, privateStore] { await store.httpCookieStore.setCookie(cookie) }
        first.switchProfile(to: .standard)
        firstCoordinator.onClose = {
            first.switchProfile(to: .privateMode)
            first.hostCoordinator = nil
        }
        await first.clearWebsiteData()
        XCTAssertTrue(oldTab.isDisposed)
        XCTAssertTrue(firstCoordinator.closed.contains(oldTab.instanceID))
        XCTAssertEqual(firstCoordinator.stores.count, 0, "The captured store must be cleared after registry unbind")
        XCTAssertTrue(first.privateTabs.contains { $0 === privateTab })
        XCTAssertTrue(first.activeTab === privateTab)
        XCTAssertNil(oldView.load(URLRequest(url: URL(string: "http://localhost/late")!)))
        let firstCookies = await firstStore.httpCookieStore.allCookies()
        let secondCookies = await secondStore.httpCookieStore.allCookies()
        let privateCookies = await privateStore.httpCookieStore.allCookies()
        XCTAssertTrue(firstCookies.isEmpty)
        XCTAssertTrue(secondCookies.isEmpty)
        XCTAssertEqual(privateCookies.first { $0.name == "synthetic" }?.value, "retained-private-value")
        XCTAssertTrue(first.consumeRetiredPrivateWebsiteDataStores().isEmpty)
    }
}

@MainActor
private final class ClearingStoreCoordinator: BrowserHostStoreCoordinating {
    var stores: [WKWebsiteDataStore]
    var closed: Set<UUID> = []
    var onClose: (() -> Void)?
    init(stores: [WKWebsiteDataStore]) { self.stores = stores }
    func wouldSwitchStore(tab: BrowserTab, url: URL) -> Bool { false }
    func dataStoreForMainFrame(tab: BrowserTab, url: URL) -> WKWebsiteDataStore? { nil }
    func mainFrameFailed(tab: BrowserTab, failure: BrowserMainFrameFailure, error: NSError) {}
    func pendingRecoveryInvalidated(tab: BrowserTab) {}
    func tabClosed(_ tab: BrowserTab) { closed.insert(tab.instanceID); stores = []; onClose?() }
    func ordinaryHostStores() -> [WKWebsiteDataStore] { stores }
    func endPrivateSession(scopeID: String) {}
}

@MainActor
private func waitForReviewCondition(_ condition: () -> Bool) async throws {
    let limit = Date().addingTimeInterval(3)
    while !condition(), Date() < limit { try await Task.sleep(for: .milliseconds(10)) }
    if !condition() { throw NSError(domain: "AegisReviewRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic operation did not start"]) }
}
