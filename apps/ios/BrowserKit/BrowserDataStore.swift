import AegisPolicyKit
import CryptoKit
import Foundation
import Security

public struct BrowserHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let url: String
    public let visitedAt: Date

    public init(id: UUID = UUID(), title: String, url: String, visitedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.visitedAt = visitedAt
    }
}

public struct BrowserBookmark: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var url: String
    public let createdAt: Date

    public init(id: UUID = UUID(), title: String, url: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = createdAt
    }
}

public struct BookmarkOrganizationPlan: Equatable, Sendable {
    public let planID: UUID
    public let transactionID: UUID
    public let rootID: UUID
    public let beforeDigest: String
    public let afterDigest: String
    public let beforeCount: Int
    public let afterCount: Int
    public let proposedBookmarks: [BrowserBookmark]
    public let changedBookmarkIDs: [UUID]
    public let removedDuplicateIDs: [UUID]
    let baseRevision: UInt64
    let baseMutationID: UUID?

    public var hasChanges: Bool { beforeDigest != afterDigest }
    public var changedCount: Int { changedBookmarkIDs.count }
    public var removedDuplicateCount: Int { removedDuplicateIDs.count }

    /// Broker 对这段排序稳定的完整参数做动作批准摘要；Store 本身不充当批准方。
    public var canonicalApplyParameters: String {
        "{\"after_count\":\(afterCount),\"before_count\":\(beforeCount),"
            + "\"changed_count\":\(changedCount),\"operation\":\"apply\","
            + "\"plan_id\":\"\(planID.uuidString.lowercased())\","
            + "\"removed_duplicate_count\":\(removedDuplicateCount),"
            + "\"root_id\":\"\(rootID.uuidString.lowercased())\","
            + "\"transaction_id\":\"\(transactionID.uuidString.lowercased())\","
            + "\"tree_after\":\"\(afterDigest)\",\"tree_before\":\"\(beforeDigest)\"}"
    }
}

public struct BookmarkTransactionReceipt: Equatable, Sendable {
    public let planID: UUID
    public let transactionID: UUID
    public let rootID: UUID
    public let beforeDigest: String
    public let afterDigest: String
    public let beforeCount: Int
    public let afterCount: Int
    public let changedBookmarkIDs: [UUID]
    public let removedDuplicateIDs: [UUID]
}

public enum BookmarkTransactionError: Error, Equatable, LocalizedError {
    case duplicateBookmarkID(UUID)
    case invalidPlan
    case transactionAlreadyExists(UUID)
    case transactionNotFound(UUID)
    case transactionAlreadyUndone(UUID)
    case stateDiverged(expected: String, actual: String)
    case persistenceFailed
    case journalCorrupted
    case unsupportedJournalVersion
    case recoveryRequired
    case storageCorrupted
    case unsupportedStorageVersion

    public var errorDescription: String? {
        switch self {
        case let .duplicateBookmarkID(id):
            "收藏中存在重复 ID：\(id.uuidString.lowercased())"
        case .invalidPlan:
            "收藏整理计划校验失败"
        case let .transactionAlreadyExists(id):
            "收藏事务已存在：\(id.uuidString.lowercased())"
        case let .transactionNotFound(id):
            "找不到收藏事务：\(id.uuidString.lowercased())"
        case let .transactionAlreadyUndone(id):
            "收藏事务已经撤销：\(id.uuidString.lowercased())"
        case .stateDiverged:
            "收藏状态已变化，已拒绝覆盖当前内容"
        case .persistenceFailed:
            "收藏数据持久化失败"
        case .journalCorrupted:
            "收藏撤销日志损坏或被篡改"
        case .unsupportedJournalVersion:
            "收藏撤销日志版本不受支持"
        case .recoveryRequired:
            "收藏事务持久化未完成，需要重启恢复"
        case .storageCorrupted:
            "收藏数据损坏或被篡改"
        case .unsupportedStorageVersion:
            "收藏数据版本不受支持"
        }
    }
}

enum BookmarkPersistenceCheckpoint: Equatable {
    case recordData
    case clearHistoryData
    case externalData
    case externalPrepareJournal
    case applyPrepareJournal
    case applyData
    case undoPrepareJournal
    case undoData
    case postReplaceFileProtection
}

@MainActor
public final class BrowserDataStore: ObservableObject {
    /// 当前收藏模型是单一有序根列表；固定 ID 让计划、授权和事务可绑定到同一逻辑根。
    public static let stableBookmarkRootID = UUID(
        uuidString: "7d862e89-6cb4-4f30-a21f-a0919bb91de6"
    )!
    private static let maximumPayloadBytes = 8 * 1_024 * 1_024
    private static let maximumJournalEnvelopeBytes = 24 * 1_024 * 1_024
    private static let maximumJournalPlaintextBytes = 16 * 1_024 * 1_024
    private static let maximumRollbackHeadBytes = 64 * 1_024

    @Published public private(set) var history: [BrowserHistoryEntry] = []
    @Published public private(set) var bookmarks: [BrowserBookmark] = []

    public var bookmarkRootID: UUID { Self.stableBookmarkRootID }

    private struct BookmarkTransactionRecord {
        let receipt: BookmarkTransactionReceipt
        let beforeBookmarks: [BrowserBookmark]
        var wasUndone: Bool
    }

    private enum JournalTransactionStatus: String, Codable {
        case committed
        case undone
    }

    private enum JournalTransitionKind: String, Codable {
        case applying
        case undoing
    }

    private struct JournalTransaction: Codable, Equatable {
        let planId: UUID
        let transactionId: UUID
        let rootId: UUID
        let beforeDigest: String
        let afterDigest: String
        let beforeCount: Int
        let afterCount: Int
        let changedBookmarkIds: [UUID]
        let removedDuplicateIds: [UUID]
        let beforeBookmarks: [BrowserBookmark]
        let afterBookmarks: [BrowserBookmark]
        let baseRevision: UInt64
        let baseMutationId: UUID?
        let baseMutation: BookmarkMutation?
        let appliedRevision: UInt64
        let appliedMutationId: UUID
        let undoneRevision: UInt64?
        let undoneMutationId: UUID?
        let status: JournalTransactionStatus

        // Swift 的 snake_case 策略不能对 `ID/IDs` 正确往返；仅持久化 `Id/Ids` 字段。
        var planID: UUID { planId }
        var transactionID: UUID { transactionId }
        var rootID: UUID { rootId }
        var baseMutationID: UUID? { baseMutationId }
        var appliedMutationID: UUID { appliedMutationId }
        var undoneMutationID: UUID? { undoneMutationId }

        init(
            planID: UUID,
            transactionID: UUID,
            rootID: UUID,
            beforeDigest: String,
            afterDigest: String,
            beforeCount: Int,
            afterCount: Int,
            changedBookmarkIds: [UUID],
            removedDuplicateIds: [UUID],
            beforeBookmarks: [BrowserBookmark],
            afterBookmarks: [BrowserBookmark],
            baseRevision: UInt64,
            baseMutationID: UUID?,
            baseMutation: BookmarkMutation?,
            appliedRevision: UInt64,
            appliedMutationID: UUID,
            undoneRevision: UInt64?,
            undoneMutationID: UUID?,
            status: JournalTransactionStatus
        ) {
            planId = planID
            transactionId = transactionID
            rootId = rootID
            self.beforeDigest = beforeDigest
            self.afterDigest = afterDigest
            self.beforeCount = beforeCount
            self.afterCount = afterCount
            self.changedBookmarkIds = changedBookmarkIds
            self.removedDuplicateIds = removedDuplicateIds
            self.beforeBookmarks = beforeBookmarks
            self.afterBookmarks = afterBookmarks
            self.baseRevision = baseRevision
            baseMutationId = baseMutationID
            self.baseMutation = baseMutation
            self.appliedRevision = appliedRevision
            appliedMutationId = appliedMutationID
            self.undoneRevision = undoneRevision
            undoneMutationId = undoneMutationID
            self.status = status
        }

        var receipt: BookmarkTransactionReceipt {
            BookmarkTransactionReceipt(
                planID: planID,
                transactionID: transactionID,
                rootID: rootID,
                beforeDigest: beforeDigest,
                afterDigest: afterDigest,
                beforeCount: beforeCount,
                afterCount: afterCount,
                changedBookmarkIDs: changedBookmarkIds,
                removedDuplicateIDs: removedDuplicateIds
            )
        }

        func markedUndone(revision: UInt64, mutationID: UUID) -> JournalTransaction {
            JournalTransaction(
                planID: planID,
                transactionID: transactionID,
                rootID: rootID,
                beforeDigest: beforeDigest,
                afterDigest: afterDigest,
                beforeCount: beforeCount,
                afterCount: afterCount,
                changedBookmarkIds: changedBookmarkIds,
                removedDuplicateIds: removedDuplicateIds,
                beforeBookmarks: beforeBookmarks,
                afterBookmarks: afterBookmarks,
                baseRevision: baseRevision,
                baseMutationID: baseMutationID,
                baseMutation: baseMutation,
                appliedRevision: appliedRevision,
                appliedMutationID: appliedMutationID,
                undoneRevision: revision,
                undoneMutationID: mutationID,
                status: .undone
            )
        }
    }

    private struct JournalTransition: Codable, Equatable {
        let kind: JournalTransitionKind
        let transaction: JournalTransaction
        let targetRevision: UInt64
        let mutationId: UUID

        var mutationID: UUID { mutationId }

