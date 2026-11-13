import SwiftUI

/// Account-service observations, never client-side billing or proof that the
/// independently configured proxy node belongs to this account.
struct AccessAccountUsageView: View {
    @ObservedObject var session: AccessAccountSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @State private var visibilityID = UUID()

    var body: some View {
        let _ = locale
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    if let snapshot = session.lastSnapshot {
                        Text(verbatim: AegisLocalization.string(statusText(snapshot.status)))
                            .accessibilityIdentifier("access-usage-status")
                        if snapshot.status != .notSubscribed {
                            amount("总额度", snapshot.quotaBytes, id: "quota")
                            amount("已用", snapshot.usedBytes, id: "used")
                            amount("剩余", snapshot.remainingBytes, id: "remaining")
                            amount("上传", snapshot.uploadedBytes, id: "uploaded")
                            amount("下载", snapshot.downloadedBytes, id: "downloaded")
                            if snapshot.quotaSource == .threeXUIAlpha {
                                Text("来源：3X-UI Alpha 测试节点")
                                    .font(.footnote).foregroundStyle(.secondary)
                                if case .some(.none) = snapshot.panelExpiryMode {
                                    LabeledContent("节点到期") { Text("未设到期") }
                                } else if let panelExpires = snapshot.panelExpiresAt {
                                    LabeledContent("节点到期") {
                                        timestamp(panelExpires)
                                    }
                                }
                            }
                            if let expires = snapshot.expiresAt {
                                LabeledContent {
                                    timestamp(expires)
                                } label: {
                                    Text(verbatim: AegisLocalization.string(expiryLabel(snapshot)))
                                }
                            }
                            Text(verbatim: AegisLocalization.string(freshnessText(snapshot)))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("access-usage-freshness")
                            if let measured = snapshot.measuredAt {
                                LabeledContent("服务端测量时间") {
                                    timestamp(measured)
                                }.font(.footnote)
                            }
                        }
                    } else {
                        switch session.state {
                        case .signedOut: Text("尚未绑定额度查询账户")
                        case .loading: Text("正在查询额度…")
                        case .unavailable: Text("额度查询不可用，不代表余额为零")
                        case .ready: Text("暂无额度数据")
                        }
                    }
                    if session.snapshotIsStale {
                        Text("这是上次查询结果，当前额度尚未确认")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
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
            Text("Access 账户额度")
        } footer: {
            Text("显示额度查询账户的数据；测试节点与该账户的对应关系须由服务端确认。查询失败不会被当作耗尽，额度展示不代替服务端计量和停流。")
        }
        .onAppear { session.usageRefresh.setVisible(scenePhase == .active, owner: visibilityID) }
        .onChange(of: scenePhase) { _, phase in
            session.usageRefresh.setVisible(phase == .active, owner: visibilityID)
        }
        .onDisappear { session.usageRefresh.setVisible(false, owner: visibilityID) }
    }

    private func amount(_ label: LocalizedStringResource, _ raw: String?, id: String) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(AccessAccountUsagePresentation.formattedBytes(raw))
                if let raw { Text(raw + " B").font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
        } label: {
            Text(verbatim: AegisLocalization.string(label))
        }
        .accessibilityIdentifier("access-usage-" + id)
    }

    private func timestamp(_ milliseconds: Int64) -> some View {
        Text(Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000),
             format: Date.FormatStyle(date: .abbreviated, time: .standard).locale(locale))
    }

    private func expiryLabel(_ snapshot: AccessAccountEntitlement) -> LocalizedStringResource {
        snapshot.quotaSource == .threeXUIAlpha ? "查询授权截止" : "到期时间"
    }

    private func statusText(_ status: AccessAccountEntitlement.Status) -> LocalizedStringResource {
        switch status {
        case .notSubscribed: return "尚无有效套餐"
        case .active: return "服务端报告：额度有效"
        case .exhausted: return "服务端报告：额度已耗尽"
        case .expired: return "服务端报告：套餐已到期"
        }
    }

    private func freshnessText(_ snapshot: AccessAccountEntitlement) -> LocalizedStringResource {
        switch AccessAccountUsagePresentation.freshness(
            snapshot: snapshot, receivedUptime: session.snapshotFreshnessAnchorUptime,
            nowUptime: ProcessInfo.processInfo.systemUptime, stale: session.snapshotIsStale
        ) {
        case .current: return "用量测量较新"
        case .delayed: return "用量同步有延迟"
        case .unavailable: return "用量测量时间未知或数据已陈旧"
        }
    }
}
