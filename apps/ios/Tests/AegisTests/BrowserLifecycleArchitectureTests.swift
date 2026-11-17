import AccessKit
import AgentKit
import Combine
import CryptoKit
import UIKit
import WebKit
import XCTest
@testable import Aegis
@testable import BrowserKit

@MainActor
final class BrowserPresentationCoordinatorTests: XCTestCase {
    func testWindowReloadCommandPreservesUnsafePrivateAndProtectedRequests() throws {
        for profile in [BrowserProfile.standard, .privateMode] {
            for protected in [false, true] {
                let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
                browser.switchProfile(to: profile)
                defer { browser.closeWindow() }
                let tab = try XCTUnwrap(browser.activeTab)
                let coordinator = AccessHostStoreCoordinator()
                if protected {
                    tab.hostCoordinator = coordinator
                    let host = try AccessSiteHost("manual-refresh.invalid")
                    coordinator.registry.setEndpoint(AccessManagedProxyEndpoint(identity: "reload-fixture", generation: 1,
                        loopbackHost: "127.0.0.1", port: 18081, state: .ready),
                        scopeID: tab.browsingScopeID, host: host, isPrivate: profile.isPrivate)
                    coordinator.setProxyEnabled(true, host: host, scopeID: tab.browsingScopeID, isPrivate: profile.isPrivate)
                }
                var request = URLRequest(url: URL(string: "https://manual-refresh.invalid/submit")!)
                request.httpMethod = "POST"; request.httpBody = Data("original=one".utf8)
                tab.load(request)
                let identity = tab.currentAttemptIDForTests, store = tab.websiteDataStore
                let loadError = tab.loadingError
                XCTAssertNil(tab.safeRouteReloadRequest)
                let command = try XCTUnwrap(BrowserKeyboardActions.forWindow(browser, presentation: BrowserPresentationCoordinator()))
                command.reload() // The exact action installed for Cmd-R.
                XCTAssertNil(tab.safeRouteReloadRequest)
                XCTAssertEqual(tab.currentAttemptIDForTests, identity)
                XCTAssertTrue(tab.websiteDataStore === store); XCTAssertEqual(tab.profile, profile)
                XCTAssertTrue(tab.reloadRequiresResubmission)
                XCTAssertEqual(tab.loadingError, loadError)
                XCTAssertFalse(tab.loadingErrorAllowsProxyRetry)
                if protected { XCTAssertFalse(store.proxyConfigurations.isEmpty) }
            }
        }
    }

    func testFIFOIncludesDistinctSameURLInputsAndRejectsOldDismissal() throws {
        let route = BrowserPresentationCoordinator()
        route.request(.reading)
        let first = try XCTUnwrap(route.current)
        let url = URL(string: "https://example.test/same")!
        route.request(.downloads(url, nil)); route.request(.downloads(url, nil))
        route.request(.external(url)); route.request(.markdown(MarkdownDocument(title: "One", text: "One")))
        XCTAssertFalse(route.isDismissing, "An unpresented request must not wait for an impossible dismissal")
        XCTAssertEqual(route.pending.count, 4)
        route.dismiss(first.id); route.didDismiss(first.id)
        let download = try XCTUnwrap(route.current)
        XCTAssertNotEqual(first.id, download.id)
        route.didDismiss(first.id)
        XCTAssertEqual(route.current?.id, download.id)
        route.dismiss(download.id); route.didDismiss(download.id)
        let second = try XCTUnwrap(route.current)
        XCTAssertNotEqual(download.id, second.id)
        guard case .downloads = second.route else { return XCTFail("Second same URL event was lost") }
        route.dismiss(second.id); route.didDismiss(second.id)
        guard case .external = route.current?.route else { return XCTFail("External event order changed") }
    }

    func testUnshownInvalidationProgressesWithoutImpossibleUIKitDismissCallback() throws {
        let route = BrowserPresentationCoordinator()
        route.request(.assistant)
        let neverShown = try XCTUnwrap(route.current)
        route.request(.settings)
        route.invalidate { $0.isDocumentBound }
        let settings = try XCTUnwrap(route.current)
        guard case .settings = settings.route else { return XCTFail("Unshown invalidation stalled the queue") }
        XCTAssertFalse(route.isDismissing)
        route.didDismiss(neverShown.id)
        XCTAssertEqual(route.current?.id, settings.id)
        route.didPresent(settings.id); route.dismiss(settings.id)
        XCTAssertTrue(route.isDismissing)
        route.didDismiss(neverShown.id)
        XCTAssertEqual(route.current?.id, settings.id)
        route.didDismiss(settings.id)
        XCTAssertNil(route.current)
    }

