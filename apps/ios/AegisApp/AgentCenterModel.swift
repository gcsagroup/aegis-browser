import AgentKit
import BrowserKit
import Foundation

@MainActor
final class AgentCenterModel: ObservableObject {
    enum Screen: Equatable {
        case catalog
        case consent
        case running
        case actionApproval
        case result
    }

    @Published private(set) var screen: Screen = .catalog
    @Published private(set) var selectedKind: AgentWorkflowKind?
    @Published private(set) var consent: ConsentDraft?
    @Published private(set) var result: WorkflowResult?
    @Published private(set) var wireState: AgentState = .draft
    @Published private(set) var errorMessage: String?
    @Published private(set) var undoLineage: UndoLineage?
    @Published private(set) var pendingActionApproval: PendingActionApproval?
    @Published private(set) var pendingBookmarkPlan: BookmarkOrganizationPlan?
    @Published private(set) var recoveredUndoReceipt: BookmarkTransactionReceipt?
    @Published private(set) var bookmarkJournalNotice: String?
    @Published var undoWasApplied = false
    @Published var recoveryNotice: String?

    private enum ExecutionError: LocalizedError, Equatable {
        case nativeCommitRequiresRecovery
        case receiptVerificationFailed

        var errorDescription: String? {
            switch self {
            case .nativeCommitRequiresRecovery:
                "收藏数据已经写入，但任务完成提交遇到竞态；已停止发布结果，请从认证日志恢复。"
            case .receiptVerificationFailed:
                "收藏事务回执或当前树摘要核对失败；已停止发布结果。"
            }
        }
    }

    /// 同进程与跨重启撤销共用这一个显式上下文；不从零散 UI 状态推断动作类型。
    private struct UndoContext {
        let receipt: BookmarkTransactionReceipt
        let lineage: UndoLineage?
        let recoveredAfterRestart: Bool
    }

    private enum PendingBookmarkOperation {
        case apply(BookmarkOrganizationPlan)
        case undo(UndoContext)
    }

    private let profileID: UUID
    private let isPrivateProfile: Bool
    private let dataStore: BrowserDataStore
    private let engine = AgentWorkflowEngine()
    private var broker: AgentBroker
    private var operationTask: Task<Void, Never>?
    private var operationGeneration: UInt64 = 0
    private var pendingBookmarkOperation: PendingBookmarkOperation?
    private var pendingUndoContext: UndoContext?
    private var bookmarkReceipt: BookmarkTransactionReceipt?
    private var nativeWriteAwaitingCommit = false
    private var recoveryMustRemainPersistent = false

    init(profileID: UUID, isPrivateProfile: Bool, dataStore: BrowserDataStore) {
        self.profileID = profileID
        self.isPrivateProfile = isPrivateProfile
        self.dataStore = dataStore
        broker = AgentBroker(profileID: profileID, isPrivateProfile: isPrivateProfile)
        if !isPrivateProfile {
            refreshRecoveredUndo()
        }
#if DEBUG
        let hasInjectedRecovery = ProcessInfo.processInfo.arguments.contains(
            "--ui-testing-recovery"
        )
#else
        let hasInjectedRecovery = false
#endif
        let hasPersistentRecovery = UserDefaults.standard.bool(
            forKey: "aegis.incompleteTask"
        )
        if !isPrivateProfile, hasInjectedRecovery || hasPersistentRecovery {
            recoveryNotice = "发现已中断任务。已进入 Recovering，写操作不会自动恢复。"
            wireState = .recovering
            recoveryMustRemainPersistent = hasPersistentRecovery
        }
    }

