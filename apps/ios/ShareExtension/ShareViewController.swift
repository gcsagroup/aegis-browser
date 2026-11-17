import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private var status: AegisLocalizedMessage = .resource("正在验证分享链接…")
    private let statusLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureUI()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLanguage),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        receiveURL()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshLanguage()
    }

    @objc private func refreshLanguage() { statusLabel.text = status.text }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func configureUI() {
        let mark = UIImageView(image: UIImage(systemName: "shield.lefthalf.filled"))
        mark.tintColor = .systemGreen
        mark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
        refreshLanguage()
        statusLabel.adjustsFontForContentSizeCategory = true
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
        let markdownType = "net.daringfireball.markdown"
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(markdownType) || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            let type = provider.hasItemConformingToTypeIdentifier(markdownType) ? markdownType : UTType.fileURL.identifier
            provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, failure in
                let result: Result<(String, Data), Error>
                do {
                    if let failure { throw failure }
                    guard let url = item as? URL, url.isFileURL, ["md", "markdown"].contains(url.pathExtension.lowercased()) else { throw ShareInboxError.invalidEnvelope }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let metadata = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard metadata.isRegularFile == true else { throw ShareInboxError.invalidEnvelope }
                    guard (metadata.fileSize ?? Int.max) <= MarkdownShareInbox.maximumTextBytes else {
                        throw MarkdownDocumentLimits.TooLarge()
                    }
                    // A provider's temporary URL must be copied while its callback owns it.
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var data = Data()
                    while data.count <= MarkdownShareInbox.maximumTextBytes,
                          let chunk = try handle.read(upToCount: min(65_536, MarkdownShareInbox.maximumTextBytes + 1 - data.count)), !chunk.isEmpty {
                        data.append(chunk)
                    }
                    guard data.count <= MarkdownShareInbox.maximumTextBytes else {
                        throw MarkdownDocumentLimits.TooLarge()
                    }
                    result = .success((url.lastPathComponent, data))
                } catch { result = .failure(error) }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let (title, data) = try result.get()
                        try await ShareInboxIO.shared.storeMarkdown(title: title, data: data)
                        self.status = .resource("文档已交给 Aegis，请在 60 秒内打开 App。")
                        self.refreshLanguage()
                        self.activity.stopAnimating()
                        self.extensionContext?.completeRequest(returningItems: nil)
                    } catch { self.finish(error: error) }
                }
            }
            return
        }
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
                await self?.handleLoadedValue(value, errorMessage: errorMessage)
            }
        }
    }

    private func handleLoadedValue(_ value: String?, errorMessage: String?) async {
        if let errorMessage {
            finish(error: NSError(domain: "AegisShare", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
            return
        }
        guard let value else {
            finish(error: ShareInboxError.invalidEnvelope)
            return
        }
        do {
            try await ShareInboxIO.shared.storeLink(value)
            status = .resource("已安全交给 Aegis\n60 秒内打开 App 即可接收")
            refreshLanguage()
            activity.stopAnimating()
            try await Task.sleep(for: .milliseconds(450))
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            finish(error: error)
        }
    }

    private func finish(error: Error) {
        status = .error(error)
        refreshLanguage()
        statusLabel.textColor = .systemRed
        activity.stopAnimating()
        extensionContext?.cancelRequest(withError: error)
    }
}
