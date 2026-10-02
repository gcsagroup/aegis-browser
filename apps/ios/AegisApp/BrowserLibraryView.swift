import BrowserKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowserLibraryView: View {
    @EnvironmentObject private var browser: BrowserSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var dataStore: BrowserDataStore
    @ObservedObject var workspaces: WorkspaceStore
    @State private var section = 0
    @State private var name = ""
    @State private var savePrompt = false
    @State private var pendingRestore: SavedWorkspace?
    @State private var showRestore = false
    @State private var restoredTabIDs: [UUID] = []
    @State private var message: String?
    @State private var editingWorkspace: SavedWorkspace?
    @State private var renamePrompt = false
    @State private var importing = false
    @State private var importPreview: [SavedWorkspace] = []
    @State private var confirmImport = false
    @State private var exporting = false
    @State private var exportDocument = WorkspaceDocument(data: Data())

    var body: some View {
        NavigationStack {
            List {
                Picker("浏览资料", selection: $section) {
                    Text("收藏").tag(0); Text("历史").tag(1); Text("工作区").tag(2)
                }.pickerStyle(.segmented)
                if section == 0 {
                    NavigationLink("检查收藏链接") { BookmarkLinkCheckerView(bookmarks: dataStore.bookmarks) }
                    if dataStore.bookmarks.isEmpty { ContentUnavailableView("暂无收藏", systemImage: "star") }
                    ForEach(dataStore.bookmarks) { item in
                        Button { open(item.url) } label: { pageRow(item.title, url: item.url) }
                            .swipeActions {
                                Button("移除收藏", role: .destructive) {
                                    guard let url = URL(string: item.url), !browser.profile.isPrivate else { return }
                                    _ = dataStore.toggleBookmark(title: item.title, url: url, isPrivate: false)
                                }
                            }
                    }
                } else if section == 1 {
                    if dataStore.history.isEmpty { ContentUnavailableView("暂无历史", systemImage: "clock") }
                    ForEach(dataStore.history) { item in
                        Button { open(item.url) } label: { pageRow(item.title, url: item.url) }
                    }
                } else {
                    Button("保存当前标签为工作区") { savePrompt = true }.accessibilityIdentifier("save-workspace")
                    HStack {
                        Button("导入工作区") { importing = true }.accessibilityIdentifier("import-workspaces")
                        Button("导出工作区") {
                            do { exportDocument = WorkspaceDocument(data: try workspaces.exportData()); exporting = true }
                            catch { message = error.localizedDescription }
                        }.disabled(workspaces.workspaces.isEmpty).accessibilityIdentifier("export-workspaces")
                    }
                    Text("保存普通标签的网址，并移除检测到的敏感参数。恢复时会追加标签，不会关闭现有页面。")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(workspaces.workspaces) { workspace in
                        Button {
                            pendingRestore = workspace; showRestore = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(workspace.name)
                                Text("\(workspace.urls.count) 个页面").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                do { try workspaces.remove(workspace.id) } catch { message = error.localizedDescription }
                            }
                            Button("重命名") { editingWorkspace = workspace; name = workspace.name; renamePrompt = true }
                        }
                    }
                    if !restoredTabIDs.isEmpty {
                        Button("撤销本次恢复") {
                            for id in restoredTabIDs { browser.close(id) }
                            restoredTabIDs = []; message = String(localized: "本次恢复的标签已关闭。")
                        }
                    }
                }
                if let message { Text(message).font(.callout).accessibilityIdentifier("library-message") }
            }
            .navigationTitle("浏览资料")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 2_000_000 else { throw WorkspaceError.invalidImport }
                    importPreview = try WorkspaceStore.previewImport(Data(contentsOf: url)); confirmImport = true
                } catch { message = error.localizedDescription }
            }
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "Aegis 工作区") { result in
                switch result {
                case .success: message = String(localized: "工作区文件已保存。")
                case let .failure(error): message = error.localizedDescription
                }
            }
            .alert("重命名工作区", isPresented: $renamePrompt) {
                TextField("工作区名称", text: $name)
                Button("保存") {
                    if let editingWorkspace {
                        do { try workspaces.rename(editingWorkspace.id, to: name) } catch { message = error.localizedDescription }
                    }
                }
                Button("取消", role: .cancel) { }
            }
            .confirmationDialog("导入这些工作区？", isPresented: $confirmImport, titleVisibility: .visible) {
                Button("确认导入") {
                    do { try workspaces.importWorkspaces(importPreview); message = String(localized: "工作区已导入。") }
                    catch { message = error.localizedDescription }
                    importPreview = []
                }
            } message: { Text(importPreview.map { "\($0.name)（\($0.urls.count)）" }.joined(separator: "、")) }
            .alert("保存工作区", isPresented: $savePrompt) {
                TextField("工作区名称", text: $name)
                Button("保存") {
                    do {
                        let value = try browser.saveWorkspace(name: name)
                        message = String(localized: "已保存 \(value.urls.count) 个页面。"); name = ""
                    } catch { message = error.localizedDescription }
                }
                Button("取消", role: .cancel) { }
            }
            .confirmationDialog("恢复工作区？", isPresented: $showRestore, titleVisibility: .visible) {
                Button("追加打开这些页面") {
                    if let pendingRestore {
                        restoredTabIDs = browser.restoreWorkspace(pendingRestore)
                        message = String(localized: "已打开 \(restoredTabIDs.count) 个页面。")
                    }
                }
            } message: {
                Text(pendingRestore?.urls.map { $0.host ?? "" }.joined(separator: "、") ?? "")
            }
        }
    }
    private func open(_ address: String) { browser.navigate(address: address); dismiss() }
    private func pageRow(_ title: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.primary)
            Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.padding(.vertical, 4)
    }
}

private struct WorkspaceDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
