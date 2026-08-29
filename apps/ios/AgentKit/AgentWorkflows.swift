import Foundation

public enum AgentWorkflowKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case research
    case browserManager
    case safeDownload
    case shopping

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .research: "深度研究"
        case .browserManager: "浏览器管家"
        case .safeDownload: "安全下载"
        case .shopping: "购物助手"
        }
    }

    public var symbol: String {
        switch self {
        case .research: "doc.text.magnifyingglass"
        case .browserManager: "square.grid.2x2"
        case .safeDownload: "arrow.down.shield"
        case .shopping: "cart"
        }
    }
}

public struct WorkflowCitation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let source: String
    public let summary: String
    public let visitedAt: Date

    public init(id: UUID = UUID(), title: String, source: String, summary: String, visitedAt: Date) {
        self.id = id
        self.title = title
        self.source = source
        self.summary = summary
        self.visitedAt = visitedAt
    }
}

public struct WorkflowResult: Equatable, Sendable {
    public let kind: AgentWorkflowKind
    public let headline: String
    public let summary: String
    public let steps: [String]
    public let evidence: [String]
    public let citations: [WorkflowCitation]
    public let requiresUserHandoff: Bool
    public let handoffReason: String?
    public let undoAvailable: Bool
}

public struct AgentWorkflowEngine: Sendable {
    public init() {}

    public func run(_ kind: AgentWorkflowKind, now: Date = Date()) -> WorkflowResult {
        switch kind {
        case .research:
            return research(now: now)
        case .browserManager:
            return browserManagerResult(
                beforeCount: 0,
                afterCount: 0,
                changedCount: 0,
                removedDuplicateCount: 0,
                undoAvailable: false
            )
        case .safeDownload:
            return safeDownload()
        case .shopping:
            return shopping()
        }
    }

    private func research(now: Date) -> WorkflowResult {
        let citations = (1...10).map { index in
            WorkflowCitation(
                title: "受控研究来源 \(index)",
                source: "https://research.aegis.test/source/\(index)",
                summary: "来源 \(index) 的可核对摘要；页面指令仅作为不可信资料处理。",
                visitedAt: now.addingTimeInterval(TimeInterval(-index * 9))
            )
        }
        return WorkflowResult(
            kind: .research,
            headline: "10 个来源已交叉核对",
            summary: "本地确定性演示已完成来源去重、观点比较和逐条引用；未调用远程模型。",
            steps: ["建立授权范围", "读取 10 个受控来源", "过滤页面提示注入", "生成可核对引用"],
            evidence: ["来源 10/10", "越权动作 0", "远程请求 0", "引用完整性 100%"],
            citations: citations,
            requiresUserHandoff: false,
            handoffReason: nil,
            undoAvailable: false
        )
    }

    public func browserManagerResult(
        beforeCount: Int,
        afterCount: Int,
        changedCount: Int,
        removedDuplicateCount: Int,
        undoAvailable: Bool
    ) -> WorkflowResult {
        let headline = undoAvailable ? "收藏夹整理已应用" : "收藏夹无需变更"
        let summary = undoAvailable
            ? "已将当前 \(beforeCount) 条收藏整理为 \(afterCount) 条；认证撤销日志可在 App 重启后恢复。"
            : "当前共有 \(beforeCount) 条收藏，确定性检查没有产生可应用的变更。"
        return WorkflowResult(
            kind: .browserManager,
            headline: headline,
            summary: summary,
            steps: ["读取当前收藏", "清理追踪参数", "精确去重并稳定排序", "原子应用并登记撤销"],
            evidence: [
                "整理前 \(beforeCount) 条",
                "整理后 \(afterCount) 条",
                "变更 \(changedCount) 条",
                "精确去重 \(removedDuplicateCount) 条",
            ],
            citations: [],
            requiresUserHandoff: false,
            handoffReason: nil,
            undoAvailable: undoAvailable
        )
    }

    public func browserManagerUndoResult(
        restoredCount: Int,
        transactionID: UUID,
        restoredDigest: String
    ) -> WorkflowResult {
        WorkflowResult(
            kind: .browserManager,
            headline: "上次收藏整理已撤销",
            summary: "已通过新的任务授权和动作确认恢复整理前的 \(restoredCount) 条收藏。",
            steps: ["读取认证撤销日志", "核对事务与逻辑树", "重新取得用户授权", "原子恢复整理前快照"],
            evidence: [
                "恢复后 \(restoredCount) 条",
                "事务 \(transactionID.uuidString.lowercased())",
                "Tree before \(restoredDigest)",
                "跨重启自动写入 0 次",
            ],
            citations: [],
            requiresUserHandoff: false,
            handoffReason: nil,
            undoAvailable: false
        )
    }

    private func safeDownload() -> WorkflowResult {
        WorkflowResult(
            kind: .safeDownload,
            headline: "候选包校验完成",
            summary: "离线候选清单中的 arm64 包已完成只读核对；MIME 与 SHA-256 匹配，发布者签名未提供，未发起真实下载。",
            steps: ["锁定官方来源", "识别平台与架构", "检查 MIME", "核对 SHA-256"],
            evidence: ["平台 iOS", "架构 arm64", "SHA-256 匹配", "发布者签名：未提供"],
            citations: [],
            requiresUserHandoff: false,
            handoffReason: nil,
            undoAvailable: false
        )
    }

    private func shopping() -> WorkflowResult {
        WorkflowResult(
            kind: .shopping,
            headline: "已停在最终提交前",
            summary: "商品、数量、币种、税费、运费和总额已复核。下单、支付、OTP 与 3DS 必须由你完成。",
            steps: ["比较商品与卖家", "核对规格和数量", "生成结算预览", "撤销动作能力并交还用户"],
            evidence: ["商品 Aegis Key", "数量 1", "总额 CNY 399.00", "最终提交 0 次"],
            citations: [],
            requiresUserHandoff: true,
            handoffReason: "最终下单和支付属于 R3，只能由用户完成",
            undoAvailable: false
        )
    }
}
