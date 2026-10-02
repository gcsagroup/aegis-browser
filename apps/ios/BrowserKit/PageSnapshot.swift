import Foundation
import WebKit

public struct PageSnapshot: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let navigationEpoch: UInt64
    public let url: URL
    public let title: String
    public let text: String
    public let capturedAt: Date
    public let truncated: Bool
}

public enum PageSnapshotError: LocalizedError {
    case unavailable, changed, sensitive
    public var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "此页面暂时无法读取，请等待加载完成或换一个普通网页。")
        case .changed: String(localized: "页面已经变化，请重新确认要使用的页面。")
        case .sensitive: String(localized: "此页面包含登录或支付表单，请换一个不含敏感表单的页面。")
        }
    }
}

extension BrowserTab {
    /// 调用方必须先取得明确授权。固定标签、完整 URL 和导航版本，读取后再次核对。
    public func snapshot() async throws -> PageSnapshot {
        guard !profile.isPrivate, !isLoading, let expectedURL = url,
              ["http", "https"].contains(expectedURL.scheme ?? "") else { throw PageSnapshotError.unavailable }
        let epoch = navigationEpoch
        let script = """
        const expected = expectedURL;
        if (location.href !== expected) return {changed: true};
        if (document.querySelector('input[type=password],input[autocomplete="cc-number"],input[autocomplete="one-time-code"]')) return {sensitive: true};
        const root = document.querySelector('main,article') || document.body;
        const pieces = [];
        let length = 0;
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode(node) {
                const parent = node.parentElement;
                if (!parent || parent.closest('script,style,noscript,input,textarea,select,[contenteditable],nav,footer,[hidden],[aria-hidden="true"]')) return NodeFilter.FILTER_REJECT;
                for (let element = parent; element; element = element.parentElement) {
                    const style = getComputedStyle(element);
                    if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return NodeFilter.FILTER_REJECT;
                }
                return NodeFilter.FILTER_ACCEPT;
            }
        });
        while (walker.nextNode()) {
            const text = walker.currentNode.textContent.replace(/\\s+/g, ' ').trim();
            if (text) { pieces.push(text); length += text.length + 1; }
            if (length > 24000) break;
        }
        return {url: location.href, title: document.title.slice(0, 300), text: pieces.join(' ').slice(0, 24000), truncated: length > 24000};
        """
        let result = try await webView.callAsyncJavaScript(script, arguments: ["expectedURL": expectedURL.absoluteString],
                                                          in: nil, contentWorld: .defaultClient)
        try Task.checkCancellation()
        guard epoch == navigationEpoch, url == expectedURL, !isLoading,
              let value = result as? [String: Any], value["changed"] == nil else { throw PageSnapshotError.changed }
        guard value["sensitive"] == nil else { throw PageSnapshotError.sensitive }
        guard value["url"] as? String == expectedURL.absoluteString,
              let text = value["text"] as? String, !text.isEmpty else { throw PageSnapshotError.unavailable }
        return PageSnapshot(id: id, navigationEpoch: epoch, url: expectedURL,
                            title: value["title"] as? String ?? title, text: text, capturedAt: Date(), truncated: value["truncated"] as? Bool ?? false)
    }
}
