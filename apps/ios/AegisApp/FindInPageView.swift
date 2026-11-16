import BrowserKit
import SwiftUI
import WebKit

@MainActor
final class FindInPageModel: ObservableObject {
    @Published var text = "" { didSet { invalidate() } }
    @Published private(set) var message: AegisLocalizedMessage?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private let search: @MainActor (WKWebView, String) async throws -> Bool

    init(search: @escaping @MainActor (WKWebView, String) async throws -> Bool = { view, query in
        try await view.find(query, configuration: .init()).matchFound
    }) { self.search = search }

    func invalidate() {
        generation = UUID(); operation?.cancel(); operation = nil; message = nil
    }

    func find(in tab: BrowserTab) {
        invalidate()
        guard !text.isEmpty, !tab.isDisposed else { return }
        let token = generation, epoch = tab.navigationEpoch, viewGeneration = tab.webViewGeneration
        let view = tab.webView, query = text
        operation = Task { @MainActor in
            do {
                let found = try await search(view, query)
                guard !Task.isCancelled, generation == token, !tab.isDisposed,
                      tab.navigationEpoch == epoch, tab.webViewGeneration == viewGeneration else { return }
                message = found ? .resource("已找到匹配内容。") : .resource("未找到匹配内容。")
            } catch {
                guard !Task.isCancelled, generation == token, !tab.isDisposed, tab.navigationEpoch == epoch else { return }
                message = .error(error)
            }
        }
    }
}

/// The query and reply belong to one presentation of one tab, never the window/profile.
struct FindInPageView: View {
    @ObservedObject var tab: BrowserTab
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = FindInPageModel()

    var body: some View {
        NavigationStack {
            Form {
                FindQueryField(text: $model.text)
                Button("查找下一个") {
                    guard scenePhase == .active else { return }
                    model.find(in: tab)
                }.disabled(model.text.isEmpty)
                Text(model.message?.text ?? "").accessibilityIdentifier("find-result")
            }
            .localizedNavigationTitle("在页面中查找")
            .toolbar { Button("完成") { model.invalidate(); dismiss() }.keyboardShortcut(.escape, modifiers: []) }
        }
        .presentationDetents([.medium])
        .onChange(of: tab.navigationEpoch) { _, _ in model.invalidate(); dismiss() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.invalidate(); dismiss() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            model.invalidate(); dismiss()
        }
        .onDisappear { model.invalidate(); model.text = "" }
    }
}
