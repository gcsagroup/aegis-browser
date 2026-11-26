import AVFoundation
import BrowserKit
import SwiftUI
import VisionKit

extension AccessTestNodePage: Identifiable {}

struct AccessTestNodeOptionsLink: View {
    let isPrivate: Bool

    var body: some View {
        if AccessTestNodeRepository.shared.allowsEditing(isPrivate: isPrivate) {
            NavigationLink {
                AccessTestNodeProfilesView(isPrivate: isPrivate)
            } label: {
                Text("Access 连接设置", tableName: "AccessTestNode")
            }
            .accessibilityIdentifier("access-test-node-options")
        }
    }
}

private struct AccessTestNodeProfilesView: View {
    let isPrivate: Bool

    var body: some View {
        Form {
            if AccessTestNodeRepository.shared.allowsEditing(isPrivate: isPrivate) {
                NavigationLink {
                    AccessTestNodeDetailView(isPrivate: isPrivate)
                } label: {
                    Text("3X-UI 测试 Profile", tableName: "AccessTestNode")
                }
                .accessibilityIdentifier("access-test-profile")
            }
            NavigationLink {
                AccessUsagePage(isPrivate: isPrivate)
            } label: {
                Text("隐藏地理位置服务")
            }
        }
        .navigationTitle(Text("Access 连接设置", tableName: "AccessTestNode"))
    }
}

private struct AccessTestNodeDetailView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var editor: AccessTestNodeEditor
    @State private var input = ""
    @State private var presentedScan: AccessTestNodeEditor.Scan?
    @State private var authorization: Task<Void, Never>?
    @State private var confirmsRemoval = false
    @State private var targetURL = ""
    @State private var transport: AccessTestNodeTransport = .automatic
    @State private var page: AccessTestNodePage?
    @FocusState private var textFocused: Bool
    private let isPrivate: Bool

    init(isPrivate: Bool) {
        self.isPrivate = isPrivate
        _editor = State(initialValue: AccessTestNodeEditor(isPrivate: isPrivate))
    }

    var body: some View {
        Form {
            Section {
                SecureField(text: $input) { Text("单条节点分享链接", tableName: "AccessTestNode") }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .focused($textFocused)
                    .accessibilityIdentifier("access-test-node-link")
                Button {
                    textFocused = false
                    editor.preview(input)
                    input = ""
                } label: {
                    Text("预览", tableName: "AccessTestNode")
                }
                .disabled(input.isEmpty)
                .accessibilityIdentifier("access-test-node-preview")
                Button(action: startScan) {
                    Label {
                        Text("扫描节点二维码", tableName: "AccessTestNode")
                    } icon: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                }
                .disabled(editor.scan != nil)
                .accessibilityIdentifier("access-test-node-scan")
            }
            if let protocolName = editor.draftProtocolName {
                Section {
                    Text("3X-UI 测试节点", tableName: "AccessTestNode")
                        .accessibilityIdentifier("access-test-node-redacted-preview")
                    Text(verbatim: protocolName)
                } header: {
                    Text("预览", tableName: "AccessTestNode")
                }
            }
            if editor.hasSavedNode {
                Text("节点已保存。", tableName: "AccessTestNode")
                    .accessibilityIdentifier("access-test-node-saved")
                Picker(selection: $transport) {
                    Text("自动", tableName: "AccessTestNode").tag(AccessTestNodeTransport.automatic)
                    Text(verbatim: "HTTP CONNECT").tag(AccessTestNodeTransport.http)
                    Text(verbatim: "SOCKS5").tag(AccessTestNodeTransport.socks5)
                        .disabled(!AccessInternalSOCKSAdmission.current)
                } label: {
                    Text("本地入站", tableName: "AccessTestNode")
                }
                .accessibilityIdentifier("access-test-node-transport")
                TextField(text: $targetURL) { Text("测试网页 HTTPS URL", tableName: "AccessTestNode") }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("access-test-page-url")
                Button {
                    guard let url = URL(string: targetURL), url.scheme == "https" else { return }
                    let session = AccessTestNodePage(isPrivate: isPrivate, transport: transport)
                    page = session
                    Task { await session.open(url) }
                } label: {
                    Text("打开测试网页", tableName: "AccessTestNode")
                }
                .disabled(URL(string: targetURL)?.scheme != "https")
                .accessibilityIdentifier("access-test-page-open")
                Button(role: .destructive) {
                    confirmsRemoval = true
                } label: {
                    Text("移除已保存的节点", tableName: "AccessTestNode")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.interaction, Rectangle())
                }
                .disabled(editor.scan != nil)
                .accessibilityIdentifier("access-test-node-remove")
                .confirmationDialog(
                    Text("移除已保存的节点？", tableName: "AccessTestNode"),
                    isPresented: $confirmsRemoval,
                    titleVisibility: .visible
                ) {
                    Button(role: .destructive) {
                        input = ""
                        editor.removeSavedNode()
                    } label: {
                        Text("移除已保存的节点", tableName: "AccessTestNode")
                    }
                    .accessibilityIdentifier("access-test-node-confirm-remove")
                    Button("取消", role: .cancel) {}
                }
            }
            if editor.showsEmptyProfile {
                Text("尚未保存节点。", tableName: "AccessTestNode")
                    .accessibilityIdentifier("access-test-node-empty")
            }
            if let error = editor.error {
                Text(message(for: error)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("access-test-node-error")
            }
            Section {
                Button {
                    editor.apply()
                } label: {
                    Text("应用", tableName: "AccessTestNode")
                }
                .disabled(!editor.canApply || !input.isEmpty)
                .accessibilityIdentifier("access-test-node-apply")
                Button {
                    cancelScan()
                    input = ""
                    editor.discard()
                } label: {
                    Text("放弃更改", tableName: "AccessTestNode")
                }
                .accessibilityIdentifier("access-test-node-discard")
            }
        }
        .navigationTitle(Text("3X-UI 测试 Profile", tableName: "AccessTestNode"))
        .onAppear { editor.openProfile() }
        .onDisappear {
            cancelScan()
            input = ""
            editor.closeProfile()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                cancelScan()
                input = ""
            }
        }
        .sheet(item: $page, onDismiss: { page?.close(); page = nil }) { session in
            NavigationStack {
                AccessTestNodePageView(session: session)
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { session.close(); page = nil }
                    } }
            }
            .interactiveDismissDisabled()
        }
        .sheet(item: $presentedScan) { scan in
            NavigationStack {
                AccessTestNodeScanner { result in
                    guard presentedScan == scan else { return }
                    editor.finishScan(scan, result: result, pendingText: &input)
                    presentedScan = nil
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(Text("扫描节点二维码", tableName: "AccessTestNode"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            editor.finishScan(scan, result: nil)
                            presentedScan = nil
                        }
                    }
                }
            }
            .interactiveDismissDisabled()
        }
    }

    private func startScan() {
        textFocused = false
        guard let scan = editor.beginScan() else { return }
        guard DataScannerViewController.isSupported else {
            editor.finishScan(scan, result: .failure(.cameraUnavailable))
            return
        }
        authorization = Task {
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: granted = true
            case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
            default: granted = false
            }
            guard !Task.isCancelled, editor.scan == scan else { return }
            guard granted else {
                editor.finishScan(scan, result: .failure(.cameraDenied))
                return
            }
            guard DataScannerViewController.isAvailable else {
                editor.finishScan(scan, result: .failure(.cameraUnavailable))
                return
            }
            presentedScan = scan
        }
    }

    private func cancelScan() {
        authorization?.cancel()
        authorization = nil
        if let scan = editor.scan { editor.finishScan(scan, result: nil) }
        presentedScan = nil
    }

    private func message(for error: AccessTestNodeError) -> LocalizedStringResource {
        switch error {
        case .unavailable: LocalizedStringResource("此版本无法编辑测试节点。", table: "AccessTestNode")
        case .unsupportedVMessCipher: LocalizedStringResource("此 VMess 节点的加密方式不受支持。", table: "AccessTestNode")
        case .invalidLink: LocalizedStringResource("请输入一条支持的 VLESS、VMess、Trojan 或 Hysteria2 分享链接。", table: "AccessTestNode")
        case .cameraDenied: LocalizedStringResource("相机权限未开启，可继续输入节点链接。", table: "AccessTestNode")
        case .cameraUnavailable: LocalizedStringResource("相机扫码暂不可用，可继续输入节点链接。", table: "AccessTestNode")
        case .conflict: LocalizedStringResource("另一窗口已保存。放弃更改后重新预览即可应用。", table: "AccessTestNode")
        case .storageUnavailable: LocalizedStringResource("暂时无法访问节点安全存储。", table: "AccessTestNode")
        }
    }
}

