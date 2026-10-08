import BrowserKit
import SwiftUI

struct TabSwitcher: View {
    @EnvironmentObject private var browser: BrowserSession
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var error: String?
    @State private var releaseMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Menu {
                        Button("所有标签") { browser.selectGroup(nil) }
                        ForEach(browser.groups) { group in
                            Button(group.name) { browser.selectGroup(group.id) }
                        }
                        Divider()
                        Button("新建标签组", systemImage: "folder.badge.plus") { editingID = nil; name = ""; naming = true }
                        if let id = browser.selectedGroupID {
                            Button("重命名标签组") { editingID = id; name = browser.selectedGroupName; naming = true }
                            Button("取消分组（保留标签）") { browser.removeGroup(id) }
                        }
                    } label: {
                        HStack {
                            Label(browser.selectedGroupName, systemImage: "folder")
                            Spacer()
                            Image(systemName: "chevron.down")
                        }.frame(maxWidth: .infinity).contentShape(Rectangle())
                    }.buttonStyle(.borderless).accessibilityIdentifier("tab-group-selector")
                    if browser.profile.isPrivate {
                        Text("私密标签组仅保留在当前窗口内存中，关闭窗口或退出 App 后不会恢复。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !browser.profile.isPrivate {
                        Button("释放闲置页面内存", systemImage: "leaf") {
                            Task { @MainActor in
                                let count = await browser.releaseInactiveTabs()
                                releaseMessage = String(localized: "已休眠 \(count) 个标签，切换时会重新加载。")
                            }
                        }.accessibilityIdentifier("release-idle-tabs")
                        Text("已编辑表单、媒体播放、含框架或有浏览历史的页面会保留。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let releaseMessage { Text(releaseMessage).accessibilityIdentifier("tab-release-result") }
                }
                Section("标签页") {
                    ForEach(browser.displayedTabs) { tab in
                        HStack {
                            TabRow(tab: tab, isActive: tab.id == browser.activeTabID) {
                                browser.activate(tab.id); dismiss()
                            }
                            Menu {
                                Button("移出标签组") { browser.moveTab(tab.id, to: nil) }
                                ForEach(browser.groups) { group in
                                    Button(group.name) { browser.moveTab(tab.id, to: group.id) }
                                }
                            } label: { Image(systemName: "folder").frame(width: 44, height: 44) }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("移动标签")
                                .accessibilityIdentifier("move-tab-" + tab.id.uuidString)
                        }
                        .swipeActions {
                            Button(role: .destructive) { browser.close(tab.id) } label: { Label("关闭", systemImage: "xmark") }
                        }
                    }
                    Button("新建标签页", systemImage: "plus") { _ = browser.newTab(); dismiss() }
                        .accessibilityIdentifier("new-group-tab")
                }
                if let error { Text(error).foregroundStyle(.red) }
                if let error = browser.sessionError { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("标签与分组")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.keyboardShortcut(.escape, modifiers: []) } }
            .alert(editingID == nil ? "新建标签组" : "重命名标签组", isPresented: $naming) {
                TextField("名称", text: $name)
                Button("保存") {
                    do {
                        if let editingID { try browser.renameGroup(editingID, to: name) }
                        else { _ = try browser.createGroup(name: name) }
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
}
