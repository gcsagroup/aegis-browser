import SwiftUI
import UIKit

/// UIKit supplies the actual alert dismissal completion, so queued sheets do not
/// race an alert animation or rely on an artificial async delay.
struct BrowserRouteAlert: UIViewControllerRepresentable {
    let request: BrowserPresentationCoordinator.Request?
    let isDismissing: Bool
    let makeAlert: @MainActor (BrowserPresentationCoordinator.Request, @escaping @MainActor () -> Void) -> UIAlertController
    let onDismiss: @MainActor (UUID) -> Void

    func makeUIViewController(context: Context) -> Host { Host() }
    func updateUIViewController(_ host: Host, context: Context) {
        host.request = request; host.isDismissing = isDismissing
        host.makeAlert = makeAlert; host.onDismiss = onDismiss
        host.reconcile()
    }

    @MainActor final class Host: UIViewController {
        var request: BrowserPresentationCoordinator.Request?
        var isDismissing = false
        var makeAlert: (@MainActor (BrowserPresentationCoordinator.Request, @escaping @MainActor () -> Void) -> UIAlertController)?
        var onDismiss: (@MainActor (UUID) -> Void)?
        private var active: (id: UUID, alert: UIAlertController)?
        private var closing = false

        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); reconcile() }
        func reconcile() {
            if let active {
                if isDismissing || request?.id != active.id { close(active.id) }
                return
            }
            guard !closing, !isDismissing, let request, request.route.isAlert,
                  viewIfLoaded?.window != nil, presentedViewController == nil, let makeAlert else { return }
            let alert = makeAlert(request) { [weak self] in self?.close(request.id) }
            active = (request.id, alert)
            present(alert, animated: true)
        }
        private func close(_ id: UUID) {
            guard let active, active.id == id, !closing else { return }
            closing = true
            active.alert.dismiss(animated: true) { [weak self] in
                guard let self, self.active?.id == id else { return }
                self.active = nil; self.closing = false
                self.onDismiss?(id)
                self.reconcile()
            }
        }
    }
}
