import AgentKit
import BrowserKit
import SwiftUI

struct AgentCenterView: View {
    @EnvironmentObject private var browser: BrowserSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let currentURL: URL?
    @StateObject private var model: AgentCenterModel

    init(
        currentURL: URL?,
        profileID: UUID,
        isPrivateProfile: Bool,
        dataStore: BrowserDataStore
    ) {
        self.currentURL = currentURL
        _model = StateObject(wrappedValue: AgentCenterModel(
            profileID: profileID,
            isPrivateProfile: isPrivateProfile,
            dataStore: dataStore
        ))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let recovery = model.recoveryNotice {
                        recoveryBanner(recovery)
                    }
                    stateBadge
                    switch model.screen {
                    case .catalog: catalog
                    case .consent: consentView
                    case .running: runningView
                    case .actionApproval: actionApprovalView
                    case .result: resultView
                    }
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("整理收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Label("仅在本机处理", systemImage: "network.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        model.cancelForLifecycle()
                        dismiss()
                    }
                }
            }
        }
        .accessibilityIdentifier("agent-center")
        .onChange(of: browser.profile) { _, _ in
            model.cancelForLifecycle()
            dismiss()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            model.cancelForLifecycle()
            dismiss()
        }
        .onDisappear { model.cancelForLifecycle() }
    }

    private var stateBadge: some View {
        HStack {
            Circle().fill(stateColor).frame(width: 8, height: 8)
            Text(LocalizedStringKey(stateTitle))
                .font(.caption.weight(.bold).monospaced())
            Spacer()
            Text("不会发送给模型")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("agent-state")
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("整理收藏，保留撤销")
                .font(.title2.bold())
            Text("先检查收藏并预览变更。只有再次确认后才会应用整理，你也可以撤销最近一次整理。")
                .foregroundStyle(.secondary)
            if model.recoveredUndoReceipt != nil {
                VStack(alignment: .leading, spacing: 9) {
                    Label("发现可撤销的上次整理", systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.headline)
                    Text("可恢复到整理前的收藏")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("检查并撤销") { model.prepareRecoveredUndo() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("recovered-bookmark-undo")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            }
            if let notice = model.bookmarkJournalNotice {
                Label(notice, systemImage: "exclamationmark.shield.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("bookmark-journal-error")
            }
            ForEach([AgentWorkflowKind.browserManager]) { kind in
                Button { model.prepare(kind, currentURL: currentURL) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: kind.symbol)
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(kind.title).font(.headline)
                            Text(subtitle(for: kind)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("workflow-\(kind.rawValue)")
            }
        }
    }

    private var consentView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("任务授权", systemImage: "checkmark.shield")
                .font(.title2.bold())
            if let consent = model.consent {
                consentRow("目标", consent.goal)
                consentRow("范围", "本机 Aegis 收藏")
                consentRow("操作", "检查、预览整理或撤销")
                consentRow("确认", "应用变更前会再次询问")
            }
            Text("确认前：页面读取 0 · 模型调用 0 · 网络请求 0")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
                .accessibilityIdentifier("pre-consent-zero-io")
            HStack {
                Button("拒绝", role: .cancel) { model.deny() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("授权并运行") { model.approve() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("approve-task-button")
            }
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var runningView: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text("正在检查整理结果").font(.headline)
            Text("取消任务或页面变化后，会停止尚未执行的操作。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
        .accessibilityIdentifier("agent-running")
    }

    @ViewBuilder
    private var actionApprovalView: some View {
        if let approval = model.pendingActionApproval {
            VStack(alignment: .leading, spacing: 16) {
                Label(
                    approval.tool == "bookmarks.undo" ? "确认撤销动作" : "确认收藏夹动作",
                    systemImage: "exclamationmark.shield.fill"
                )
                .font(.title2.bold())
                .foregroundStyle(.orange)
                .accessibilityIdentifier("action-approval-screen")

                Text("此页是独立动作确认。离开或取消会销毁一次性批准，不会修改收藏。")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                consentRow("操作", approval.tool == "bookmarks.undo" ? "恢复整理前的收藏" : "清理链接、去重并排序")
                if let plan = model.pendingBookmarkPlan {
                    consentRow(
                        "变更",
                        "当前 \(plan.beforeCount) 条 → \(plan.afterCount) 条；变更 \(plan.changedCount) 条，去重 \(plan.removedDuplicateCount) 条"
                    )
                } else if approval.tool == "bookmarks.undo" {
                    consentRow("来源", "最近一次已保存的收藏整理")
                }
                DisclosureGroup("查看核验详情") {
                    if let before = model.pendingTreeBeforeDigest { digestRow("整理前摘要", before) }
                    if let after = model.pendingTreeAfterDigest { digestRow("整理后摘要", after) }
                    digestRow("确认摘要", approval.confirmationDigest)
                        .accessibilityIdentifier("action-confirmation-digest")
                    digestRow("操作参数", approval.normalizedParameters)
                }

                HStack {
                    Button("取消", role: .cancel) { model.cancelPendingAction() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button(
                        approval.tool == "bookmarks.undo" ? "确认并撤销" : "确认并应用整理"
                    ) {
                        model.confirmPendingAction()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(
                        approval.tool == "bookmarks.undo"
                            ? "confirm-bookmark-undo"
                            : "confirm-bookmark-action"
                    )
                }
            }
            .padding(18)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 20)
            )
        }
    }

    @ViewBuilder
    private var resultView: some View {
        if let result = model.result {
            VStack(alignment: .leading, spacing: 18) {
                Label(result.headline, systemImage: result.requiresUserHandoff ? "hand.raised.fill" : "checkmark.circle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(result.requiresUserHandoff ? .orange : .green)
                Text(result.summary).foregroundStyle(.secondary)

                section("执行链") {
                    ForEach(Array(result.steps.enumerated()), id: \.offset) { index, step in
                        Label(step, systemImage: "\(index + 1).circle.fill")
                    }
                }
                section("证据") {
                    ForEach(result.evidence, id: \.self) { evidence in
                        Label(evidence, systemImage: "checkmark")
                    }
                }
                if !result.citations.isEmpty {
                    section("引用 · \(result.citations.count)") {
                        ForEach(result.citations) { citation in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(citation.title).font(.headline)
                                Text(citation.source).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(citation.summary).font(.subheadline)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                    .accessibilityIdentifier("research-citations")
                }
                if let reason = result.handoffReason {
                    Label(reason, systemImage: "person.crop.circle.badge.checkmark")
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("user-handoff")
                }
                if result.undoAvailable {
                    Button(model.undoWasApplied ? "已恢复整理前的收藏" : "撤销本次整理") {
                        model.applyUndo()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.undoWasApplied)
                    .accessibilityIdentifier("undo-workflow-button")
                }
                Button("返回收藏整理") { model.startAnother() }
                    .buttonStyle(.bordered)
            }
            .accessibilityIdentifier("workflow-result-\(result.kind.rawValue)")
        }
    }

    private func recoveryBanner(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("任务已中断", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.headline)
            Text(text).font(.subheadline)
            Button("转为用户接管") { model.dismissRecovery() }
                .buttonStyle(.bordered)
        }
        .padding(16)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("recovery-banner")
    }

    private func consentRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(LocalizedStringKey(title)).font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(LocalizedStringKey(value)).font(.callout).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func digestRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(title)).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey(title)).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func subtitle(for kind: AgentWorkflowKind) -> String {
        switch kind {
        case .research: String(localized: "多来源比较与可核对引用")
        case .browserManager: String(localized: "标签、收藏差异与一键撤销")
        case .safeDownload: String(localized: "官方来源、MIME 与哈希证据")
        case .shopping: String(localized: "比价、结算预览与最终接管")
        }
    }

    private var stateColor: Color {
        switch model.wireState {
        case .completed: .green
        case .userTakeover, .recovering: .orange
        case .failed, .cancelled, .expired: .red
        default: .blue
        }
    }

    private var stateTitle: String {
        switch model.wireState {
        case .draft, .planning: String(localized: "准备中")
        case .awaitingTaskConsent, .awaitingActionApproval: String(localized: "等待确认")
        case .running, .reflecting, .verifying: String(localized: "正在处理")
        case .pausedByUser: String(localized: "已暂停")
        case .userTakeover: String(localized: "需要你操作")
        case .recovering: String(localized: "发现中断任务")
        case .completed: String(localized: "已完成")
        case .failed: String(localized: "处理失败")
        case .cancelled: String(localized: "已取消")
        case .expired: String(localized: "确认已过期，请重试")
        }
    }
}
