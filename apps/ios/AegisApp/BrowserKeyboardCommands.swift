import BrowserKit
import SwiftUI
import UIKit

/// 按当前窗口分派快捷键，避免只在菜单展开后才能使用。
struct BrowserKeyboardActions {
    let newTab: () -> Void
    let closeTab: () -> Void
    let editAddress: () -> Void
    let find: () -> Void
    let reload: () -> Void
    let back: () -> Void
    let forward: () -> Void
    var canCloseTab = true
    var canUsePageCommands = true

    @MainActor static func forWindow(_ browser: BrowserSession, presentation: BrowserPresentationCoordinator,
                                     editAddress: @escaping () -> Void = {}) -> Self? {
        guard !browser.isWindowClosed, !presentation.blocksBrowserCommands else { return nil }
        let hasVisibleTab = browser.activeTab != nil
        func allowed(_ action: () -> Void) {
            guard !browser.isWindowClosed, !presentation.blocksBrowserCommands else { return }
            action()
        }
        // FocusedValues may cache this action across a rapid new-tab command.
        // Resolve the tab in this owning window when the key actually executes.
        func onCurrentTab(_ action: (BrowserTab) -> Void) {
            allowed {
                guard let tab = browser.activeTab, !tab.isDisposed else { return }
                action(tab)
            }
        }
        return Self(newTab: { allowed { _ = browser.newTab() } },
                    closeTab: { onCurrentTab { browser.close($0.id) } },
                    editAddress: { onCurrentTab { _ in editAddress() } },
                    find: { onCurrentTab { presentation.request(.find($0.id, $0.instanceID)) } },
                    reload: { onCurrentTab { $0.reload() } }, back: { onCurrentTab { $0.goBack() } }, forward: { onCurrentTab { $0.goForward() } },
                    canCloseTab: hasVisibleTab, canUsePageCommands: hasVisibleTab)
    }
}

/// One enabled Close command occupies UIKit's File > Close slot for the app.
/// Its receiver selects the owning window; protected presentations consume it
/// without asking iPadOS to close the scene.
@MainActor
final class BrowserWindowCloseCommand: ObservableObject {
    private final class Registration {
        weak var owner: BrowserWindowCloseCommand?
        let id: UUID
        init(_ owner: BrowserWindowCloseCommand, id: UUID) { self.owner = owner; self.id = id }
    }
    private static var registrations: [ObjectIdentifier: Registration] = [:]
    private static let menuToken = UUID().uuidString
    private weak var window: UIWindow?
    private weak var root: UIViewController?
    private weak var browser: BrowserSession?
    private weak var presentation: BrowserPresentationCoordinator?
    private var bridgeID: UUID?
    private var registrationKey: ObjectIdentifier?
    private var registrationID: UUID?

    static func closeMenu(replacing menu: UIMenu?) -> UIMenu {
        let title = AegisLocalization.string("关闭当前标签")
        let command = UIKeyCommand(title: title, action: #selector(UIViewController.aegisCloseCurrentBrowserTab(_:)),
                                   input: "w", modifierFlags: .command, propertyList: menuToken,
                                   discoverabilityTitle: title)
        command.wantsPriorityOverSystemBehavior = true
        return (menu ?? UIMenu(title: "", identifier: .close, options: .displayInline, children: []))
            .replacingChildren([command])
    }

    static func replaceCloseMenu(in builder: any UIMenuBuilder) {
        guard builder.system === UIMenuSystem.main else { return }
        if let menu = builder.menu(for: .close) {
            builder.replace(menu: .close, with: closeMenu(replacing: menu))
        } else {
            builder.insertChild(closeMenu(replacing: nil), atEndOfMenu: .file)
        }
    }

    func attach(window: UIWindow, bridgeID: UUID, browser: BrowserSession,
                presentation: BrowserPresentationCoordinator) {
        guard !browser.isWindowClosed, let root = window.rootViewController else { invalidate(); return }
        if self.window === window, self.root === root, self.browser === browser, self.presentation === presentation {
            self.bridgeID = bridgeID
            return
        }
        invalidate()
        let key = ObjectIdentifier(window)
        Self.registrations[key]?.owner?.invalidate()
        let id = UUID()
        self.window = window; self.root = root; self.browser = browser; self.presentation = presentation
        self.bridgeID = bridgeID; registrationKey = key; registrationID = id
        Self.registrations[key] = Registration(self, id: id)
    }

    func detach(bridgeID: UUID) {
        if self.bridgeID == bridgeID { invalidate() }
    }

    func invalidate() {
        if let registrationKey, let registrationID { Self.remove(registrationKey, id: registrationID) }
        window = nil; root = nil; browser = nil; presentation = nil; bridgeID = nil; registrationKey = nil; registrationID = nil
    }

