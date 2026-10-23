import SwiftUI

// 原生菜单仍负责选择；当前值独占一行，长名称和辅助字号不被截断。
struct SettingsPicker<Value: Hashable, Options: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let selectedValue: String
    let options: Options

    init(_ title: LocalizedStringKey, selection: Binding<Value>, value: String,
         @ViewBuilder content: () -> Options) {
        self.title = title
        _selection = selection
        selectedValue = value
        options = content()
    }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) { options }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                Text(LocalizedStringKey(selectedValue)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// 输入后仍显示字段名称，所有输入框共用左边界。
struct SettingsField<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
