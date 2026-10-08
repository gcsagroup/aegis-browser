import BrowserKit
import SwiftUI

struct BookmarkLinkCheckerView: View {
    let bookmarks: [BrowserBookmark]
    @State private var results: [BookmarkLinkResult] = []
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section {
                Text("检查会访问前 50 条收藏的网址，不发送 Cookie 或模型请求。访问受限和暂时失败不会被当作失效，也不会删除任何收藏。")
                    .font(.callout)
                Button(busy ? "停止检查" : "开始检查") {
                    if busy { operation?.cancel(); busy = false } else { start() }
                }.disabled(bookmarks.isEmpty)
                if busy { ProgressView() }
            }
            ForEach(results) { result in
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.title)
                    Text(result.url.host ?? "").font(.caption).foregroundStyle(.secondary)
                    Text(result.status.title).font(.callout)
                }
            }
        }
        .navigationTitle("检查收藏链接")
        .onDisappear { operation?.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { operation?.cancel(); busy = false } }
    }
    private func start() {
        results = []; busy = true
        let selected = Array(bookmarks.prefix(50))
        operation = Task { @MainActor in
            defer { busy = false }
            for bookmark in selected {
                guard !Task.isCancelled, let url = URL(string: bookmark.url) else { return }
                let result = await BookmarkLinkChecker.check(id: bookmark.id, title: bookmark.title, url: url)
                guard !Task.isCancelled else { return }
                results.append(result)
            }
        }
    }
}
