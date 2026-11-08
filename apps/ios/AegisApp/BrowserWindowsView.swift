import BrowserKit
import SwiftUI

struct BrowserWindowActions: View {
    @EnvironmentObject private var browser: BrowserSession
    @EnvironmentObject private var windows: BrowserWindowStore
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow
    @Binding var managesWindows: Bool
    @Binding var error: String?
    var body: some View {
        if supportsMultipleWindows {
            Button("新建窗口", systemImage: "rectangle.badge.plus") {
                do { let id = try windows.createWindow(); openWindow(id: "browser", value: id) }
                catch { self.error = error.localizedDescription }
            }.accessibilityIdentifier("new-browser-window")
            Button("窗口管理", systemImage: "rectangle.on.rectangle") { managesWindows = true }
                .accessibilityIdentifier("manage-browser-windows")
        }
    }
}

struct BrowserWindowsView: View {
    @EnvironmentObject private var browser: BrowserSession
    @EnvironmentObject private var windows: BrowserWindowStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var name = ""
    @State private var deletingID: UUID?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("每个窗口独立保存普通标签和分组。关闭窗口后可从这里重新打开；私密页面不会保留。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("重命名当前窗口") { name = windows.snapshot(browser.windowID)?.name ?? ""; naming = true }
                    Button("关闭当前窗口") {
                        browser.persistSession()
                        browser.discardPrivateSession()
                        windows.unregister(browser.windowID)
                        dismiss(); dismissWindow(id: "browser", value: browser.windowID)
                    }.accessibilityIdentifier("close-browser-window")
                }
                Section("已保存的窗口") {
                    ForEach(Array(windows.windows.enumerated()), id: \.element.id) { index, value in
                        Button {
                            dismiss()
                            openWindow(id: "browser", value: value.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(value.name.isEmpty ? String(localized: "窗口 \(index + 1)") : value.name)
                                Text("\(value.tabs.count) 个普通标签 · \(value.groups.count) 个分组")
                                    .font(.caption).foregroundStyle(.secondary)
                                if value.id == browser.windowID { Text("当前窗口").font(.caption) }
                            }
                        }.accessibilityIdentifier("saved-window-" + value.id.uuidString)
                            .swipeActions {
                                if !windows.openIDs.contains(value.id) {
                                    Button("删除记录", role: .destructive) { deletingID = value.id }
                                }
                            }
                    }
                }
                if let error = error ?? windows.storageError { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("窗口管理")
            .toolbar { Button("完成") { dismiss() } }
            .alert("重命名当前窗口", isPresented: $naming) {
                TextField("名称", text: $name)
                Button("保存") {
                    do { try windows.rename(browser.windowID, to: name); error = nil }
                    catch { self.error = error.localizedDescription }
                }
                Button("取消", role: .cancel) {}
            }
            .alert("删除已保存窗口？", isPresented: Binding(get: { deletingID != nil }, set: { if !$0 { deletingID = nil } })) {
                Button("删除", role: .destructive) {
                    guard let deletingID else { return }
                    do { try windows.removeSavedWindow(deletingID); error = nil }
                    catch { self.error = error.localizedDescription }
                    self.deletingID = nil
                }
                Button("取消", role: .cancel) { deletingID = nil }
            } message: { Text("该窗口保存的普通标签和分组将被删除，收藏与下载不受影响。") }
        }
    }
}
