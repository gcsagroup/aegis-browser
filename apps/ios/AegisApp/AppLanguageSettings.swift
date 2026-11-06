import SwiftUI

@MainActor
final class AppLanguageSettings: ObservableObject {
    @Published private(set) var family: AegisLanguageFamily?
    @Published private(set) var snapshot: AegisLocalizationSnapshot
    @Published private(set) var revision = 0
    private let store: AegisLanguagePreferenceStore

    init(store: AegisLanguagePreferenceStore = .runtime) {
        self.store = store
        family = store.family
        snapshot = AegisLocalization.snapshot(store: store)
    }

    func select(_ family: AegisLanguageFamily?) {
        store.setFamily(family)
        refresh()
    }

    func refresh() {
        let next = AegisLocalization.snapshot(store: store)
        if family != store.family || snapshot != next {
            family = store.family
            snapshot = next
            revision &+= 1
        }
    }
}

/// Materialize the title on every locale update so native navigation chrome
/// receives a new value without replacing the destination or its state.
private struct AppLocalizedNavigationTitle: ViewModifier {
    @Environment(\.locale) private var locale
    let resource: LocalizedStringResource

    func body(content: Content) -> some View {
        let _ = locale
        content.navigationTitle(Text(verbatim: AegisLocalization.string(resource)))
    }
}

extension View {
    func localizedNavigationTitle(_ resource: LocalizedStringResource) -> some View {
        modifier(AppLocalizedNavigationTitle(resource: resource))
    }
}
