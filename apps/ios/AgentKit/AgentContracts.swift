import Foundation

public enum AgentState: String, Codable, CaseIterable, Sendable {
    case draft = "Draft"
    case planning = "Planning"
    case awaitingTaskConsent = "AwaitingTaskConsent"
    case running = "Running"
    case reflecting = "Reflecting"
    case awaitingActionApproval = "AwaitingActionApproval"
    case pausedByUser = "PausedByUser"
    case userTakeover = "UserTakeover"
    case recovering = "Recovering"
    case verifying = "Verifying"
    case completed = "Completed"
    case failed = "Failed"
    case cancelled = "Cancelled"
    case expired = "Expired"
}

public enum AgentRisk: Int, Codable, Comparable, Sendable {
    case readOnly = 0
    case localReversible = 1
    case externalOrSensitive = 2
    case userOnly = 3

    public static func < (lhs: AgentRisk, rhs: AgentRisk) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum AgentSurface: String, Codable, Sendable {
    case aegisBrowser
    case safariReadOnly
}

public enum AgentContractError: Error, Equatable, LocalizedError, Sendable {
    case invalidState
    case privateProfileDenied
    case consentRequired
    case expiredGrant
    case unsupportedVersion
    case toolDenied
    case originDenied
    case riskExceeded
    case invalidLease
    case staleResourceRevision
    case capabilityExpired
    case capabilityAlreadyConsumed
    case capabilityMismatch
    case invalidTransition
    case resourceReuse
    case unknownResource

    public var errorDescription: String? {
        switch self {
        case .invalidState: "当前任务状态不允许此操作"
        case .privateProfileDenied: "私密浏览不启用 Agent"
        case .consentRequired: "需要先取得任务授权"
        case .expiredGrant: "任务授权已过期"
        case .unsupportedVersion: "合同或策略版本不受支持"
        case .toolDenied: "工具不在授权范围内"
        case .originDenied: "页面来源不在授权范围内"
        case .riskExceeded: "动作风险超过授权上限"
        case .invalidLease: "页面身份已变化，请重新确认"
        case .staleResourceRevision: "浏览器资源已变化，请重新预览"
        case .capabilityExpired: "动作确认已过期"
        case .capabilityAlreadyConsumed: "动作确认已使用或不存在"
        case .capabilityMismatch: "动作与确认内容不一致"
        case .invalidTransition: "资源状态变化不合法"
        case .resourceReuse: "资源 ID 不允许复用"
        case .unknownResource: "资源不存在"
        }
    }
}

public struct ModelDestination: Codable, Equatable, Sendable {
    public let provider: String
    public let exactHTTPSHost: String
    public let purpose: String
    public let dataClasses: Set<String>
    public let maxRequestBytes: Int

    public init(
        provider: String,
        exactHTTPSHost: String,
        purpose: String,
        dataClasses: Set<String>,
        maxRequestBytes: Int
    ) {
        self.provider = provider
        self.exactHTTPSHost = exactHTTPSHost
        self.purpose = purpose
        self.dataClasses = dataClasses
        self.maxRequestBytes = maxRequestBytes
    }
}

public struct TabScope: Codable, Equatable, Sendable {
    public let approvedExistingTabIDs: Set<UUID>
    public let mayCreateTabs: Bool

    public init(approvedExistingTabIDs: Set<UUID>, mayCreateTabs: Bool) {
        self.approvedExistingTabIDs = approvedExistingTabIDs
        self.mayCreateTabs = mayCreateTabs
    }
}

public struct BookmarkScope: Codable, Equatable, Sendable {
    public let rootIDs: Set<UUID>
    public let mayWrite: Bool

    public init(rootIDs: Set<UUID>, mayWrite: Bool) {
        self.rootIDs = rootIDs
        self.mayWrite = mayWrite
    }
}

public struct DownloadScope: Codable, Equatable, Sendable {
    public let approvedExistingIDs: Set<UUID>
    public let mayStartDownloads: Bool

    public init(approvedExistingIDs: Set<UUID>, mayStartDownloads: Bool) {
        self.approvedExistingIDs = approvedExistingIDs
        self.mayStartDownloads = mayStartDownloads
    }
}

public struct TaskGrant: Codable, Equatable, Sendable {
    public static let supportedContractVersion = 1

    public let contractVersion: Int
    public let taskID: UUID
    public let grantID: UUID
    public let surface: AgentSurface
    public let profileID: UUID
    public let allowedTopOrigins: Set<String>
    public let allowedFrameOrigins: Set<String>
    public let allowedTools: Set<String>
    public let dataClasses: Set<String>
    public let riskCeiling: AgentRisk
    public let maxSteps: Int
    public let timeBudgetSeconds: Int
    public let byteBudget: Int
    public let costBudget: Decimal
    public let tabScope: TabScope
    public let bookmarkScope: BookmarkScope
    public let downloadScope: DownloadScope
    public let expiresAt: Date
    public let policyVersion: String
    public let modelVersion: String
    public let modelDestination: ModelDestination?

