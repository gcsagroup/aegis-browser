import CryptoKit
import Foundation

public struct WebActionTarget: Codable, Equatable, Sendable {
    public let leaseID: UUID
    public let browserSessionID: UUID
    public let webViewID: UUID
    public let tabID: UUID
    public let frameID: String
    public let topOrigin: String
    public let frameOrigin: String
    public let navigationEpoch: UInt64
    public let documentNonce: String
    public let callSequence: UInt64
    public let documentDigest: String
    public let nodeFingerprint: String
}

public enum NativeResourceType: String, Codable, Sendable {
    case bookmarkPlan
    case bookmarkTransaction
    case tabBatch
    case download
}

public struct NativeActionTarget: Codable, Equatable, Sendable {
    public let resourceType: NativeResourceType
    public let registryRevision: UInt64
    public let resourceID: UUID
}

public enum ActionTarget: Codable, Equatable, Sendable {
    case web(WebActionTarget)
    case native(NativeActionTarget)
}

public struct ActionCapability: Equatable, Sendable {
    public let token: UUID
    public let taskID: UUID
    public let grantID: UUID
    public let profileID: UUID
    public let processInstanceID: UUID
    public let surface: AgentSurface
    public let policyVersion: String
    public let tool: String
    public let normalizedParameters: String
    public let callSequence: UInt64
    public let target: ActionTarget
    public let confirmationDigest: String?
    public let actionDigest: String
    public let expiresAt: Date
}

enum AgentToolCatalog {
    private static let risks: [String: AgentRisk] = [
        "page.observe": .readOnly,
        "page.extract": .readOnly,
        "url.health": .readOnly,
        "bookmarks.list": .readOnly,
        "bookmarks.plan": .readOnly,
        "bookmarks.apply": .localReversible,
        "bookmarks.undo": .localReversible,
        "downloads.verify": .readOnly,
        "downloads.start": .externalOrSensitive,
        "downloads.cancel": .localReversible,
        "browser.tabs.create": .localReversible,
        "page.click": .externalOrSensitive,
    ]

    static func risk(for tool: String) throws -> AgentRisk {
        guard let risk = risks[tool] else { throw AgentContractError.toolDenied }
        return risk
    }
}

