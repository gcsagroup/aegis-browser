import BrowserKit
import SwiftUI

struct RecordRecoveryView: View {
    let fileURL: URL?
    let availableBackups: () -> [RecordBackup]
    let reload: () async throws -> Void
    let restore: (RecordBackup) async throws -> Void
    let reset: () async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var backups: [RecordBackup] = []
    @State private var selected: RecordBackup?
    @State private var confirmRestore = false
    @State private var confirmReset = false
    @State private var exportFile: ExportedFile?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Text("恢复或重置前会保留当前原始记录。备份不会自动删除；下载文件不会因重置记录而删除。")
                    .font(.callout)
                Button("导出原始记录") {
                    guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
                        message = RecordRecoveryError.noFile.localizedDescription; return
                    }
                    exportFile = ExportedFile(url: fileURL)
                }.accessibilityIdentifier("export-original-records")
                Button("重新读取记录") {
                    perform { try await reload() }
                }.accessibilityIdentifier("reload-records")
            }
            Section("可恢复的备份") {
                if backups.isEmpty { Text("暂无备份") }
                ForEach(backups) { backup in
                    Button {
                        selected = backup; confirmRestore = true
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(backup.isLastGood ? "上一个有效版本" : "操作前保留的原件")
                            Text(backup.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("restore-record-backup-\(backup.id)")
                }
            }
            Section {
                Button("备份后重置记录", role: .destructive) { confirmReset = true }
                    .accessibilityIdentifier("reset-records")
            }
            if busy { ProgressView("正在处理记录").accessibilityIdentifier("record-recovery-progress") }
            if let message { Text(message).accessibilityIdentifier("record-recovery-result") }
        }
        .navigationTitle("记录恢复")
        .disabled(busy)
        .task { backups = availableBackups() }
        .confirmationDialog("恢复选中的备份？", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("备份当前记录并恢复") {
                guard let selected else { return }
                perform { try await restore(selected) }
            }
        } message: { Text("将替换当前记录。当前原件会另存一份，无效备份不会覆盖现有资料。") }
        .confirmationDialog("重置这些记录？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("确认备份并重置", role: .destructive) { perform { try await reset() } }
        } message: { Text("当前原件会先备份，然后建立空记录。此操作不会删除下载文件。") }
        .sheet(item: $exportFile) { file in
            FileExportPicker(url: file.url) { saved in
                exportFile = nil
                if saved { message = String(localized: "原始记录已导出。") }
            }
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        busy = true; message = nil
        Task { @MainActor in
            do { try await action(); message = String(localized: "记录已更新，可以继续使用。") }
            catch { message = error.localizedDescription }
            backups = availableBackups(); busy = false
        }
    }
}

struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct FileExportPicker: UIViewControllerRepresentable {
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
