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
    @State private var query = ""
    @State private var sort: LibrarySort = .newest
    @State private var bookmarkToRemove: BrowserBookmark?
    @State private var confirmsPrivateBookmarkRemoval = false

    private enum LibrarySort: String, CaseIterable {
        case newest, title, site
        var title: String {
            switch self {
            case .newest: String(localized: "最新优先")
            case .title: String(localized: "按名称")
            case .site: String(localized: "按网站")
            }
        }
    }

    private func matches(_ text: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.localizedStandardContains(query)
    }

    private func precedes(_ a: (String, String, Date), _ b: (String, String, Date)) -> Bool {
        switch sort {
        case .newest: a.2 > b.2
        case .title: a.0.localizedStandardCompare(b.0) == .orderedAscending
        case .site: (URL(string: a.1)?.host ?? a.1).localizedStandardCompare(URL(string: b.1)?.host ?? b.1) == .orderedAscending
        }
    }

    private var bookmarks: [BrowserBookmark] {
        dataStore.bookmarks.filter { matches($0.title + " " + $0.url) }.sorted {
            precedes(($0.title, $0.url, $0.createdAt), ($1.title, $1.url, $1.createdAt))
        }
    }
    private var history: [BrowserHistoryEntry] {
        dataStore.history.filter { matches($0.title + " " + $0.url) }.sorted {
            precedes(($0.title, $0.url, $0.visitedAt), ($1.title, $1.url, $1.visitedAt))
        }
    }
    private var savedWorkspaces: [SavedWorkspace] {
        workspaces.workspaces.filter { matches($0.name + " " + $0.urls.map(\.absoluteString).joined(separator: " ")) }.sorted {
            precedes(($0.name, $0.urls.first?.absoluteString ?? "", $0.savedAt), ($1.name, $1.urls.first?.absoluteString ?? "", $1.savedAt))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("浏览资料", selection: $section) {
                    Text("收藏").tag(0); Text("历史").tag(1); Text("工作区").tag(2)
                }.pickerStyle(.segmented)
                if browser.profile.isPrivate {
                    Text("这里显示已保存的资料。私密浏览不会新增历史；主动修改收藏或保存工作区后，资料会继续保留。打开的页面仍使用私密标签。")
                        .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("private-library-notice")
                }
                if let error = workspaces.storageError {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("workspace-storage-error")
                }
                if section == 0 {
                    NavigationLink("检查收藏链接") { BookmarkLinkCheckerView(bookmarks: dataStore.bookmarks) }
                    if bookmarks.isEmpty { ContentUnavailableView(query.isEmpty ? "暂无收藏" : "没有匹配的资料", systemImage: "star") }
                    ForEach(bookmarks) { item in
                        Button { open(item.url) } label: { pageRow(item.title, url: item.url) }
                            .swipeActions {
                                Button("移除收藏", role: .destructive) {
                                    if browser.profile.isPrivate {
                                        bookmarkToRemove = item; confirmsPrivateBookmarkRemoval = true
                                    } else { removeBookmark(item) }
                                }
                            }
                    }
                } else if section == 1 {
                    if history.isEmpty { ContentUnavailableView(query.isEmpty ? "暂无历史" : "没有匹配的资料", systemImage: "clock") }
                    ForEach(history) { item in
                        Button { open(item.url) } label: { pageRow(item.title, url: item.url) }
                    }
                } else {
                    if workspaces.recordFileURL != nil {
                        NavigationLink("备份与恢复") {
                            RecordRecoveryView(fileURL: workspaces.recordFileURL,
                                availableBackups: { workspaces.backups },
                                reload: { try workspaces.reloadRecords() },
                                restore: { try workspaces.restoreBackup($0) },
                                reset: { try workspaces.resetRecords() })
                        }.accessibilityIdentifier("workspace-recovery")
                    }
                    Button("保存当前标签为工作区") { savePrompt = true }.accessibilityIdentifier("save-workspace")
                    HStack {
                        Button("导入工作区") { importing = true }.accessibilityIdentifier("import-workspaces")
                        Button("导出工作区") {
                            do { exportDocument = WorkspaceDocument(data: try workspaces.exportData()); exporting = true }
                            catch { message = error.localizedDescription }
                        }.disabled(workspaces.workspaces.isEmpty).accessibilityIdentifier("export-workspaces")
                    }
                    Text("保存当前浏览模式下标签的网址，并移除检测到的敏感参数。恢复时会追加标签，不会关闭现有页面。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !query.isEmpty, savedWorkspaces.isEmpty { Text("没有匹配的资料") }
                    ForEach(savedWorkspaces) { workspace in
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
                if let message, message != workspaces.storageError {
                    Text(message).font(.callout).accessibilityIdentifier("library-message")
                }
            }
            .navigationTitle("浏览资料")
            .searchable(text: $query, prompt: "搜索标题或网址")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.keyboardShortcut(.escape, modifiers: []) }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("排序", selection: $sort) {
                            ForEach(LibrarySort.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    } label: { Label("排序", systemImage: "arrow.up.arrow.down") }
                    .accessibilityIdentifier("library-sort")
                }
            }
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
            .alert("移除已保存的收藏？", isPresented: $confirmsPrivateBookmarkRemoval) {
                Button("确认移除", role: .destructive) {
                    if let bookmarkToRemove { removeBookmark(bookmarkToRemove) }
                    bookmarkToRemove = nil
                }
                Button("取消", role: .cancel) { bookmarkToRemove = nil }
            } message: { Text(bookmarkToRemove?.url ?? "") }
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
                        let value = try browser.saveWorkspace(name: name, privateSaveConfirmed: browser.profile.isPrivate)
                        message = String(localized: "已保存 \(value.urls.count) 个页面。"); name = ""
                    } catch { message = error.localizedDescription }
                }
                Button("取消", role: .cancel) { }
            } message: {
                if browser.profile.isPrivate {
                    Text("当前私密标签的网址会保存到工作区，退出私密浏览后仍然保留。浏览历史和会话不会自动保存。")
                }
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
    private func removeBookmark(_ item: BrowserBookmark) {
        guard dataStore.bookmarks.contains(where: { $0.id == item.id }), let url = URL(string: item.url) else { return }
        _ = dataStore.toggleBookmark(title: item.title, url: url, isPrivate: false)
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