        init(
            kind: JournalTransitionKind,
            transaction: JournalTransaction,
            targetRevision: UInt64,
            mutationID: UUID
        ) {
            self.kind = kind
            self.transaction = transaction
            self.targetRevision = targetRevision
            mutationId = mutationID
        }
    }

    private struct JournalFile: Codable, Equatable {
        let schemaVersion: Int
        let rootId: UUID
        let latest: JournalTransaction?
        let transition: JournalTransition?

        var rootID: UUID { rootId }

        init(
            schemaVersion: Int,
            rootID: UUID,
            latest: JournalTransaction?,
            transition: JournalTransition?
        ) {
            self.schemaVersion = schemaVersion
            rootId = rootID
            self.latest = latest
            self.transition = transition
        }
    }

    private struct JournalEnvelope: Codable {
        let schemaVersion: Int
        let algorithm: String
        let nonce: String
        let ciphertext: String
        let tag: String
    }

    private enum RollbackHeadStatus: String, Codable {
        case committed
        case pending
    }

    private struct RollbackHeadUnsigned: Codable, Equatable {
        let schemaVersion: Int
        let epoch: UInt64
        let status: RollbackHeadStatus
        let digest: String?
        let previousDigest: String?
        let targetDigest: String?
        let operationId: UUID?
    }

    private struct RollbackHeadFile: Codable, Equatable {
        let schemaVersion: Int
        let epoch: UInt64
        let status: RollbackHeadStatus
        let digest: String?
        let previousDigest: String?
        let targetDigest: String?
        let operationId: UUID?
        let authenticationTag: String

        var unsigned: RollbackHeadUnsigned {
            RollbackHeadUnsigned(
                schemaVersion: schemaVersion,
                epoch: epoch,
                status: status,
                digest: digest,
                previousDigest: previousDigest,
                targetDigest: targetDigest,
                operationId: operationId
            )
        }
    }

    private struct RollbackState: Codable {
        let schemaVersion: Int
        let rootId: String
        let rollbackEpoch: UInt64?
        let bookmarkRevision: UInt64
        let bookmarkMutation: BookmarkMutation?
        let historyDigest: String
        let treeDigest: String
        let journalDigest: String?
    }

    private struct RollbackTransitionContext {
        let epoch: UInt64
        let targetDigest: String
        let pendingHead: RollbackHeadFile
    }

    private enum BookmarkMutationKind: String, Codable {
        case external
        case transactionApplied
        case transactionUndone
    }

    private struct BookmarkMutation: Codable, Equatable {
        let kind: BookmarkMutationKind
        let mutationId: UUID
        let transactionId: UUID?
        let rootId: UUID
        let treeDigest: String
        let counterpartDigest: String?

        var mutationID: UUID { mutationId }
        var transactionID: UUID? { transactionId }
        var rootID: UUID { rootId }

        init(
            kind: BookmarkMutationKind,
            mutationID: UUID,
            transactionID: UUID?,
            rootID: UUID,
            treeDigest: String,
            counterpartDigest: String?
        ) {
            self.kind = kind
            mutationId = mutationID
            transactionId = transactionID
            rootId = rootID
            self.treeDigest = treeDigest
            self.counterpartDigest = counterpartDigest
        }

        private enum CodingKeys: String, CodingKey {
            case kind
            case mutationId
            case legacyMutationID = "mutationID"
            case transactionId
            case legacyTransactionID = "transactionID"
            case rootId
            case legacyRootID = "rootID"
            case treeDigest
            case counterpartDigest
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(BookmarkMutationKind.self, forKey: .kind)
            mutationId = try container.decodeIfPresent(UUID.self, forKey: .mutationId)
                ?? container.decode(UUID.self, forKey: .legacyMutationID)
            transactionId = try container.decodeIfPresent(UUID.self, forKey: .transactionId)
                ?? container.decodeIfPresent(UUID.self, forKey: .legacyTransactionID)
            rootId = try container.decodeIfPresent(UUID.self, forKey: .rootId)
                ?? container.decode(UUID.self, forKey: .legacyRootID)
            treeDigest = try container.decode(String.self, forKey: .treeDigest)
            counterpartDigest = try container.decodeIfPresent(
                String.self,
                forKey: .counterpartDigest
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(mutationId, forKey: .mutationId)
            try container.encodeIfPresent(transactionId, forKey: .transactionId)
            try container.encode(rootId, forKey: .rootId)
            try container.encode(treeDigest, forKey: .treeDigest)
            try container.encodeIfPresent(counterpartDigest, forKey: .counterpartDigest)
        }
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let rollbackEpoch: UInt64?
        let bookmarkRevision: UInt64
        let bookmarkMutation: BookmarkMutation?
        let history: [BrowserHistoryEntry]
        let bookmarks: [BrowserBookmark]
    }

    private struct LegacyPayload: Codable {
        let history: [BrowserHistoryEntry]
        let bookmarks: [BrowserBookmark]
    }

    private struct CanonicalBookmark: Codable {
        let createdAtMilliseconds: Int64
        let id: String
        let position: Int
        let title: String
        let url: String
    }

    private struct CanonicalSnapshot: Codable {
        let items: [CanonicalBookmark]
        let rootID: String
        let schemaVersion: Int
    }

    private let persistenceURL: URL?
    private let journalURL: URL?
    private var bookmarkTransactions: [UUID: BookmarkTransactionRecord] = [:]
    private var journalFile: JournalFile?
    private var journalFailure: BookmarkTransactionError?
    private var storageFailure: BookmarkTransactionError?
    private var rollbackHead: RollbackHeadFile?
    private var rollbackEpoch: UInt64?
    private var bookmarkRevision: UInt64 = 0
    private var bookmarkMutation: BookmarkMutation?

    /// 仅供定向测试模拟双文件提交的崩溃窗口；生产默认不注入故障。
    var persistenceFailureInjector: ((BookmarkPersistenceCheckpoint) -> Bool)?

    public init(
        persistenceURL: URL? = BrowserDataStore.defaultPersistenceURL(),
        initialBookmarks: [BrowserBookmark] = []
    ) {
        self.persistenceURL = persistenceURL
        journalURL = persistenceURL.map(Self.bookmarkJournalURL(for:))
        bookmarks = initialBookmarks
        load()
    }

    public func record(title: String, url: URL, isPrivate: Bool) {
        guard !isPrivate, canPersistChanges else { return }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        let redactedURL = components?.url?.absoluteString ?? url.absoluteString
        let candidateHistory = Array(
            ([BrowserHistoryEntry(title: title, url: redactedURL)] + history).prefix(500)
        )
        do {
            let rollback = try beginRollbackTransitionIfPersistent(
                targetHistory: candidateHistory,
                targetBookmarks: bookmarks,
                targetRevision: bookmarkRevision,
                targetMutation: bookmarkMutation,
                targetJournal: journalFile
            )
            try persist(
                history: candidateHistory,
                bookmarks: bookmarks,
                rollbackEpoch: rollback?.epoch,
                checkpoint: .recordData
            )
            if let rollback { try commitRollbackTransition(rollback) }
            history = candidateHistory
            rollbackEpoch = rollback?.epoch ?? rollbackEpoch
        } catch {
            // head pending 可能已写入；冻结至重启按真实磁盘状态收敛。
            if persistenceURL != nil { journalFailure = .recoveryRequired }
        }
    }

    @discardableResult
    public func toggleBookmark(title: String, url: URL, isPrivate: Bool) -> Bool {
        guard !isPrivate else { return false }
        guard canPersistChanges else {
            return bookmarks.contains { $0.url == url.absoluteString }
        }
        var candidateBookmarks = bookmarks
        let wasBookmarked: Bool
        if let index = candidateBookmarks.firstIndex(where: { $0.url == url.absoluteString }) {
            candidateBookmarks.remove(at: index)
            wasBookmarked = false
        } else {
            candidateBookmarks.append(BrowserBookmark(title: title, url: url.absoluteString))
            wasBookmarked = true
        }
        do {
            let nextRevision = try incrementedRevision()
            let mutation = BookmarkMutation(
                kind: .external,
                mutationID: UUID(),
                transactionID: nil,
                rootID: bookmarkRootID,
                treeDigest: try Self.snapshotDigest(candidateBookmarks),
                counterpartDigest: nil
            )
            let rollback = try beginRollbackTransitionIfPersistent(
                targetHistory: history,
                targetBookmarks: candidateBookmarks,
                targetRevision: nextRevision,
                targetMutation: mutation,
                targetJournal: journalFile
            )
            try prepareJournalForExternalBookmarkMutation()
            try persist(
                history: history,
                bookmarks: candidateBookmarks,
                bookmarkRevision: nextRevision,
                bookmarkMutation: mutation,
                rollbackEpoch: rollback?.epoch,
                checkpoint: .externalData
            )
            if let rollback { try commitRollbackTransition(rollback) }
            bookmarks = candidateBookmarks
            bookmarkRevision = nextRevision
            bookmarkMutation = mutation
            rollbackEpoch = rollback?.epoch ?? rollbackEpoch
            return wasBookmarked
        } catch {
            if persistenceURL != nil { journalFailure = .recoveryRequired }
            // 返回实际保留的内存状态；重启将用 head 判定磁盘落在 previous 或 target。
            return bookmarks.contains { $0.url == url.absoluteString }
        }
    }

