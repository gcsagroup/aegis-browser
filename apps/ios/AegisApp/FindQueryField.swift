import SwiftUI

/// 等查找面板完成显示后再交接键盘焦点，避免网页仍占用响应链。
struct FindQueryField: UIViewControllerRepresentable {
    @Binding var text: String

    func makeUIViewController(context: Context) -> Controller { Controller(text: $text) }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.text = $text
        if controller.field.text != text { controller.field.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: Controller, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: max(44, uiViewController.field.intrinsicContentSize.height))
    }

    final class Controller: UIViewController {
        var text: Binding<String>
        let field = UITextField()

        init(text: Binding<String>) {
            self.text = text
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { return nil }

        override func loadView() {
            field.text = text.wrappedValue
            field.placeholder = String(localized: "查找文字")
            field.accessibilityIdentifier = "find-text"
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.addTarget(self, action: #selector(updateText), for: .editingChanged)
            view = field
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            field.becomeFirstResponder()
        }

        @objc private func updateText() { text.wrappedValue = field.text ?? "" }
    }
}
