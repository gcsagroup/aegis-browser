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
            .navigationTitle("Aegis Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Label("本地确定性", systemImage: "network.slash")
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
        .onChange(of: browser.profile) { _, profile in
            guard profile.isPrivate else { return }
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
            Text("状态 · \(model.wireState.rawValue)")
                .font(.caption.weight(.bold).monospaced())
            Spacer()
            Text("远程请求 0")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("agent-state")
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("选择一个工作流")
                .font(.title2.bold())
            Text("Agent 先在本地生成范围草案。你确认 Origin、工具、数据和预算后，Broker 才允许页面读取或动作。")
                .foregroundStyle(.secondary)
            if let receipt = model.recoveredUndoReceipt {
                VStack(alignment: .leading, spacing: 9) {
                    Label("发现可撤销的上次整理", systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.headline)
                    Text("事务 \(receipt.transactionID.uuidString.lowercased())")
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
            ForEach(AgentWorkflowKind.allCases) { kind in
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
                consentRow("Origin", consent.origins.joined(separator: "\n"))
                consentRow("工具", consent.tools.joined(separator: "\n"))
                consentRow("数据", consent.dataClasses.joined(separator: "、"))
                consentRow("风险", "R\(consent.risk.rawValue)")
                consentRow("预算", "最多 \(consent.maxSteps) 步 · \(consent.timeBudgetSeconds) 秒 · 64 KiB")
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
            Text("Broker 正在验证计划与证据").font(.headline)
            Text("所有动作都受 task grant、页面 lease 和一次性 capability 约束。")
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

                consentRow("风险", "R\(approval.risk.rawValue)")
                consentRow("工具", approval.tool)
                if case let .native(target) = approval.target {
                    consentRow("Plan target", target.resourceID.uuidString.lowercased())
                    consentRow("Registry", String(target.registryRevision))
                }
                if let plan = model.pendingBookmarkPlan {
                    consentRow("树根", plan.rootID.uuidString.lowercased())
                    consentRow(
                        "变更",
                        "当前 \(plan.beforeCount) 条 → \(plan.afterCount) 条；变更 \(plan.changedCount) 条，去重 \(plan.removedDuplicateCount) 条"
                    )
                } else if let lineage = model.undoLineage {
                    consentRow("树根", lineage.rootID.uuidString.lowercased())
                    consentRow("原任务", lineage.originalTaskID.uuidString.lowercased())
                    consentRow("原授权", lineage.originalGrantID.uuidString.lowercased())
                } else if let receipt = model.recoveredUndoReceipt,
                          approval.tool == "bookmarks.undo" {
                    consentRow("来源", "跨重启认证日志")
                    consentRow("树根", receipt.rootID.uuidString.lowercased())
                    consentRow("事务", receipt.transactionID.uuidString.lowercased())
                }
                if let before = model.pendingTreeBeforeDigest {
                    digestRow("Tree before", before)
                }
                if let after = model.pendingTreeAfterDigest {
                    digestRow("Tree after", after)
                }
                digestRow("确认摘要", approval.confirmationDigest)
                    .accessibilityIdentifier("action-confirmation-digest")
                digestRow("规范参数", approval.normalizedParameters)

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
                    Button(model.undoWasApplied ? "已撤销，逻辑树哈希一致" : "撤销本次整理") {
                        model.applyUndo()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.undoWasApplied)
                    .accessibilityIdentifier("undo-workflow-button")
                }
                Button("运行其他工作流") { model.startAnother() }
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
            Text(title).font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(value).font(.callout.monospaced()).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func digestRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func subtitle(for kind: AgentWorkflowKind) -> String {
        switch kind {
        case .research: "多来源比较与可核对引用"
        case .browserManager: "标签、收藏差异与一键撤销"
        case .safeDownload: "官方来源、MIME 与哈希证据"
        case .shopping: "比价、结算预览与最终接管"
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
}