private struct AccessTestNodeScanner: UIViewControllerRepresentable {
    let finish: (Result<String, AccessTestNodeError>) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        Task { @MainActor [weak scanner] in
            guard let scanner, let delegate = scanner.delegate as? Coordinator else { return }
            do { try scanner.startScanning() }
            catch { delegate.complete(scanner, with: .failure(.cameraUnavailable)) }
        }
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.delegate = nil
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private var finish: ((Result<String, AccessTestNodeError>) -> Void)?

        init(finish: @escaping (Result<String, AccessTestNodeError>) -> Void) {
            self.finish = finish
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            let payloads = allItems.map { item -> String? in
                guard case let .barcode(barcode) = item else { return nil }
                return barcode.payloadStringValue
            }
            complete(dataScanner, with: AccessTestNodeQRCode.payload(from: payloads))
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            complete(dataScanner, with: .failure(.cameraUnavailable))
        }

        func complete(_ scanner: DataScannerViewController, with result: Result<String, AccessTestNodeError>) {
            let callback = finish
            finish = nil
            scanner.stopScanning()
            callback?(result)
        }
    }
}

private struct AccessTestNodePageView: View {
    @Environment(\.scenePhase) private var scenePhase
    let session: AccessTestNodePage
    var body: some View {
        VStack {
            Text(LocalizedStringKey(session.status), tableName: "AccessTestNode")
                .accessibilityIdentifier("access-test-page-status")
            if let endpoint = session.endpoint {
                Text(verbatim: "\(endpoint.transport == .socks5 ? "SOCKS5" : "HTTP") · \(endpoint.port)").font(.caption)
            }
            if let view = session.webView { BrowserWebView(webView: view) }
        }
        .onDisappear { session.close() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { session.close() } }
    }
}