    public init(
        contractVersion: Int = TaskGrant.supportedContractVersion,
        taskID: UUID,
        grantID: UUID,
        surface: AgentSurface,
        profileID: UUID,
        allowedTopOrigins: Set<String>,
        allowedFrameOrigins: Set<String> = [],
        allowedTools: Set<String>,
        dataClasses: Set<String>,
        riskCeiling: AgentRisk,
        maxSteps: Int,
        timeBudgetSeconds: Int,
        byteBudget: Int,
        costBudget: Decimal,
        tabScope: TabScope,
        bookmarkScope: BookmarkScope,
        downloadScope: DownloadScope,
        expiresAt: Date,
        policyVersion: String,
        modelVersion: String,
        modelDestination: ModelDestination?
    ) {
        self.contractVersion = contractVersion
        self.taskID = taskID
        self.grantID = grantID
        self.surface = surface
        self.profileID = profileID
        self.allowedTopOrigins = allowedTopOrigins
        self.allowedFrameOrigins = allowedFrameOrigins
        self.allowedTools = allowedTools
        self.dataClasses = dataClasses
        self.riskCeiling = riskCeiling
        self.maxSteps = maxSteps
        self.timeBudgetSeconds = timeBudgetSeconds
        self.byteBudget = byteBudget
        self.costBudget = costBudget
        self.tabScope = tabScope
        self.bookmarkScope = bookmarkScope
        self.downloadScope = downloadScope
        self.expiresAt = expiresAt
        self.policyVersion = policyVersion
        self.modelVersion = modelVersion
        self.modelDestination = modelDestination
    }

    public func validate(tool: String, topOrigin: String, risk: AgentRisk, now: Date = Date()) throws {
        guard contractVersion == Self.supportedContractVersion else {
            throw AgentContractError.unsupportedVersion
        }
        guard now < expiresAt else { throw AgentContractError.expiredGrant }
        guard allowedTools.contains(tool) else { throw AgentContractError.toolDenied }
        guard allowedTopOrigins.contains(topOrigin) else { throw AgentContractError.originDenied }
        guard risk <= riskCeiling else { throw AgentContractError.riskExceeded }
    }
}

public struct DocumentLease: Codable, Equatable, Sendable {
    public let leaseID: UUID
    public let taskID: UUID
    public let grantID: UUID
    public let profileID: UUID
    public let processInstanceID: UUID
    public let browserSessionID: UUID
    public let webViewID: UUID
    public let tabID: UUID
    public let frameID: String
    public let committedTopOrigin: String
    public let frameOrigin: String
    public let navigationEpoch: UInt64
    public let documentNonce: String
    public let callSequence: UInt64
    public let expiresAt: Date

    public func validate(grant: TaskGrant, now: Date = Date()) throws {
        guard now < expiresAt else { throw AgentContractError.invalidLease }
        let frameAllowed = frameOrigin == committedTopOrigin
            || grant.allowedFrameOrigins.contains(frameOrigin)
        guard taskID == grant.taskID,
              grantID == grant.grantID,
              profileID == grant.profileID,
              grant.allowedTopOrigins.contains(committedTopOrigin),
              frameAllowed,
              !documentNonce.isEmpty
        else { throw AgentContractError.invalidLease }
    }
}

public struct ConsentDraft: Equatable, Sendable {
    public let goal: String
    public let origins: [String]
    public let tools: [String]
    public let dataClasses: [String]
    public let risk: AgentRisk
    public let maxSteps: Int
    public let timeBudgetSeconds: Int

    public init(
        goal: String,
        origins: [String],
        tools: [String],
        dataClasses: [String],
        risk: AgentRisk,
        maxSteps: Int,
        timeBudgetSeconds: Int
    ) {
        self.goal = goal
        self.origins = origins
        self.tools = tools
        self.dataClasses = dataClasses
        self.risk = risk
        self.maxSteps = maxSteps
        self.timeBudgetSeconds = timeBudgetSeconds
    }
}

public struct PendingActionApproval: Equatable, Sendable {
    public let approvalID: UUID
    public let expiresAt: Date
    public let grant: TaskGrant
    public let taskID: UUID
    public let grantID: UUID
    public let profileID: UUID
    public let surface: AgentSurface
    public let policyVersion: String
    public let tool: String
    public let normalizedParameters: String
    public let callSequence: UInt64
    public let target: ActionTarget
    public let risk: AgentRisk
    public let confirmationDigest: String
}
