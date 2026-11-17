import Foundation
import WebKit

@available(iOS 18.4, *)
@MainActor
public final class WebExtensionRuntime {
    public enum RuntimeError: Error {
        case missingResources
        case loadRejected
        case invalidSite
    }

    public let controller: WKWebExtensionController
    public private(set) var context: WKWebExtensionContext?
    private var loading = false
    public private(set) var status = "尚未加载"

    public init(isPrivate: Bool) {
        let configuration = isPrivate
            ? WKWebExtensionController.Configuration.nonPersistent()
            : WKWebExtensionController.Configuration.default()
        controller = WKWebExtensionController(configuration: configuration)
    }

    public func apply(to configuration: WKWebViewConfiguration) {
        configuration.webExtensionController = controller
    }

    public func loadSharedResources(from resourceURL: URL?) async throws {
        guard let resourceURL else {
            status = "共享扩展资源缺失"
            throw RuntimeError.missingResources
        }
        if context != nil {
            try setEnabled(true)
            return
        }
        guard !loading else { throw RuntimeError.loadRejected }
        loading = true
        defer { loading = false }
        let webExtension = try await WKWebExtension(resourceBaseURL: resourceURL)
        let extensionContext = WKWebExtensionContext(for: webExtension)
        extensionContext.uniqueIdentifier = "com.gcsa.aegis.shared.readonly"
        extensionContext.unsupportedAPIs = [
            "browser.downloads",
            "browser.tabs.create",
            "browser.tabs.remove",
            "browser.webNavigation"
        ]
        context = extensionContext
        do {
            try setEnabled(true)
        } catch {
            context = nil
            throw error
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        guard let context else { throw RuntimeError.loadRejected }
        if enabled && !context.isLoaded {
            try controller.load(context)
        } else if !enabled && context.isLoaded {
            try controller.unload(context)
        }
        status = enabled ? "Shared WebExtension 已加载" : "Shared WebExtension 已停用"
    }

    public func revokeSitePermission(_ url: URL) throws {
        guard let context else { throw RuntimeError.loadRejected }
        guard ["http", "https"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.password == nil
        else { throw RuntimeError.invalidSite }
        context.setPermissionStatus(.deniedExplicitly, for: url)
    }
}
