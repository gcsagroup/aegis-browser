import Combine
import SwiftUI
import UIKit

/// A synchronous notification revokes consent even when SwiftUI coalesces a rapid
/// inactive/active transition. A service that ignores cancellation cannot publish a stale reply.
@MainActor
final class AssistantOperationLifetime: ObservableObject {
    private(set) var generation = UUID()
    var operation: Task<Void, Never>?
    private var foreground: Bool
    private var sceneID: String?
    private var sceneForeground = true
    let sceneDeactivated = PassthroughSubject<Void, Never>()
    private let applicationIsActive: @MainActor () -> Bool
    private var observations: Set<AnyCancellable> = []

    init(applicationIsActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }) {
        self.applicationIsActive = applicationIsActive
        foreground = applicationIsActive()
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in self?.foreground = false; self?.invalidate() }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.foreground = true }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification))
            .sink { [weak self] note in
                guard let scene = note.object as? UIScene else { return }
                self?.deactivateScene(scene.session.persistentIdentifier)
            }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: UIScene.didActivateNotification)
            .sink { [weak self] note in
                guard let scene = note.object as? UIScene else { return }
                self?.activateScene(scene.session.persistentIdentifier)
            }
            .store(in: &observations)
    }

    func attach(sceneID: String, isActive: Bool) {
        if let previous = self.sceneID, previous != sceneID { invalidate() }
        self.sceneID = sceneID
        if isActive { activateScene(sceneID) } else { deactivateScene(sceneID) }
    }

    func deactivateScene(_ id: String) {
        guard id == sceneID, sceneForeground else { return }
        sceneForeground = false
        invalidate()
        sceneDeactivated.send()
    }

    func activateScene(_ id: String) {
        guard id == sceneID else { return }
        sceneForeground = true
    }

    func isCurrent(_ token: UUID?) -> Bool {
        token == generation && foreground && sceneForeground && applicationIsActive()
    }

    func invalidate() {
        generation = UUID()
        operation?.cancel(); operation = nil
    }

    deinit { operation?.cancel() }
}

/// Each assistant resolves its own UIKit scene, including when presented in a sheet.
struct AssistantSceneAttachment: UIViewRepresentable {
    let lifetime: AssistantOperationLifetime
    func makeUIView(context: Context) -> SceneView { SceneView(lifetime: lifetime) }
    func updateUIView(_ view: SceneView, context: Context) { view.attach() }

    final class SceneView: UIView {
        private weak var lifetime: AssistantOperationLifetime?
        init(lifetime: AssistantOperationLifetime) {
            self.lifetime = lifetime
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() { super.didMoveToWindow(); attach() }
        func attach() {
            guard let scene = window?.windowScene else { return }
            lifetime?.attach(sceneID: scene.session.persistentIdentifier, isActive: scene.activationState == .foregroundActive)
        }
    }
}
