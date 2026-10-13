import BrowserKit
import Combine
import Foundation

public enum BrowserOperationKind: String, Codable, CaseIterable, Sendable {
    case groupTabs, saveWorkspace, openURLs, reloadTabs, closeTabs, scrollDown
    public var title: String {
        switch self {
        case .groupTabs: String(localized: "将所选标签分组")
        case .saveWorkspace: String(localized: "将所选标签保存为工作区")
        case .openURLs: String(localized: "打开输入的网址")
        case .reloadTabs: String(localized: "重新载入所选标签")
        case .closeTabs: String(localized: "关闭所选标签")
        case .scrollDown: String(localized: "向下滚动当前页面")
        }
    }
}

public struct BrowserOperationStep: Codable, Identifiable, Equatable, Sendable {
    public var id: String { kind.rawValue }
    public let kind: BrowserOperationKind
    public let name: String
    public init(kind: BrowserOperationKind, name: String = "") { self.kind = kind; self.name = name }
}

public struct BrowserOperationSource: Identifiable, Sendable {
    public let id: UUID
    public let url: URL?
    public let title: String
    public let epoch: UInt64
}

public struct BrowserOperationPlan: Identifiable, Sendable {
    public let id: UUID
    public let windowID: UUID
    public let profileID: UUID
    public let createdAt: Date
    public let sources: [BrowserOperationSource]
    public let urls: [URL]
    public let steps: [BrowserOperationStep]

    @MainActor public init(browser: BrowserSession, selected: Set<UUID>, urls: [URL], steps: [BrowserOperationStep], now: Date = Date()) throws {
        id = UUID(); windowID = browser.windowID; profileID = browser.activeProfileID; createdAt = now
        sources = browser.visibleTabs.filter { selected.contains($0.id) }.map {
            BrowserOperationSource(id: $0.id, url: $0.requestedURL ?? $0.url, title: $0.title, epoch: $0.navigationEpoch)
        }
        self.urls = urls; self.steps = steps
        guard sources.count == selected.count else { throw BrowserOperationError.changed }
        try validateShape()
    }

    public func validateShape() throws {
        guard (1...6).contains(steps.count), sources.count <= 16, Set(sources.map(\.id)).count == sources.count,
              Set(steps.map(\.kind)).count == steps.count, urls.count <= 16,
              steps.allSatisfy({ $0.name.count <= 80 }),
              urls.allSatisfy({ BrowserPreferences.origin($0) != nil && BrowserNavigationPolicy.evaluate($0).kind != .blocked })
        else { throw BrowserOperationError.invalidPlan }
        for (index, step) in steps.enumerated() {
            guard step.kind == .openURLs ? !urls.isEmpty : !sources.isEmpty else { throw BrowserOperationError.invalidPlan }
            if [.groupTabs, .saveWorkspace].contains(step.kind), step.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw BrowserOperationError.invalidPlan
            }
            if [.closeTabs, .reloadTabs].contains(step.kind), index != steps.count - 1 { throw BrowserOperationError.invalidPlan }
            if step.kind == .scrollDown, sources.count != 1 { throw BrowserOperationError.invalidPlan }
        }
    }
}

public enum BrowserOperationError: LocalizedError {
    case invalidPlan, changed, expired, alreadyUsed, cancelled
    public var errorDescription: String? {
        switch self {
        case .invalidPlan: String(localized: "操作计划超出允许范围，请调整所选标签、网址或步骤。")
        case .changed: String(localized: "窗口、浏览模式或页面已变化，请重新生成并确认操作。")
        case .expired: String(localized: "操作预览已过期，请重新生成。")
        case .alreadyUsed: String(localized: "此操作计划已处理，请重新预览后再执行。")
        case .cancelled: String(localized: "操作已取消。已完成的步骤保持原状。")
        }
    }
}

