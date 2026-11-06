import AgentKit
import SwiftUI

struct AssistantHistoryView: View {
    @EnvironmentObject private var tasks: AssistantTaskStore
    @Environment(\.dismiss) private var dismiss
    let resume: (AssistantTaskRecord) -> Void
    @State private var error: AegisLocalizedMessage?
    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        NavigationStack {
            List {
                Text("记录会保留目标和来源。继续任务时需重新读取网页、确认发送。只有主动保存的研究结果才会保留。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error.text).foregroundStyle(.red) }
                if tasks.records.isEmpty { ContentUnavailableView("暂无任务记录", systemImage: "clock") }
                ForEach(tasks.records) { record in
                    DisclosureGroup {
                        Text(stateTitle(record.state)).font(.caption)
                        ForEach(record.sources, id: \.self) { Text($0.absoluteString).font(.caption) }
                        Button("继续此任务") { resume(record) }.accessibilityIdentifier("resume-assistant-task")
                        if let report = record.savedReport {
                            Text(report).textSelection(.enabled).accessibilityIdentifier("saved-assistant-report")
                            ShareLink(item: report) { Label("分享研究结果", systemImage: "square.and.arrow.up") }
                        }
                        Button("删除记录", role: .destructive) {
                            do { try tasks.remove(record.id) } catch { self.error = .error(error) }
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(record.goal).lineLimit(3)
                            Text(record.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .localizedNavigationTitle("任务记录")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
    private func stateTitle(_ state: AssistantTaskRecord.State) -> String {
        switch state {
        case .running: AegisLocalization.string("正在分析")
        case .completed: AegisLocalization.string("已完成")
        case .interrupted: AegisLocalization.string("已暂停，可重新运行")
        case .failed: AegisLocalization.string("分析失败")
        }
    }
}