    func prepareRecoveredUndo() {
        refreshRecoveredUndo()
        guard let receipt = recoveredUndoReceipt else { return }

        replaceBroker()
        let activeBroker = broker
        let generation = operationGeneration
        selectedKind = .browserManager
        consent = nil
        result = nil
        undoWasApplied = false
        undoLineage = nil
        bookmarkReceipt = receipt
        clearPendingAction()
        pendingUndoContext = UndoContext(
            receipt: receipt,
            lineage: nil,
            recoveredAfterRestart: true
        )
        errorMessage = nil
        wireState = .planning
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let draft = try await activeBroker.makeLocalConsentDraft(
                    goal: "撤销上次已完成的收藏夹整理",
                    origins: ["aegis://native"],
                    tools: ["bookmarks.undo"],
                    dataClasses: ["bookmark_metadata"],
                    risk: .localReversible,
                    maxSteps: 1,
                    timeBudgetSeconds: 30
                )
                try requireCurrent(generation, broker: activeBroker)
                let currentState = await activeBroker.state
                try requireCurrent(generation, broker: activeBroker)
                consent = draft
                wireState = currentState
                screen = .consent
                operationTask = nil
            } catch {
                await handleFailure(
                    error,
                    fallback: .catalog,
                    broker: activeBroker,
                    generation: generation
                )
            }
        }
    }

    func prepare(_ kind: AgentWorkflowKind, currentURL: URL?) {
        guard recoveryNotice == nil else { return }
        replaceBroker()
        let activeBroker = broker
        let generation = operationGeneration
        selectedKind = kind
        consent = nil
        result = nil
        undoWasApplied = false
        undoLineage = nil
        bookmarkReceipt = nil
        clearPendingAction()
        errorMessage = nil

        let origin = Self.origin(for: kind, currentURL: currentURL)
        let scope = Self.scope(for: kind)
        wireState = .planning
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let draft = try await activeBroker.makeLocalConsentDraft(
                    goal: scope.goal,
                    origins: [origin],
                    tools: scope.tools,
                    dataClasses: scope.dataClasses,
                    risk: scope.risk,
                    maxSteps: scope.maxSteps,
                    timeBudgetSeconds: 120
                )
                try requireCurrent(generation, broker: activeBroker)
                let currentState = await activeBroker.state
                try requireCurrent(generation, broker: activeBroker)
                consent = draft
                wireState = currentState
                screen = .consent
                operationTask = nil
            } catch {
                await handleFailure(
                    error,
                    fallback: .catalog,
                    broker: activeBroker,
                    generation: generation
                )
            }
        }
    }

    /// 第一次真实用户手势只授予任务，并生成最终计划 target 与待确认快照。
    func approve() {
        guard let selectedKind, let consent else { return }
        let undoContext = pendingUndoContext
        let activeBroker = broker
        let generation = operationGeneration
        let planID = UUID()
        let transactionID = UUID()
        let bookmarkRootIDs: Set<UUID> = selectedKind == .browserManager
            ? [dataStore.bookmarkRootID]
            : []
        let grant = TaskGrant(
            taskID: UUID(),
            grantID: UUID(),
            surface: .aegisBrowser,
            profileID: profileID,
            allowedTopOrigins: Set(consent.origins),
            allowedTools: Set(consent.tools),
            dataClasses: Set(consent.dataClasses),
            riskCeiling: consent.risk,
            maxSteps: consent.maxSteps,
            timeBudgetSeconds: consent.timeBudgetSeconds,
            byteBudget: 64 * 1_024,
            costBudget: 0,
            tabScope: TabScope(approvedExistingTabIDs: [], mayCreateTabs: false),
            bookmarkScope: BookmarkScope(
                rootIDs: bookmarkRootIDs,
                mayWrite: selectedKind == .browserManager
            ),
            downloadScope: DownloadScope(approvedExistingIDs: [], mayStartDownloads: false),
            expiresAt: Date().addingTimeInterval(300),
            policyVersion: "ios-policy-v1",
            modelVersion: "deterministic-local-v1",
            modelDestination: nil
        )

        screen = .running
        UserDefaults.standard.set(true, forKey: "aegis.incompleteTask")
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await activeBroker.approve(grant)
                try requireCurrent(generation, broker: activeBroker)
                let approvedState = await activeBroker.state
                try requireCurrent(generation, broker: activeBroker)
                wireState = approvedState

                if let undoContext {
                    try await prepareUndoActionApproval(
                        context: undoContext,
                        broker: activeBroker,
                        generation: generation
                    )
                    operationTask = nil
                    return
                }

                if selectedKind == .browserManager {
                    try await prepareBookmarkActionApproval(
                        grant: grant,
                        planID: planID,
                        transactionID: transactionID,
                        broker: activeBroker,
                        generation: generation
                    )
                    operationTask = nil
                    return
                }

                try await Task.sleep(for: .milliseconds(180))
                try requireCurrent(generation, broker: activeBroker)
                try await authorizeReadWorkflow(
                    selectedKind,
                    origin: consent.origins[0],
                    broker: activeBroker
                )
                try requireCurrent(generation, broker: activeBroker)
                let workflowResult = engine.run(selectedKind)
                if workflowResult.requiresUserHandoff {
                    await activeBroker.enterUserTakeover()
                } else {
                    try await activeBroker.beginVerification()
                    try await activeBroker.completeVerified()
                }
                try requireCurrent(generation, broker: activeBroker)
                let completedState = await activeBroker.state
                try requireCurrent(generation, broker: activeBroker)
                wireState = completedState
                result = workflowResult
                UserDefaults.standard.set(false, forKey: "aegis.incompleteTask")
                screen = .result
                operationTask = nil
            } catch {
                await handleFailure(
                    error,
                    fallback: .catalog,
                    broker: activeBroker,
                    generation: generation
                )
            }
        }
    }

    /// 第二次真实用户手势才恢复并消费与界面所示字段完全一致的批准。
    func confirmPendingAction() {
        guard screen == .actionApproval,
              let approval = pendingActionApproval,
              let operation = pendingBookmarkOperation
        else { return }

        let activeBroker = broker
        let generation = operationGeneration
        let fallback: Screen = result == nil ? .catalog : .result
        screen = .running
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await activeBroker.resumeAfterApproval(
                    approvalID: approval.approvalID,
                    confirmationDigest: approval.confirmationDigest
                )
                try requireCurrent(generation, broker: activeBroker)
                let capability = try await activeBroker.issueAction(
                    tool: approval.tool,
                    normalizedParameters: approval.normalizedParameters,
                    callSequence: approval.callSequence,
                    target: approval.target,
                    approvalID: approval.approvalID,
                    confirmationDigest: approval.confirmationDigest
                )
                try requireCurrent(generation, broker: activeBroker)
                try await activeBroker.consumeAction(
                    capability,
                    expectedTool: approval.tool,
                    expectedParameters: approval.normalizedParameters,
                    expectedTarget: approval.target
                )
                try requireCurrent(generation, broker: activeBroker)

                guard case let .native(target) = approval.target else {
                    throw AgentContractError.capabilityMismatch
                }

                switch operation {
                case let .apply(plan):
                    guard target.resourceType == .bookmarkPlan,
                          target.resourceID == plan.planID
                    else {
                        throw AgentContractError.capabilityMismatch
                    }
                    let ticket = try await activeBroker.beginNativeVerification(
                        capability: capability
                    )
                    try requireCurrent(generation, broker: activeBroker)

                    // Broker 已进入 Verifying 后才允许唯一一次原子写；成功结果要等回执与树摘要核对。
                    let receipt = try applyAndVerifyBookmarkPlan(plan)
                    let committed = await activeBroker.commitNativeVerification(ticket)
                    if committed { nativeWriteAwaitingCommit = false }
                    try requireCurrent(generation, broker: activeBroker)
                    guard committed else { throw ExecutionError.nativeCommitRequiresRecovery }

                    publishBookmarkApply(
                        receipt: receipt,
                        approval: approval
                    )
                case let .undo(context):
                    let receipt = context.receipt
                    if let lineage = context.lineage {
                        guard receipt.transactionID == lineage.transactionID,
                              receipt.rootID == lineage.rootID,
                              receipt.beforeDigest == lineage.treeBeforeDigest,
                              receipt.afterDigest == lineage.treeAfterDigest
                        else { throw AgentContractError.capabilityMismatch }
                    }
                    guard target.resourceType == .bookmarkTransaction,
                          target.resourceID == receipt.transactionID
                    else {
                        throw AgentContractError.capabilityMismatch
                    }
                    let ticket = try await activeBroker.beginNativeVerification(
                        capability: capability
                    )
                    try requireCurrent(generation, broker: activeBroker)

                    try undoAndVerifyBookmarkTransaction(receipt)
                    let committed = await activeBroker.commitNativeVerification(ticket)
                    if committed { nativeWriteAwaitingCommit = false }
                    try requireCurrent(generation, broker: activeBroker)
                    guard committed else { throw ExecutionError.nativeCommitRequiresRecovery }

                    undoWasApplied = true
                    if context.recoveredAfterRestart {
                        result = engine.browserManagerUndoResult(
                            restoredCount: receipt.beforeCount,
                            transactionID: receipt.transactionID,
                            restoredDigest: receipt.beforeDigest
                        )
                        bookmarkReceipt = nil
                        recoveredUndoReceipt = nil
                    }
                }

                wireState = .completed
                clearPendingAction()
                recoveryNotice = nil
                recoveryMustRemainPersistent = false
                UserDefaults.standard.set(false, forKey: "aegis.incompleteTask")
                screen = .result
                operationTask = nil
            } catch {
                await handleFailure(
                    error,
                    fallback: fallback,
                    broker: activeBroker,
                    generation: generation
                )
            }
        }
    }

    func deny() {
        cancelForLifecycle()
    }

    func cancelPendingAction() {
        let fallback: Screen = result == nil ? .catalog : .result
        let activeBroker = broker
        invalidateOperation()
        operationTask?.cancel()
        operationTask = nil
        clearPendingAction()
        wireState = recoveryMustRemainPersistent ? .recovering : .cancelled
        UserDefaults.standard.set(
            recoveryMustRemainPersistent,
            forKey: "aegis.incompleteTask"
        )
        screen = fallback
        Task { await activeBroker.cancel() }
    }

    func startAnother() {
        cancelForLifecycle()
        refreshRecoveredUndo()
        wireState = .draft
    }

    func dismissRecovery() {
        recoveryNotice = nil
        recoveryMustRemainPersistent = false
        UserDefaults.standard.set(false, forKey: "aegis.incompleteTask")
        wireState = .userTakeover
    }

    /// Profile、场景或 sheet 生命周期变化时，撤销任务并清空迟到结果入口。
    func cancelForLifecycle() {
        let activeBroker = broker
        let preserveRecovery = nativeWriteAwaitingCommit || recoveryMustRemainPersistent
        invalidateOperation()
        operationTask?.cancel()
        operationTask = nil
        UserDefaults.standard.set(preserveRecovery, forKey: "aegis.incompleteTask")
        selectedKind = nil
        consent = nil
        result = nil
        undoLineage = nil
        bookmarkReceipt = nil
        undoWasApplied = false
        clearPendingAction()
        wireState = .cancelled
        screen = .catalog
        Task { await activeBroker.cancel() }
    }

    /// 结果页的第一次撤销手势只创建新的 bookmarks.undo 任务草案。
    /// 用户仍需分别点击任务授权与动作确认，任何一步都不会被代码自动批准。
    func applyUndo() {
        guard !undoWasApplied,
              let lineage = undoLineage,
              let receipt = bookmarkReceipt,
              receipt.transactionID == lineage.transactionID,
              receipt.rootID == lineage.rootID
        else { return }

        replaceBroker()
        let activeBroker = broker
        let generation = operationGeneration
        selectedKind = .browserManager
        consent = nil
        clearPendingAction()
        pendingUndoContext = UndoContext(
            receipt: receipt,
            lineage: lineage,
            recoveredAfterRestart: false
        )
        errorMessage = nil
        wireState = .planning
        screen = .running
        UserDefaults.standard.set(true, forKey: "aegis.incompleteTask")
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let draft = try await activeBroker.makeLocalConsentDraft(
                    goal: "撤销刚才的收藏夹离线事务",
                    origins: ["aegis://native"],
                    tools: ["bookmarks.undo"],
                    dataClasses: ["bookmark_metadata"],
                    risk: .localReversible,
                    maxSteps: 1,
                    timeBudgetSeconds: 30
                )
                try requireCurrent(generation, broker: activeBroker)
                let currentState = await activeBroker.state
                try requireCurrent(generation, broker: activeBroker)
                consent = draft
                wireState = currentState
                screen = .consent
                operationTask = nil
            } catch {
                await handleFailure(
                    error,
                    fallback: .result,
                    broker: activeBroker,
                    generation: generation
                )
            }
        }
    }

    var pendingTreeBeforeDigest: String? {
        if let pendingBookmarkPlan { return pendingBookmarkPlan.beforeDigest }
        if pendingActionApproval?.tool == "bookmarks.undo" {
            return pendingUndoContext?.receipt.beforeDigest
        }
        return nil
    }

    var pendingTreeAfterDigest: String? {
        if let pendingBookmarkPlan { return pendingBookmarkPlan.afterDigest }
        if pendingActionApproval?.tool == "bookmarks.undo" {
            return pendingUndoContext?.receipt.afterDigest
        }
        return nil
    }

    private func prepareUndoActionApproval(
        context: UndoContext,
        broker activeBroker: AgentBroker,
        generation: UInt64
    ) async throws {
        let receipt = context.receipt
        guard try dataStore.latestUndoableBookmarkTransaction() == receipt else {
            throw AgentContractError.capabilityMismatch
        }
        if let lineage = context.lineage {
            guard receipt.transactionID == lineage.transactionID,
                  receipt.rootID == lineage.rootID,
                  receipt.beforeDigest == lineage.treeBeforeDigest,
                  receipt.afterDigest == lineage.treeAfterDigest
            else { throw AgentContractError.capabilityMismatch }
        }
        try requireCurrent(generation, broker: activeBroker)
        let nativeTarget = try await activeBroker.registerNativeResource(
            type: .bookmarkTransaction,
            id: receipt.transactionID,
            scopeRootID: receipt.rootID
        )
        try requireCurrent(generation, broker: activeBroker)
        let parameters = context.lineage.map(Self.undoParameters)
            ?? Self.recoveredUndoParameters(receipt)
        let approval = try await activeBroker.requestActionApproval(
            tool: "bookmarks.undo",
            normalizedParameters: parameters,
            callSequence: 1,
            target: .native(nativeTarget)
        )
        try requireCurrent(generation, broker: activeBroker)
        let approvalState = await activeBroker.state
        try requireCurrent(generation, broker: activeBroker)
        bookmarkReceipt = receipt
        pendingBookmarkOperation = .undo(context)
        pendingBookmarkPlan = nil
        pendingActionApproval = approval
        wireState = approvalState
        screen = .actionApproval
    }

    private func prepareBookmarkActionApproval(
        grant: TaskGrant,
        planID: UUID,
        transactionID: UUID,
        broker activeBroker: AgentBroker,
        generation: UInt64
    ) async throws {
        let origin = try grant.allowedTopOrigins.sorted().first
            .unwrap(or: AgentContractError.originDenied)
        try await activeBroker.authorizeRead(tool: "bookmarks.list", topOrigin: origin)
        try requireCurrent(generation, broker: activeBroker)
        try await activeBroker.authorizeRead(tool: "bookmarks.plan", topOrigin: origin)
        try requireCurrent(generation, broker: activeBroker)

        let plan = try dataStore.makeBookmarkOrganizationPlan(
            planID: planID,
            transactionID: transactionID
        )
        let nativeTarget = try await activeBroker.registerNativeResource(
            type: .bookmarkPlan,
            id: plan.planID,
            scopeRootID: plan.rootID
        )
        try requireCurrent(generation, broker: activeBroker)
        let approval = try await activeBroker.requestActionApproval(
            tool: "bookmarks.apply",
            normalizedParameters: plan.canonicalApplyParameters,
            callSequence: 1,
            target: .native(nativeTarget)
        )
        try requireCurrent(generation, broker: activeBroker)
        let approvalState = await activeBroker.state
        try requireCurrent(generation, broker: activeBroker)
        pendingBookmarkPlan = plan
        pendingBookmarkOperation = .apply(plan)
        pendingActionApproval = approval
        wireState = approvalState
        screen = .actionApproval
    }

    private func applyAndVerifyBookmarkPlan(
        _ plan: BookmarkOrganizationPlan
    ) throws -> BookmarkTransactionReceipt {
        let receipt = try dataStore.apply(plan)
        // Store 已返回即代表本地写已提交；之后任何核验/Actor 提交失败都必须持久恢复。
        nativeWriteAwaitingCommit = true
        guard receipt.planID == plan.planID,
              receipt.transactionID == plan.transactionID,
              receipt.rootID == plan.rootID,
              receipt.beforeDigest == plan.beforeDigest,
              receipt.afterDigest == plan.afterDigest,
              receipt.beforeCount == plan.beforeCount,
              receipt.afterCount == plan.afterCount,
              receipt.changedBookmarkIDs == plan.changedBookmarkIDs,
              receipt.removedDuplicateIDs == plan.removedDuplicateIDs,
              try dataStore.bookmarkDigest() == receipt.afterDigest,
              try dataStore.latestUndoableBookmarkTransaction() == receipt
        else { throw ExecutionError.receiptVerificationFailed }
        return receipt
    }

    private func undoAndVerifyBookmarkTransaction(
        _ expected: BookmarkTransactionReceipt
    ) throws {
        let receipt = try dataStore.undoBookmarkTransaction(
            transactionID: expected.transactionID,
            expectedAfterDigest: expected.afterDigest
        )
        nativeWriteAwaitingCommit = true
        guard receipt == expected,
              try dataStore.bookmarkDigest() == expected.beforeDigest,
              try dataStore.latestUndoableBookmarkTransaction() == nil
        else { throw ExecutionError.receiptVerificationFailed }
    }

    private func publishBookmarkApply(
        receipt: BookmarkTransactionReceipt,
        approval: PendingActionApproval
    ) {
        bookmarkReceipt = receipt
        undoLineage = UndoLineage(
            originalTaskID: approval.taskID,
            originalGrantID: approval.grantID,
            transactionID: receipt.transactionID,
            rootID: receipt.rootID,
            treeBeforeDigest: receipt.beforeDigest,
            treeAfterDigest: receipt.afterDigest,
            confirmationDigest: approval.confirmationDigest
        )
        result = engine.browserManagerResult(
            beforeCount: receipt.beforeCount,
            afterCount: receipt.afterCount,
            changedCount: receipt.changedBookmarkIDs.count,
            removedDuplicateCount: receipt.removedDuplicateIDs.count,
            undoAvailable: true
        )
    }

    private func authorizeReadWorkflow(
        _ kind: AgentWorkflowKind,
        origin: String,
        broker activeBroker: AgentBroker
    ) async throws {
        switch kind {
        case .research, .shopping:
            try await activeBroker.authorizeRead(tool: "page.observe", topOrigin: origin)
            try await activeBroker.authorizeRead(tool: "page.extract", topOrigin: origin)
        case .safeDownload:
            try await activeBroker.authorizeRead(tool: "downloads.verify", topOrigin: origin)
        case .browserManager:
            throw AgentContractError.invalidState
        }
    }

    private func replaceBroker() {
        let previousBroker = broker
        invalidateOperation()
        operationTask?.cancel()
        operationTask = nil
        Task { await previousBroker.cancel() }
        broker = AgentBroker(profileID: profileID, isPrivateProfile: isPrivateProfile)
    }

    private func invalidateOperation() {
        operationGeneration &+= 1
    }

    private func requireCurrent(
        _ generation: UInt64,
        broker activeBroker: AgentBroker
    ) throws {
        try Task.checkCancellation()
        guard operationGeneration == generation, broker === activeBroker else {
            throw CancellationError()
        }
    }

    private func clearPendingAction() {
        pendingActionApproval = nil
        pendingBookmarkPlan = nil
        pendingBookmarkOperation = nil
        pendingUndoContext = nil
    }

    private func refreshRecoveredUndo() {
        do {
            recoveredUndoReceipt = try dataStore.latestUndoableBookmarkTransaction()
            bookmarkJournalNotice = nil
        } catch {
            recoveredUndoReceipt = nil
            bookmarkJournalNotice = "收藏撤销日志不可用：\(error.localizedDescription)"
        }
    }

    private func handleFailure(
        _ error: Error,
        fallback: Screen,
        broker activeBroker: AgentBroker,
        generation: UInt64
    ) async {
        if nativeWriteAwaitingCommit || Self.requiresPersistentRecovery(error) {
            await handlePersistentRecovery(
                error,
                fallback: fallback,
                broker: activeBroker,
                generation: generation
            )
            return
        }
        if recoveryMustRemainPersistent {
            await activeBroker.cancel()
            guard operationGeneration == generation, broker === activeBroker else { return }
            wireState = .recovering
            UserDefaults.standard.set(true, forKey: "aegis.incompleteTask")
            clearPendingAction()
            refreshRecoveredUndo()
            errorMessage = error.localizedDescription
            screen = .catalog
            operationTask = nil
            return
        }
        await activeBroker.cancel()
        guard operationGeneration == generation, broker === activeBroker else { return }
        let cancelledState = await activeBroker.state
        guard operationGeneration == generation, broker === activeBroker else { return }
        wireState = cancelledState
        UserDefaults.standard.set(false, forKey: "aegis.incompleteTask")
        clearPendingAction()
        errorMessage = error.localizedDescription
        screen = fallback
        operationTask = nil
    }

    private func handlePersistentRecovery(
        _ error: Error,
        fallback: Screen,
        broker activeBroker: AgentBroker,
        generation: UInt64
    ) async {
        let operationWasUndo: Bool
        if case .undo? = pendingBookmarkOperation {
            operationWasUndo = true
        } else {
            operationWasUndo = false
        }
        await activeBroker.cancel()
        guard operationGeneration == generation, broker === activeBroker else { return }
        nativeWriteAwaitingCommit = false
        recoveryMustRemainPersistent = true
        wireState = .recovering
        UserDefaults.standard.set(true, forKey: "aegis.incompleteTask")
        if operationWasUndo {
            undoWasApplied = true
            bookmarkReceipt = nil
            undoLineage = nil
        }
        clearPendingAction()
        refreshRecoveredUndo()
        recoveryNotice = "本地收藏写入进入恢复状态；不会自动重放，重启后将按认证日志核对。"
        errorMessage = error.localizedDescription
        screen = fallback
        operationTask = nil
    }

    private static func requiresPersistentRecovery(_ error: Error) -> Bool {
        if let executionError = error as? ExecutionError,
           executionError == .nativeCommitRequiresRecovery
            || executionError == .receiptVerificationFailed {
            return true
        }
        guard let transactionError = error as? BookmarkTransactionError else { return false }
        return transactionError == .persistenceFailed
            || transactionError == .recoveryRequired
    }

    private struct WorkflowScope {
        let goal: String
        let tools: [String]
        let dataClasses: [String]
        let risk: AgentRisk
        let maxSteps: Int
    }

    private static func scope(for kind: AgentWorkflowKind) -> WorkflowScope {
        switch kind {
        case .research:
            WorkflowScope(
                goal: "读取受控来源并生成可核对引用",
                tools: ["page.observe", "page.extract"],
                dataClasses: ["visible_text", "page_metadata"],
                risk: .readOnly,
                maxSteps: 12
            )
        case .browserManager:
            WorkflowScope(
                goal: "预览并整理 Aegis 收藏夹",
                tools: ["bookmarks.list", "bookmarks.plan", "bookmarks.apply"],
                dataClasses: ["bookmark_metadata"],
                risk: .localReversible,
                maxSteps: 10
            )
        case .safeDownload:
            WorkflowScope(
                goal: "检查官方候选并核对下载证据",
                tools: ["downloads.verify"],
                dataClasses: ["download_metadata"],
                risk: .readOnly,
                maxSteps: 8
            )
        case .shopping:
            WorkflowScope(
                goal: "比较报价并停在最终提交前",
                tools: ["page.observe", "page.extract"],
                dataClasses: ["product", "price", "shipping"],
                risk: .readOnly,
                maxSteps: 10
            )
        }
    }

    private static func origin(for kind: AgentWorkflowKind, currentURL url: URL?) -> String {
        if kind == .browserManager || kind == .safeDownload { return "aegis://native" }
        guard let url else { return "aegis://start" }
        if let scheme = url.scheme, let host = url.host { return "\(scheme)://\(host)" }
        return "aegis://start"
    }

    private static func undoParameters(_ lineage: UndoLineage) -> String {
        "{" + [
            "\"operation\":\"undo\"",
            "\"original_confirmation_digest\":\"\(lineage.confirmationDigest)\"",
            "\"original_grant_id\":\"\(lineage.originalGrantID.uuidString.lowercased())\"",
            "\"original_task_id\":\"\(lineage.originalTaskID.uuidString.lowercased())\"",
            "\"root_id\":\"\(lineage.rootID.uuidString.lowercased())\"",
            "\"transaction_id\":\"\(lineage.transactionID.uuidString.lowercased())\"",
            "\"tree_after\":\"\(lineage.treeAfterDigest)\"",
            "\"tree_before\":\"\(lineage.treeBeforeDigest)\"",
        ].joined(separator: ",") + "}"
    }

    private static func recoveredUndoParameters(
        _ receipt: BookmarkTransactionReceipt
    ) -> String {
        "{" + [
            "\"operation\":\"undo\"",
            "\"recovered_from_journal\":true",
            "\"root_id\":\"\(receipt.rootID.uuidString.lowercased())\"",
            "\"transaction_id\":\"\(receipt.transactionID.uuidString.lowercased())\"",
            "\"tree_after\":\"\(receipt.afterDigest)\"",
            "\"tree_before\":\"\(receipt.beforeDigest)\"",
        ].joined(separator: ",") + "}"
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
