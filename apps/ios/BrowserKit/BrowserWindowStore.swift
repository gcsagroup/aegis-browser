import Combine
import AegisPolicyKit
import Foundation

public struct BrowserTabGroup: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

public struct SavedBrowserTab: Codable, Equatable, Sendable {
    public let id: UUID
    public let url: URL?
    public let groupID: UUID?
    public let title: String?
    public let scrollOffset: Double?
    public init(id: UUID, url: URL?, groupID: UUID?, title: String? = nil, scrollOffset: Double? = nil) {
        self.id = id; self.url = url; self.groupID = groupID; self.title = title; self.scrollOffset = scrollOffset
    }
}

public struct BrowserWindowSnapshot: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var tabs: [SavedBrowserTab]
    public var groups: [BrowserTabGroup]
    public var selectedGroupID: UUID?
    public var activeTabID: UUID?
    public var updatedAt: Date
    public init(id: UUID, name: String = "", tabs: [SavedBrowserTab] = [], groups: [BrowserTabGroup] = [],
                selectedGroupID: UUID? = nil, activeTabID: UUID? = nil, updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.tabs = tabs; self.groups = groups
        self.selectedGroupID = selectedGroupID; self.activeTabID = activeTabID; self.updatedAt = updatedAt
    }
}

/// 所有窗口共用一个主线程存储实例，按窗口身份更新，避免后写窗口覆盖其他窗口。
/// 文件只接收普通会话的快照；私密标签与分组由 BrowserSession 留在内存中。
@MainActor public final class BrowserWindowStore: ObservableObject {
    @Published public private(set) var windows: [BrowserWindowSnapshot] = []
    @Published public private(set) var storageError: String?
    @Published public private(set) var openIDs: Set<UUID> = []
    private let persistenceURL: URL?
    private var unreadable = false

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("browser-windows-v1.json")
    }

    public init(persistenceURL: URL? = nil, legacyURLs: [URL] = []) {
        self.persistenceURL = persistenceURL
        if let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) {
            do {
                let data = try Data(contentsOf: persistenceURL)
                guard data.count <= 4_000_000 else { throw BrowserWindowError.invalidData }
                let values = try JSONDecoder().decode([BrowserWindowSnapshot].self, from: data)
                guard values.count <= 20, Set(values.map(\.id)).count == values.count else { throw BrowserWindowError.invalidData }
                windows = try values.map(Self.sanitized)
            } catch { unreadable = true; storageError = String(localized: "窗口记录无法读取，原文件已保留。") }
        } else if !legacyURLs.isEmpty {
            let tabs = WorkspaceStore.persistableURLs(legacyURLs).map { SavedBrowserTab(id: UUID(), url: $0, groupID: nil) }
            do { try save(BrowserWindowSnapshot(id: UUID(), tabs: tabs, activeTabID: tabs.first?.id)) }
            catch { storageError = error.localizedDescription }
        }
    }

    public func defaultWindowID() -> UUID {
        if openIDs.isEmpty, let previous = windows.max(by: { $0.updatedAt < $1.updatedAt }) { return previous.id }
        return UUID()
    }
    public func register(_ id: UUID) { openIDs.insert(id) }
    public func unregister(_ id: UUID) { openIDs.remove(id) }
    public func snapshot(_ id: UUID) -> BrowserWindowSnapshot? { windows.first { $0.id == id } }

    @discardableResult public func createWindow() throws -> UUID {
        let id = UUID()
        try save(BrowserWindowSnapshot(id: id))
        return id
    }

    public func save(_ value: BrowserWindowSnapshot) throws {
        guard !unreadable else { throw BrowserWindowError.invalidData }
        let value = try Self.sanitized(value)
        var next = windows.filter { $0.id != value.id }
        guard next.count < 20 else { throw BrowserWindowError.capacity }
        next.append(value)
        try persist(next)
        windows = next; storageError = nil
    }

    public func rename(_ id: UUID, to name: String) throws {
        guard var value = snapshot(id) else { return }
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty else { throw BrowserWindowError.invalidName }
        try save(value)
    }

    public func removeSavedWindow(_ id: UUID) throws {
        guard !openIDs.contains(id), !unreadable else { throw BrowserWindowError.windowOpen }
        let next = windows.filter { $0.id != id }
        try persist(next); windows = next
    }

    private func persist(_ values: [BrowserWindowSnapshot]) throws {
        guard let persistenceURL else { return }
        let data = try JSONEncoder().encode(values)
        guard data.count <= 4_000_000 else { throw BrowserWindowError.capacity }
        try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: persistenceURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private static func sanitized(_ input: BrowserWindowSnapshot) throws -> BrowserWindowSnapshot {
        guard input.tabs.count <= 200, input.groups.count <= 20,
              Set(input.tabs.map(\.id)).count == input.tabs.count,
              Set(input.groups.map(\.id)).count == input.groups.count else { throw BrowserWindowError.invalidData }
        var value = input
        value.name = String(value.name.prefix(80))
        value.groups = value.groups.map { BrowserTabGroup(id: $0.id, name: String($0.name.prefix(80))) }
        let groupIDs = Set(value.groups.map(\.id))
        value.tabs = value.tabs.map { tab in
            SavedBrowserTab(id: tab.id, url: tab.url.flatMap { WorkspaceStore.persistableURLs([$0]).first },
                            groupID: tab.groupID.flatMap { groupIDs.contains($0) ? $0 : nil },
                            title: tab.title.map { String(PIIScanner.scan($0).redacted.prefix(200)) },
                            scrollOffset: tab.scrollOffset.flatMap { $0.isFinite ? min(10_000_000, max(0, $0)) : nil })
        }
        if let group = value.selectedGroupID, !groupIDs.contains(group) { value.selectedGroupID = nil }
        if !value.tabs.contains(where: { $0.id == value.activeTabID }) { value.activeTabID = value.tabs.first?.id }
        return value
    }
}

public enum BrowserWindowError: LocalizedError {
    case invalidData, capacity, invalidName, windowOpen
    public var errorDescription: String? {
        switch self {
        case .invalidData: String(localized: "窗口记录无效，未覆盖原有数据。")
        case .capacity: String(localized: "窗口存储已达上限，请先删除不需要的已关闭窗口。")
        case .invalidName: String(localized: "请输入名称。")
        case .windowOpen: String(localized: "请先关闭该窗口，再删除保存的记录。")
        }
    }
}