    public func clearHistory() {
        guard canPersistChanges else { return }
        do {
            let rollback = try beginRollbackTransitionIfPersistent(
                targetHistory: [],
                targetBookmarks: bookmarks,
                targetRevision: bookmarkRevision,
                targetMutation: bookmarkMutation,
                targetJournal: journalFile
            )
            try persist(
                history: [],
                bookmarks: bookmarks,
                rollbackEpoch: rollback?.epoch,
                checkpoint: .clearHistoryData
            )
            if let rollback { try commitRollbackTransition(rollback) }
            history = []
            rollbackEpoch = rollback?.epoch ?? rollbackEpoch
        } catch {
            if persistenceURL != nil { journalFailure = .recoveryRequired }
        }
    }

    public func bookmarkDigest() throws -> String {
        try Self.snapshotDigest(bookmarks)
    }

    public func makeBookmarkOrganizationPlan(
        planID: UUID = UUID(),
        transactionID: UUID = UUID()
    ) throws -> BookmarkOrganizationPlan {
        try ensureStorageHealthy()
        try Self.validateUniqueIDs(bookmarks)
        let beforeDigest = try Self.snapshotDigest(bookmarks)
        let proposedBookmarks = Self.organizedBookmarks(from: bookmarks)
        let afterDigest = try Self.snapshotDigest(proposedBookmarks)

        let summary = Self.changeSummary(before: bookmarks, after: proposedBookmarks)

        return BookmarkOrganizationPlan(
            planID: planID,
            transactionID: transactionID,
            rootID: bookmarkRootID,
            beforeDigest: beforeDigest,
            afterDigest: afterDigest,
            beforeCount: bookmarks.count,
            afterCount: proposedBookmarks.count,
            proposedBookmarks: proposedBookmarks,
            changedBookmarkIDs: summary.changedIDs,
            removedDuplicateIDs: summary.removedIDs,
            baseRevision: bookmarkRevision,
            baseMutationID: bookmarkMutation?.mutationID
        )
    }

    @discardableResult
    public func apply(_ plan: BookmarkOrganizationPlan) throws -> BookmarkTransactionReceipt {
        try ensureStorageHealthy()
        guard plan.rootID == bookmarkRootID,
              bookmarkTransactions[plan.transactionID] == nil,
              plan.afterCount == plan.proposedBookmarks.count,
              try Self.snapshotDigest(plan.proposedBookmarks) == plan.afterDigest
        else {
            if bookmarkTransactions[plan.transactionID] != nil {
                throw BookmarkTransactionError.transactionAlreadyExists(plan.transactionID)
            }
            throw BookmarkTransactionError.invalidPlan
        }
        try Self.validatePlanIdentity(before: bookmarks, after: plan.proposedBookmarks)

        let currentDigest = try bookmarkDigest()
        guard currentDigest == plan.beforeDigest else {
            throw BookmarkTransactionError.stateDiverged(
                expected: plan.beforeDigest,
                actual: currentDigest
            )
        }
        // Digest 先区分普通状态漂移；revision/mutation 再阻断内容相同的 ABA 恢复。
        guard plan.baseRevision == bookmarkRevision,
              plan.baseMutationID == bookmarkMutation?.mutationID
        else { throw BookmarkTransactionError.invalidPlan }
        guard plan.beforeCount == bookmarks.count else {
            throw BookmarkTransactionError.invalidPlan
        }
        let summary = Self.changeSummary(before: bookmarks, after: plan.proposedBookmarks)
        guard summary.changedIDs == plan.changedBookmarkIDs,
              summary.removedIDs == plan.removedDuplicateIDs
        else { throw BookmarkTransactionError.invalidPlan }

        let appliedRevision = try incrementedRevision()
        let appliedMutationID = plan.transactionID

        let receipt = BookmarkTransactionReceipt(
            planID: plan.planID,
            transactionID: plan.transactionID,
            rootID: plan.rootID,
            beforeDigest: plan.beforeDigest,
            afterDigest: plan.afterDigest,
            beforeCount: plan.beforeCount,
            afterCount: plan.afterCount,
            changedBookmarkIDs: plan.changedBookmarkIDs,
            removedDuplicateIDs: plan.removedDuplicateIDs
        )
        let transaction = JournalTransaction(
            planID: receipt.planID,
            transactionID: receipt.transactionID,
            rootID: receipt.rootID,
            beforeDigest: receipt.beforeDigest,
            afterDigest: receipt.afterDigest,
            beforeCount: receipt.beforeCount,
            afterCount: receipt.afterCount,
            changedBookmarkIds: receipt.changedBookmarkIDs,
            removedDuplicateIds: receipt.removedDuplicateIDs,
            beforeBookmarks: bookmarks,
            afterBookmarks: plan.proposedBookmarks,
            baseRevision: bookmarkRevision,
            baseMutationID: bookmarkMutation?.mutationID,
            baseMutation: bookmarkMutation,
            appliedRevision: appliedRevision,
            appliedMutationID: appliedMutationID,
            undoneRevision: nil,
            undoneMutationID: nil,
            status: .committed
        )
        let mutation = BookmarkMutation(
            kind: .transactionApplied,
            mutationID: appliedMutationID,
            transactionID: transaction.transactionID,
            rootID: transaction.rootID,
            treeDigest: transaction.afterDigest,
            counterpartDigest: transaction.beforeDigest
        )

        if persistenceURL != nil {
            do {
                let previousLatest = stableLatestTransaction(for: bookmarks)
                let committed = try makeJournalFile(latest: transaction, transition: nil)
                let applying = try makeJournalFile(
                    latest: previousLatest,
                    transition: JournalTransition(
                        kind: .applying,
                        transaction: transaction,
                        targetRevision: appliedRevision,
                        mutationID: appliedMutationID
                    )
                )
                let rollback = try beginRollbackTransition(
                    targetHistory: history,
                    targetBookmarks: plan.proposedBookmarks,
                    targetRevision: appliedRevision,
                    targetMutation: mutation,
                    targetJournal: committed
                )
                try persistJournal(applying, checkpoint: .applyPrepareJournal)
                // 主数据替换后再提交 Keychain head；任一失败均由 pending head 在重启时收敛。
                try persist(
                    history: history,
                    bookmarks: plan.proposedBookmarks,
                    bookmarkRevision: appliedRevision,
                    bookmarkMutation: mutation,
                    rollbackEpoch: rollback.epoch,
                    checkpoint: .applyData
                )
                try commitRollbackTransition(rollback)
                journalFile = committed
                rollbackEpoch = rollback.epoch
            } catch {
                journalFailure = .recoveryRequired
                throw error
            }
        }
        bookmarkRevision = appliedRevision
        bookmarkMutation = mutation

        // 数据写成功后不再执行可失败持久化步骤，立即发布与磁盘一致的内存状态。
        let record = BookmarkTransactionRecord(
            receipt: receipt,
            beforeBookmarks: bookmarks,
            wasUndone: false
        )
        bookmarks = plan.proposedBookmarks
        bookmarkTransactions = [plan.transactionID: record]
        return receipt
    }

    @discardableResult
    public func undoBookmarkTransaction(
        transactionID: UUID,
        expectedAfterDigest: String
    ) throws -> BookmarkTransactionReceipt {
        try ensureStorageHealthy()
        guard var record = bookmarkTransactions[transactionID] else {
            throw BookmarkTransactionError.transactionNotFound(transactionID)
        }
        guard !record.wasUndone else {
            throw BookmarkTransactionError.transactionAlreadyUndone(transactionID)
        }
        guard expectedAfterDigest == record.receipt.afterDigest else {
            throw BookmarkTransactionError.invalidPlan
        }

        let currentDigest = try bookmarkDigest()
        guard currentDigest == record.receipt.afterDigest else {
            throw BookmarkTransactionError.stateDiverged(
                expected: record.receipt.afterDigest,
                actual: currentDigest
            )
        }
        guard try Self.snapshotDigest(record.beforeBookmarks) == record.receipt.beforeDigest else {
            throw BookmarkTransactionError.invalidPlan
        }

        if persistenceURL != nil {
            guard let latest = journalFile?.latest,
                  latest.transactionID == transactionID,
                  latest.status == .committed,
                  latest.receipt == record.receipt,
                  latest.beforeBookmarks == record.beforeBookmarks,
                  latest.afterBookmarks == bookmarks
            else { throw BookmarkTransactionError.journalCorrupted }
            guard latest.appliedRevision == bookmarkRevision,
                  bookmarkMutation == Self.appliedMutation(for: latest)
            else {
                // 树内容即使被改回相同值，revision/mutation 仍能识别 ABA 漂移。
                throw BookmarkTransactionError.stateDiverged(
                    expected: latest.afterDigest,
                    actual: currentDigest
                )
            }

            do {
                let undoRevision = try incrementedRevision()
                let undoMutationID = UUID()
                let undoneTransaction = latest.markedUndone(
                    revision: undoRevision,
                    mutationID: undoMutationID
                )
                let logicalUndoneJournal = try makeJournalFile(
                    latest: undoneTransaction,
                    transition: nil
                )
                let undoing = try makeJournalFile(
                    latest: latest,
                    transition: JournalTransition(
                        kind: .undoing,
                        transaction: latest,
                        targetRevision: undoRevision,
                        mutationID: undoMutationID
                    )
                )
                let mutation = BookmarkMutation(
                    kind: .transactionUndone,
                    mutationID: undoMutationID,
                    transactionID: latest.transactionID,
                    rootID: latest.rootID,
                    treeDigest: latest.beforeDigest,
                    counterpartDigest: latest.afterDigest
                )
                let rollback = try beginRollbackTransition(
                    targetHistory: history,
                    targetBookmarks: record.beforeBookmarks,
                    targetRevision: undoRevision,
                    targetMutation: mutation,
                    targetJournal: logicalUndoneJournal
                )
                try persistJournal(undoing, checkpoint: .undoPrepareJournal)
                try persist(
                    history: history,
                    bookmarks: record.beforeBookmarks,
                    bookmarkRevision: undoRevision,
                    bookmarkMutation: mutation,
                    rollbackEpoch: rollback.epoch,
                    checkpoint: .undoData
                )
                try commitRollbackTransition(rollback)
                bookmarkRevision = undoRevision
                bookmarkMutation = mutation
                rollbackEpoch = rollback.epoch
                journalFile = logicalUndoneJournal
            } catch {
                journalFailure = .recoveryRequired
                throw error
            }
        } else {
            bookmarkRevision = try incrementedRevision()
            bookmarkMutation = BookmarkMutation(
                kind: .transactionUndone,
                mutationID: UUID(),
                transactionID: transactionID,
                rootID: record.receipt.rootID,
                treeDigest: record.receipt.beforeDigest,
                counterpartDigest: record.receipt.afterDigest
            )
        }

        bookmarks = record.beforeBookmarks
        record.wasUndone = true
        bookmarkTransactions = [transactionID: record]
        return record.receipt
    }

