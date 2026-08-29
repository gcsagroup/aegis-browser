import CryptoKit
import Foundation

public struct NativeVerificationTicket: Equatable, Sendable {
    public let target: NativeActionTarget

    fileprivate let taskID: UUID
    fileprivate let grantID: UUID
    fileprivate let cancellationEpoch: UInt64
    fileprivate let registryRevision: UInt64
}

public actor AgentBroker {
    private static let maximumActionApprovalTTL: TimeInterval = 60

    public private(set) var state: AgentState = .draft
    public private(set) var cancellationEpoch: UInt64 = 0
    public private(set) var activeGrant: TaskGrant?
    public private(set) var pendingActionApproval: PendingActionApproval?

    private let profileID: UUID
    private let isPrivateProfile: Bool
    private let capabilityBroker: ActionCapabilityBroker
    private var resourceRegistry: ResourceRegistry?
    private var pendingConsentDraft: ConsentDraft?
    private var approvedActionApproval: PendingActionApproval?
    private var consumedNativeAction: (capability: ActionCapability, cancellationEpoch: UInt64)?

    public init(
        profileID: UUID,
        isPrivateProfile: Bool,
        processInstanceID: UUID = UUID()
    ) {
        self.profileID = profileID
        self.isPrivateProfile = isPrivateProfile
        capabilityBroker = ActionCapabilityBroker(processInstanceID: processInstanceID)
    }

    public func makeLocalConsentDraft(
        goal: String,
        origins: [String],
        tools: [String],
        dataClasses: [String],
        risk: AgentRisk,
        maxSteps: Int = 12,
        timeBudgetSeconds: Int = 120
    ) throws -> ConsentDraft {
        guard !isPrivateProfile else { throw AgentContractError.privateProfileDenied }
        guard state == .draft else { throw AgentContractError.invalidState }
        state = .planning
        // 同意前只进行本地、确定性的作用域草拟，不读取页面也不调用远程 Planner。
        let draft = ConsentDraft(
            goal: goal,
            origins: origins.sorted(),
            tools: tools.sorted(),
            dataClasses: dataClasses.sorted(),
            risk: risk,
            maxSteps: maxSteps,
            timeBudgetSeconds: timeBudgetSeconds
        )
        pendingConsentDraft = draft
        state = .awaitingTaskConsent
        return draft
    }

    public func approve(_ grant: TaskGrant, now: Date = Date()) throws {
        guard !isPrivateProfile else { throw AgentContractError.privateProfileDenied }
        guard state == .awaitingTaskConsent, let pendingConsentDraft else {
            throw AgentContractError.invalidState
        }
        guard grant.profileID == profileID else { throw AgentContractError.capabilityMismatch }
        guard grant.contractVersion == TaskGrant.supportedContractVersion else {
            throw AgentContractError.unsupportedVersion
        }
        guard now < grant.expiresAt else { throw AgentContractError.expiredGrant }
        guard grant.surface == .aegisBrowser,
              grant.allowedTopOrigins == Set(pendingConsentDraft.origins),
              grant.allowedFrameOrigins.isEmpty,
              grant.allowedTools == Set(pendingConsentDraft.tools),
              grant.allowedTools.allSatisfy({ (try? AgentToolCatalog.risk(for: $0)) != nil }),
              grant.dataClasses == Set(pendingConsentDraft.dataClasses),
              grant.riskCeiling == pendingConsentDraft.risk,
              grant.allowedTools.allSatisfy({
                  guard let toolRisk = try? AgentToolCatalog.risk(for: $0) else { return false }
                  return toolRisk <= grant.riskCeiling
              }),
              grant.maxSteps > 0,
              grant.maxSteps <= pendingConsentDraft.maxSteps,
              grant.timeBudgetSeconds > 0,
              grant.timeBudgetSeconds <= pendingConsentDraft.timeBudgetSeconds,
              grant.byteBudget >= 0,
              grant.byteBudget <= 64 * 1_024,
              grant.costBudget >= 0,
              grant.costBudget == 0,
              grant.modelDestination == nil,
              !grant.bookmarkScope.mayWrite
                || grant.allowedTools.contains("bookmarks.apply")
                || grant.allowedTools.contains("bookmarks.undo"),
              !grant.downloadScope.mayStartDownloads
                || grant.allowedTools.contains("downloads.start"),
              !grant.tabScope.mayCreateTabs
                || grant.allowedTools.contains("browser.tabs.create")
        else { throw AgentContractError.capabilityMismatch }
        activeGrant = grant
        self.pendingConsentDraft = nil
        clearActionApproval()
        resourceRegistry = ResourceRegistry(taskID: grant.taskID, grantID: grant.grantID)
        state = .running
    }

    public func authorizeRead(tool: String, topOrigin: String, now: Date = Date()) throws {
        guard state == .running || state == .reflecting || state == .verifying else {
            throw activeGrant == nil ? AgentContractError.consentRequired : AgentContractError.invalidState
        }
        guard let activeGrant else { throw AgentContractError.consentRequired }
        guard try AgentToolCatalog.risk(for: tool) == .readOnly else {
            throw AgentContractError.riskExceeded
        }
        try activeGrant.validate(tool: tool, topOrigin: topOrigin, risk: .readOnly, now: now)
    }

    public func requestActionApproval(
        tool: String,
        normalizedParameters: String,
        callSequence: UInt64,
        target: ActionTarget,
        documentLease: DocumentLease? = nil,
        approvalTTL: TimeInterval = 60,
        now: Date = Date()
    ) async throws -> PendingActionApproval {
        guard state == .running || state == .reflecting,
              let activeGrant,
              pendingActionApproval == nil,
              approvedActionApproval == nil,
              consumedNativeAction == nil
        else { throw AgentContractError.invalidState }
        let canonicalParameters = try AgentContractCodec.canonicalNormalizedParameters(
            normalizedParameters
        )
        let snapshot: ResourceRegistrySnapshot?
        if case .native = target {
            guard let resourceRegistry else { throw AgentContractError.unknownResource }
            snapshot = await resourceRegistry.snapshot()
        } else {
            snapshot = nil
        }
        let risk = try await capabilityBroker.validateApprovalCandidate(
            grant: activeGrant,
            tool: tool,
            callSequence: callSequence,
            target: target,
            documentLease: documentLease,
            registrySnapshot: snapshot,
            now: now
        )
        guard (state == .running || state == .reflecting),
              self.activeGrant == activeGrant,
              pendingActionApproval == nil,
              approvedActionApproval == nil
        else { throw AgentContractError.invalidState }
        guard risk == .localReversible || risk == .externalOrSensitive else {
            throw AgentContractError.riskExceeded
        }
        guard approvalTTL.isFinite, approvalTTL > 0 else {
            throw AgentContractError.capabilityExpired
        }
        let approvalID = UUID()
        let candidateExpiry = min(
            activeGrant.expiresAt,
            now.addingTimeInterval(min(approvalTTL, Self.maximumActionApprovalTTL))
        )
        // 摘要使用 UTC 毫秒；同时按同一毫秒边界执行过期判断。
        let expiresAt = Date(
            timeIntervalSince1970: (
                candidateExpiry.timeIntervalSince1970 * 1_000
            ).rounded(.down) / 1_000
        )
        guard now < expiresAt else { throw AgentContractError.capabilityExpired }
        let digestData = try AgentContractCodec.actionApprovalDigestData(
            approvalID: approvalID,
            expiresAt: expiresAt,
            grant: activeGrant,
            tool: tool,
            normalizedParameters: canonicalParameters,
            callSequence: callSequence,
            target: target,
            risk: risk
        )
        let approval = PendingActionApproval(
            approvalID: approvalID,
            expiresAt: expiresAt,
            grant: activeGrant,
            taskID: activeGrant.taskID,
            grantID: activeGrant.grantID,
            profileID: activeGrant.profileID,
            surface: activeGrant.surface,
            policyVersion: activeGrant.policyVersion,
            tool: tool,
            normalizedParameters: canonicalParameters,
            callSequence: callSequence,
            target: target,
            risk: risk,
            confirmationDigest: Self.digest(digestData)
        )
        pendingActionApproval = approval
        state = .awaitingActionApproval
        return approval
    }

    public func registerNativeResource(
        type: NativeResourceType,
        id: UUID = UUID(),
        scopeRootID: UUID? = nil,
        now: Date = Date()
    ) async throws -> NativeActionTarget {
        guard state == .running, let activeGrant, let resourceRegistry else {
            throw activeGrant == nil ? AgentContractError.consentRequired : AgentContractError.invalidState
        }
        switch type {
        case .bookmarkPlan, .bookmarkTransaction:
            guard activeGrant.bookmarkScope.mayWrite,
                  let scopeRootID,
                  activeGrant.bookmarkScope.rootIDs.contains(scopeRootID)
            else { throw AgentContractError.toolDenied }
        case .tabBatch:
            guard scopeRootID == nil, activeGrant.tabScope.mayCreateTabs else {
                throw AgentContractError.toolDenied
            }
        case .download:
            guard scopeRootID == nil,
                  activeGrant.downloadScope.mayStartDownloads
                    || activeGrant.downloadScope.approvedExistingIDs.contains(id)
            else { throw AgentContractError.toolDenied }
        }
        let revision = try await resourceRegistry.append(
            id: id,
            kind: Self.kind(for: type),
            scopeRootID: scopeRootID,
            now: now
        )
        return NativeActionTarget(resourceType: type, registryRevision: revision, resourceID: id)
    }

    public func issueAction(
        tool: String,
        normalizedParameters: String,
        callSequence: UInt64,
        target: ActionTarget,
        documentLease: DocumentLease? = nil,
        approvalID: UUID? = nil,
        confirmationDigest: String? = nil,
        ttl: TimeInterval = 30,
        now: Date = Date()
    ) async throws -> ActionCapability {
        // 任何签发尝试都先烧掉已恢复的批准，后续任一校验失败也不能重放。
        let approved = approvedActionApproval
        if approved != nil { approvedActionApproval = nil }
        guard state == .running, let activeGrant else {
            throw activeGrant == nil ? AgentContractError.consentRequired : AgentContractError.invalidState
        }
        let risk = try AgentToolCatalog.risk(for: tool)
        let canonicalParameters = try AgentContractCodec.canonicalNormalizedParameters(
            normalizedParameters
        )
        if risk == .localReversible || risk == .externalOrSensitive {
            guard let approved else { throw AgentContractError.consentRequired }
            guard now < approved.expiresAt else { throw AgentContractError.capabilityExpired }
            guard approved.grant == activeGrant,
                  let approvalID,
                  approvalID == approved.approvalID,
                  approved.taskID == activeGrant.taskID,
                  approved.grantID == activeGrant.grantID,
                  approved.profileID == activeGrant.profileID,
                  approved.surface == activeGrant.surface,
                  approved.policyVersion == activeGrant.policyVersion,
                  approved.tool == tool,
                  approved.normalizedParameters == canonicalParameters,
                  approved.callSequence == callSequence,
                  approved.target == target,
                  approved.risk == risk,
                  let confirmationDigest,
                  !confirmationDigest.isEmpty,
                  confirmationDigest == approved.confirmationDigest
            else { throw AgentContractError.capabilityMismatch }
        } else if approved != nil {
            throw AgentContractError.capabilityMismatch
        }
        let snapshot: ResourceRegistrySnapshot?
        if case .native = target {
            guard let resourceRegistry else { throw AgentContractError.unknownResource }
            snapshot = await resourceRegistry.snapshot()
        } else {
            snapshot = nil
        }
        return try await capabilityBroker.issue(
            grant: activeGrant,
            tool: tool,
            normalizedParameters: canonicalParameters,
            callSequence: callSequence,
            target: target,
            documentLease: documentLease,
            registrySnapshot: snapshot,
            confirmationDigest: confirmationDigest,
            ttl: ttl,
            now: now
        )
    }

    public func consumeAction(
        _ capability: ActionCapability,
        expectedTool: String,
        expectedParameters: String,
        expectedTarget: ActionTarget,
        now: Date = Date()
    ) async throws {
        guard state == .running, let activeGrant,
              capability.taskID == activeGrant.taskID,
              capability.grantID == activeGrant.grantID,
              capability.profileID == profileID,
              capability.policyVersion == activeGrant.policyVersion
        else { throw AgentContractError.capabilityMismatch }
        let startingCancellationEpoch = cancellationEpoch
        if case .native = capability.target {
            guard consumedNativeAction == nil else { throw AgentContractError.invalidState }
        }
        let snapshot: ResourceRegistrySnapshot?
        if case .native = capability.target {
            guard let resourceRegistry else { throw AgentContractError.unknownResource }
            snapshot = await resourceRegistry.snapshot()
        } else {
            snapshot = nil
        }
        try await capabilityBroker.consume(
            capability,
            expectedTool: expectedTool,
            expectedParameters: expectedParameters,
            expectedTarget: expectedTarget,
            registrySnapshot: snapshot,
            now: now
        )
        guard state == .running,
              self.activeGrant == activeGrant,
              cancellationEpoch == startingCancellationEpoch
        else { throw AgentContractError.invalidState }
        if case .native = capability.target {
            consumedNativeAction = (capability, startingCancellationEpoch)
        }
    }

    public func resumeAfterApproval(
        approvalID: UUID,
        confirmationDigest: String,
        now: Date = Date()
    ) throws {
        guard state == .awaitingActionApproval,
              let pendingActionApproval
        else { throw AgentContractError.invalidState }
        guard approvalID == pendingActionApproval.approvalID,
              !confirmationDigest.isEmpty,
              confirmationDigest == pendingActionApproval.confirmationDigest
        else { throw AgentContractError.capabilityMismatch }
        guard now < pendingActionApproval.expiresAt else {
            throw AgentContractError.capabilityExpired
        }
        self.pendingActionApproval = nil
        approvedActionApproval = pendingActionApproval
        state = .running
    }

    public func pause() async {
        cancellationEpoch += 1
        clearActionApproval()
        state = .pausedByUser
        await capabilityBroker.revokeAll()
    }

    public func cancel() async {
        cancellationEpoch += 1
        state = .cancelled
        activeGrant = nil
        pendingConsentDraft = nil
        clearActionApproval()
        resourceRegistry = nil
        await capabilityBroker.revokeAll()
    }

    public func enterUserTakeover() async {
        cancellationEpoch += 1
        state = .userTakeover
        activeGrant = nil
        pendingConsentDraft = nil
        clearActionApproval()
        resourceRegistry = nil
        await capabilityBroker.revokeAll()
    }

    public func recoverAfterProcessRestart() async {
        cancellationEpoch += 1
        activeGrant = nil
        pendingConsentDraft = nil
        clearActionApproval()
        resourceRegistry = nil
        state = .recovering
        await capabilityBroker.revokeAll()
    }

    public func requireUserAfterRecovery() throws {
        guard state == .recovering else { throw AgentContractError.invalidState }
        state = .userTakeover
    }

    /// 通用验证只供没有登记原生写资源的只读任务使用。
    /// 原生写任务必须走 beginNativeVerification/commitNativeVerification 的 ticket 链。
    public func beginVerification() async throws {
        guard state == .running || state == .reflecting,
              let activeGrant,
              let resourceRegistry,
              Self.isReadOnlyGrant(activeGrant),
              consumedNativeAction == nil,
              pendingActionApproval == nil,
              approvedActionApproval == nil
        else { throw AgentContractError.invalidState }
        let snapshot = await resourceRegistry.snapshot()
        guard (state == .running || state == .reflecting),
              self.activeGrant == activeGrant,
              self.resourceRegistry === resourceRegistry,
              snapshot.resources.isEmpty
        else { throw AgentContractError.invalidState }
        state = .verifying
    }

    /// 在原子数据写入前进入 Verifying，并预检动作绑定的 native 资源仍为 active。
    /// 返回的 ticket 只能由同一 task/grant、同一 cancellation epoch 提交一次。
    public func beginNativeVerification(
        capability: ActionCapability
    ) async throws -> NativeVerificationTicket {
        guard state == .running,
              let activeGrant,
              let resourceRegistry,
              let consumedNativeAction
        else { throw AgentContractError.invalidState }
        // 一次性消费标记在任何后续校验前先销毁；预检失败也不能重放。
        self.consumedNativeAction = nil
        guard consumedNativeAction.capability == capability,
              consumedNativeAction.cancellationEpoch == cancellationEpoch,
              capability.taskID == activeGrant.taskID,
              capability.grantID == activeGrant.grantID,
              capability.profileID == profileID,
              case let .native(target) = capability.target
        else { throw AgentContractError.capabilityMismatch }

        let expectedKind = Self.kind(for: target.resourceType)
        let snapshot = await resourceRegistry.snapshot()
        guard state == .running,
              self.activeGrant == activeGrant,
              self.resourceRegistry === resourceRegistry,
              snapshot.revision == target.registryRevision,
              let resource = snapshot.resources.first(where: { $0.id == target.resourceID }),
              resource.kind == expectedKind,
              resource.ownerTaskID == activeGrant.taskID,
              resource.ownerGrantID == activeGrant.grantID,
              resource.state == .active
        else { throw AgentContractError.capabilityMismatch }

        state = .verifying
        return NativeVerificationTicket(
            target: target,
            taskID: activeGrant.taskID,
            grantID: activeGrant.grantID,
            cancellationEpoch: cancellationEpoch,
            registryRevision: snapshot.revision
        )
    }

    /// 数据写入与摘要核对成功后唯一允许的 native 完成入口。
    /// false 表示资源或 Broker 在提交窗口发生竞态，调用方必须显式恢复，不能发布成功结果。
    public func commitNativeVerification(_ ticket: NativeVerificationTicket) async -> Bool {
        guard state == .verifying,
              cancellationEpoch == ticket.cancellationEpoch,
              let activeGrant,
              activeGrant.taskID == ticket.taskID,
              activeGrant.grantID == ticket.grantID,
              let resourceRegistry
        else { return false }

        let resourceCompleted = await resourceRegistry.completeIfActive(
            id: ticket.target.resourceID,
            kind: Self.kind(for: ticket.target.resourceType),
            ownerTaskID: ticket.taskID,
            ownerGrantID: ticket.grantID,
            expectedRevision: ticket.registryRevision
        )
        guard resourceCompleted,
              state == .verifying,
              cancellationEpoch == ticket.cancellationEpoch,
              self.activeGrant == activeGrant,
              self.resourceRegistry === resourceRegistry
        else { return false }

        state = .completed
        self.activeGrant = nil
        pendingConsentDraft = nil
        clearActionApproval()
        self.resourceRegistry = nil
        await capabilityBroker.revokeAll()
        return state == .completed && cancellationEpoch == ticket.cancellationEpoch
    }

    public func completeVerified() async throws {
        guard state == .verifying,
              let activeGrant,
              let resourceRegistry,
              Self.isReadOnlyGrant(activeGrant),
              consumedNativeAction == nil
        else { throw AgentContractError.invalidState }
        let snapshot = await resourceRegistry.snapshot()
        guard state == .verifying,
              self.activeGrant == activeGrant,
              self.resourceRegistry === resourceRegistry,
              snapshot.resources.isEmpty
        else { throw AgentContractError.invalidState }
        state = .completed
        self.activeGrant = nil
        pendingConsentDraft = nil
        clearActionApproval()
        self.resourceRegistry = nil
        await capabilityBroker.revokeAll()
    }

    private func clearActionApproval() {
        pendingActionApproval = nil
        approvedActionApproval = nil
        consumedNativeAction = nil
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func kind(for type: NativeResourceType) -> AgentResourceKind {
        switch type {
        case .bookmarkPlan: .bookmarkPlan
        case .bookmarkTransaction: .bookmarkTransaction
        case .tabBatch: .tabBatch
        case .download: .download
        }
    }

    private static func isReadOnlyGrant(_ grant: TaskGrant) -> Bool {
        guard grant.riskCeiling == .readOnly,
              !grant.bookmarkScope.mayWrite,
              !grant.downloadScope.mayStartDownloads,
              !grant.tabScope.mayCreateTabs
        else { return false }
        return grant.allowedTools.allSatisfy {
            (try? AgentToolCatalog.risk(for: $0)) == .readOnly
        }
    }
}

public struct AuditEvent: Codable, Equatable, Sendable {
    public let eventID: UUID
    public let taskID: UUID
    public let timestamp: Date
    public let state: AgentState
    public let tool: String?
    public let resultCode: String
    public let evidenceDigest: String?
}

public struct Checkpoint: Codable, Equatable, Sendable {
    public let checkpointID: UUID
    public let taskID: UUID
    public let timestamp: Date
    public let state: AgentState
    public let redactedGoalSummary: String
    public let lastActionID: UUID?
    public let reconciliationReference: String?
    public let undoRecordID: UUID?
}

public struct UndoRecord: Codable, Equatable, Sendable {
    public let undoRecordID: UUID
    public let taskID: UUID
    public let createdAt: Date
    public let expiresAt: Date
    public let transactionID: UUID
    public let encryptedInversePayload: Data
    public let consumedAt: Date?
}

public struct UndoLineage: Codable, Equatable, Sendable {
    public let originalTaskID: UUID
    public let originalGrantID: UUID
    public let transactionID: UUID
    public let rootID: UUID
    public let treeBeforeDigest: String
    public let treeAfterDigest: String
    public let confirmationDigest: String

    public init(
        originalTaskID: UUID,
        originalGrantID: UUID,
        transactionID: UUID,
        rootID: UUID,
        treeBeforeDigest: String,
        treeAfterDigest: String,
        confirmationDigest: String
    ) {
        self.originalTaskID = originalTaskID
        self.originalGrantID = originalGrantID
        self.transactionID = transactionID
        self.rootID = rootID
        self.treeBeforeDigest = treeBeforeDigest
        self.treeAfterDigest = treeAfterDigest
        self.confirmationDigest = confirmationDigest
    }
}