    func testSessionEventsPreserveSameURLAndMarkdownBeforeAnyRootRender() throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.closeWindow() }
        let url = URL(string: "https://example.test/file")!
        browser.pendingDownloadURL = url; browser.pendingDownloadURL = url
        XCTAssertEqual(browser.consumePendingDownload()?.url, url)
        XCTAssertEqual(browser.consumePendingDownload()?.url, url)
        XCTAssertNil(browser.consumePendingDownload())
        let first = MarkdownDocument(title: "Same", text: "First"), second = MarkdownDocument(title: "Same", text: "Second")
        browser.pendingMarkdown = first; browser.pendingMarkdown = second
        XCTAssertEqual(browser.consumePendingMarkdown()?.id, first.id)
        XCTAssertEqual(browser.consumePendingMarkdown()?.id, second.id)
        XCTAssertNil(browser.consumePendingMarkdown())
    }

    func testActualWindowCommandsCannotPenetrateReadingMarkdownOrHandoff() throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        let other = BrowserSession(dataStore: browser.dataStore)
        defer { browser.closeWindow(); other.closeWindow() }
        let route = BrowserPresentationCoordinator(), secondRoute = BrowserPresentationCoordinator()
        let tab = try XCTUnwrap(browser.activeTab)
        let original = browser.visibleTabs.count
        let oldCommands = try XCTUnwrap(BrowserKeyboardActions.forWindow(browser, presentation: route))
        route.request(.reading)
        XCTAssertNil(BrowserKeyboardActions.forWindow(browser, presentation: route))
        oldCommands.closeTab(); oldCommands.newTab()
        XCTAssertEqual(browser.visibleTabs.count, original)
        XCTAssertTrue(browser.activeTab === tab)
        XCTAssertNotNil(BrowserKeyboardActions.forWindow(other, presentation: secondRoute))
        route.request(.markdown(MarkdownDocument(title: "Private", text: "Synthetic")))
        let reading = try XCTUnwrap(route.current)
        route.dismiss(reading.id); route.didDismiss(reading.id)
        XCTAssertNil(BrowserKeyboardActions.forWindow(browser, presentation: route))
        oldCommands.closeTab()
        XCTAssertTrue(browser.activeTab === tab)
        let markdown = try XCTUnwrap(route.current)
        route.dismiss(markdown.id); route.didDismiss(markdown.id)
        let commands = try XCTUnwrap(BrowserKeyboardActions.forWindow(browser, presentation: route))
        commands.newTab()
        XCTAssertEqual(browser.visibleTabs.count, original + 1)
        oldCommands.closeTab() // A cached action still targets this window's current tab.
        XCTAssertEqual(browser.visibleTabs.count, original)
        XCTAssertTrue(browser.activeTab === tab)
    }

    func testCachedWindowCommandsHandleRapidNewCloseWithoutAnyViewRefresh() throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        let other = BrowserSession(dataStore: browser.dataStore)
        defer { browser.closeWindow(); other.closeWindow() }
        let route = BrowserPresentationCoordinator()
        let commands = try XCTUnwrap(BrowserKeyboardActions.forWindow(browser, presentation: route))
        let original = try XCTUnwrap(browser.activeTab), otherTab = try XCTUnwrap(other.activeTab)
        let originalCount = browser.visibleTabs.count, otherCount = other.visibleTabs.count
        // Reuse the exact same action value with no awaits or SwiftUI renders.
        for _ in 0..<10 {
            commands.newTab()
            let created = try XCTUnwrap(browser.activeTab)
            XCTAssertFalse(created === original)
            XCTAssertEqual(browser.visibleTabs.count, originalCount + 1)
            commands.closeTab()
            XCTAssertTrue(created.isDisposed)
            XCTAssertTrue(browser.activeTab === original)
            XCTAssertEqual(browser.visibleTabs.count, originalCount)
            XCTAssertTrue(other.activeTab === otherTab)
            XCTAssertEqual(other.visibleTabs.count, otherCount)
        }
        // Cached actions must still obey a presentation that appeared later.
        route.request(.reading)
        commands.newTab(); commands.closeTab()
        XCTAssertTrue(browser.activeTab === original)
        XCTAssertEqual(browser.visibleTabs.count, originalCount)
        XCTAssertFalse(browser.isWindowClosed); XCTAssertFalse(other.isWindowClosed)
    }

    func testEmptyGroupOnlyAdvertisesWorkingNewTabAction() throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.closeWindow() }
        _ = try browser.createGroup(name: "Empty")
        browser.moveTab(try XCTUnwrap(browser.activeTab?.id), to: nil)
        XCTAssertNil(browser.activeTab)
        let commands = try XCTUnwrap(BrowserKeyboardActions.forWindow(browser, presentation: BrowserPresentationCoordinator()))
        XCTAssertFalse(commands.canCloseTab); XCTAssertFalse(commands.canUsePageCommands)
        commands.closeTab(); commands.reload(); commands.find()
        XCTAssertNil(browser.activeTab)
        commands.newTab()
        XCTAssertNotNil(browser.activeTab)
    }

    func testConsumedProtectedDownloadRetainsOnlyLiveScopedAuthorityAndOwnAcknowledgment() throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        defer { browser.closeWindow() }
        let tab = try XCTUnwrap(browser.activeTab), url = URL(string: "https://example.test/file")!
        tab.prepareForRestore(url: url); tab.selectedAccessHost = "example.test"
        tab.onDownload?(url)
        let first = try XCTUnwrap(browser.consumePendingDownload()?.access)
        XCTAssertNil(browser.pendingDownloadURL); XCTAssertNil(browser.pendingAccessDownload)
        XCTAssertTrue(browser.ownsAccessDownload(first))
        tab.onDownload?(url)
        let second = try XCTUnwrap(browser.consumePendingDownload()?.access)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(browser.ownsAccessDownload(first)); XCTAssertTrue(browser.ownsAccessDownload(second))
        browser.releasePresentedAccessDownload(first)
        XCTAssertFalse(browser.ownsAccessDownload(first)); XCTAssertTrue(browser.ownsAccessDownload(second))
        // Same URL, same tab UUID, a different document: a frozen route grants no authority.
        tab.load(url)
        XCTAssertFalse(browser.ownsAccessDownload(second))
        browser.releasePresentedAccessDownload(first)
        XCTAssertFalse(browser.ownsAccessDownload(second))
    }

    func testProfileInvalidationDiscardsSensitiveQueuedContentButKeepsOrdinarySettings() throws {
        let route = BrowserPresentationCoordinator()
        route.request(.settings)
        route.request(.markdown(MarkdownDocument(title: "Private", text: "Private")))
        route.request(.reading); route.request(.settings)
        route.invalidate { $0.isProfileBound }
        XCTAssertEqual(route.pending.count, 1)
        let first = try XCTUnwrap(route.current)
        route.dismiss(first.id); route.didDismiss(first.id)
        guard case .settings = route.current?.route else { return XCTFail("Non-sensitive route was lost") }
    }
}

