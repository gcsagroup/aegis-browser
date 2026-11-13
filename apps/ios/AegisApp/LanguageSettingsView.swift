import SwiftUI

struct LanguageSettingsView: View {
    @EnvironmentObject private var language: AppLanguageSettings

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        List {
            Section {
                choice(nil, title: AegisLocalization.string("跟随系统"))
                ForEach(AegisLanguageChoice.displayOrder) { option in
                    choice(option, title: option.autonym)
                }
            } footer: {
                if language.choice?.regionOverride == nil {
                    Text("地区版本自动匹配系统语言偏好，地区格式保持系统设置。")
                }
            }
        }
        .localizedNavigationTitle("语言")
        .accessibilityIdentifier("language-settings")
    }

    private func choice(_ option: AegisLanguageChoice?, title: String) -> some View {
        Button { language.selectChoice(option) } label: {
            HStack {
                Text(verbatim: title).foregroundStyle(Color.primary)
                Spacer()
                if language.choice == option {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("language-choice-\(option?.rawValue ?? "system")")
        .accessibilityAddTraits(language.choice == option ? .isSelected : [])
    }
}
