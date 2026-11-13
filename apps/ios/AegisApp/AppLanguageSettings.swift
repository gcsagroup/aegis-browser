import SwiftUI

@MainActor
final class AppLanguageSettings: ObservableObject {
    @Published private(set) var choice: AegisLanguageChoice?
    var family: AegisLanguageFamily? { choice?.family }
    @Published private(set) var snapshot: AegisLocalizationSnapshot
    @Published private(set) var revision = 0
    private let store: AegisLanguagePreferenceStore

    init(store: AegisLanguagePreferenceStore = .runtime) {
        self.store = store
        choice = store.choice
        snapshot = AegisLocalization.snapshot(store: store)
    }

    func select(_ family: AegisLanguageFamily?) {
        selectChoice(family.map(AegisLanguageChoice.family))
    }

    func selectChoice(_ choice: AegisLanguageChoice?) {
        store.setChoice(choice)
        refresh()
    }

    func refresh() {
        let next = AegisLocalization.snapshot(store: store)
        if choice != store.choice || snapshot != next {
            choice = store.choice
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