    public func latestUndoableBookmarkTransaction() throws -> BookmarkTransactionReceipt? {
        try ensureStorageHealthy()
        guard let transaction = bookmarkTransactions.values.first,
              !transaction.wasUndone
        else { return nil }
        let currentDigest = try bookmarkDigest()
        guard currentDigest == transaction.receipt.afterDigest else {
            throw BookmarkTransactionError.stateDiverged(
                expected: transaction.receipt.afterDigest,
                actual: currentDigest
            )
        }
        if let latest = journalFile?.latest {
            guard latest.transactionID == transaction.receipt.transactionID,
                  latest.status == .committed,
                  latest.appliedRevision == bookmarkRevision,
                  bookmarkMutation == Self.appliedMutation(for: latest)
            else { throw BookmarkTransactionError.journalCorrupted }
        }
        return transaction.receipt
    }

    private func load() {
        guard let persistenceURL else { return }
        let baselineHistory = history
        let baselineBookmarks = bookmarks
        var isDirectory = ObjCBool(false)
        let payloadExists = FileManager.default.fileExists(
            atPath: persistenceURL.path,
            isDirectory: &isDirectory
        )
        if payloadExists, !isDirectory.boolValue {
            do {
                let payload = try Self.decodePayload(Self.readBoundedFile(
                    at: persistenceURL,
                    maximumBytes: Self.maximumPayloadBytes,
                    oversizedError: .storageCorrupted
                ))
                history = payload.history
                bookmarks = payload.bookmarks
                rollbackEpoch = payload.rollbackEpoch
                bookmarkRevision = payload.bookmarkRevision
                bookmarkMutation = payload.bookmarkMutation
                try Self.validatePayloadMutation(payload)
            } catch let error as BookmarkTransactionError {
                storageFailure = error
                restoreLoadedState(
                    history: baselineHistory,
                    bookmarks: baselineBookmarks
                )
                return
            } catch {
                storageFailure = .storageCorrupted
                restoreLoadedState(
                    history: baselineHistory,
                    bookmarks: baselineBookmarks
                )
                return
            }
        }
        loadAndRecoverJournal()
        guard storageFailure == nil, journalFailure == nil else {
            restoreLoadedState(history: baselineHistory, bookmarks: baselineBookmarks)
            return
        }
        do {
            try loadAndValidateRollbackHead()
            try ensurePersistentFileProtection()
        } catch let error as BookmarkTransactionError {
            journalFailure = error == .persistenceFailed ? .recoveryRequired : error
            restoreLoadedState(history: baselineHistory, bookmarks: baselineBookmarks)
        } catch {
            journalFailure = .journalCorrupted
            restoreLoadedState(history: baselineHistory, bookmarks: baselineBookmarks)
        }
    }

    private func restoreLoadedState(
        history baselineHistory: [BrowserHistoryEntry],
        bookmarks baselineBookmarks: [BrowserBookmark]
    ) {
        history = baselineHistory
        bookmarks = baselineBookmarks
        bookmarkTransactions = [:]
        journalFile = nil
        rollbackHead = nil
        rollbackEpoch = nil
        bookmarkRevision = 0
        bookmarkMutation = nil
    }

