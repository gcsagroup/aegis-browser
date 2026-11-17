import UIKit
import WebKit

public enum WebpageCaptureError: Error, Equatable {
    case unavailable
    case tooLarge
}

@MainActor
extension BrowserTab {
    public func captureFullPage() async throws -> UIImage {
        guard let scheme = url?.scheme, ["http", "https"].contains(scheme),
              protectionIncident == nil, !isLoading else {
            throw WebpageCaptureError.unavailable
        }
        let view = webView
        let epoch = navigationEpoch
        let scroll = view.scrollView
        let size = scroll.contentSize
        let inset = scroll.adjustedContentInset
        let viewport = view.bounds.inset(by: inset)
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, viewport.width > 1, viewport.height > 1,
              size.width <= 4096, size.height <= 36_000 else {
            throw WebpageCaptureError.tooLarge
        }
        let columns = Int(ceil(size.width / viewport.width))
        let rows = Int(ceil(size.height / viewport.height))
        guard columns * rows <= 45 else { throw WebpageCaptureError.tooLarge }
        let savedOffset = scroll.contentOffset
        defer {
            if epoch == navigationEpoch && webView === view {
                scroll.setContentOffset(savedOffset, animated: false)
            }
        }
        let screenScale = view.traitCollection.displayScale
        let scale = min(screenScale, sqrt(16_000_000 / (size.width * size.height)))
        var parts: [(image: UIImage, rect: CGRect)] = []
        for row in 0..<rows {
            for column in 0..<columns {
                try Task.checkCancellation()
                guard epoch == navigationEpoch, webView === view else {
                    throw WebpageCaptureError.unavailable
                }
                let x = CGFloat(column) * viewport.width
                let y = CGFloat(row) * viewport.height
                let offset = CGPoint(x: min(x, max(0, size.width - viewport.width)),
                                     y: min(y, max(0, size.height - viewport.height)))
                scroll.setContentOffset(CGPoint(x: offset.x - inset.left, y: offset.y - inset.top),
                                        animated: false)
                // 等待网页进程完成滚动后的两次绘制，再读取当前视口。
                _ = try await view.callAsyncJavaScript(
                    "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))); return true;",
                    arguments: [:], in: nil, contentWorld: .defaultClient)
                let part = CGRect(x: x, y: y, width: min(viewport.width, size.width - x),
                                  height: min(viewport.height, size.height - y))
                let configuration = WKSnapshotConfiguration()
                configuration.rect = viewport
                configuration.snapshotWidth = NSNumber(value: viewport.width * min(1, scale / max(1, screenScale)))
                configuration.afterScreenUpdates = true
                let image = try await view.takeSnapshot(configuration: configuration)
                guard let image = image.cgImage else { throw WebpageCaptureError.unavailable }
                let sx = CGFloat(image.width) / viewport.width
                let sy = CGFloat(image.height) / viewport.height
                let source = CGRect(x: (x - offset.x) * sx, y: (y - offset.y) * sy,
                                    width: part.width * sx, height: part.height * sy).integral
                guard let tile = image.cropping(to: source) else { throw WebpageCaptureError.unavailable }
                parts.append((UIImage(cgImage: tile), part))
            }
        }
        guard epoch == navigationEpoch, webView === view, !Task.isCancelled else {
            throw WebpageCaptureError.unavailable
        }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.white.setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            for part in parts { part.image.draw(in: part.rect) }
        }
    }
}

@MainActor
enum WebpageImageHitTest {
    static func capture(at point: CGPoint, in view: WKWebView) async -> UIImage? {
        guard let scheme = view.url?.scheme, ["http", "https"].contains(scheme),
              view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let bounds = view.bounds
        let script = """
        const vp = window.visualViewport;
        const scale = (vp?.width || window.innerWidth) / width;
        const dx = vp?.offsetLeft || 0, dy = vp?.offsetTop || 0;
        const image = document.elementFromPoint(x * scale + dx, y * scale + dy);
        if (!(image instanceof HTMLImageElement) || !image.complete || !image.naturalWidth) return null;
        const rect = image.getBoundingClientRect();
        const result = {x: (rect.x-dx)/scale, y: (rect.y-dy)/scale, w: rect.width/scale, h: rect.height/scale};
        if (image.naturalWidth <= 4096 && image.naturalHeight <= 4096 &&
            image.naturalWidth * image.naturalHeight <= 4000000) {
          try {
            const canvas = document.createElement('canvas');
            canvas.width = image.naturalWidth;
            canvas.height = image.naturalHeight;
            canvas.getContext('2d').drawImage(image, 0, 0);
            const png = canvas.toDataURL('image/png');
            if (png.length <= 4000000) result.png = png.slice('data:image/png;base64,'.length);
          } catch (_) {}
        }
        return result;
        """
        guard let result = try? await view.callAsyncJavaScript(
            script, arguments: ["x": point.x, "y": point.y, "width": bounds.width],
            in: nil, contentWorld: .defaultClient) as? [String: Any], !Task.isCancelled else {
            return nil
        }
        if let encoded = result["png"] as? String, encoded.count <= 4_000_000,
           let data = Data(base64Encoded: encoded), let image = UIImage(data: data) {
            return image
        }
        // 受网页跨域规则保护的图片只读取当前实际显示的像素。
        guard let x = result["x"] as? Double, let y = result["y"] as? Double,
              let w = result["w"] as? Double, let h = result["h"] as? Double,
              [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0 else { return nil }
        let rect = CGRect(x: x, y: y, width: w, height: h).intersection(bounds)
        guard !rect.isNull, !rect.isEmpty else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        return try? await view.takeSnapshot(configuration: configuration)
    }
}
