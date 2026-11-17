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
        case inputError(AegisLocalizedMessage)

        var isAlert: Bool {
            switch self { case .external, .privateBookmark, .windowError, .inputError: true; default: false }
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
        let id: UUID
        let route: Route
        let scope: UUID?
    }
    @Published private(set) var current: Request?
    @Published private(set) var isDismissing = false
    private enum Resolution { case waiting, resolved(Route?) }
    private struct Slot {
        let id: UUID
        let scope: UUID?
        var result: Resolution = .waiting
    }
    private var queue: [Slot] = []
    var pending: [Request] {
        queue.compactMap { slot in
            guard case let .resolved(route?) = slot.result else { return nil }
            return Request(id: slot.id, route: route, scope: slot.scope)
        }
    }
    private var shownID: UUID?
    var blocksBrowserCommands: Bool { current != nil || !queue.isEmpty }

    func request(_ route: Route) {
        resolve(reserve(), to: route)
    }

    func reserve(scope: UUID? = nil) -> UUID {
        let id = UUID()
        objectWillChange.send()
        queue.append(Slot(id: id, scope: scope))
        return id
    }

    func resolve(_ id: UUID, to route: Route?) {
        guard let index = queue.firstIndex(where: { $0.id == id }), case .waiting = queue[index].result else { return }
        objectWillChange.send()
        queue[index].result = .resolved(route)
        advance()
    }

    func revoke(scope: UUID) {
        objectWillChange.send()
        queue.removeAll { $0.scope == scope }
        if let current, current.scope == scope { dismiss(current.id) }
        advance()
    }

    private func advance() {
        guard current == nil else { return }
        while let first = queue.first, case let .resolved(result) = first.result {
            queue.removeFirst()
            if let result { current = Request(id: first.id, route: result, scope: first.scope); return }
        }
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
        current = nil
        shownID = nil
        isDismissing = false
        advance()
    }

    func closeWindow() {
        queue.removeAll(); current = nil; shownID = nil; isDismissing = false
    }

    func invalidate(where predicate: (Route) -> Bool) {
        objectWillChange.send()
        queue.removeAll { slot in
            guard case let .resolved(route?) = slot.result else { return false }
            return predicate(route)
        }
        if let current, predicate(current.route) { dismiss(current.id) }
        advance()
    }
}
