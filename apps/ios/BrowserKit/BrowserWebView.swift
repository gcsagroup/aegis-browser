import SwiftUI
import WebKit

public struct BrowserWebView: UIViewRepresentable {
    public let webView: WKWebView

    private let onFind: (() -> Void)?

    public init(webView: WKWebView, onFind: (() -> Void)? = nil) {
        self.webView = webView; self.onFind = onFind
    }

    public func makeUIView(context: Context) -> WKWebView {
        (webView as? BrowserContentWebView)?.onFind = onFind
        return webView
    }
    public func updateUIView(_ uiView: WKWebView, context: Context) {
        (uiView as? BrowserContentWebView)?.onFind = onFind
    }
    public static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        (uiView as? BrowserContentWebView)?.onFind = nil
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