@MainActor
final class BrowserWindowCloseCommandTests: XCTestCase {
    private func nativeWindow() throws -> (UIWindow, UIViewController) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        return (window, controller)
    }

    private func command() throws -> UIKeyCommand {
        try XCTUnwrap(BrowserWindowCloseCommand.closeMenu(replacing: nil).children.first as? UIKeyCommand)
    }

    func testCloseMenuReplacesSystemCloseWithOneEnabledPriorityCommand() throws {
        let systemAction = NSSelectorFromString("performClose:")
        let systemClose = UIKeyCommand(input: "w", modifierFlags: .command, action: systemAction)
        let menu = UIMenu(title: "Close", identifier: .close, options: .displayInline, children: [systemClose])
        let replacement = BrowserWindowCloseCommand.closeMenu(replacing: menu)
        XCTAssertEqual(replacement.identifier, menu.identifier); XCTAssertEqual(replacement.title, menu.title)
        XCTAssertEqual(replacement.options, menu.options); XCTAssertEqual(replacement.children.count, 1)
        let close = try XCTUnwrap(replacement.children.first as? UIKeyCommand)
        XCTAssertEqual(close.input, "w"); XCTAssertEqual(close.modifierFlags, .command)
        XCTAssertNotEqual(close.action, systemAction)
        XCTAssertTrue(close.wantsPriorityOverSystemBehavior)
        XCTAssertFalse(close.attributes.contains(.disabled))
        XCTAssertFalse(close.discoverabilityTitle?.isEmpty ?? true)
    }

    func testCopiedNativeCommandUsesLiveTabAndIgnoresOldBridgeTeardown() throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        let route = BrowserPresentationCoordinator(), owner = BrowserWindowCloseCommand()
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let (window, controller) = try nativeWindow()
        defer { owner.invalidate(); window.isHidden = true; previous?.makeKeyAndVisible(); browser.closeWindow() }
        let firstBridge = UUID(), nextBridge = UUID()
        owner.attach(window: window, bridgeID: firstBridge, browser: browser, presentation: route)
        owner.attach(window: window, bridgeID: nextBridge, browser: browser, presentation: route)
        owner.detach(bridgeID: firstBridge)
        let copied = try XCTUnwrap(try command().copy() as? UIKeyCommand), action = try XCTUnwrap(copied.action)
        XCTAssertTrue(controller.canPerformAction(action, withSender: copied))
        XCTAssertTrue(controller.target(forAction: action, withSender: copied) as AnyObject? === controller)
        let original = try XCTUnwrap(browser.activeTab), count = browser.visibleTabs.count
        for _ in 0..<10 {
            let created = browser.newTab()
            _ = controller.perform(action, with: copied)
            XCTAssertTrue(created.isDisposed); XCTAssertTrue(browser.activeTab === original)
            XCTAssertEqual(browser.visibleTabs.count, count)
        }
        owner.detach(bridgeID: nextBridge)
        let retained = browser.newTab()
        _ = controller.perform(action, with: copied)
        XCTAssertFalse(retained.isDisposed)
        XCTAssertEqual(browser.visibleTabs.count, count + 1)
    }

    func testNativeCloseConsumesAllRootRoutesAndDismissalHandoff() throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        let route = BrowserPresentationCoordinator(), owner = BrowserWindowCloseCommand()
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let (window, controller) = try nativeWindow()
        defer { owner.invalidate(); window.isHidden = true; previous?.makeKeyAndVisible(); browser.closeWindow() }
        owner.attach(window: window, bridgeID: UUID(), browser: browser, presentation: route)
        let close = try command(), action = try XCTUnwrap(close.action)
        let original = try XCTUnwrap(browser.activeTab), count = browser.visibleTabs.count
        let routes: [BrowserPresentationCoordinator.Route] = [.reading, .markdown(MarkdownDocument(title: "Root", text: "Text")),
            .website, .settings, .tabs, .assistant, .library, .downloads(nil, nil), .windows,
            .find(original.id, original.instanceID), .external(URL(string: "https://example.test")!),
            .privateBookmark(original.id, URL(string: "https://example.test")!, original.navigationEpoch),
            .windowError(.verbatim("Fixture"))]
        for request in routes {
            route.request(request)
            let current = try XCTUnwrap(route.current)
            route.didPresent(current.id)
            XCTAssertTrue(controller.canPerformAction(action, withSender: close), "Protection must consume the key, not disable it")
            _ = controller.perform(action, with: close)
            route.dismiss(current.id)
            _ = controller.perform(action, with: close)
            XCTAssertTrue(browser.activeTab === original); XCTAssertEqual(browser.visibleTabs.count, count)
            route.didDismiss(current.id)
        }
        route.request(.reading)
        let reading = try XCTUnwrap(route.current)
        route.didPresent(reading.id)
        route.request(.markdown(MarkdownDocument(title: "Next", text: "Next")))
        route.dismiss(reading.id); route.didDismiss(reading.id)
        _ = controller.perform(action, with: close)
        XCTAssertTrue(browser.activeTab === original); XCTAssertEqual(browser.visibleTabs.count, count)
        XCTAssertTrue(window.isKeyWindow); XCTAssertFalse(browser.isWindowClosed)
    }

    func testPresentedAndNestedControllersConsumeCloseWithoutRootRoute() async throws {
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        let route = BrowserPresentationCoordinator(), owner = BrowserWindowCloseCommand()
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let (window, controller) = try nativeWindow()
        defer { owner.invalidate(); window.isHidden = true; previous?.makeKeyAndVisible(); browser.closeWindow() }
        owner.attach(window: window, bridgeID: UUID(), browser: browser, presentation: route)
        let close = try command(), action = try XCTUnwrap(close.action)
        let original = try XCTUnwrap(browser.activeTab), count = browser.visibleTabs.count
        let sheet = UIViewController(), nested = UIViewController()
        await withCheckedContinuation { completion in controller.present(sheet, animated: false) { completion.resume() } }
        await withCheckedContinuation { completion in sheet.present(nested, animated: false) { completion.resume() } }
        XCTAssertFalse(route.blocksBrowserCommands)
        XCTAssertTrue(nested.canPerformAction(action, withSender: close))
        XCTAssertTrue(nested.target(forAction: action, withSender: close) as AnyObject? === nested)
        _ = nested.perform(action, with: close)
        XCTAssertTrue(browser.activeTab === original); XCTAssertEqual(browser.visibleTabs.count, count)
        XCTAssertTrue(window.isKeyWindow); XCTAssertFalse(browser.isWindowClosed)
        await withCheckedContinuation { completion in controller.dismiss(animated: false) { completion.resume() } }
        let created = browser.newTab()
        _ = controller.perform(action, with: close)
        XCTAssertTrue(created.isDisposed); XCTAssertTrue(browser.activeTab === original)
    }

    func testNativeCloseUsesReceiverWindowAndEmptyGroupIsNoOp() throws {
        let first = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
        let second = BrowserSession(dataStore: first.dataStore)
        let firstRoute = BrowserPresentationCoordinator(), secondRoute = BrowserPresentationCoordinator()
        let firstOwner = BrowserWindowCloseCommand(), secondOwner = BrowserWindowCloseCommand()
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let (firstWindow, firstController) = try nativeWindow(), (secondWindow, secondController) = try nativeWindow()
        defer {
            firstOwner.invalidate(); secondOwner.invalidate(); firstWindow.isHidden = true; secondWindow.isHidden = true
            previous?.makeKeyAndVisible(); first.closeWindow(); second.closeWindow()
        }
        firstOwner.attach(window: firstWindow, bridgeID: UUID(), browser: first, presentation: firstRoute)
        secondOwner.attach(window: secondWindow, bridgeID: UUID(), browser: second, presentation: secondRoute)
        let close = try command(), action = try XCTUnwrap(close.action)
        let firstTab = try XCTUnwrap(first.activeTab), secondTab = try XCTUnwrap(second.activeTab)
        _ = firstController.perform(action, with: close) // A non-key receiver cannot close its background tab.
        XCTAssertTrue(first.activeTab === firstTab); XCTAssertTrue(second.activeTab === secondTab)
        let created = second.newTab()
        _ = secondController.perform(action, with: close)
        XCTAssertTrue(created.isDisposed); XCTAssertTrue(second.activeTab === secondTab)
        let emptyGroup = try second.createGroup(name: "Empty")
        let seededTab = try XCTUnwrap(second.activeTab)
        second.moveTab(seededTab.id, to: nil)
        XCTAssertEqual(second.selectedGroupID, emptyGroup)
        XCTAssertTrue(second.displayedTabs.isEmpty); XCTAssertNil(second.activeTab)
        let hiddenIDs = second.visibleTabs.map(\.id)
        let count = second.visibleTabs.count
        _ = secondController.perform(action, with: close)
        XCTAssertNil(second.activeTab); XCTAssertEqual(second.visibleTabs.count, count)
        XCTAssertEqual(second.visibleTabs.map(\.id), hiddenIDs)
        XCTAssertTrue(second.displayedTabs.isEmpty); XCTAssertEqual(second.selectedGroupID, emptyGroup)
        XCTAssertFalse(secondTab.isDisposed); XCTAssertFalse(seededTab.isDisposed)
        XCTAssertTrue(first.activeTab === firstTab); XCTAssertFalse(second.isWindowClosed)
        firstWindow.makeKeyAndVisible()
        let firstCreated = first.newTab()
        _ = firstController.perform(action, with: close)
        XCTAssertTrue(firstCreated.isDisposed); XCTAssertTrue(first.activeTab === firstTab)
        XCTAssertEqual(second.visibleTabs.map(\.id), hiddenIDs); XCTAssertNil(second.activeTab)
    }
}

