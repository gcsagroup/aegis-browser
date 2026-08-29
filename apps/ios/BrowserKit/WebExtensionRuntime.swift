import Foundation
import WebKit

@available(iOS 18.4, *)
@MainActor
public final class WebExtensionRuntime {
    public enum RuntimeError: Error {
        case missingResources
        case loadRejected
    }

    public let controller: WKWebExtensionController
    public private(set) var context: WKWebExtensionContext?
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
        let webExtension = try await WKWebExtension(resourceBaseURL: resourceURL)
        let extensionContext = WKWebExtensionContext(for: webExtension)
        extensionContext.uniqueIdentifier = "com.gcsa.aegis.shared.readonly"
        extensionContext.unsupportedAPIs = [
            "browser.downloads",
            "browser.tabs.create",
            "browser.tabs.remove",
            "browser.webNavigation"
        ]
        try controller.load(extensionContext)
        context = extensionContext
        status = "Shared WebExtension 已加载"
    }
}
