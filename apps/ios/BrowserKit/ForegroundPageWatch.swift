import Combine
import CryptoKit
import Foundation

/// 检查仅在用户打开此面板并明确启动后运行；不持久化正文，不向模型发送内容。
@MainActor public final class ForegroundPageWatch: ObservableObject {
    @Published public private(set) var running = false
    @Published public private(set) var checks = 0
    @Published public private(set) var changed = false
    @Published public private(set) var lastChecked: Date?
    @Published public private(set) var error: String?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    public init() { }

    public func start(tab: BrowserTab, interval: TimeInterval) {
        stop()
        guard [60.0, 300, 900].contains(interval), let url = tab.url,
              ["http", "https"].contains(url.scheme ?? ""), !tab.isLoading else {
            error = PageSnapshotError.unavailable.localizedDescription; return
        }
        running = true; checks = 0; changed = false; error = nil; lastChecked = nil
        let token = generation
        operation = Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            defer { if generation == token { running = false } }
            do {
                var expectedEpoch = tab.navigationEpoch
                var previous: Data?
                while !Task.isCancelled, generation == token {
                    guard tab.url == url, tab.navigationEpoch == expectedEpoch, !tab.isLoading else { throw PageSnapshotError.changed }
                    if previous != nil { tab.reload() }
                    let value = try await tab.snapshot(privateReadConfirmed: tab.profile.isPrivate)
                    try Task.checkCancellation()
                    guard generation == token, value.url == url else { throw PageSnapshotError.changed }
                    expectedEpoch = value.navigationEpoch
                    let hash = Self.digest(value.text)
                    if let previous, previous != hash { changed = true }
                    previous = hash; checks += 1; lastChecked = Date()
                    try await Task.sleep(for: .seconds(interval))
                }
            } catch is CancellationError { } catch {
                if generation == token { self.error = error.localizedDescription }
            }
        }
    }
    public func stop() { generation = UUID(); operation?.cancel(); operation = nil; running = false }
    public nonisolated static func digest(_ text: String) -> Data {
        Data(SHA256.hash(data: Data(text.utf8)))
    }
}
