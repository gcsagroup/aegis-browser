import SwiftUI
import WebKit

public struct BrowserWebView: UIViewRepresentable {
    public let webView: WKWebView

    private let onFind: (() -> Void)?
    private let onScroll: ((Bool) -> Void)?

    public init(webView: WKWebView, onFind: (() -> Void)? = nil, onScroll: ((Bool) -> Void)? = nil) {
        self.webView = webView; self.onFind = onFind; self.onScroll = onScroll
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> WKWebView {
        (webView as? BrowserContentWebView)?.onFind = onFind
        context.coordinator.onScroll = onScroll
        context.coordinator.scrollView = webView.scrollView
        webView.scrollView.panGestureRecognizer.addTarget(context.coordinator, action: #selector(Coordinator.didPan(_:)))
        return webView
    }
    public func updateUIView(_ uiView: WKWebView, context: Context) {
        (uiView as? BrowserContentWebView)?.onFind = onFind
        context.coordinator.onScroll = onScroll
    }
    public static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        (uiView as? BrowserContentWebView)?.onFind = nil
        uiView.scrollView.panGestureRecognizer.removeTarget(coordinator, action: #selector(Coordinator.didPan(_:)))
        coordinator.onScroll = nil
        coordinator.scrollView = nil
    }

    /// 只响应用户在网页上的拖动，不更换 WebKit 的滚动代理，也不读取页面内容。
    @MainActor public final class Coordinator: NSObject {
        weak var scrollView: UIScrollView?
        var onScroll: ((Bool) -> Void)?
        private var anchor: CGFloat = 0

        @objc func didPan(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView else { return }
            let translation = gesture.translation(in: scrollView).y
            if gesture.state == .began { anchor = translation; return }
            guard gesture.state == .changed else { return }
            let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            guard scrollView.contentSize.height > scrollView.bounds.height + 120, offset > 12 else {
                onScroll?(false); anchor = translation; return
            }
            if translation - anchor < -48 {
                onScroll?(true); anchor = translation
            } else if translation - anchor > 24 {
                onScroll?(false); anchor = translation
            }
        }
    }
}

/// 网页取得焦点后，查找快捷键由 WebKit 的响应链处理。
final class BrowserContentWebView: WKWebView {
    var onFind: (() -> Void)?
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        let find = UIKeyCommand(input: "f", modifierFlags: .command, action: #selector(showPageFind))
        find.discoverabilityTitle = String(localized: "在页面中查找")
        find.wantsPriorityOverSystemBehavior = true
        return [find] + (super.keyCommands ?? [])
    }

    @objc private func showPageFind() {
        onFind?()
    }
}
