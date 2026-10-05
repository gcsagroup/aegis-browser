import SwiftUI

/// 浏览时显示主机名，取得焦点后切换为完整网址并选中，避免快捷键输入残留旧文字。
struct BrowserAddressField: UIViewRepresentable {
    @Binding var address: String
    @Binding var focused: Bool
    let displayText: String
    let selectionRequest: Int
    let submit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = String(localized: "搜索或输入网址")
        field.accessibilityIdentifier = "address-field"
        field.accessibilityLabel = String(localized: "搜索或输入网址")
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let text = focused ? address : displayText
        if field.text != text, field.markedTextRange == nil { field.text = text }
        field.textAlignment = focused ? .left : .center
        field.accessibilityValue = address
        if focused {
            let needsSelection = coordinator.lastSelectionRequest != selectionRequest || !field.isFirstResponder
            coordinator.lastSelectionRequest = selectionRequest
            if needsSelection {
                // 等 SwiftUI 完成地址栏布局后再交接焦点，原生输入框保留至少 44 点点击区域。
                Task { @MainActor [weak field, weak coordinator] in
                    guard let field, let coordinator, coordinator.parent.focused, field.window != nil else { return }
                    field.becomeFirstResponder()
                    field.selectAll(nil)
                }
            }
        } else if field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: max(44, uiView.font?.lineHeight ?? 0))
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: BrowserAddressField
        var lastSelectionRequest = -1

        init(_ parent: BrowserAddressField) { self.parent = parent }

        func textFieldDidBeginEditing(_ field: UITextField) {
            field.text = parent.address
            field.textAlignment = .left
            parent.focused = true
            Task { @MainActor [weak field] in
                guard let field, field.isFirstResponder else { return }
                field.selectAll(nil)
            }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            parent.focused = false
            field.text = parent.displayText
            field.accessibilityValue = parent.address
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            let destination = field.text ?? ""
            parent.address = destination
            parent.focused = false
            parent.submit(destination)
            return true
        }

        @objc func changed(_ field: UITextField) {
            parent.address = field.text ?? ""
            field.accessibilityValue = parent.address
        }
    }
}
