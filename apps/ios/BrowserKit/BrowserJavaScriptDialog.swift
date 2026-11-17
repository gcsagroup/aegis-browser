import Combine
import UIKit

/// Owns WebKit's completion independently of UIKit's presentation/dismissal callbacks.
@MainActor
final class BrowserJavaScriptDialog: NSObject {
    enum Kind { case alert, confirm, prompt(String?) }
    let id: UUID
    let controller: UIAlertController
    private var completion: (@MainActor (Bool, String?) -> Void)?
    private var backgroundObservation: AnyCancellable?
    private var sceneObservation: AnyCancellable?
    private var sceneDisconnectObservation: AnyCancellable?
    private var presentationObservation: Task<Void, Never>?

    init(id: UUID = UUID(), origin: String, message: String, kind: Kind, scene: UIScene? = nil,
         completion: @escaping @MainActor (Bool, String?) -> Void) {
        self.id = id
        controller = UIAlertController(title: origin, message: message, preferredStyle: .alert)
        self.completion = completion
        super.init()
        if case .prompt(let initial) = kind { controller.addTextField { $0.text = initial } }
        controller.addAction(UIAlertAction(title: AegisLocalization.string("完成"), style: .default) { [weak self] _ in
            self?.finish(accept: true, text: self?.controller.textFields?.first?.text)
        })
        if case .alert = kind {} else {
            controller.addAction(UIAlertAction(title: AegisLocalization.string("取消"), style: .cancel) { [weak self] _ in
                self?.finish(accept: false)
            })
        }
        backgroundObservation = NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in self?.cancel() }
        sceneObservation = NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)
            .sink { [weak self, weak scene] note in
                if let scene, note.object as? UIScene === scene { self?.cancel() }
            }
        sceneDisconnectObservation = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)
            .sink { [weak self, weak scene] note in
                if let scene, note.object as? UIScene === scene { self?.cancel() }
            }
    }

    func present(from presenter: UIViewController) {
        guard completion != nil else { return }
        // No transition may overlap the next WebKit dialog or a teardown callback.
        presenter.present(controller, animated: false)
        guard controller.presentingViewController != nil else { cancel(); return }
        // UIAlertController owns its presentation delegate and private view hierarchy.
        // Inspect only UIKit's public presentation/window state to catch dismissal by
        // another owner, including dismissal of an ancestor or removal of its window.
        presentationObservation = Task { @MainActor [weak self, weak window = presenter.viewIfLoaded?.window] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self else { return }
                guard let window, !window.isHidden, self.controller.presentingViewController != nil,
                      self.controller.viewIfLoaded?.window === window else {
                    self.cancel()
                    return
                }
            }
        }
    }

    func finish(accept: Bool, text: String? = nil) {
        resolve(accept: accept, text: text, waitForDismissal: true)
    }

    func cancel() {
        resolve(accept: false, text: nil, waitForDismissal: false)
    }

    private func resolve(accept: Bool, text: String?, waitForDismissal: Bool) {
        guard let completion else { return }
        self.completion = nil
        backgroundObservation = nil
        sceneObservation = nil
        sceneDisconnectObservation = nil
        presentationObservation?.cancel()
        presentationObservation = nil
        let finish = { completion(accept, accept ? text : nil) }
        if waitForDismissal, controller.isBeingDismissed {
            // An UIAlertAction can arrive during UIKit's own dismissal. Starting a
            // second dismissal then has no reliable completion callback.
            Task { @MainActor [controller] in
                while controller.presentingViewController != nil, controller.viewIfLoaded?.window != nil {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                finish()
            }
        } else if waitForDismissal, controller.presentingViewController != nil {
            // WebKit can ask for the next dialog as soon as we complete this one.
            // Let UIKit remove the current presenter before unblocking JavaScript.
            controller.dismiss(animated: false, completion: finish)
        } else {
            if !controller.isBeingDismissed { controller.dismiss(animated: false) }
            finish()
        }
    }

    deinit {
        presentationObservation?.cancel()
        let remaining = completion
        Task { @MainActor in remaining?(false, nil) }
    }
}
