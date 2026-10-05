import BrowserKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var browser: BrowserSession
    @Environment(\.dismiss) private var dismiss
    var initialURL: URL?
    @State private var address = ""
    @State private var expectedHash = ""
    @State private var mirrorAddresses = ""
    @State private var importingMetalink = false
    @State private var importedPlan: DownloadPlan?
    @State private var error: String?
    @State private var exportFile: ExportedFile?
    @State private var savedMessage: String?
    @State private var query = ""
    @State private var filter: DownloadFilter = .all
    @State private var sort: DownloadSort = .newest
    @State private var selection: Set<UUID> = []
    @State private var pendingRemoval: Set<UUID> = []
    @State private var confirmsRemoval = false
    @State private var confirmsEmpty = false
    @State private var previewURL: URL?
    @State private var recoveringFiles = false
    @State private var privateDownloadPlan: DownloadPlan?
    @State private var confirmsPrivateDownload = false
    private enum Field { case address, hash, mirrors }
    @FocusState private var editing: Field?

    private enum DownloadFilter: String, CaseIterable {
        case all, active, completed, interrupted
        var title: String {
            switch self {
            case .all: String(localized: "全部")
            case .active: String(localized: "进行中")
            case .completed: String(localized: "已完成")
            case .interrupted: String(localized: "暂停或失败")
            }
        }
        func includes(_ item: BrowserDownload) -> Bool {
            switch self {
            case .all: true
            case .active: [.queued, .running, .pausing].contains(item.state)
            case .completed: item.state == .completed
            case .interrupted: [.paused, .failed, .cancelled].contains(item.state)
            }
        }
    }
    private enum DownloadSort: String, CaseIterable {
        case newest, name, size
        var title: String {
            switch self {
            case .newest: String(localized: "最新优先")
            case .name: String(localized: "按名称")
            case .size: String(localized: "按文件大小")
            }
        }
    }
    private var visibleItems: [BrowserDownload] {
        downloads.items.filter { item in
            filter.includes(item) && (query.isEmpty || (item.filename + " " + item.currentURL.absoluteString).localizedStandardContains(query))
        }.sorted {
            switch sort {
            case .newest: ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            case .name: $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            case .size: max($0.received, $0.expected) > max($1.received, $1.expected)
            }
        }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                if let error = downloads.storageError {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("download-storage-error")
                }
                newDownloadSection
                if let plan = importedPlan { metalinkSection(plan) }
                if let error, error != downloads.storageError { Text(error).foregroundStyle(.red) }
                if let savedMessage { Text(savedMessage).accessibilityIdentifier("download-export-result") }
                storageSection
                Section("筛选与排序") {
                    Picker("下载状态", selection: $filter) {
                        ForEach(DownloadFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("download-filter")
                    Picker("排序", selection: $sort) {
                        ForEach(DownloadSort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("download-sort")
                }
                Section("下载记录") {
                    if downloads.items.isEmpty { ContentUnavailableView("暂无下载", systemImage: "arrow.down.circle") }
                    else if visibleItems.isEmpty { Text("没有匹配的下载") }
                    ForEach(visibleItems) { item in
                        downloadRow(item).tag(item.id)
                            .swipeActions {
                                Button("移除", role: .destructive) {
                                    pendingRemoval = [item.id]; confirmsRemoval = true
                                }.disabled([.running, .queued, .pausing].contains(item.state))
                            }
                    }
                }
            }
            .navigationTitle("下载")
            .searchable(text: $query, prompt: "搜索文件名或网址")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.keyboardShortcut(.escape, modifiers: []) }
                ToolbarItem(placement: .topBarLeading) { EditButton().accessibilityIdentifier("edit-downloads") }
                if !selection.isEmpty {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("全选筛选结果") { selection = Set(visibleItems.map(\.id)) }
                        Spacer()
                        Button("管理所选 \(selection.count) 项") { pendingRemoval = selection; confirmsRemoval = true }
                            .accessibilityIdentifier("manage-selected-downloads")
                    }
                }
            }
            .alert("保存私密浏览中的下载？", isPresented: $confirmsPrivateDownload) {
                Button("确认下载并保留记录") {
                    if let privateDownloadPlan { start(privateDownloadPlan) }
                    privateDownloadPlan = nil
                }
                Button("取消", role: .cancel) { privateDownloadPlan = nil }
            } message: {
                Text(String(localized: "文件、下载链接和下载记录会保留在设备上，退出私密浏览后不会自动删除。")
                     + "\n\n" + (privateDownloadPlan?.urls.map(\.absoluteString).joined(separator: "\n") ?? ""))
            }
            .confirmationDialog("如何移除下载？", isPresented: $confirmsRemoval, titleVisibility: .visible) {
                Button("仅移除记录，保留文件") { remove(includingFiles: false) }
                Button("记录和文件移入回收站", role: .destructive) { remove(includingFiles: true) }
            } message: { Text("记录会先备份。保留的文件可重新识别，回收站文件在清空前可以恢复。正在下载的项目需要先暂停。") }
            .confirmationDialog("永久清空回收站？", isPresented: $confirmsEmpty, titleVisibility: .visible) {
                Button("永久删除回收站文件", role: .destructive) {
                    do { try downloads.emptyRecycleBin(); savedMessage = String(localized: "回收站已清空。") }
                    catch { self.error = error.localizedDescription }
                }
            } message: { Text("只删除回收站中的文件，不能撤销。当前下载列表和其他备份不受影响。") }
        }
        .fileImporter(isPresented: $importingMetalink, allowedContentTypes: [.data, .xml], allowsMultipleSelection: false) { result in
            do {
                let url = try result.get()[0]
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_048_576 else { throw DownloadPlanError.invalidMetalink }
                importedPlan = try DownloadPlan.metalink(Data(contentsOf: url)); error = nil
            } catch { self.error = error.localizedDescription }
        }
        .onAppear { address = initialURL?.absoluteString ?? ""; downloads.refreshStorageUsage() }
        .quickLookPreview($previewURL)
        .sheet(item: $exportFile) { file in
            FileExportPicker(url: file.url) { saved in
                exportFile = nil
                if saved { savedMessage = String(localized: "文件已保存。") }
            }
        }
    }

    private var newDownloadSection: some View {
        Section("新建下载") {
            TextField("文件链接", text: $address).keyboardType(.URL)
                .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("download-url")
                .focused($editing, equals: .address)
            TextField("预期 SHA-256（可选）", text: $expectedHash)
                .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("download-hash")
                .focused($editing, equals: .hash)
            DisclosureGroup("备用镜像（每行一个）") {
                TextField("备用文件链接", text: $mirrorAddresses, axis: .vertical)
                    .lineLimit(2...6).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("download-mirrors").focused($editing, equals: .mirrors)
                Text("镜像失败后从下一个地址重新下载；不会合并不同镜像的文件片段。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("导入 Metalink 文件") { importingMetalink = true }.accessibilityIdentifier("import-metalink")
            Button {
                editing = nil
                do {
                    let inputs = [address] + mirrorAddresses.split(whereSeparator: \.isNewline).map(String.init)
                    let urls = try inputs.map { try DownloadManager.validatedURL($0) }
                    requestDownload(DownloadPlan(urls: urls, sha256: expectedHash))
                } catch { self.error = error.localizedDescription }
            } label: { Text("开始下载").frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent).disabled(address.isEmpty).accessibilityIdentifier("start-download")
            Text("仅下载你指定的文件，不会执行或安装。登录后才能访问的文件可能需要网站提供直接下载链接。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func metalinkSection(_ plan: DownloadPlan) -> some View {
        Section("确认 Metalink 下载") {
            Text(plan.filename ?? "")
            if let size = plan.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
            ForEach(Array(plan.urls.enumerated()), id: \.offset) { _, url in Text(url.absoluteString).font(.caption) }
            Text(plan.sha256 != nil ? "包含 SHA-256 校验值" : "包含 SHA-512 校验值").font(.caption)
            Button("确认并开始下载") {
                requestDownload(plan)
            }.accessibilityIdentifier("confirm-metalink")
            Button("取消", role: .cancel) { importedPlan = nil }
        }
    }

    private func requestDownload(_ plan: DownloadPlan) {
        error = nil
        if browser.profile.isPrivate {
            privateDownloadPlan = plan
            confirmsPrivateDownload = true
        } else { start(plan) }
    }

    private func start(_ plan: DownloadPlan) {
        do { _ = try downloads.start(plan); importedPlan = nil; error = nil }
        catch { self.error = error.localizedDescription }
    }

    private var storageSection: some View {
        Section {
            DisclosureGroup("下载设置与存储") {
                Picker("同时下载数量", selection: Binding(get: { downloads.maximumConcurrentDownloads }, set: { downloads.setConcurrencyLimit($0) })) {
                    ForEach(1...4, id: \.self) { Text("\($0) 个任务").tag($0) }
                }.accessibilityIdentifier("download-concurrency")
                Text("下载与备份占用：\(ByteCountFormatter.string(fromByteCount: downloads.storedBytes, countStyle: .file))")
                Text("回收站占用：\(ByteCountFormatter.string(fromByteCount: downloads.recycleBinBytes, countStyle: .file))")
                if let available = downloads.availableBytes { Text("设备可用空间：\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))") }
                NavigationLink("备份与恢复") {
                    RecordRecoveryView(fileURL: downloads.recordFileURL, availableBackups: { downloads.backups },
                        reload: { try await downloads.reloadRecords() },
                        restore: { try await downloads.restoreBackup($0) },
                        reset: { try await downloads.resetRecords() })
                }.accessibilityIdentifier("download-recovery")
                Button("找回已完成文件") { recoverFiles(fromRecycleBin: false) }
                    .disabled(downloads.hasActiveDownloads || recoveringFiles).accessibilityIdentifier("recover-download-files")
                Button("恢复回收站文件") { recoverFiles(fromRecycleBin: true) }
                    .disabled(downloads.hasActiveDownloads || recoveringFiles || downloads.recycleBinBytes == 0)
                Button("清空回收站", role: .destructive) { confirmsEmpty = true }
                    .disabled(recoveringFiles || downloads.recycleBinBytes == 0)
                if recoveringFiles { ProgressView("正在校验文件").accessibilityIdentifier("download-recovery-progress") }
                Text("后台下载由系统调度。强制退出 App 会中止后台传输；重新打开后请确认状态并继续。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func downloadRow(_ item: BrowserDownload) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.filename).font(.headline).lineLimit(2)
            Text(item.currentURL.host ?? "").font(.caption).foregroundStyle(.secondary)
            Text(stateTitle(item.state)).accessibilityIdentifier("download-state-\(item.id)")
            if let message = item.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if (item.mirrors?.count ?? 1) > 1 { Text("镜像 \((item.mirrorIndex ?? 0) + 1) / \(item.mirrors?.count ?? 1)").font(.caption) }
            if [.running, .queued].contains(item.state) {
                if item.state == .running {
                    if let progress = item.progress {
                        ProgressView(value: progress).accessibilityLabel("下载进度")
                            .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
                    } else { ProgressView("正在下载") }
                }
                Text(ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file)).font(.caption)
                HStack {
                    Button("暂停") { downloads.pause(item.id) }
                    Button("取消下载", role: .destructive) { downloads.cancel(item.id) }
                }
            } else if item.state == .pausing { ProgressView("正在暂停") }
            else if item.state == .completed {
                if let hash = item.sha256 {
                    Text("SHA-256：\(hash)").font(.caption.monospaced()).textSelection(.enabled)
                    Text(item.expectedSHA256 == nil ? "已计算文件摘要，未提供可信预期值。" : "与预期 SHA-256 一致。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if item.expectedSHA512 != nil { Text("与预期 SHA-512 一致。").font(.caption) }
                VStack(alignment: .leading, spacing: 8) { fileActions(item) }
                    .labelStyle(.titleAndIcon)
            } else {
                Button(item.state == .paused ? "继续下载" : "重新下载") {
                    do { try downloads.resume(item.id) } catch { self.error = error.localizedDescription }
                }
            }
        }.padding(.vertical, 8).buttonStyle(.bordered).accessibilityElement(children: .contain)
    }

    @ViewBuilder private func fileActions(_ item: BrowserDownload) -> some View {
        Button("预览文件", systemImage: "doc.text.magnifyingglass") { showFile(item, preview: true) }
            .accessibilityIdentifier("preview-download-file")
        Button("保存到文件", systemImage: "folder") { showFile(item, preview: false) }.accessibilityIdentifier("save-download-file")
        ShareLink(item: downloads.fileURL(item)) { Label("分享文件", systemImage: "square.and.arrow.up") }
    }
    private func showFile(_ item: BrowserDownload, preview: Bool) {
        let url = downloads.fileURL(item)
        guard FileManager.default.fileExists(atPath: url.path) else { error = DownloadError.missingFile.localizedDescription; return }
        if preview { previewURL = url } else { exportFile = ExportedFile(url: url) }
    }
    private func remove(includingFiles: Bool) {
        do {
            try downloads.removeDownloads(pendingRemoval, includingFiles: includingFiles)
            selection.subtract(pendingRemoval); savedMessage = String(localized: "下载记录已备份并移除。"); error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func recoverFiles(fromRecycleBin: Bool) {
        recoveringFiles = true; error = nil
        Task { @MainActor in
            do {
                let count: Int
                if fromRecycleBin { count = try await downloads.restoreRecycledFiles() }
                else { count = try await downloads.recoverCompletedFiles() }
                savedMessage = String(localized: "已恢复 \(count) 个文件的记录。")
            } catch { self.error = error.localizedDescription }
            recoveringFiles = false
        }
    }
    private func stateTitle(_ state: BrowserDownload.State) -> String {
        switch state {
        case .queued: String(localized: "等待下载")
        case .running: String(localized: "正在下载")
        case .pausing: String(localized: "正在暂停")
        case .paused: String(localized: "已暂停")
        case .completed: String(localized: "已完成")
        case .failed: String(localized: "下载失败")
        case .cancelled: String(localized: "已取消")
        }
    }
}
