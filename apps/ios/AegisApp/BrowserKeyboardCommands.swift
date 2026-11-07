import SwiftUI

/// 按当前窗口分派快捷键，避免只在菜单展开后才能使用。
struct BrowserKeyboardActions {
    let newTab: () -> Void
    let closeTab: () -> Void
    let editAddress: () -> Void
    let find: () -> Void
    let reload: () -> Void
    let back: () -> Void
    let forward: () -> Void
}

private struct BrowserKeyboardActionsKey: FocusedValueKey {
    typealias Value = BrowserKeyboardActions
}

extension FocusedValues {
    var browserKeyboardActions: BrowserKeyboardActions? {
        get { self[BrowserKeyboardActionsKey.self] }
        set { self[BrowserKeyboardActionsKey.self] = newValue }
    }
}

struct BrowserKeyboardCommands: Commands {
    @ObservedObject var language: AppLanguageSettings
    @FocusedValue(\.browserKeyboardActions) private var actions
    var body: some Commands {
        let _ = language.revision
        CommandGroup(replacing: .newItem) {
            Button(AegisLocalization.string("新建")) { actions?.newTab() }.keyboardShortcut("t").disabled(actions == nil)
            Button(AegisLocalization.string("关闭当前标签")) { actions?.closeTab() }.keyboardShortcut("w").disabled(actions == nil)
        }
        CommandGroup(after: .textEditing) {
            Button(AegisLocalization.string("在页面中查找")) {
                actions?.find()
            }.keyboardShortcut("f").disabled(actions == nil)
            Button(AegisLocalization.string("编辑网址")) { actions?.editAddress() }.keyboardShortcut("l").disabled(actions == nil)
            Button(AegisLocalization.string("刷新")) { actions?.reload() }.keyboardShortcut("r").disabled(actions == nil)
            Button(AegisLocalization.string("后退")) { actions?.back() }.keyboardShortcut("[").disabled(actions == nil)
            Button(AegisLocalization.string("前进")) { actions?.forward() }.keyboardShortcut("]").disabled(actions == nil)
        }
    }
}
