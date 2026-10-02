import Foundation

/// 外部入口只接受一个普通网页地址。打开页面仍需用户确认，不携带模型动作。
enum ExternalPageLink {
    static func destination(_ input: URL) -> URL? {
        guard input.scheme == "gcsa-aegis", input.host == "open", input.user == nil, input.password == nil,
              input.fragment == nil, input.absoluteString.utf8.count <= 12_000,
              let parts = URLComponents(url: input, resolvingAgainstBaseURL: false),
              let query = parts.queryItems, query.count == 1, query[0].name == "url",
              let value = query[0].value, value.utf8.count <= ShareInbox.maximumPayloadBytes,
              let url = URL(string: value), ["http", "https"].contains(url.scheme ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
