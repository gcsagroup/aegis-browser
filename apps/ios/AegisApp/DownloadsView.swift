import BrowserKit
import SwiftUI
import UniformTypeIdentifiers

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    var initialURL: URL?
    @State private var address = ""
    @State private var expectedHash = ""
    @State private var mirrorAddresses = ""
    @State private var importingMetalink = false
    @State private var importedPlan: DownloadPlan?
    @State private var error: String?
    @State private var exportFile: DownloadExportFile?
    @State private var savedMessage: String?
    private enum Field { case address, hash, mirrors }
    @FocusState private var editing: Field?

    var body: some View {
        NavigationStack {
            List {
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
                    Button("导入 Metalink 文件") { importingMetalink = true }
                        .accessibilityIdentifier("import-metalink")
                    Button {
                        editing = nil
                        do {
                            let inputs = [address] + mirrorAddresses.split(whereSeparator: \.isNewline).map(String.init)
                            let urls = try inputs.map { try DownloadManager.validatedURL($0) }
                            _ = try downloads.start(DownloadPlan(urls: urls, sha256: expectedHash)); error = nil
                        }
                        catch { self.error = error.localizedDescription }
                    } label: { Text("开始下载").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(address.isEmpty).accessibilityIdentifier("start-download")
                    Text("仅下载你指定的文件，不会执行或安装。登录后才能访问的文件可能需要网站提供直接下载链接。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let plan = importedPlan {
                    Section("确认 Metalink 下载") {
                        Text(plan.filename ?? "")
                        if let size = plan.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                        ForEach(Array(plan.urls.enumerated()), id: \.offset) { _, url in Text(url.absoluteString).font(.caption) }
                        Text(plan.sha256 != nil ? "包含 SHA-256 校验值" : "包含 SHA-512 校验值").font(.caption)
                        Button("确认并开始下载") {
                            do { _ = try downloads.start(plan); importedPlan = nil; error = nil }
                            catch { self.error = error.localizedDescription }
                        }.accessibilityIdentifier("confirm-metalink")
                        Button("取消", role: .cancel) { importedPlan = nil }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                if let savedMessage { Text(savedMessage).accessibilityIdentifier("download-export-result") }
                if let error = downloads.storageError { Text(error).foregroundStyle(.red) }
                Section("下载记录") {
                    if downloads.items.isEmpty { ContentUnavailableView("暂无下载", systemImage: "arrow.down.circle") }
                    ForEach(downloads.items) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(item.filename).font(.headline).lineLimit(2)
                            Text(item.currentURL.host ?? "").font(.caption).foregroundStyle(.secondary)
                            Text(LocalizedStringKey(stateTitle(item.state))).accessibilityIdentifier("download-state-\(item.id)")
                            if (item.mirrors?.count ?? 1) > 1 {
                                Text("镜像 \((item.mirrorIndex ?? 0) + 1) / \(item.mirrors?.count ?? 1)").font(.caption)
                            }
                            if item.state == .running {
                                if let progress = item.progress { ProgressView(value: progress) } else { ProgressView() }
                                Text(ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file)).font(.caption)
                                HStack {
                                    Button("暂停") { downloads.pause(item.id) }
                                    Button("取消下载", role: .destructive) { downloads.cancel(item.id) }
                                }
                            } else if item.state == .pausing {
                                ProgressView()
                            } else if item.state == .completed {
                                if let hash = item.sha256 {
                                    Text("SHA-256：\(hash)").font(.caption.monospaced()).textSelection(.enabled)
                                    Text(item.expectedSHA256 == nil ? "已计算文件摘要，未提供可信预期值。" : "与预期 SHA-256 一致。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if item.expectedSHA512 != nil { Text("与预期 SHA-512 一致。").font(.caption) }
                                HStack {
                                    Button("保存到文件", systemImage: "folder") {
                                        exportFile = DownloadExportFile(url: downloads.fileURL(item))
                                    }.accessibilityIdentifier("save-download-file")
                                    ShareLink(item: downloads.fileURL(item)) { Label("分享文件", systemImage: "square.and.arrow.up") }
                                }
                            } else {
                                if let message = item.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                                Button(item.state == .paused ? "继续下载" : "重新下载") {
                                    do { try downloads.resume(item.id) } catch { self.error = error.localizedDescription }
                                }
                            }
                        }.padding(.vertical, 8).buttonStyle(.bordered)
                    }
                }
            }
            .navigationTitle("下载")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
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
        .onAppear { address = initialURL?.absoluteString ?? "" }
        .sheet(item: $exportFile) { file in
            DownloadExportPicker(url: file.url) { saved in
                exportFile = nil
                if saved { savedMessage = String(localized: "文件已保存。") }
            }
        }
    }
    private func stateTitle(_ state: BrowserDownload.State) -> String {
        switch state {
        case .running: String(localized: "正在下载")
        case .pausing: String(localized: "正在暂停")
        case .paused: String(localized: "已暂停")
        case .completed: String(localized: "已完成")
        case .failed: String(localized: "下载失败")
        case .cancelled: String(localized: "已取消")
        }
    }
}

private struct DownloadExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct DownloadExportPicker: UIViewControllerRepresentable {
    let url: URL
    let completion: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Bool) -> Void
        init(completion: @escaping (Bool) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(!urls.isEmpty) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(false) }
    }
}
