import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureUI()
        receiveURL()
    }

    private func configureUI() {
        let mark = UIImageView(image: UIImage(systemName: "shield.lefthalf.filled"))
        mark.tintColor = .systemGreen
        mark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
        statusLabel.text = "正在验证分享链接…"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        activity.startAnimating()

        let stack = UIStackView(arrangedSubviews: [mark, statusLabel, activity])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func receiveURL() {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }) else {
            finish(error: ShareInboxError.invalidEnvelope)
            return
        }
        let type = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            ? UTType.url.identifier
            : UTType.plainText.identifier
        provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] (item: NSSecureCoding?, error: Error?) in
            let value: String?
            if let url = item as? URL {
                value = url.absoluteString
            } else if let text = item as? String {
                value = text
            } else if let data = item as? Data, data.count <= ShareInbox.maximumPayloadBytes {
                value = String(data: data, encoding: .utf8)
            } else {
                value = nil
            }
            let errorMessage = error?.localizedDescription
            Task { @MainActor [weak self, value, errorMessage] in
                self?.handleLoadedValue(value, errorMessage: errorMessage)
            }
        }
    }

    private func handleLoadedValue(_ value: String?, errorMessage: String?) {
        if let errorMessage {
            finish(error: NSError(domain: "AegisShare", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
            return
        }
        guard let value else {
            finish(error: ShareInboxError.invalidEnvelope)
            return
        }
        do {
            let inbox = try ShareInbox()
            let envelope = try inbox.makeEnvelope(from: value)
            try inbox.store(envelope)
            statusLabel.text = "已安全交给 Aegis\n60 秒内打开 App 即可接收"
            activity.stopAnimating()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        } catch {
            finish(error: error)
        }
    }

    private func finish(error: Error) {
        statusLabel.text = error.localizedDescription
        statusLabel.textColor = .systemRed
        activity.stopAnimating()
        extensionContext?.cancelRequest(withError: error)
    }
}