actor ActionCapabilityBroker {
    private let processInstanceID: UUID
    private var issued: [UUID: ActionCapability] = [:]

    init(processInstanceID: UUID = UUID()) {
        self.processInstanceID = processInstanceID
    }

    func issue(
        grant: TaskGrant,
        tool: String,
        normalizedParameters: String,
        callSequence: UInt64,
        target: ActionTarget,
        documentLease: DocumentLease? = nil,
        registrySnapshot: ResourceRegistrySnapshot? = nil,
        confirmationDigest: String? = nil,
        ttl: TimeInterval = 30,
        now: Date = Date()
    ) throws -> ActionCapability {
        let canonicalParameters = try AgentContractCodec.canonicalNormalizedParameters(
            normalizedParameters
        )
        let risk = try validateApprovalCandidate(
            grant: grant,
            tool: tool,
            callSequence: callSequence,
            target: target,
            documentLease: documentLease,
            registrySnapshot: registrySnapshot,
            now: now
        )
        if risk == .localReversible || risk == .externalOrSensitive {
            guard let confirmationDigest, !confirmationDigest.isEmpty else {
                throw AgentContractError.capabilityMismatch
            }
        }

        let boundedTTL = max(0.001, min(ttl, 30))
        var expiresAt = min(now.addingTimeInterval(boundedTTL), grant.expiresAt)
        if let documentLease {
            expiresAt = min(expiresAt, documentLease.expiresAt)
        }
        let digestData = try AgentContractCodec.actionDigestData(
            taskID: grant.taskID,
            grantID: grant.grantID,
            profileID: grant.profileID,
            processInstanceID: processInstanceID,
            surface: grant.surface,
            policyVersion: grant.policyVersion,
            tool: tool,
            normalizedParameters: canonicalParameters,
            callSequence: callSequence,
            target: target,
            confirmationDigest: confirmationDigest,
            expiresAt: expiresAt
        )
        let capability = ActionCapability(
            token: UUID(),
            taskID: grant.taskID,
            grantID: grant.grantID,
            profileID: grant.profileID,
            processInstanceID: processInstanceID,
            surface: grant.surface,
            policyVersion: grant.policyVersion,
            tool: tool,
            normalizedParameters: canonicalParameters,
            callSequence: callSequence,
            target: target,
            confirmationDigest: confirmationDigest,
            actionDigest: Self.digest(digestData),
            expiresAt: expiresAt
        )
        issued[capability.token] = capability
        return capability
    }

    /// 在最终 target 已登记后预校验批准对象，但不签发可执行能力。
    func validateApprovalCandidate(
        grant: TaskGrant,
        tool: String,
        callSequence: UInt64,
        target: ActionTarget,
        documentLease: DocumentLease? = nil,
        registrySnapshot: ResourceRegistrySnapshot? = nil,
        now: Date = Date()
    ) throws -> AgentRisk {
        let origin: String
        switch target {
        case let .web(webTarget):
            guard let documentLease, documentLease.processInstanceID == processInstanceID,
                  documentLease.leaseID == webTarget.leaseID,
                  documentLease.browserSessionID == webTarget.browserSessionID,
                  documentLease.webViewID == webTarget.webViewID,
                  documentLease.tabID == webTarget.tabID,
                  documentLease.frameID == webTarget.frameID,
                  documentLease.committedTopOrigin == webTarget.topOrigin,
                  documentLease.frameOrigin == webTarget.frameOrigin,
                  documentLease.navigationEpoch == webTarget.navigationEpoch,
                  documentLease.documentNonce == webTarget.documentNonce,
                  documentLease.callSequence == callSequence,
                  webTarget.callSequence == callSequence,
                  registrySnapshot == nil
            else { throw AgentContractError.invalidLease }
            try documentLease.validate(grant: grant, now: now)
            origin = webTarget.topOrigin
        case let .native(nativeTarget):
            guard documentLease == nil, let registrySnapshot else {
                throw AgentContractError.capabilityMismatch
            }
            try Self.validateNative(
                nativeTarget,
                tool: tool,
                grant: grant,
                snapshot: registrySnapshot
            )
            origin = grant.allowedTopOrigins.sorted().first ?? "aegis://native"
        }
        let risk = try AgentToolCatalog.risk(for: tool)
        try grant.validate(tool: tool, topOrigin: origin, risk: risk, now: now)
        return risk
    }

    func consume(
        _ presented: ActionCapability,
        expectedTool: String,
        expectedParameters: String,
        expectedTarget: ActionTarget,
        registrySnapshot: ResourceRegistrySnapshot? = nil,
        now: Date = Date()
    ) throws {
        // 先移除再核对，保证每次执行尝试都只能消费一次，失败也不能重放。
        guard let stored = issued.removeValue(forKey: presented.token) else {
            throw AgentContractError.capabilityAlreadyConsumed
        }
        guard now < stored.expiresAt else { throw AgentContractError.capabilityExpired }
        let canonicalExpectedParameters = try AgentContractCodec.canonicalNormalizedParameters(
            expectedParameters
        )
        guard stored == presented,
              stored.processInstanceID == processInstanceID,
              stored.tool == expectedTool,
              stored.normalizedParameters == canonicalExpectedParameters,
              stored.target == expectedTarget
        else { throw AgentContractError.capabilityMismatch }
        switch stored.target {
        case let .native(target):
            guard let registrySnapshot else { throw AgentContractError.capabilityMismatch }
            _ = try Self.validateNative(
                target,
                tool: stored.tool,
                grantTaskID: stored.taskID,
                grantID: stored.grantID,
                snapshot: registrySnapshot
            )
        case .web:
            guard registrySnapshot == nil else { throw AgentContractError.capabilityMismatch }
        }
    }

    func revokeAll() {
        issued.removeAll()
    }

    func pendingCount() -> Int {
        issued.count
    }

    private static func digest(_ data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validateNative(
        _ target: NativeActionTarget,
        tool: String,
        grant: TaskGrant,
        snapshot: ResourceRegistrySnapshot
    ) throws {
        let resource = try validateNative(
            target,
            tool: tool,
            grantTaskID: grant.taskID,
            grantID: grant.grantID,
            snapshot: snapshot
        )
        switch target.resourceType {
        case .bookmarkPlan, .bookmarkTransaction:
            guard grant.bookmarkScope.mayWrite,
                  let scopeRootID = resource.scopeRootID,
                  grant.bookmarkScope.rootIDs.contains(scopeRootID)
            else { throw AgentContractError.toolDenied }
        case .tabBatch:
            guard grant.tabScope.mayCreateTabs else { throw AgentContractError.toolDenied }
        case .download:
            guard grant.downloadScope.mayStartDownloads
                    || grant.downloadScope.approvedExistingIDs.contains(target.resourceID)
            else { throw AgentContractError.toolDenied }
        }
    }

    private static func validateNative(
        _ target: NativeActionTarget,
        tool: String,
        grantTaskID: UUID,
        grantID: UUID,
        snapshot: ResourceRegistrySnapshot
    ) throws -> AgentResource {
        guard snapshot.revision == target.registryRevision else {
            throw AgentContractError.staleResourceRevision
        }
        let expectedKind: AgentResourceKind
        let expectedTools: Set<String>
        switch target.resourceType {
        case .bookmarkPlan:
            expectedKind = .bookmarkPlan
            expectedTools = ["bookmarks.apply"]
        case .bookmarkTransaction:
            expectedKind = .bookmarkTransaction
            expectedTools = ["bookmarks.undo"]
        case .tabBatch:
            expectedKind = .tabBatch
            expectedTools = ["browser.tabs.create"]
        case .download:
            expectedKind = .download
            expectedTools = ["downloads.start", "downloads.cancel"]
        }
        guard expectedTools.contains(tool),
              let resource = snapshot.resources.first(where: { $0.id == target.resourceID }),
              resource.kind == expectedKind,
              resource.state == .active,
              resource.ownerTaskID == grantTaskID,
              resource.ownerGrantID == grantID
        else { throw AgentContractError.capabilityMismatch }
        return resource
    }
}