    private func persist(
        history candidateHistory: [BrowserHistoryEntry],
        bookmarks candidateBookmarks: [BrowserBookmark],
        bookmarkRevision candidateRevision: UInt64? = nil,
        bookmarkMutation candidateMutation: BookmarkMutation? = nil,
        rollbackEpoch candidateRollbackEpoch: UInt64? = nil,
        checkpoint: BookmarkPersistenceCheckpoint? = nil
    ) throws {
        guard let persistenceURL else { return }
        if let checkpoint, persistenceFailureInjector?(checkpoint) == true {
            throw BookmarkTransactionError.persistenceFailed
        }
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Payload(
                schemaVersion: 1,
                rollbackEpoch: candidateRollbackEpoch ?? rollbackEpoch,
                bookmarkRevision: candidateRevision ?? bookmarkRevision,
                bookmarkMutation: candidateMutation ?? bookmarkMutation,
                history: candidateHistory,
                bookmarks: candidateBookmarks
            ))
            guard data.count <= Self.maximumPayloadBytes else {
                throw BookmarkTransactionError.persistenceFailed
            }
            // 先原子替换，再设置保护属性；测试可精确注入两者之间的真实歧义窗口。
            try data.write(to: persistenceURL, options: [.atomic, .completeFileProtection])
            if persistenceFailureInjector?(.postReplaceFileProtection) == true {
                throw BookmarkTransactionError.persistenceFailed
            }
            try Self.setCompleteFileProtection(at: persistenceURL)
        } catch {
            throw BookmarkTransactionError.persistenceFailed
        }
    }

    private func ensureStorageHealthy() throws {
        if let storageFailure { throw storageFailure }
        if let journalFailure { throw journalFailure }
        if journalFile?.transition != nil { throw BookmarkTransactionError.recoveryRequired }
    }

    private var canPersistChanges: Bool {
        storageFailure == nil && journalFailure == nil && journalFile?.transition == nil
    }

    private func prepareJournalForExternalBookmarkMutation() throws {
        guard persistenceURL != nil, let journalFile else { return }
        try persistJournal(journalFile, checkpoint: .externalPrepareJournal)
    }

    private func stableLatestTransaction(
        for currentBookmarks: [BrowserBookmark]
    ) -> JournalTransaction? {
        guard let latest = journalFile?.latest else { return nil }
        switch latest.status {
        case .committed
            where latest.afterBookmarks == currentBookmarks
                && latest.appliedRevision == bookmarkRevision
                && bookmarkMutation == Self.appliedMutation(for: latest):
            return latest
        case .undone
            where latest.beforeBookmarks == currentBookmarks
                && latest.undoneRevision == bookmarkRevision
                && bookmarkMutation == Self.undoneMutation(for: latest):
            return latest
        default:
            // 用户在事务外修改了收藏后，旧撤销入口失效；新 apply 可成为唯一最新事务。
            return nil
        }
    }

    private static func appliedMutation(for transaction: JournalTransaction) -> BookmarkMutation {
        BookmarkMutation(
            kind: .transactionApplied,
            mutationID: transaction.appliedMutationID,
            transactionID: transaction.transactionID,
            rootID: transaction.rootID,
            treeDigest: transaction.afterDigest,
            counterpartDigest: transaction.beforeDigest
        )
    }

    private static func undoneMutation(for transaction: JournalTransaction) -> BookmarkMutation? {
        guard let revision = transaction.undoneRevision,
              let mutationID = transaction.undoneMutationID
        else { return nil }
        return undoneMutation(for: transaction, revision: revision, mutationID: mutationID)
    }

    private static func undoneMutation(
        for transaction: JournalTransaction,
        revision _: UInt64,
        mutationID: UUID
    ) -> BookmarkMutation {
        BookmarkMutation(
            kind: .transactionUndone,
            mutationID: mutationID,
            transactionID: transaction.transactionID,
            rootID: transaction.rootID,
            treeDigest: transaction.beforeDigest,
            counterpartDigest: transaction.afterDigest
        )
    }

    private static func payloadMatchesStableTransaction(
        _ transaction: JournalTransaction,
        bookmarks: [BrowserBookmark],
        revision: UInt64,
        mutation: BookmarkMutation?
    ) -> Bool {
        switch transaction.status {
        case .committed:
            return bookmarks == transaction.afterBookmarks
                && revision == transaction.appliedRevision
                && mutation == appliedMutation(for: transaction)
        case .undone:
            return bookmarks == transaction.beforeBookmarks
                && revision == transaction.undoneRevision
                && mutation == undoneMutation(for: transaction)
        }
    }

    private func incrementedRevision() throws -> UInt64 {
        let (revision, overflow) = bookmarkRevision.addingReportingOverflow(1)
        guard !overflow else { throw BookmarkTransactionError.persistenceFailed }
        return revision
    }

    private func beginRollbackTransitionIfPersistent(
        targetHistory: [BrowserHistoryEntry],
        targetBookmarks: [BrowserBookmark],
        targetRevision: UInt64,
        targetMutation: BookmarkMutation?,
        targetJournal: JournalFile?
    ) throws -> RollbackTransitionContext? {
        guard persistenceURL != nil else { return nil }
        return try beginRollbackTransition(
            targetHistory: targetHistory,
            targetBookmarks: targetBookmarks,
            targetRevision: targetRevision,
            targetMutation: targetMutation,
            targetJournal: targetJournal
        )
    }

    private func beginRollbackTransition(
        targetHistory: [BrowserHistoryEntry],
        targetBookmarks: [BrowserBookmark],
        targetRevision: UInt64,
        targetMutation: BookmarkMutation?,
        targetJournal: JournalFile?
    ) throws -> RollbackTransitionContext {
        let previousDigest = try rollbackStateDigest(
            history: history,
            bookmarks: bookmarks,
            rollbackEpoch: rollbackEpoch,
            revision: bookmarkRevision,
            mutation: bookmarkMutation,
            journal: journalFile
        )

        if rollbackHead == nil {
            guard rollbackEpoch == nil, journalFile == nil else {
                throw BookmarkTransactionError.journalCorrupted
            }
            let anchor = try makeRollbackHead(
                epoch: 0,
                status: .committed,
                digest: previousDigest
            )
            try persistRollbackHead(anchor)
            rollbackHead = anchor
        }

        guard let currentHead = rollbackHead,
              currentHead.status == .committed,
              currentHead.digest == previousDigest
        else { throw BookmarkTransactionError.journalCorrupted }
        let (nextEpoch, overflow) = currentHead.epoch.addingReportingOverflow(1)
        guard !overflow else { throw BookmarkTransactionError.persistenceFailed }
        let targetDigest = try rollbackStateDigest(
            history: targetHistory,
            bookmarks: targetBookmarks,
            rollbackEpoch: nextEpoch,
            revision: targetRevision,
            mutation: targetMutation,
            journal: targetJournal
        )
        let pending = try makeRollbackHead(
            epoch: nextEpoch,
            status: .pending,
            previousDigest: previousDigest,
            targetDigest: targetDigest,
            operationId: UUID()
        )
        try persistRollbackHead(pending)
        rollbackHead = pending
        return RollbackTransitionContext(
            epoch: nextEpoch,
            targetDigest: targetDigest,
            pendingHead: pending
        )
    }

    private func commitRollbackTransition(_ context: RollbackTransitionContext) throws {
        guard rollbackHead == context.pendingHead else {
            throw BookmarkTransactionError.journalCorrupted
        }
        let committed = try makeRollbackHead(
            epoch: context.epoch,
            status: .committed,
            digest: context.targetDigest
        )
        try persistRollbackHead(committed)
        rollbackHead = committed
    }

    private func loadAndValidateRollbackHead() throws {
        let head = try readRollbackHead()
        let currentDigest = try rollbackStateDigest(
            history: history,
            bookmarks: bookmarks,
            rollbackEpoch: rollbackEpoch,
            revision: bookmarkRevision,
            mutation: bookmarkMutation,
            journal: journalFile
        )
        guard let head else {
            guard rollbackEpoch == nil, journalFile == nil else {
                throw BookmarkTransactionError.journalCorrupted
            }
            rollbackHead = nil
            return
        }

        switch head.status {
        case .committed:
            guard head.digest == currentDigest else {
                throw BookmarkTransactionError.journalCorrupted
            }
            rollbackHead = head
        case .pending:
            guard currentDigest == head.previousDigest || currentDigest == head.targetDigest else {
                throw BookmarkTransactionError.journalCorrupted
            }
            // 先补齐数据保护，再把 Keychain pending 原子收敛到实际磁盘一侧。
            try ensurePersistentFileProtection()
            let committed = try makeRollbackHead(
                epoch: head.epoch,
                status: .committed,
                digest: currentDigest
            )
            do {
                try persistRollbackHead(committed)
            } catch {
                throw BookmarkTransactionError.recoveryRequired
            }
            rollbackHead = committed
        }
    }

    private func rollbackStateDigest(
        history: [BrowserHistoryEntry],
        bookmarks: [BrowserBookmark],
        rollbackEpoch: UInt64?,
        revision: UInt64,
        mutation: BookmarkMutation?,
        journal: JournalFile?
    ) throws -> String {
        let journalDigest: String?
        if let journal, journal.latest != nil || journal.transition != nil {
            journalDigest = try Self.digest(
                journal,
                domain: "aegis-bookmark-logical-journal-v1"
            )
        } else {
            // prepared apply 未提交时会恢复出认证空 journal；语义上等同操作前无 journal。
            journalDigest = nil
        }
        return try Self.digest(
            RollbackState(
                schemaVersion: 1,
                rootId: bookmarkRootID.uuidString.lowercased(),
                rollbackEpoch: rollbackEpoch,
                bookmarkRevision: revision,
                bookmarkMutation: mutation,
                historyDigest: try Self.digest(
                    history,
                    domain: "aegis-browser-history-snapshot-v1"
                ),
                treeDigest: try Self.snapshotDigest(bookmarks),
                journalDigest: journalDigest
            ),
            domain: "aegis-bookmark-rollback-state-v1"
        )
    }

    private static func decodePayload(_ data: Data) throws -> Payload {
        guard data.count <= maximumPayloadBytes else {
            throw BookmarkTransactionError.storageCorrupted
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BookmarkTransactionError.storageCorrupted
        }
        guard let object = raw as? [String: Any] else {
            throw BookmarkTransactionError.storageCorrupted
        }
        let decoder = JSONDecoder()
        if let version = object["schemaVersion"] as? NSNumber {
            guard version.intValue == 1 else {
                throw BookmarkTransactionError.unsupportedStorageVersion
            }
            let requiredKeys: Set<String> = [
                "schemaVersion",
                "bookmarkRevision",
                "history",
                "bookmarks",
            ]
            guard Set(object.keys).isSubset(
                of: requiredKeys.union(["bookmarkMutation", "rollbackEpoch"])
            ),
                  requiredKeys.isSubset(of: Set(object.keys))
            else { throw BookmarkTransactionError.storageCorrupted }
            try validatePayloadJSONShape(object)
            do {
                return try decoder.decode(Payload.self, from: data)
            } catch {
                throw BookmarkTransactionError.storageCorrupted
            }
        }

        // 旧版仅含 history/bookmarks；首次后续写入会升级到 v1 envelope。
        guard Set(object.keys) == ["history", "bookmarks"] else {
            throw BookmarkTransactionError.storageCorrupted
        }
        try validatePayloadJSONShape(object)
        do {
            let legacy = try decoder.decode(LegacyPayload.self, from: data)
            return Payload(
                schemaVersion: 1,
                rollbackEpoch: nil,
                bookmarkRevision: 0,
                bookmarkMutation: nil,
                history: legacy.history,
                bookmarks: legacy.bookmarks
            )
        } catch {
            throw BookmarkTransactionError.storageCorrupted
        }
    }

    private static func validatePayloadMutation(_ payload: Payload) throws {
        guard payload.schemaVersion == 1 else {
            throw BookmarkTransactionError.unsupportedStorageVersion
        }
        if let rollbackEpoch = payload.rollbackEpoch, rollbackEpoch == 0 {
            throw BookmarkTransactionError.storageCorrupted
        }
        try validateUniqueIDs(payload.bookmarks)
        guard let mutation = payload.bookmarkMutation else {
            guard payload.bookmarkRevision == 0 else {
                throw BookmarkTransactionError.storageCorrupted
            }
            return
        }
        guard mutation.rootID == stableBookmarkRootID,
              mutation.treeDigest == (try snapshotDigest(payload.bookmarks))
        else { throw BookmarkTransactionError.storageCorrupted }
        guard isValidMutationShape(mutation) else {
            throw BookmarkTransactionError.storageCorrupted
        }
    }

    private static func validatePayloadJSONShape(_ object: [String: Any]) throws {
        guard let history = object["history"] as? [Any],
              let bookmarks = object["bookmarks"] as? [Any]
        else { throw BookmarkTransactionError.storageCorrupted }
        for value in history {
            guard let item = value as? [String: Any],
                  Set(item.keys) == ["id", "title", "url", "visitedAt"]
            else { throw BookmarkTransactionError.storageCorrupted }
        }
        for value in bookmarks {
            guard let item = value as? [String: Any],
                  Set(item.keys) == ["id", "title", "url", "createdAt"]
            else { throw BookmarkTransactionError.storageCorrupted }
        }
        if let mutation = object["bookmarkMutation"], !(mutation is NSNull) {
            guard let item = mutation as? [String: Any] else {
                throw BookmarkTransactionError.storageCorrupted
            }
            let keys = Set(item.keys)
            guard keys.isSubset(of: [
                      "kind",
                      "mutationId",
                      "mutationID",
                      "transactionId",
                      "transactionID",
                      "rootId",
                      "rootID",
                      "treeDigest",
                      "counterpartDigest",
                  ]),
                  keys.contains("kind"),
                  keys.contains("treeDigest"),
                  keys.intersection(["mutationId", "mutationID"]).count == 1,
                  keys.intersection(["rootId", "rootID"]).count == 1,
                  keys.intersection(["transactionId", "transactionID"]).count <= 1
            else { throw BookmarkTransactionError.storageCorrupted }
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func isValidMutationShape(_ mutation: BookmarkMutation) -> Bool {
        guard mutation.rootID == stableBookmarkRootID,
              isLowercaseSHA256(mutation.treeDigest)
        else { return false }
        switch mutation.kind {
        case .external:
            return mutation.transactionID == nil && mutation.counterpartDigest == nil
        case .transactionApplied, .transactionUndone:
            return mutation.transactionID != nil
                && mutation.counterpartDigest.map(isLowercaseSHA256) == true
        }
    }

    private func makeJournalFile(
        latest: JournalTransaction?,
        transition: JournalTransition?
    ) throws -> JournalFile {
        JournalFile(
            schemaVersion: 1,
            rootID: bookmarkRootID,
            latest: latest,
            transition: transition
        )
    }

    private func persistJournal(
        _ file: JournalFile,
        checkpoint: BookmarkPersistenceCheckpoint
    ) throws {
        guard let journalURL else { return }
        if persistenceFailureInjector?(checkpoint) == true {
            throw BookmarkTransactionError.persistenceFailed
        }
        do {
            try FileManager.default.createDirectory(
                at: journalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let plaintext = try Self.journalEncoder().encode(file)
            guard plaintext.count <= Self.maximumJournalPlaintextBytes else {
                throw BookmarkTransactionError.persistenceFailed
            }
            let envelope = try encryptJournal(plaintext)
            let envelopeData = try Self.journalEncoder().encode(envelope)
            guard envelopeData.count <= Self.maximumJournalEnvelopeBytes else {
                throw BookmarkTransactionError.persistenceFailed
            }
            try Self.writeProtectedAtomically(
                envelopeData,
                to: journalURL
            )
            journalFile = file
        } catch {
            throw BookmarkTransactionError.persistenceFailed
        }
    }

    private func loadAndRecoverJournal() {
        guard let journalURL else { return }
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            if bookmarkMutation?.kind == .transactionApplied
                || bookmarkMutation?.kind == .transactionUndone {
                journalFailure = .journalCorrupted
            }
            return
        }
        do {
            let data = try Self.readBoundedFile(
                at: journalURL,
                maximumBytes: Self.maximumJournalEnvelopeBytes,
                oversizedError: .journalCorrupted
            )
            var file = try decodeAndValidateJournal(data)
            try validateJournalTransactions(file)

            if let transition = file.transition {
                file = try recover(transition: transition, from: file)
            }
            if file.latest == nil,
               bookmarkMutation?.kind == .transactionApplied
                || bookmarkMutation?.kind == .transactionUndone {
                throw BookmarkTransactionError.journalCorrupted
            }
            journalFile = file
            if let latest = file.latest {
                if Self.payloadMatchesStableTransaction(
                    latest,
                    bookmarks: bookmarks,
                    revision: bookmarkRevision,
                    mutation: bookmarkMutation
                ) {
                    bookmarkTransactions = [
                        latest.transactionID: BookmarkTransactionRecord(
                            receipt: latest.receipt,
                            beforeBookmarks: latest.beforeBookmarks,
                            wasUndone: latest.status == .undone
                        ),
                    ]
                } else if bookmarkMutation?.kind == .transactionApplied
                    || bookmarkMutation?.kind == .transactionUndone {
                    throw BookmarkTransactionError.journalCorrupted
                }
            }
        } catch let error as BookmarkTransactionError {
            journalFailure = error
            bookmarkTransactions = [:]
        } catch {
            journalFailure = .journalCorrupted
            bookmarkTransactions = [:]
        }
    }

    private func recover(
        transition: JournalTransition,
        from file: JournalFile
    ) throws -> JournalFile {
        switch transition.kind {
        case .applying:
            let transaction = transition.transaction
            guard transition.targetRevision == transaction.appliedRevision,
                  transition.mutationID == transaction.appliedMutationID
            else { throw BookmarkTransactionError.journalCorrupted }
            if bookmarks == transaction.afterBookmarks,
               bookmarkRevision == transaction.appliedRevision,
               bookmarkMutation == Self.appliedMutation(for: transaction) {
                return try makeJournalFile(latest: transaction, transition: nil)
            }
            if bookmarks == transaction.beforeBookmarks,
               bookmarkRevision == transaction.baseRevision,
               bookmarkMutation == transaction.baseMutation {
                if let latest = file.latest {
                    guard Self.payloadMatchesStableTransaction(
                        latest,
                        bookmarks: bookmarks,
                        revision: bookmarkRevision,
                        mutation: bookmarkMutation
                    ) else {
                        throw Self.divergence(expected: latest, actual: bookmarks)
                    }
                }
                return try makeJournalFile(latest: file.latest, transition: nil)
            }
            throw Self.divergence(expected: transaction, actual: bookmarks)

        case .undoing:
            let transaction = transition.transaction
            guard file.latest == transaction, transaction.status == .committed else {
                throw BookmarkTransactionError.journalCorrupted
            }
            if bookmarks == transaction.beforeBookmarks,
               bookmarkRevision == transition.targetRevision,
               bookmarkMutation == Self.undoneMutation(
                   for: transaction,
                   revision: transition.targetRevision,
                   mutationID: transition.mutationID
               ) {
                return try makeJournalFile(
                    latest: transaction.markedUndone(
                        revision: transition.targetRevision,
                        mutationID: transition.mutationID
                    ),
                    transition: nil
                )
            }
            if bookmarks == transaction.afterBookmarks,
               bookmarkRevision == transaction.appliedRevision,
               bookmarkMutation == Self.appliedMutation(for: transaction) {
                return try makeJournalFile(latest: transaction, transition: nil)
            }
            throw Self.divergence(expected: transaction, actual: bookmarks)
        }
    }

    private func validateJournalTransactions(_ file: JournalFile) throws {
        guard file.schemaVersion == 1, file.rootID == bookmarkRootID else {
            throw BookmarkTransactionError.unsupportedJournalVersion
        }
        if let latest = file.latest { try Self.validateJournalTransaction(latest) }
        if let transition = file.transition {
            try Self.validateJournalTransaction(transition.transaction)
            switch transition.kind {
            case .applying:
                guard transition.transaction.status == .committed,
                      transition.targetRevision == transition.transaction.appliedRevision,
                      transition.mutationID == transition.transaction.appliedMutationID
                else {
                    throw BookmarkTransactionError.journalCorrupted
                }
                if let latest = file.latest {
                    guard Self.payloadMatchesStableTransaction(
                        latest,
                        bookmarks: transition.transaction.beforeBookmarks,
                        revision: transition.transaction.baseRevision,
                        mutation: transition.transaction.baseMutation
                    ) else {
                        throw BookmarkTransactionError.journalCorrupted
                    }
                }
            case .undoing:
                guard file.latest == transition.transaction,
                      transition.transaction.status == .committed,
                      transition.targetRevision > transition.transaction.appliedRevision,
                      transition.mutationID != transition.transaction.appliedMutationID
                else { throw BookmarkTransactionError.journalCorrupted }
            }
        }
    }

    private static func validateJournalTransaction(
        _ transaction: JournalTransaction
    ) throws {
        let (expectedAppliedRevision, revisionOverflow) = transaction.baseRevision
            .addingReportingOverflow(1)
        guard transaction.rootID == stableBookmarkRootID,
              transaction.beforeCount == transaction.beforeBookmarks.count,
              transaction.afterCount == transaction.afterBookmarks.count,
              transaction.baseMutationID == transaction.baseMutation?.mutationID,
              !revisionOverflow,
              transaction.appliedRevision == expectedAppliedRevision,
              transaction.appliedMutationID == transaction.transactionID,
              try snapshotDigest(transaction.beforeBookmarks) == transaction.beforeDigest,
              try snapshotDigest(transaction.afterBookmarks) == transaction.afterDigest
        else { throw BookmarkTransactionError.journalCorrupted }
        if let baseMutation = transaction.baseMutation {
            guard isValidMutationShape(baseMutation),
                  baseMutation.treeDigest == transaction.beforeDigest
            else { throw BookmarkTransactionError.journalCorrupted }
        } else if transaction.baseRevision != 0 {
            throw BookmarkTransactionError.journalCorrupted
        }
        switch transaction.status {
        case .committed:
            guard transaction.undoneRevision == nil,
                  transaction.undoneMutationID == nil
            else { throw BookmarkTransactionError.journalCorrupted }
        case .undone:
            guard let undoneRevision = transaction.undoneRevision,
                  let undoneMutationID = transaction.undoneMutationID,
                  undoneRevision > transaction.appliedRevision,
                  undoneMutationID != transaction.appliedMutationID
            else { throw BookmarkTransactionError.journalCorrupted }
        }
        do {
            try validatePlanIdentity(
                before: transaction.beforeBookmarks,
                after: transaction.afterBookmarks
            )
        } catch {
            throw BookmarkTransactionError.journalCorrupted
        }
        let summary = changeSummary(
            before: transaction.beforeBookmarks,
            after: transaction.afterBookmarks
        )
        guard summary.changedIDs == transaction.changedBookmarkIds,
              summary.removedIDs == transaction.removedDuplicateIds
        else { throw BookmarkTransactionError.journalCorrupted }
    }

    private static func divergence(
        expected transaction: JournalTransaction,
        actual bookmarks: [BrowserBookmark]
    ) -> BookmarkTransactionError {
        let actualDigest = (try? snapshotDigest(bookmarks)) ?? "invalid"
        return .stateDiverged(expected: transaction.afterDigest, actual: actualDigest)
    }

    private func decodeAndValidateJournal(_ data: Data) throws -> JournalFile {
        guard let journalURL else { throw BookmarkTransactionError.journalCorrupted }
        guard data.count <= Self.maximumJournalEnvelopeBytes else {
            throw BookmarkTransactionError.journalCorrupted
        }
        let envelopeRaw: Any
        do {
            envelopeRaw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BookmarkTransactionError.journalCorrupted
        }
        guard let envelopeObject = envelopeRaw as? [String: Any],
              let version = envelopeObject["schema_version"] as? NSNumber
        else { throw BookmarkTransactionError.journalCorrupted }
        guard version.intValue == 1 else {
            throw BookmarkTransactionError.unsupportedJournalVersion
        }
        try Self.exactKeys(
            envelopeObject,
            ["schema_version", "algorithm", "nonce", "ciphertext", "tag"]
        )

        let envelope: JournalEnvelope
        do {
            envelope = try Self.journalDecoder().decode(JournalEnvelope.self, from: data)
        } catch {
            throw BookmarkTransactionError.journalCorrupted
        }
        guard envelope.schemaVersion == 1,
              envelope.algorithm == Self.journalAlgorithm,
              let nonce = Self.canonicalBase64(envelope.nonce, expectedCount: 12),
              let ciphertext = Self.canonicalBase64(envelope.ciphertext),
              !ciphertext.isEmpty,
              ciphertext.count <= Self.maximumJournalPlaintextBytes,
              let tag = Self.canonicalBase64(envelope.tag, expectedCount: 16)
        else { throw BookmarkTransactionError.journalCorrupted }

        let plaintext: Data
        do {
            let key = try Self.journalEncryptionKey(
                for: journalURL,
                createIfMissing: false
            )
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            plaintext = try AES.GCM.open(
                sealedBox,
                using: SymmetricKey(data: key),
                authenticating: Self.journalAssociatedData
            )
        } catch {
            throw BookmarkTransactionError.journalCorrupted
        }

        let plaintextRaw: Any
        do {
            plaintextRaw = try JSONSerialization.jsonObject(with: plaintext)
        } catch {
            throw BookmarkTransactionError.journalCorrupted
        }
        guard let object = plaintextRaw as? [String: Any],
              let plaintextVersion = object["schema_version"] as? NSNumber
        else { throw BookmarkTransactionError.journalCorrupted }
        guard plaintextVersion.intValue == 1 else {
            throw BookmarkTransactionError.unsupportedJournalVersion
        }
        try Self.validateJournalJSONShape(object)

        let file: JournalFile
        do {
            file = try Self.journalDecoder().decode(JournalFile.self, from: plaintext)
        } catch {
            throw BookmarkTransactionError.journalCorrupted
        }
        guard file.schemaVersion == 1,
              file.rootID == Self.stableBookmarkRootID
        else { throw BookmarkTransactionError.journalCorrupted }
        return file
    }

    private static func validateJournalJSONShape(_ object: [String: Any]) throws {
        try allowedKeys(
            object,
            required: ["schema_version", "root_id"],
            allowed: ["schema_version", "root_id", "latest", "transition"]
        )
        if let latest = object["latest"], !(latest is NSNull) {
            try validateJournalTransactionJSON(latest)
        }
        if let transition = object["transition"], !(transition is NSNull) {
            guard let value = transition as? [String: Any] else {
                throw BookmarkTransactionError.journalCorrupted
            }
            try exactKeys(value, ["kind", "transaction", "target_revision", "mutation_id"])
            try validateJournalTransactionJSON(value["transaction"] as Any)
        }
    }

    private static func validateJournalTransactionJSON(_ value: Any) throws {
        guard let object = value as? [String: Any] else {
            throw BookmarkTransactionError.journalCorrupted
        }
        try allowedKeys(object, required: [
            "plan_id",
            "transaction_id",
            "root_id",
            "before_digest",
            "after_digest",
            "before_count",
            "after_count",
            "changed_bookmark_ids",
            "removed_duplicate_ids",
            "before_bookmarks",
            "after_bookmarks",
            "base_revision",
            "applied_revision",
            "applied_mutation_id",
            "status",
        ], allowed: [
            "plan_id",
            "transaction_id",
            "root_id",
            "before_digest",
            "after_digest",
            "before_count",
            "after_count",
            "changed_bookmark_ids",
            "removed_duplicate_ids",
            "before_bookmarks",
            "after_bookmarks",
            "base_revision",
            "base_mutation_id",
            "base_mutation",
            "applied_revision",
            "applied_mutation_id",
            "undone_revision",
            "undone_mutation_id",
            "status",
        ])
        if let mutation = object["base_mutation"], !(mutation is NSNull) {
            try validateMutationJSON(mutation)
        }
        for key in ["before_bookmarks", "after_bookmarks"] {
            guard let bookmarks = object[key] as? [Any] else {
                throw BookmarkTransactionError.journalCorrupted
            }
            for bookmark in bookmarks {
                guard let bookmarkObject = bookmark as? [String: Any] else {
                    throw BookmarkTransactionError.journalCorrupted
                }
                try exactKeys(bookmarkObject, ["id", "title", "url", "created_at"])
            }
        }
    }

    private static func validateMutationJSON(_ value: Any) throws {
        guard let object = value as? [String: Any] else {
            throw BookmarkTransactionError.journalCorrupted
        }
        try allowedKeys(object, required: [
            "kind",
            "mutation_id",
            "root_id",
            "tree_digest",
        ], allowed: [
            "kind",
            "mutation_id",
            "transaction_id",
            "root_id",
            "tree_digest",
            "counterpart_digest",
        ])
    }

    private static func allowedKeys(
        _ object: [String: Any],
        required: Set<String>,
        allowed: Set<String>
    ) throws {
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: allowed) else {
            throw BookmarkTransactionError.journalCorrupted
        }
    }

    private static func exactKeys(
        _ object: [String: Any],
        _ expected: Set<String>
    ) throws {
        guard Set(object.keys) == expected else {
            throw BookmarkTransactionError.journalCorrupted
        }
    }

    private static func journalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func journalDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private func encryptJournal(_ plaintext: Data) throws -> JournalEnvelope {
        guard let journalURL else { throw BookmarkTransactionError.persistenceFailed }
        guard plaintext.count <= Self.maximumJournalPlaintextBytes else {
            throw BookmarkTransactionError.persistenceFailed
        }
        let key = try Self.journalEncryptionKey(
            for: journalURL,
            createIfMissing: true
        )
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: key),
            authenticating: Self.journalAssociatedData
        )
        let nonce = sealedBox.nonce.withUnsafeBytes { Data($0) }
        return JournalEnvelope(
            schemaVersion: 1,
            algorithm: Self.journalAlgorithm,
            nonce: nonce.base64EncodedString(),
            ciphertext: sealedBox.ciphertext.base64EncodedString(),
            tag: sealedBox.tag.base64EncodedString()
        )
    }

    private static let journalAlgorithm = "AES-256-GCM"

    private static let journalAssociatedData = Data(
        "aegis-bookmark-undo-journal-envelope-v1\nAES-256-GCM".utf8
    )

    private static func canonicalBase64(
        _ value: String,
        expectedCount: Int? = nil
    ) -> Data? {
        guard let data = Data(base64Encoded: value),
              data.base64EncodedString() == value,
              expectedCount.map({ data.count == $0 }) ?? true
        else { return nil }
        return data
    }

    private func makeRollbackHead(
        epoch: UInt64,
        status: RollbackHeadStatus,
        digest: String? = nil,
        previousDigest: String? = nil,
        targetDigest: String? = nil,
        operationId: UUID? = nil
    ) throws -> RollbackHeadFile {
        let unsigned = RollbackHeadUnsigned(
            schemaVersion: 1,
            epoch: epoch,
            status: status,
            digest: digest,
            previousDigest: previousDigest,
            targetDigest: targetDigest,
            operationId: operationId
        )
        return RollbackHeadFile(
            schemaVersion: unsigned.schemaVersion,
            epoch: unsigned.epoch,
            status: unsigned.status,
            digest: unsigned.digest,
            previousDigest: unsigned.previousDigest,
            targetDigest: unsigned.targetDigest,
            operationId: unsigned.operationId,
            authenticationTag: try rollbackHeadAuthenticationTag(
                for: unsigned,
                createKeyIfMissing: true
            )
        )
    }

    private func rollbackHeadAuthenticationTag(
        for unsigned: RollbackHeadUnsigned,
        createKeyIfMissing: Bool
    ) throws -> String {
        guard let journalURL else { throw BookmarkTransactionError.persistenceFailed }
        let key = try Self.journalEncryptionKey(
            for: journalURL,
            createIfMissing: createKeyIfMissing
        )
        var message = Data("aegis-bookmark-rollback-head-v1".utf8)
        message.append(0x0A)
        message.append(try Self.journalEncoder().encode(unsigned))
        return HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: key)
        ).map { String(format: "%02x", $0) }.joined()
    }

    private func readRollbackHead() throws -> RollbackHeadFile? {
        guard let journalURL else { return nil }
        var query = Self.rollbackHeadKeychainQuery(for: journalURL)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              data.count <= Self.maximumRollbackHeadBytes
        else {
            throw BookmarkTransactionError.persistenceFailed
        }

        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BookmarkTransactionError.journalCorrupted
        }
        guard let object = raw as? [String: Any],
              let version = object["schema_version"] as? NSNumber,
              version.intValue == 1
        else { throw BookmarkTransactionError.journalCorrupted }
        try Self.allowedKeys(
            object,
            required: ["schema_version", "epoch", "status", "authentication_tag"],
            allowed: [
                "schema_version",
                "epoch",
                "status",
                "digest",
                "previous_digest",
                "target_digest",
                "operation_id",
                "authentication_tag",
            ]
        )
        let head: RollbackHeadFile
        do {
            head = try Self.journalDecoder().decode(RollbackHeadFile.self, from: data)
        } catch {
            throw BookmarkTransactionError.journalCorrupted
        }
        guard head.schemaVersion == 1,
              Self.isLowercaseSHA256(head.authenticationTag),
              head.authenticationTag == (try rollbackHeadAuthenticationTag(
                  for: head.unsigned,
                  createKeyIfMissing: false
              ))
        else { throw BookmarkTransactionError.journalCorrupted }
        switch head.status {
        case .committed:
            guard head.digest.map(Self.isLowercaseSHA256) == true,
                  head.previousDigest == nil,
                  head.targetDigest == nil,
                  head.operationId == nil
            else { throw BookmarkTransactionError.journalCorrupted }
        case .pending:
            guard head.digest == nil,
                  head.previousDigest.map(Self.isLowercaseSHA256) == true,
                  head.targetDigest.map(Self.isLowercaseSHA256) == true,
                  head.previousDigest != head.targetDigest,
                  head.operationId != nil
            else { throw BookmarkTransactionError.journalCorrupted }
        }
        return head
    }

    private func persistRollbackHead(_ head: RollbackHeadFile) throws {
        guard let journalURL else { return }
        let data: Data
        do {
            data = try Self.journalEncoder().encode(head)
        } catch {
            throw BookmarkTransactionError.persistenceFailed
        }
        guard data.count <= Self.maximumRollbackHeadBytes else {
            throw BookmarkTransactionError.persistenceFailed
        }
        let query = Self.rollbackHeadKeychainQuery(for: journalURL)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw BookmarkTransactionError.persistenceFailed
        }
        var addQuery = query
        addQuery[kSecValueData] = data
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw BookmarkTransactionError.persistenceFailed
        }
    }

    private static func rollbackHeadKeychainQuery(for journalURL: URL) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.gcsa.aegis.bookmark-rollback-head-v1",
            kSecAttrAccount: journalSecurityAccount(for: journalURL),
        ]
    }

    private func ensurePersistentFileProtection() throws {
        if let persistenceURL,
           FileManager.default.fileExists(atPath: persistenceURL.path) {
            try Self.setCompleteFileProtection(at: persistenceURL)
        }
        if let journalURL,
           FileManager.default.fileExists(atPath: journalURL.path) {
            try Self.setCompleteFileProtection(at: journalURL)
        }
    }

    private static func journalEncryptionKey(
        for journalURL: URL,
        createIfMissing: Bool
    ) throws -> Data {
        let account = journalSecurityAccount(for: journalURL)
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.gcsa.aegis.bookmark-undo-journal-encryption-v1",
            kSecAttrAccount: account,
        ]
        var readQuery = baseQuery
        readQuery[kSecReturnData] = true
        readQuery[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &item)
        if readStatus == errSecSuccess, let data = item as? Data, data.count == 32 {
            return data
        }
        guard readStatus == errSecItemNotFound, createIfMissing else {
            throw createIfMissing
                ? BookmarkTransactionError.persistenceFailed
                : BookmarkTransactionError.journalCorrupted
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw BookmarkTransactionError.persistenceFailed
        }
        let data = Data(bytes)
        var addQuery = baseQuery
        addQuery[kSecValueData] = data
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return data }
        if addStatus == errSecDuplicateItem {
            return try journalEncryptionKey(for: journalURL, createIfMissing: false)
        }
        throw BookmarkTransactionError.persistenceFailed
    }

    static func removeBookmarkJournalEncryptionKey(for persistenceURL: URL) {
        let journalURL = bookmarkJournalURL(for: persistenceURL)
        let account = journalSecurityAccount(for: journalURL)
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.gcsa.aegis.bookmark-undo-journal-encryption-v1",
            kSecAttrAccount: account,
        ] as CFDictionary)
        SecItemDelete(rollbackHeadKeychainQuery(for: journalURL) as CFDictionary)
    }

    #if DEBUG
    /// UI 测试必须显式删除数据文件后再调用；Release 不暴露安全锚点重置入口。
    public static func resetBookmarkSecurityStateForTesting(persistenceURL: URL) {
        removeBookmarkJournalEncryptionKey(for: persistenceURL)
    }
    #endif

    private static func journalSecurityAccount(for journalURL: URL) -> String {
        SHA256.hash(data: Data(journalURL.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func setCompleteFileProtection(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    private static func readBoundedFile(
        at url: URL,
        maximumBytes: Int,
        oversizedError: BookmarkTransactionError
    ) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else { throw oversizedError }
            return data
        } catch let error as BookmarkTransactionError {
            throw error
        } catch {
            throw oversizedError
        }
    }

    private static func writeProtectedAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try setCompleteFileProtection(at: url)
    }

    static func bookmarkJournalURL(for persistenceURL: URL) -> URL {
        URL(fileURLWithPath: persistenceURL.path + ".bookmark-undo-journal-v1.json")
    }

    private static func organizedBookmarks(from source: [BrowserBookmark]) -> [BrowserBookmark] {
        var survivorByURL: [String: BrowserBookmark] = [:]
        for bookmark in source {
            let cleanedURL = LinkSanitizer.sanitize(bookmark.url).cleaned
            let candidate = BrowserBookmark(
                id: bookmark.id,
                title: bookmark.title,
                url: cleanedURL,
                createdAt: bookmark.createdAt
            )
            if let existing = survivorByURL[cleanedURL] {
                if survivorPrecedes(candidate, existing) {
                    survivorByURL[cleanedURL] = candidate
                }
            } else {
                survivorByURL[cleanedURL] = candidate
            }
        }
        return survivorByURL.values.sorted(by: bookmarkPrecedes)
    }

    private static func survivorPrecedes(_ lhs: BrowserBookmark, _ rhs: BrowserBookmark) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return utf8Precedes(lhs.id.uuidString.lowercased(), rhs.id.uuidString.lowercased())
    }

    private static func bookmarkPrecedes(_ lhs: BrowserBookmark, _ rhs: BrowserBookmark) -> Bool {
        if lhs.url != rhs.url { return utf8Precedes(lhs.url, rhs.url) }
        if lhs.title != rhs.title { return utf8Precedes(lhs.title, rhs.title) }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return utf8Precedes(lhs.id.uuidString.lowercased(), rhs.id.uuidString.lowercased())
    }

    private static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func sortedIDs<S: Sequence>(_ ids: S) -> [UUID] where S.Element == UUID {
        ids.sorted {
            utf8Precedes($0.uuidString.lowercased(), $1.uuidString.lowercased())
        }
    }

    private static func validateUniqueIDs(_ bookmarks: [BrowserBookmark]) throws {
        var observed: Set<UUID> = []
        for bookmark in bookmarks where !observed.insert(bookmark.id).inserted {
            throw BookmarkTransactionError.duplicateBookmarkID(bookmark.id)
        }
    }

    private static func validatePlanIdentity(
        before: [BrowserBookmark],
        after: [BrowserBookmark]
    ) throws {
        try validateUniqueIDs(after)
        let beforeByID = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        for bookmark in after {
            guard let original = beforeByID[bookmark.id],
                  original.createdAt == bookmark.createdAt
            else { throw BookmarkTransactionError.invalidPlan }
        }
    }

    private static func changeSummary(
        before: [BrowserBookmark],
        after: [BrowserBookmark]
    ) -> (changedIDs: [UUID], removedIDs: [UUID]) {
        let beforeByID = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        let beforeIndexByID = Dictionary(
            uniqueKeysWithValues: before.enumerated().map { ($0.element.id, $0.offset) }
        )
        let afterIDs = Set(after.map(\.id))
        let removedIDs = sortedIDs(before.lazy.map(\.id).filter { !afterIDs.contains($0) })
        let changedIDs = sortedIDs(after.enumerated().compactMap { index, bookmark in
            guard beforeByID[bookmark.id] != bookmark
                    || beforeIndexByID[bookmark.id] != index
            else { return nil }
            return bookmark.id
        })
        return (changedIDs, removedIDs)
    }

    private static func snapshotDigest(_ bookmarks: [BrowserBookmark]) throws -> String {
        try validateUniqueIDs(bookmarks)
        let items = try bookmarks.enumerated().map { index, bookmark in
            CanonicalBookmark(
                createdAtMilliseconds: try millisecondsSince1970(bookmark.createdAt),
                id: bookmark.id.uuidString.lowercased(),
                position: index,
                title: bookmark.title,
                url: bookmark.url
            )
        }
        return try digest(
            CanonicalSnapshot(
                items: items,
                rootID: stableBookmarkRootID.uuidString.lowercased(),
                schemaVersion: 1
            ),
            domain: "aegis-bookmark-snapshot-v1"
        )
    }

    private static func digest<T: Encodable>(_ value: T, domain: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data(domain.utf8)
        data.append(0x0A)
        data.append(try encoder.encode(value))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func millisecondsSince1970(_ date: Date) throws -> Int64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds < Double(Int64.max)
        else { throw BookmarkTransactionError.invalidPlan }
        return Int64(milliseconds.rounded(.towardZero))
    }

    public static func defaultPersistenceURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Aegis", isDirectory: true)
            .appendingPathComponent("browser-data-v1.json")
    }
}