@MainActor
final class MainFrameNavigationStateTests: XCTestCase {
    private func navigation() throws -> (WKWebView, WKNavigation) {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        return (view, try XCTUnwrap(view.loadHTMLString("<p>Identity fixture</p>", baseURL: nil)))
    }

    func testFIFOAndRetiredCallbacksCannotBorrowNewerSameURLAttempt() throws {
        let state = MainFrameNavigationState()
        let url = URL(string: "https://example.test/same")!
        state.begin(url: url, method: "POST", unsafeReplay: true, policyType: .formSubmitted)
        let old = state.current
        state.begin(url: url, method: "GET", unsafeReplay: false, policyType: .linkActivated)
        let latest = state.current
        let (firstView, first) = try navigation(), (secondView, second) = try navigation()
        defer { firstView.stopLoading(); secondView.stopLoading() }
        XCTAssertEqual(state.bindNext(first)?.navigationID, old.navigationID)
        XCTAssertFalse(state.isCurrent(first, isLoading: true))
        XCTAssertEqual(state.bindNext(second)?.navigationID, latest.navigationID)
        XCTAssertTrue(state.isCurrent(second, isLoading: true))
        XCTAssertTrue(state.retire(first)?.hasReplayableBody == true)
        XCTAssertEqual(state.current.navigationID, latest.navigationID)
        XCTAssertNil(state.retire(first))
        state.retireAll()
        XCTAssertNil(state.bindNext(second)); XCTAssertFalse(state.isCurrent(second, isLoading: true))
    }

