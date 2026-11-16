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
                            AccessUsageSummaryView(usedBytes: snapshot.usedBytes, quotaBytes: snapshot.quotaBytes)
                            amount("总额度", snapshot.quotaBytes, id: "quota")
                            amount("剩余", snapshot.remainingBytes, id: "remaining")
                            Divider()
                            AccessTransferBreakdown(uploaded: snapshot.uploadedBytes, downloaded: snapshot.downloadedBytes)
                            if snapshot.quotaSource == .threeXUIAlpha {
                                if case .some(.none) = snapshot.panelExpiryMode {
                                    LabeledContent("到期时间") { Text("未设到期") }
                                } else if let panelExpires = snapshot.panelExpiresAt {
                                    LabeledContent("到期时间") {
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
                        case .signedOut:
                            ContentUnavailableView {
                                Label("尚未关联账号", systemImage: "person.crop.circle")
                            }
                            .accessibilityIdentifier("access-usage-unlinked")
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
            if session.state != .signedOut {
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
            }
        } header: {
            if session.lastSnapshot?.quotaSource == .threeXUIAlpha { Text("测试服务用量（共享）") }
            else { Text("账号与用量") }
        } footer: {
            if session.lastSnapshot?.quotaSource == .threeXUIAlpha {
                Text("共享测试用量，不代表个人套餐；重置以服务端为准。")
            }
        }
        .onAppear { session.usageRefresh.setVisible(scenePhase == .active, owner: visibilityID) }
        .onChange(of: scenePhase) { _, phase in
            session.usageRefresh.setVisible(phase == .active, owner: visibilityID)
        }
        .onDisappear { session.usageRefresh.setVisible(false, owner: visibilityID) }
    }

    private func amount(_ label: LocalizedStringResource, _ raw: String?, id: String) -> some View {
        LabeledContent {
            Text(verbatim: AccessAccountUsagePresentation.formattedBytes(raw))
        } label: {
            Text(verbatim: AegisLocalization.string(label))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: AegisLocalization.string(label)))
        .accessibilityValue(AccessAccountUsagePresentation.accessibleBytes(raw, locale: locale))
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
