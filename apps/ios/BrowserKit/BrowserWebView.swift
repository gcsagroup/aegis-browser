import SwiftUI
import WebKit

public struct BrowserWebView: UIViewRepresentable {
    public let webView: WKWebView

    private let onFind: (() -> Void)?
    private let onScroll: ((Bool) -> Void)?
    private let onImage: ((UIImage) -> Void)?

    public init(webView: WKWebView, onFind: (() -> Void)? = nil, onScroll: ((Bool) -> Void)? = nil,
                onImage: ((UIImage) -> Void)? = nil) {
        self.webView = webView; self.onFind = onFind; self.onScroll = onScroll; self.onImage = onImage
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> WKWebView {
        (webView as? BrowserContentWebView)?.onFind = onFind
        context.coordinator.onScroll = onScroll
        context.coordinator.onImage = onImage
        context.coordinator.scrollView = webView.scrollView
        webView.scrollView.panGestureRecognizer.addTarget(context.coordinator, action: #selector(Coordinator.didPan(_:)))
        if onImage != nil {
            let interaction = UIContextMenuInteraction(delegate: context.coordinator)
            context.coordinator.imageMenu = interaction
            webView.addInteraction(interaction)
        }
        return webView
    }
    public func updateUIView(_ uiView: WKWebView, context: Context) {
        (uiView as? BrowserContentWebView)?.onFind = onFind
        context.coordinator.onScroll = onScroll
        context.coordinator.onImage = onImage
    }
    public static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        (uiView as? BrowserContentWebView)?.onFind = nil
        uiView.scrollView.panGestureRecognizer.removeTarget(coordinator, action: #selector(Coordinator.didPan(_:)))
        coordinator.onScroll = nil
        coordinator.onImage = nil
        if let menu = coordinator.imageMenu { uiView.removeInteraction(menu) }
        coordinator.imageMenu = nil
        coordinator.scrollView = nil
    }

    /// 只响应用户在网页上的拖动，不更换 WebKit 的滚动代理，也不读取页面内容。
    @MainActor public final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        weak var scrollView: UIScrollView?
        var onScroll: ((Bool) -> Void)?
        var onImage: ((UIImage) -> Void)?
        var imageMenu: UIContextMenuInteraction?
        private var anchor: CGFloat = 0

        public func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                           configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard let view = interaction.view as? WKWebView, onImage != nil else { return nil }
            // 异步命中图片后才显示识字项，原有链接和图片菜单继续交给 WebKit。
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self, weak view] suggested in
                let imageItem = UIDeferredMenuElement.uncached { completion in
                    Task { @MainActor [weak self, weak view] in
                        guard let self, let view, let image = await WebpageImageHitTest.capture(at: location, in: view),
                              interaction.view === view, self.onImage != nil else {
                            completion([])
                            return
                        }
                        completion([UIAction(title: AegisLocalization.string("识别图片文字"),
                                             image: UIImage(systemName: "text.viewfinder")) { [weak self] _ in
                            self?.onImage?(image)
                        }])
                    }
                }
                return UIMenu(children: suggested + [imageItem])
            }
        }

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
    private var terminalNavigation: TerminalNavigation?
    private var installingTerminalDocument = false
    private static let inertHTML = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'none'\"><title></title>"

    func terminateDocument(completion: @escaping @MainActor () -> Void) {
        guard terminalNavigation == nil else { return }
        stopLoading()
        onFind = nil; onDidMoveToWindow = nil
        configuration.userContentController.removeAllUserScripts()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let terminal = TerminalNavigation(completion: completion)
        terminalNavigation = terminal
        navigationDelegate = terminal
        installingTerminalDocument = true
        terminal.navigation = super.loadHTMLString(Self.inertHTML, baseURL: URL(string: "about:blank")!)
        installingTerminalDocument = false
    }

    override func load(_ request: URLRequest) -> WKNavigation? {
        guard terminalNavigation == nil || installingTerminalDocument else { return nil }
        return super.load(request)
    }
    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        guard terminalNavigation == nil || installingTerminalDocument else { return nil }
        return super.loadHTMLString(string, baseURL: baseURL)
    }
    override func loadFileURL(_ URL: URL, allowingReadAccessTo readAccessURL: URL) -> WKNavigation? {
        guard terminalNavigation == nil || installingTerminalDocument else { return nil }
        return super.loadFileURL(URL, allowingReadAccessTo: readAccessURL)
    }
    override func reload() -> WKNavigation? { terminalNavigation == nil ? super.reload() : nil }
    override func reloadFromOrigin() -> WKNavigation? { terminalNavigation == nil ? super.reloadFromOrigin() : nil }
    override func goBack() -> WKNavigation? { terminalNavigation == nil ? super.goBack() : nil }
    override func goForward() -> WKNavigation? { terminalNavigation == nil ? super.goForward() : nil }
    override func go(to item: WKBackForwardListItem) -> WKNavigation? {
        terminalNavigation == nil ? super.go(to: item) : nil
    }

    /// A committed inert document has destroyed the prior JS realm. If UIKit
    /// releases the view first, delegate destruction supplies the same receipt.
    private final class TerminalNavigation: NSObject, WKNavigationDelegate {
        var navigation: WKNavigation?
        private var completion: (@MainActor () -> Void)?
        init(completion: @escaping @MainActor () -> Void) { self.completion = completion }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard let navigation, navigation === self.navigation else { return }
            let finish = completion; completion = nil
            finish?()
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(completion != nil && action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
        deinit {
            let finish = completion
            Task { @MainActor in finish?() }
        }
    }
    var onFind: (() -> Void)?
    var onDidMoveToWindow: (() -> Void)?
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        let find = UIKeyCommand(input: "f", modifierFlags: .command, action: #selector(showPageFind))
        find.discoverabilityTitle = AegisLocalization.string("在页面中查找")
        find.wantsPriorityOverSystemBehavior = true
        return [find] + (super.keyCommands ?? [])
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onDidMoveToWindow?()
    }

    @objc private func showPageFind() {
        onFind?()
    }
}