    func testHistoryAcknowledgmentAndRedirectNeverInventSafeReplay() throws {
        let state = MainFrameNavigationState()
        let initial = URL(string: "https://example.test/form")!, target = URL(string: "https://example.test/redirect")!
        state.begin(url: initial, method: "GET", unsafeReplay: false, policyType: .backForward)
        let id = state.current.navigationID
        state.programmaticPolicyNavigationID = id
        XCTAssertTrue(state.adoptPolicy(url: initial, method: "POST", continues: false, unsafeReplay: true, policyType: .formResubmitted))
        XCTAssertEqual(state.current.navigationID, id)
        XCTAssertEqual(state.current.method, "POST")
        let (view, navigation) = try navigation(); defer { view.stopLoading() }
        state.bind(navigation, to: state.current); state.pendingNavigation = navigation
        XCTAssertTrue(state.confirmRedirect(navigation, url: target))
        XCTAssertTrue(state.adoptPolicy(url: target, method: "GET", continues: false, unsafeReplay: false, policyType: .other))
        XCTAssertEqual(state.current.method, "POST")
        XCTAssertTrue(state.current.hasReplayableBody)
        XCTAssertNil(state.uniqueCurrentUnbound)
    }
}

@MainActor
final class PageAssistantModelTests: XCTestCase {
    @MainActor private struct Fixture {
        let browser: BrowserSession
        let settings: BrowserSettings
        let tasks: AssistantTaskStore
        let defaults: UserDefaults
        let suite: String
        let directory: URL
        let encryptionKey: SymmetricKey
        init(profile: BrowserProfile = .standard) throws {
            browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil))
            suite = "page-assistant-model-" + UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            settings = BrowserSettings(defaults: defaults)
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            encryptionKey = SymmetricKey(size: .bits256)
            tasks = AssistantTaskStore(url: directory.appendingPathComponent("tasks.aes"), key: encryptionKey)
            browser.switchProfile(to: profile)
            let tab = try XCTUnwrap(browser.activeTab)
            tab.adoptPolicyMainFrameNavigationForTests(url: URL(string: "https://example.test/article")!)
            tab.commitPendingMainFrameForTests(); tab.stop()
        }
        func close() { browser.closeWindow(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        func reloadedTasks() -> AssistantTaskStore { AssistantTaskStore(url: directory.appendingPathComponent("tasks.aes"), key: encryptionKey) }
        func attach(_ model: PageAssistantModel) { model.attach(browser: browser, settings: settings, tasks: tasks) }
    }
    private func model(stream: @escaping PageAssistantModel.Stream) -> PageAssistantModel {
        PageAssistantModel(lifetime: AssistantOperationLifetime(applicationIsActive: { true }), credential: { _ in "fixture-key" },
                           readPage: { tab, _ in
            PageSnapshot(id: tab.id, navigationEpoch: tab.navigationEpoch, url: tab.url!, title: "Synthetic", text: "Synthetic source", capturedAt: Date(), truncated: false)
        }, stream: stream)
    }
    private func read(_ model: PageAssistantModel) async throws {
        model.readPages()
        let task = try XCTUnwrap(model.lifetime.operation)
        await task.value
        XCTAssertEqual(model.snapshots.count, 1)
    }

    func testConsentAndImmediateCancellationSendZeroRequestsAndCreateNoRecords() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var sends = 0
        let model = model { _, _, _, _, _, _ in sends += 1; return "Unexpected" }
        fixture.attach(model); try await read(model)
        model.requestConsent(); XCTAssertNotNil(model.consent)
        model.cancel(); model.send()
        XCTAssertEqual(sends, 0); XCTAssertTrue(fixture.tasks.records.isEmpty)
        model.requestConsent(); model.send()
        let task = try XCTUnwrap(model.lifetime.operation)
        model.cancel(); await task.value
        XCTAssertEqual(sends, 0); XCTAssertTrue(fixture.tasks.records.isEmpty)
        XCTAssertFalse(model.busy)
    }

    func testSameURLReloadAndCredentialChangeRevokeApprovedSourcesBeforeSend() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var sends = 0, key = "first-account"
        let model = PageAssistantModel(lifetime: AssistantOperationLifetime(applicationIsActive: { true }), credential: { _ in key },
                                      readPage: { tab, _ in PageSnapshot(id: tab.id, navigationEpoch: tab.navigationEpoch, url: tab.url!, title: "Synthetic", text: "Synthetic", capturedAt: Date(), truncated: false) },
                                      stream: { _, _, _, _, _, _ in sends += 1; return "Unexpected" })
        fixture.attach(model); try await read(model); model.requestConsent()
        key = "another-account"; model.send()
        XCTAssertEqual(sends, 0); XCTAssertTrue(fixture.tasks.records.isEmpty)
        model.requestConsent()
        let tab = try XCTUnwrap(fixture.browser.activeTab), url = try XCTUnwrap(fixture.browser.activeTab?.url)
        tab.load(url)
        XCTAssertNil(model.consent); XCTAssertTrue(model.snapshots.isEmpty)
        model.send(); XCTAssertEqual(sends, 0)
    }

    func testCancelledUncooperativeStreamCannotPublishOrCompleteNewerOperation() async throws {
        for oldCompletionFails in [false, true] {
            let fixture = try Fixture(); defer { fixture.close() }
            var replies: [String: CheckedContinuation<String, any Error>] = [:]
            var partials: [String: @MainActor @Sendable (String) -> Void] = [:]
            let firstStarted = expectation(description: "First request"), secondStarted = expectation(description: "Second request")
            let model = model { _, _, goal, _, _, onText in
                partials[goal] = onText
                return try await withCheckedThrowingContinuation { reply in
                    replies[goal] = reply
                    (goal == "First" ? firstStarted : secondStarted).fulfill()
                }
            }
            fixture.attach(model); try await read(model)
            model.goal = "First"; model.requestConsent(); model.send()
            let firstTask = try XCTUnwrap(model.lifetime.operation)
            await fulfillment(of: [firstStarted], timeout: 2)
            model.cancel()
            XCTAssertEqual(fixture.tasks.records.first?.state, .interrupted)
            try await read(model); model.goal = "Second"; model.requestConsent(); model.send()
            let secondTask = try XCTUnwrap(model.lifetime.operation)
            await fulfillment(of: [secondStarted], timeout: 2)
            partials["First"]?("Stale partial")
            XCTAssertTrue(model.output.isEmpty)
            partials["Second"]?("Current partial")
            XCTAssertEqual(model.output, "Current partial")
            replies["Second"]?.resume(returning: "Current [1]"); await secondTask.value
            XCTAssertTrue(model.outputComplete); XCTAssertEqual(model.output, "Current [1]")
            if oldCompletionFails { replies["First"]?.resume(throwing: ModelClientError.invalidResponse) }
            else { replies["First"]?.resume(returning: "Stale final [1]") }
            await firstTask.value
            XCTAssertTrue(model.outputComplete); XCTAssertEqual(model.output, "Current [1]")
            XCTAssertNil(model.error); XCTAssertFalse(model.busy)
            XCTAssertEqual(fixture.tasks.records.first?.state, .completed)
            XCTAssertEqual(fixture.tasks.records.last?.state, .interrupted)
        }
    }

    func testCompletedStreamRejectsLateTextBeforeAndAfterExplicitSave() async throws {
        for profile in [BrowserProfile.standard, .privateMode] {
            let fixture = try Fixture(profile: profile); defer { fixture.close() }
            var callback: (@MainActor @Sendable (String) -> Void)?
            let model = model { _, _, _, _, _, onText in
                callback = onText
                onText("Draft [1]")
                return "Validated result [1]"
            }
            fixture.attach(model); try await read(model)
            model.requestConsent(); model.send()
            let operation = try XCTUnwrap(model.lifetime.operation); await operation.value
            let lateText = try XCTUnwrap(callback), report = model.report
            let completedStatus = Aegis.AegisLocalization.string(model.status)
            XCTAssertEqual(model.output, "Validated result [1]"); XCTAssertTrue(model.outputComplete)
            XCTAssertFalse(model.busy); XCTAssertNil(model.lifetime.operation); XCTAssertNil(model.error)
            XCTAssertEqual(fixture.tasks.records.count, profile.isPrivate ? 0 : 1)
            XCTAssertNil(fixture.tasks.records.first?.savedReport)

            // No cancellation or newer operation: returning already ended this stream.
            lateText("Late unvalidated text before save")
            XCTAssertEqual(model.output, "Validated result [1]"); XCTAssertEqual(model.report, report)
            XCTAssertEqual(Aegis.AegisLocalization.string(model.status), completedStatus)
            XCTAssertTrue(model.outputComplete); XCTAssertFalse(model.busy); XCTAssertNil(model.error)
            model.saveResult()
            XCTAssertEqual(fixture.tasks.records.first?.state, .completed)
            XCTAssertEqual(fixture.tasks.records.first?.savedReport, report)
            XCTAssertEqual(fixture.reloadedTasks().records.first?.savedReport, report)

            let savedStatus = Aegis.AegisLocalization.string(model.status)
            lateText("Late unvalidated text after save")
            XCTAssertEqual(model.output, "Validated result [1]"); XCTAssertEqual(model.report, report)
            XCTAssertEqual(Aegis.AegisLocalization.string(model.status), savedStatus)
            model.saveResult()
            XCTAssertEqual(fixture.reloadedTasks().records.first?.savedReport, report)
            XCTAssertEqual(fixture.tasks.records.count, 1)
        }
    }

    func testFailedStreamRejectsLateTextAndRetrySavesOnlyValidatedResult() async throws {
        for failure in [ModelClientError.sensitiveData, .invalidCitation, .invalidResponse, .incompleteResponse] {
            let fixture = try Fixture(); defer { fixture.close() }
            var callbacks: [@MainActor @Sendable (String) -> Void] = []
            let model = model { _, _, _, _, _, onText in
                callbacks.append(onText)
                onText("Current draft [1]")
                if callbacks.count == 1 { throw failure }
                return "Validated retry [1]"
            }
            fixture.attach(model); try await read(model)
            model.requestConsent(); model.send()
            let failedOperation = try XCTUnwrap(model.lifetime.operation); await failedOperation.value
            let failedText = try XCTUnwrap(callbacks.first)
            let expectedDraft = failure == .incompleteResponse ? "Current draft [1]" : ""
            let failedStatus = Aegis.AegisLocalization.string(model.status)
            XCTAssertEqual(model.output, expectedDraft); XCTAssertFalse(model.outputComplete)
            XCTAssertEqual(model.error as? ModelClientError, failure); XCTAssertFalse(model.busy)
            XCTAssertNil(model.lifetime.operation); XCTAssertEqual(fixture.tasks.records.first?.state, .failed)

            failedText("Rejected body revived by a late callback")
            XCTAssertEqual(model.output, expectedDraft)
            XCTAssertEqual(Aegis.AegisLocalization.string(model.status), failedStatus)
            XCTAssertEqual(model.error as? ModelClientError, failure)
            XCTAssertFalse(model.outputComplete); XCTAssertFalse(model.busy)
            model.saveResult()
            XCTAssertNil(fixture.reloadedTasks().records.first?.savedReport)

            // Retry still reuses the preview, with fresh consent and a fresh stream.
            model.requestConsent(); XCTAssertNotNil(model.consent); model.send()
            let retry = try XCTUnwrap(model.lifetime.operation); await retry.value
            let retryReport = model.report, retryStatus = Aegis.AegisLocalization.string(model.status)
            failedText("Another old failure callback")
            callbacks.last?("Late text from the completed retry")
            XCTAssertEqual(model.output, "Validated retry [1]"); XCTAssertEqual(model.report, retryReport)
            XCTAssertEqual(Aegis.AegisLocalization.string(model.status), retryStatus)
            XCTAssertTrue(model.outputComplete); XCTAssertFalse(model.busy); XCTAssertNil(model.error)
            model.saveResult()
            let stored = fixture.reloadedTasks().records
            XCTAssertEqual(stored.map(\.state), [.completed, .failed])
            XCTAssertEqual(stored.first?.savedReport, retryReport); XCTAssertNil(stored.last?.savedReport)
        }
    }

    func testCancelledStreamRejectsLateTextWithoutAnotherOperation() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var callback: (@MainActor @Sendable (String) -> Void)?
        var reply: CheckedContinuation<String, any Error>?
        defer { reply?.resume(returning: "Cleanup [1]") }
        let started = expectation(description: "Streaming draft before cancellation")
        let model = model { _, _, _, _, _, onText in
            callback = onText; onText("Unfinished draft [1]")
            return try await withCheckedThrowingContinuation { reply = $0; started.fulfill() }
        }
        fixture.attach(model); try await read(model); model.requestConsent(); model.send()
        let operation = try XCTUnwrap(model.lifetime.operation)
        await fulfillment(of: [started], timeout: 2)
        model.cancel()
        let pausedStatus = Aegis.AegisLocalization.string(model.status)
        let lateText = try XCTUnwrap(callback)
        lateText("Late partial after cancel")
        reply?.resume(returning: "Late final after cancel [1]"); reply = nil
        await operation.value
        XCTAssertEqual(model.output, "Unfinished draft [1]"); XCTAssertFalse(model.outputComplete)
        XCTAssertEqual(Aegis.AegisLocalization.string(model.status), pausedStatus)
        XCTAssertFalse(model.busy); XCTAssertNil(model.lifetime.operation); XCTAssertNil(model.taskID)
        model.saveResult()
        XCTAssertEqual(fixture.reloadedTasks().records.first?.state, .interrupted)
        XCTAssertNil(fixture.reloadedTasks().records.first?.savedReport)
    }

    func testRevokingIdlePreviewCompletedAndSavedResultResetsVisibleStatus() async throws {
        for state in ["preview", "completed", "saved"] {
            let fixture = try Fixture(); defer { fixture.close() }
            let model = model { _, _, _, _, _, _ in "Validated [1]" }
            fixture.attach(model)
            let readyStatus = Aegis.AegisLocalization.string(model.status)
            try await read(model)
            if state != "preview" {
                model.requestConsent(); model.send()
                let operation = try XCTUnwrap(model.lifetime.operation); await operation.value
                if state == "saved" { model.saveResult() }
            }
            XCTAssertNotEqual(Aegis.AegisLocalization.string(model.status), readyStatus)
            switch state {
            case "preview": model.select(try XCTUnwrap(fixture.browser.activeTab).id, included: false)
            case "completed":
                let tab = try XCTUnwrap(fixture.browser.activeTab)
                tab.load(try XCTUnwrap(tab.url)); tab.stop()
            default: fixture.settings.model = ModelConfiguration(endpoint: "https://another-model.test", model: "other")
            }
            XCTAssertTrue(model.snapshots.isEmpty); XCTAssertTrue(model.output.isEmpty)
            XCTAssertNil(model.consent); XCTAssertFalse(model.outputComplete); XCTAssertFalse(model.busy)
            XCTAssertEqual(Aegis.AegisLocalization.string(model.status), readyStatus)
            // Source/config invalidation never mutates the earlier record's terminal state.
            if state != "preview" { XCTAssertEqual(fixture.tasks.records.first?.state, .completed) }
        }
    }

    func testRepeatedSendWithoutRereadingRejectsPreviouslyCompletedStreamsLateCallback() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var callbacks: [String: @MainActor @Sendable (String) -> Void] = [:]
        var secondReply: CheckedContinuation<String, any Error>?
        let secondStarted = expectation(description: "Second send against same preview")
        let model = model { _, _, goal, _, _, onText in
            callbacks[goal] = onText
            if goal == "First" { return "First [1]" }
            return try await withCheckedThrowingContinuation { secondReply = $0; secondStarted.fulfill() }
        }
        fixture.attach(model); try await read(model)
        model.goal = "First"; model.requestConsent(); model.send()
        let first = try XCTUnwrap(model.lifetime.operation); await first.value
        XCTAssertTrue(model.outputComplete)
        model.goal = "Second"; model.requestConsent(); model.send()
        let second = try XCTUnwrap(model.lifetime.operation)
        await fulfillment(of: [secondStarted], timeout: 2)
        callbacks["First"]?("Late callback after first stream already returned")
        XCTAssertTrue(model.output.isEmpty)
        callbacks["Second"]?("Current partial")
        XCTAssertEqual(model.output, "Current partial")
        secondReply?.resume(returning: "Second [1]"); await second.value
        callbacks["First"]?("Another stale callback")
        XCTAssertEqual(model.output, "Second [1]"); XCTAssertTrue(model.outputComplete)
        XCTAssertEqual(fixture.tasks.records.map(\.state), [.completed, .completed])
    }

    func testCancellingRepeatedSendBeforeTaskStartsPreservesPriorCompletedRecord() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var sends = 0
        let model = model { _, _, _, _, _, _ in sends += 1; return "Complete [1]" }
        fixture.attach(model); try await read(model)
        model.requestConsent(); model.send()
        let first = try XCTUnwrap(model.lifetime.operation); await first.value
        XCTAssertEqual(fixture.tasks.records.first?.state, .completed)
        model.requestConsent(); model.send()
        let second = try XCTUnwrap(model.lifetime.operation)
        model.cancel(); await second.value
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(fixture.tasks.records.count, 1)
        XCTAssertEqual(fixture.tasks.records.first?.state, .completed)
    }

    func testEarlierSourceNavigationRevokesBatchWhileLaterReadIgnoresCancellation() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let first = try XCTUnwrap(fixture.browser.activeTab), second = fixture.browser.newTab()
        second.adoptPolicyMainFrameNavigationForTests(url: URL(string: "https://example.test/second")!)
        second.commitPendingMainFrameForTests(); second.stop()
        let firstBatchWaiting = expectation(description: "First batch waits for second document")
        let nextBatchWaiting = expectation(description: "Next batch waits for second document")
        var replies: [(snapshot: PageSnapshot, continuation: CheckedContinuation<PageSnapshot, any Error>)] = []
        let model = PageAssistantModel(lifetime: AssistantOperationLifetime(applicationIsActive: { true }), readPage: { tab, _ in
            let snapshot = PageSnapshot(id: tab.id, navigationEpoch: tab.navigationEpoch, url: tab.url!,
                                        title: "Synthetic", text: "Synthetic document", capturedAt: Date(), truncated: false)
            guard tab === second else { return snapshot }
            return try await withCheckedThrowingContinuation { continuation in
                replies.append((snapshot, continuation))
                (replies.count == 1 ? firstBatchWaiting : nextBatchWaiting).fulfill()
            }
        })
        fixture.attach(model); model.select(first.id, included: true); model.readPages()
        let staleTask = try XCTUnwrap(model.lifetime.operation)
        await fulfillment(of: [firstBatchWaiting], timeout: 2)
        XCTAssertTrue(first.assistantPinned); XCTAssertTrue(second.assistantPinned)
        first.load(try XCTUnwrap(first.url)); first.stop()
        XCTAssertFalse(model.busy); XCTAssertNil(model.lifetime.operation)
        XCTAssertTrue(model.snapshots.isEmpty); XCTAssertNil(model.consent)
        XCTAssertFalse(first.assistantPinned); XCTAssertFalse(second.assistantPinned)
        model.readPages()
        let currentTask = try XCTUnwrap(model.lifetime.operation)
        await fulfillment(of: [nextBatchWaiting], timeout: 2)
        replies[0].continuation.resume(returning: replies[0].snapshot); await staleTask.value
        XCTAssertTrue(model.busy); XCTAssertTrue(model.snapshots.isEmpty)
        XCTAssertTrue(first.assistantPinned); XCTAssertTrue(second.assistantPinned)
        replies[1].continuation.resume(returning: replies[1].snapshot); await currentTask.value
        XCTAssertFalse(model.busy); XCTAssertEqual(model.snapshots.count, 2)
        model.cancel()
    }

    func testSourceClosureDuringUncooperativeReadCannotRestorePreview() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let started = expectation(description: "Reading source")
        var reply: CheckedContinuation<PageSnapshot, any Error>?
        let tab = try XCTUnwrap(fixture.browser.activeTab)
        let snapshot = PageSnapshot(id: tab.id, navigationEpoch: tab.navigationEpoch, url: tab.url!, title: "Synthetic", text: "Private fixture", capturedAt: Date(), truncated: false)
        let model = PageAssistantModel(lifetime: AssistantOperationLifetime(applicationIsActive: { true }), readPage: { _, _ in
            try await withCheckedThrowingContinuation { reply = $0; started.fulfill() }
        })
        fixture.attach(model); model.readPages()
        let operation = try XCTUnwrap(model.lifetime.operation)
        await fulfillment(of: [started], timeout: 2)
        fixture.browser.close(tab.id)
        reply?.resume(returning: snapshot); await operation.value
        XCTAssertTrue(model.snapshots.isEmpty); XCTAssertNil(model.consent); XCTAssertFalse(model.busy)
    }

    func testOwningSceneRevokesConsentWhileAnotherWindowRemainsUsable() async throws {
        let first = try Fixture(), second = try Fixture(); defer { first.close(); second.close() }
        let firstModel = model { _, _, _, _, _, _ in "First [1]" }, secondModel = model { _, _, _, _, _, _ in "Second [1]" }
        first.attach(firstModel); second.attach(secondModel)
        firstModel.lifetime.attach(sceneID: "First", isActive: true); secondModel.lifetime.attach(sceneID: "Second", isActive: true)
        try await read(firstModel); try await read(secondModel)
        firstModel.requestConsent(); secondModel.requestConsent()
        firstModel.lifetime.deactivateScene("First"); secondModel.lifetime.deactivateScene("First")
        XCTAssertNil(firstModel.consent); XCTAssertTrue(firstModel.snapshots.isEmpty)
        XCTAssertNotNil(secondModel.consent)
        firstModel.lifetime.activateScene("First"); XCTAssertNil(firstModel.consent)
        secondModel.send(); let operation = try XCTUnwrap(secondModel.lifetime.operation); await operation.value
        XCTAssertTrue(secondModel.outputComplete)
    }
}
