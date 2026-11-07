import SwiftUI

struct LanguageSettingsView: View {
    @EnvironmentObject private var language: AppLanguageSettings

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        List {
            Section {
                choice(nil, title: AegisLocalization.string("跟随系统"))
                ForEach(AegisLanguageFamily.allCases, id: \.rawValue) { family in
                    choice(family, title: family.autonym)
                }
            } footer: {
                Text("地区版本自动匹配系统语言偏好，地区格式保持系统设置。")
            }
        }
        .localizedNavigationTitle("语言")
        .accessibilityIdentifier("language-settings")
    }

    private func choice(_ family: AegisLanguageFamily?, title: String) -> some View {
        Button { language.select(family) } label: {
            HStack {
                Text(verbatim: title).foregroundStyle(Color.primary)
                Spacer()
                if language.family == family {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("language-choice-\(family?.rawValue ?? "system")")
        .accessibilityAddTraits(language.family == family ? .isSelected : [])
    }
}