public enum BrowserPlanDecoder {
    /// 仅接收已知枚举和名称，不接受脚本、任意工具参数或模型新编的来源网址。
    public static func decode(_ text: String) throws -> [BrowserOperationStep] {
        guard text.utf8.count <= 8_000, let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["steps"], let steps = root["steps"] as? [[String: Any]], (1...6).contains(steps.count)
        else { throw BrowserOperationError.invalidPlan }
        return try steps.map { step in
            guard Set(step.keys).isSubset(of: ["kind", "name"]), let raw = step["kind"] as? String,
                  let kind = BrowserOperationKind(rawValue: raw), step["name"] == nil || step["name"] is String
            else { throw BrowserOperationError.invalidPlan }
            return BrowserOperationStep(kind: kind, name: step["name"] as? String ?? "")
        }
    }
}

@MainActor
public final class BrowserOperationExecutor: ObservableObject {
    @Published public private(set) var completedSteps = 0
    @Published public private(set) var running = false
    private var consumed: Set<UUID> = []
    private var generation = UUID()
    public init() { }
    public func cancel() { generation = UUID() }

    public func execute(_ plan: BrowserOperationPlan, in browser: BrowserSession, confirmed: Bool, now: Date = Date()) async throws {
        guard confirmed, !running else { throw BrowserOperationError.invalidPlan }
        completedSteps = 0
        guard !consumed.contains(plan.id) else { throw BrowserOperationError.alreadyUsed }
        guard now.timeIntervalSince(plan.createdAt) >= 0, now.timeIntervalSince(plan.createdAt) <= 300 else { throw BrowserOperationError.expired }
        try plan.validateShape()
        try checkSources(plan, browser: browser)
        guard !plan.steps.contains(where: { $0.kind == .openURLs }) || browser.visibleTabs.count + plan.urls.count <= 50 else { throw BrowserOperationError.invalidPlan }
        consumed.insert(plan.id)
        running = true; generation = UUID()
        let token = generation
        browser.protectAssistantTabs(Set(plan.sources.map(\.id)))
        defer { running = false; browser.protectAssistantTabs([]) }
        for step in plan.steps {
            try Task.checkCancellation()
            guard generation == token else { throw BrowserOperationError.cancelled }
            try checkSources(plan, browser: browser)
            switch step.kind {
            case .groupTabs:
                let group = try browser.createGroup(name: step.name)
                let placeholder = browser.activeTabID
                plan.sources.forEach { browser.moveTab($0.id, to: group) }
                if let placeholder, !plan.sources.contains(where: { $0.id == placeholder }) { browser.close(placeholder) }
                if let first = plan.sources.first { browser.activate(first.id) }
            case .saveWorkspace:
                _ = try browser.workspaceStore.save(name: step.name, urls: plan.sources.compactMap(\.url))
            case .openURLs:
                for url in plan.urls { browser.newTab().load(url) }
            case .reloadTabs:
                for source in plan.sources { browser.visibleTabs.first { $0.id == source.id }?.reload() }
            case .closeTabs:
                plan.sources.forEach { browser.close($0.id) }
            case .scrollDown:
                guard let source = plan.sources.first, let tab = browser.activeTab, tab.id == source.id,
                      let url = source.url, ["http", "https"].contains(url.scheme ?? "") else { throw BrowserOperationError.changed }
                let result = try await tab.webView.callAsyncJavaScript(
                    "if (location.href !== expectedURL) return false; window.scrollBy(0, Math.max(100, innerHeight * 0.8)); return true;",
                    arguments: ["expectedURL": url.absoluteString], in: nil, contentWorld: .defaultClient)
                guard result as? Bool == true else { throw BrowserOperationError.changed }
            }
            completedSteps += 1
            await Task.yield()
        }
    }

    private func checkSources(_ plan: BrowserOperationPlan, browser: BrowserSession) throws {
        guard browser.windowID == plan.windowID, browser.activeProfileID == plan.profileID else { throw BrowserOperationError.changed }
        for source in plan.sources {
            guard let tab = browser.visibleTabs.first(where: { $0.id == source.id }), !tab.isLoading,
                  tab.navigationEpoch == source.epoch, (tab.requestedURL ?? tab.url) == source.url else { throw BrowserOperationError.changed }
        }
    }
}
