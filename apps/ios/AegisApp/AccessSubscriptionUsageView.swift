import SwiftUI

struct AccessSubscriptionUsageView: View {
    @ObservedObject var session: AccessSubscriptionUsageSession
    let usesAlphaNodeSelection: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @State private var visibilityID = UUID()

    var body: some View {
        let _ = locale
        if session.managesConnections {
            Section {
                LabeledContent("服务账户") { Text("共享测试账号") }
                LabeledContent("可用连接") {
                    if session.isRefreshing { ProgressView() }
                    else if session.unavailable || session.connectionsUnavailable || session.snapshot == nil { Text("暂不可用") }
                    else { Text(session.availableConnectionCount, format: .number) }
                }
                .accessibilityIdentifier("access-account-connections")
                if !usesAlphaNodeSelection {
                    Text("连接由账号自动获取，无需手动配置。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    if let usage = session.snapshot {
                        if !usage.enabled { Text("服务已停用") }
                        if usage.remainingBytes == 0 { Text("服务端报告：额度已耗尽") }
                        AccessUsageSummaryView(usedBytes: String(usage.usedBytes), quotaBytes: String(usage.totalByte))
                        amount("总额度", usage.totalByte, id: "quota")
                        amount("剩余", usage.remainingBytes, id: "remaining")
                        Divider()
                        AccessTransferBreakdown(uploaded: String(usage.uploadByte), downloaded: String(usage.downloadByte))
                        LabeledContent("到期时间") {
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
            Text("测试服务用量（共享）")
        } footer: {
            Text("共享测试用量，不代表个人套餐；重置以服务端为准。")
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
            Text(verbatim: AccessAccountUsagePresentation.formattedBytes(String(bytes)))
        } label: {
            Text(verbatim: AegisLocalization.string(label))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: AegisLocalization.string(label)))
        .accessibilityValue(AccessAccountUsagePresentation.accessibleBytes(String(bytes), locale: locale))
        .accessibilityIdentifier("access-usage-" + id)
    }
}
