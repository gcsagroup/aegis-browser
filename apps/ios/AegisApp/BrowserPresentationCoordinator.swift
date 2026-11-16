import BrowserKit
import SwiftUI

/// One presentation owner per browser window. Requests arriving during dismissal
/// are handed off only after the retiring presentation acknowledges its own ID.
@MainActor
final class BrowserPresentationCoordinator: ObservableObject {
    enum Route {
        case tabs, assistant, library, settings, website, reading, windows
        case find(UUID, UUID)
        case downloads(URL?, BrowserAccessDownload?)
        case markdown(MarkdownDocument)
        case external(URL)
        case privateBookmark(UUID, URL, UInt64)
        case windowError(AegisLocalizedMessage)

        var isAlert: Bool {
            switch self { case .external, .privateBookmark, .windowError: true; default: false }
        }
        var isExternal: Bool { if case .external = self { true } else { false } }
        var isDocumentBound: Bool {
            switch self { case .assistant, .find: true; default: false }
        }
        var isProfileBound: Bool {
            switch self { case .assistant, .library, .downloads, .find, .website, .markdown, .reading, .privateBookmark: true; default: false }
        }
    }
    struct Request: Identifiable {
        let id = UUID()
        let route: Route
    }
    @Published private(set) var current: Request?
    @Published private(set) var isDismissing = false
    private(set) var pending: [Request] = []
    private var shownID: UUID?
    var blocksBrowserCommands: Bool { current != nil || !pending.isEmpty }

    func request(_ route: Route) {
        let request = Request(route: route)
        guard current != nil else { self.current = request; return }
        pending.append(request)
    }

    func didPresent(_ id: UUID) {
        if current?.id == id { shownID = id }
    }

    func dismiss(_ id: UUID) {
        guard current?.id == id else { return }
        isDismissing = true
        if shownID != id { didDismiss(id) }
    }

    func didDismiss(_ id: UUID) {
        guard current?.id == id, isDismissing else { return }
        current = pending.isEmpty ? nil : pending.removeFirst()
        shownID = nil
        isDismissing = false
    }

    func closeWindow() {
        pending.removeAll(); current = nil; shownID = nil; isDismissing = false
    }

    func invalidate(where predicate: (Route) -> Bool) {
        pending.removeAll { predicate($0.route) }
        if let current, predicate(current.route) { dismiss(current.id) }
    }
}
