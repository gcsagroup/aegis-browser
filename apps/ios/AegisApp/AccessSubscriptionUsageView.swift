import SwiftUI

struct AccessSubscriptionUsageView: View {
    @ObservedObject var session: AccessSubscriptionUsageSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @State private var visibilityID = UUID()

    var body: some View {
        let _ = locale
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    if let usage = session.snapshot {
                        if !usage.enabled { Text("节点已停用") }
                        if usage.remainingBytes == 0 { Text("服务端报告：额度已耗尽") }
                        amount("总额度", usage.totalByte, id: "quota")
                        amount("上传", usage.uploadByte, id: "uploaded")
                        amount("下载", usage.downloadByte, id: "downloaded")
                        amount("已用", usage.usedBytes, id: "used")
                        amount("剩余", usage.remainingBytes, id: "remaining")
                        LabeledContent("节点到期") {
                            if usage.expire == 0 { Text("未设到期") }
                            else { timestamp(Date(timeIntervalSince1970: TimeInterval(usage.expire))) }
                        }
                        if let receivedAt = session.receivedAt {
                            LabeledContent("上次查询") { timestamp(receivedAt) }
                        }
                        Text("用量测量时间未知或数据已陈旧")
                            .font(.footnote).foregroundStyle(.secondary)
                        if session.isStale {
                            Text("这是上次查询结果，当前额度尚未确认")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else if session.isRefreshing { Text("正在查询额度…") }
                    else { Text("额度查询不可用，不代表余额为零") }
                }
            }
            Button {
                session.usageRefresh.refreshNow()
            } label: {
                HStack {
                    Text("刷新额度")
                    if session.isRefreshing { ProgressView() }
                }
            }
            .disabled(session.isRefreshing || scenePhase != .active)
            .accessibilityIdentifier("access-usage-refresh")
        } header: {
            Text("3X-UI 节点额度")
        } footer: {
            Text("直接查询 3X-UI 测试节点；每日重置按服务器时区执行，查询失败不代表额度耗尽。")
        }
        .onAppear { session.usageRefresh.setVisible(scenePhase == .active, owner: visibilityID) }
        .onChange(of: scenePhase) { _, phase in session.usageRefresh.setVisible(phase == .active, owner: visibilityID) }
        .onDisappear { session.usageRefresh.setVisible(false, owner: visibilityID) }
    }

    private func timestamp(_ date: Date) -> some View {
        Text(date, format: Date.FormatStyle(date: .abbreviated, time: .standard).locale(locale))
    }

    private func amount(_ label: LocalizedStringResource, _ bytes: UInt64, id: String) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(AccessAccountUsagePresentation.formattedBytes(String(bytes)))
                Text(String(bytes) + " B").font(.caption.monospaced())
            }
        } label: { Text(verbatim: AegisLocalization.string(label)) }
        .accessibilityElement(children: .combine)
        .accessibilityValue(String(bytes))
        .accessibilityIdentifier("access-usage-" + id)
    }
}
