import Foundation

public struct BookmarkLinkResult: Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let url: URL
    public let status: Status
    public enum Status: String, Sendable {
        case reachable, missing, restricted, unknown
        public var title: String {
            switch self {
            case .reachable: String(localized: "可以访问")
            case .missing: String(localized: "页面不存在")
            case .restricted: String(localized: "需要登录或访问许可")
            case .unknown: String(localized: "暂时无法判断")
            }
        }
    }
}

private final class LinkRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, url.user == nil, url.password == nil,
              BrowserNavigationPolicy.evaluate(url).kind != .blocked,
              ["https", "http"].contains(url.scheme ?? ""),
              !(response.url?.scheme == "https" && url.scheme != "https") else { completionHandler(nil); return }
        completionHandler(request)
    }
}

public enum BookmarkLinkChecker {
    public static func check(id: UUID, title: String, url: URL) async -> BookmarkLinkResult {
        let status: BookmarkLinkResult.Status
        do {
            guard ["https", "http"].contains(url.scheme ?? ""), url.user == nil, url.password == nil,
                  BrowserNavigationPolicy.evaluate(url).kind != .blocked else { throw URLError(.unsupportedURL) }
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: config, delegate: LinkRedirectGuard(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            let (_, response) = try await session.bytes(for: request)
            var code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 405 || code == 501 {
                request.httpMethod = "GET"
                request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
                let (_, fallback) = try await session.bytes(for: request)
                code = (fallback as? HTTPURLResponse)?.statusCode ?? 0
            }
            switch code {
            case 200..<300: status = .reachable
            case 404, 410: status = .missing
            case 401, 403: status = .restricted
            default: status = .unknown
            }
        } catch { status = .unknown }
        return BookmarkLinkResult(id: id, title: title, url: url, status: status)
    }
}