    private static func remove(_ key: ObjectIdentifier, id: UUID) {
        if registrations[key]?.id == id { registrations.removeValue(forKey: key) }
    }

    fileprivate static func dispatch(_ command: UIKeyCommand, receiver: UIViewController) {
        guard command.propertyList as? String == menuToken, command.input == "w", command.modifierFlags == .command,
              let window = receiver.viewIfLoaded?.window, let owner = registrations[ObjectIdentifier(window)]?.owner else { return }
        owner.closeCurrentTab(in: window)
    }

    private func closeCurrentTab(in window: UIWindow) {
        guard self.window === window, let root, window.rootViewController === root,
              window.isKeyWindow, window.windowScene?.activationState == .foregroundActive,
              let browser, !browser.isWindowClosed, let presentation,
              !presentation.blocksBrowserCommands, root.presentedViewController == nil,
              let tab = browser.activeTab, !tab.isDisposed else { return }
        browser.close(tab.id)
    }

    deinit {
        guard let registrationKey, let registrationID else { return }
        Task { @MainActor in Self.remove(registrationKey, id: registrationID) }
    }
}

extension UIViewController {
    /// Presented controllers also receive this unique selector, so a modal does
    /// not fall through to UIKit's default performClose: action.
    @objc fileprivate func aegisCloseCurrentBrowserTab(_ command: UIKeyCommand) {
        BrowserWindowCloseCommand.dispatch(command, receiver: self)
    }
}

struct BrowserWindowCloseAttachment: UIViewRepresentable {
    let browser: BrowserSession
    let presentation: BrowserPresentationCoordinator
    let owner: BrowserWindowCloseCommand

    func makeUIView(context: Context) -> AttachmentView {
        AttachmentView(owner: owner, browser: browser, presentation: presentation)
    }
    func updateUIView(_ view: AttachmentView, context: Context) {
        view.update(owner: owner, browser: browser, presentation: presentation)
    }
    static func dismantleUIView(_ view: AttachmentView, coordinator: ()) { view.detach() }

    final class AttachmentView: UIView {
        private weak var owner: BrowserWindowCloseCommand?
        private weak var browser: BrowserSession?
        private weak var presentation: BrowserPresentationCoordinator?
        private let bridgeID = UUID()
        init(owner: BrowserWindowCloseCommand, browser: BrowserSession, presentation: BrowserPresentationCoordinator) {
            self.owner = owner; self.browser = browser; self.presentation = presentation
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() { super.didMoveToWindow(); attach() }
        func update(owner: BrowserWindowCloseCommand, browser: BrowserSession, presentation: BrowserPresentationCoordinator) {
            if self.owner !== owner { detach() }
            self.owner = owner; self.browser = browser; self.presentation = presentation
            attach()
        }
        func attach() {
            guard let window, let browser, let presentation else { detach(); return }
            owner?.attach(window: window, bridgeID: bridgeID, browser: browser, presentation: presentation)
        }
        func detach() { owner?.detach(bridgeID: bridgeID) }
    }
}

private struct BrowserKeyboardActionsKey: FocusedValueKey {
    typealias Value = BrowserKeyboardActions
}

extension FocusedValues {
    var browserKeyboardActions: BrowserKeyboardActions? {
        get { self[BrowserKeyboardActionsKey.self] }
        set { self[BrowserKeyboardActionsKey.self] = newValue }
    }
}

struct BrowserKeyboardCommands: Commands {
    @ObservedObject var language: AppLanguageSettings
    @FocusedValue(\.browserKeyboardActions) private var actions
    var body: some Commands {
        let _ = language.revision
        CommandGroup(replacing: .newItem) {
            Button(AegisLocalization.string("新建")) { actions?.newTab() }.keyboardShortcut("t").disabled(actions == nil)
        }
        CommandGroup(after: .textEditing) {
            Button(AegisLocalization.string("在页面中查找")) {
                actions?.find()
            }.keyboardShortcut("f").disabled(actions?.canUsePageCommands != true)
            Button(AegisLocalization.string("编辑网址")) { actions?.editAddress() }.keyboardShortcut("l").disabled(actions?.canUsePageCommands != true)
            Button(AegisLocalization.string("刷新")) { actions?.reload() }.keyboardShortcut("r").disabled(actions?.canUsePageCommands != true)
            Button(AegisLocalization.string("后退")) { actions?.back() }.keyboardShortcut("[").disabled(actions?.canUsePageCommands != true)
            Button(AegisLocalization.string("前进")) { actions?.forward() }.keyboardShortcut("]").disabled(actions?.canUsePageCommands != true)
        }
    }
}
