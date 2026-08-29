import SwiftUI
import WebKit

public struct BrowserWebView: UIViewRepresentable {
    public let webView: WKWebView

    public init(webView: WKWebView) {
        self.webView = webView
    }

    public func makeUIView(context: Context) -> WKWebView { webView }
    public func updateUIView(_ uiView: WKWebView, context: Context) {}
}
