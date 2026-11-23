import UIKit
import WebKit
@testable import BrowserKit

/// 本机 HTTP 导航会等待网页进入窗口；测试须复现实际界面的挂载与关闭。
@MainActor
final class WebKitTestWindows {
    private var windows: [ObjectIdentifier: UIWindow] = [:]

    func attach(_ view: WKWebView) {
        guard view.window == nil else { return }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState != .unattached }
        view.frame = window.bounds
        window.addSubview(view)
        window.makeKeyAndVisible()
        windows[ObjectIdentifier(view)] = window
    }

    func close() {
        for window in windows.values {
            for view in window.subviews { view.removeFromSuperview() }
            window.isHidden = true
        }
        windows.removeAll()
    }
}
