import Foundation

public enum AgentResourceKind: String, Codable, Sendable {
    case tab
    case download
    case bookmarkSnapshot
    case bookmarkPlan
    case bookmarkTransaction
    case tabBatch
}

public enum AgentResourceState: String, Codable, Sendable {
    case active
    case completed
    case cancelled
    case closed
}

public struct AgentResource: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: AgentResourceKind
    /// 收藏资源实际所属的树根。资源 ID 与授权根必须保持独立。
    public let scopeRootID: UUID?
    public let ownerTaskID: UUID
    public let ownerGrantID: UUID
    public let createdAt: Date
    public let state: AgentResourceState

    public func replacingState(_ newState: AgentResourceState) -> AgentResource {
        AgentResource(
            id: id,
            kind: kind,
            scopeRootID: scopeRootID,
            ownerTaskID: ownerTaskID,
            ownerGrantID: ownerGrantID,
            createdAt: createdAt,
            state: newState
        )
    }
}

public struct ResourceRegistrySnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let resources: [AgentResource]
}

public actor ResourceRegistry {
    private let taskID: UUID
    private let grantID: UUID
    private var resources: [UUID: AgentResource] = [:]
    private var retiredIDs: Set<UUID> = []
    private var revision: UInt64 = 0

    public init(taskID: UUID, grantID: UUID) {
        self.taskID = taskID
        self.grantID = grantID
    }

    @discardableResult
    public func append(
        id: UUID = UUID(),
        kind: AgentResourceKind,
        scopeRootID: UUID? = nil,
        now: Date = Date()
    ) throws -> UInt64 {
        guard resources[id] == nil, !retiredIDs.contains(id) else {
            throw AgentContractError.resourceReuse
        }
        resources[id] = AgentResource(
            id: id,
            kind: kind,
            scopeRootID: scopeRootID,
            ownerTaskID: taskID,
            ownerGrantID: grantID,
            createdAt: now,
            state: .active
        )
        revision += 1
        return revision
    }

    @discardableResult
    public func transition(id: UUID, to state: AgentResourceState) throws -> UInt64 {
        guard let current = resources[id] else { throw AgentContractError.unknownResource }
        guard current.state == .active, state != .active else {
            throw AgentContractError.invalidTransition
        }
        resources[id] = current.replacingState(state)
        retiredIDs.insert(id)
        revision += 1
        return revision
    }

    public func containsActive(id: UUID, kind: AgentResourceKind) -> Bool {
        resources[id]?.kind == kind && resources[id]?.state == .active
    }

    /// 仅在资源仍属于同一 task/grant、且注册表没有发生任何变化时完成资源。
    /// 返回 false 代表调用方必须进入恢复路径，不能把任务标记为 Completed。
    public func completeIfActive(
        id: UUID,
        kind: AgentResourceKind,
        ownerTaskID: UUID,
        ownerGrantID: UUID,
        expectedRevision: UInt64
    ) -> Bool {
        guard revision == expectedRevision,
              let current = resources[id],
              current.kind == kind,
              current.ownerTaskID == ownerTaskID,
              current.ownerGrantID == ownerGrantID,
              current.state == .active
        else { return false }

        resources[id] = current.replacingState(.completed)
        retiredIDs.insert(id)
        revision += 1
        return true
    }

    public func snapshot() -> ResourceRegistrySnapshot {
        ResourceRegistrySnapshot(
            revision: revision,
            resources: resources.values.sorted { $0.createdAt < $1.createdAt }
        )
    }
}
