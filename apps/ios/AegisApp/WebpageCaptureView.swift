import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision

struct WebpageCaptureItem: Identifiable {
    let id = UUID()
    let image: UIImage
    let recognizesText: Bool
}

struct WebpageCaptureView: View {
    let item: WebpageCaptureItem
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: BrowserSettings
    @State private var zoom = 1.0
    @State private var editingCrop = false
    @State private var crop: CGRect?
    @State private var output: PNGDocument?
    @State private var saves = false
    @State private var sharedImage: WebpageCaptureItem?
    @State private var copied = false
    @State private var recognizes = false
    @State private var result = ""
    @State private var message: LocalizedStringKey?
    @State private var remotePreview: OCRUploadPreview?
    @State private var recognition: Task<Void, Never>?

    private var selectedImage: UIImage? {
        guard let crop else { return item.image }
        guard let image = item.image.cgImage else { return nil }
        let width = Double(image.width), height = Double(image.height)
        let rect = CGRect(x: crop.minX * width, y: crop.minY * height,
                          width: crop.width * width, height: crop.height * height)
        return image.cropping(to: rect.integral).map { UIImage(cgImage: $0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    let width = max(1, (geometry.size.width - 24) * zoom)
                    ScrollView([.vertical, .horizontal]) {
                        imagePreview(width: width)
                            .padding(12)
                    }
                    .scrollDisabled(editingCrop)
                    .background(.quaternary)
                }
                if item.recognizesText { ocrResult }
                controls
            }
            .navigationTitle(item.recognizesText ? "识别图片文字" : "整页截图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .task {
                if item.recognizesText { recognizeLocally() }
            }
            .onDisappear { recognition?.cancel() }
            .sheet(item: $remotePreview) { preview in
                sendPreview(preview)
            }
            .sheet(item: $sharedImage) { image in
                ActivityPicker(image: image.image)
            }
            .fileExporter(isPresented: $saves, document: output, contentType: .png, defaultFilename: "Aegis") { response in
                output = nil
                if case .failure = response { message = "保存图片失败" }
            }
        }
    }

    private func imagePreview(width: CGFloat) -> some View {
        let height = max(1, width * item.image.size.height / max(1, item.image.size.width))
        return Image(uiImage: item.image)
            .resizable()
            .frame(width: width, height: height)
            .overlay(alignment: .topLeading) {
                if let crop {
                    Rectangle().strokeBorder(.white, lineWidth: 2)
                        .overlay { Rectangle().strokeBorder(.blue, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                        .frame(width: width * crop.width, height: height * crop.height)
                        .position(x: width * crop.midX, y: height * crop.midY)
                        .allowsHitTesting(false)
                }
                if editingCrop {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 4)
                            .onChanged { gesture in
                                let left = max(0, min(1, min(gesture.startLocation.x, gesture.location.x) / width))
                                let top = max(0, min(1, min(gesture.startLocation.y, gesture.location.y) / height))
                                let right = max(0, min(1, max(gesture.startLocation.x, gesture.location.x) / width))
                                let bottom = max(0, min(1, max(gesture.startLocation.y, gesture.location.y) / height))
                                if (right - left) * width >= 4, (bottom - top) * height >= 4 {
                                    crop = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                                }
                            })
                }
            }
            .accessibilityIdentifier("webpage-image-preview")
    }

    private var ocrResult: some View {
        VStack(alignment: .leading, spacing: 6) {
            if recognizes { ProgressView("正在识别文字…") }
            if !result.isEmpty {
                ScrollView {
                    Text(result).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        .accessibilityIdentifier("webpage-ocr-result")
                }.frame(minHeight: 32, maxHeight: 120)
                Button("复制全部文字") { UIPasteboard.general.string = result; copied = true }
            }
            if let service = OCRService.configured(for: settings.imageOCR) {
                Button("用服务器识别") {
                    guard let image = selectedImage else { message = "无法读取图片"; return }
                    remotePreview = OCRUploadPreview(image: image, service: service)
                }.disabled(recognizes)
                    .accessibilityIdentifier("webpage-ocr-remote")
            }
        }.padding(.horizontal)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("webpage-capture-status")
            }
            if copied { Text("已复制").font(.footnote).foregroundStyle(.secondary) }
            if editingCrop {
                Text("拖动选取要保留的区域").font(.footnote)
            } else {
                Slider(value: $zoom, in: 0.55...2.3)
                    .accessibilityLabel("缩放预览")
            }
            HStack {
                Button(editingCrop ? "完成裁剪" : "裁剪") { editingCrop.toggle() }
                    .accessibilityIdentifier("webpage-crop")
                if crop != nil { Button("恢复整张") { crop = nil } }
                Spacer()
                if !item.recognizesText {
                    Menu("导出图片") {
                        Button("复制图片") {
                            guard let image = selectedImage else { message = "无法读取图片"; return }
                            UIPasteboard.general.image = image
                            copied = true
                        }
                        Button("保存 PNG") {
                            guard let data = selectedImage?.pngData() else { message = "保存图片失败"; return }
                            output = PNGDocument(data: data)
                            saves = true
                        }
                        Button("分享图片") {
                            guard let image = selectedImage else { message = "无法读取图片"; return }
                            sharedImage = WebpageCaptureItem(image: image, recognizesText: false)
                        }
                    }
                }
            }.buttonStyle(.bordered)
        }.padding([.horizontal, .bottom])
    }

    private func sendPreview(_ preview: OCRUploadPreview) -> some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(uiImage: preview.image).resizable().scaledToFit()
                Text("仅将预览中的图片发送给下列服务器。")
                Text(preview.service.destination).font(.footnote).foregroundStyle(.secondary)
                Button("发送并识别") {
                    remotePreview = nil
                    guard OCRService.configured(for: settings.imageOCR) == preview.service else {
                        message = "服务器设置已变更，请重新打开上传预览。"
                        return
                    }
                    recognizeRemotely(preview.image, service: preview.service)
                }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("webpage-ocr-send")
            }.padding()
                .navigationTitle("确认发送图片")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { remotePreview = nil }
                } }
        }
    }

    private func recognizeLocally() {
        guard let data = selectedImage?.pngData() else { message = "无法读取图片"; return }
        recognizes = true
        recognition = Task {
            defer { recognizes = false }
            do {
                let text = try await Task.detached(priority: .userInitiated) { try OCRService.localText(data) }.value
                guard !Task.isCancelled else { return }
                result = text
                message = text.isEmpty ? "本机未识别到文字" : nil
            } catch {
                if !Task.isCancelled { message = "本机识别不可用" }
            }
        }
    }

    private func recognizeRemotely(_ image: UIImage, service: OCRService) {
        guard let data = image.pngData() else { message = "无法读取图片"; return }
        recognizes = true
        message = nil
        recognition = Task {
            defer { recognizes = false }
            do {
                let text = try await service.recognize(data)
                guard !Task.isCancelled else { return }
                if !text.isEmpty { result = text }
                message = text.isEmpty ? "服务器未识别到文字" : "已用服务器识别"
            } catch {
                if !Task.isCancelled { message = "服务器识别失败，可重试" }
            }
        }
    }
}

private struct ActivityPicker: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct PNGDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.png]
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct OCRUploadPreview: Identifiable {
    let id = UUID()
    let image: UIImage
    let service: OCRService
}

struct OCRService: Equatable, Sendable {
    let url: URL
    let token: String?

    var destination: String {
        var origin = URLComponents(url: url, resolvingAgainstBaseURL: false)
        origin?.path = ""
        return origin?.string ?? url.absoluteString
    }

    static func httpsEndpoint(_ endpoint: String) -> URL? {
        endpointURL(endpoint, scheme: "https")
    }

    private static func endpointURL(_ endpoint: String, scheme: String) -> URL? {
        guard endpoint.utf8.count <= 2048,
              let components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == scheme, let host = components.host, !host.isEmpty,
              components.percentEncodedPath == "/v1/ocr", components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return components.url
    }

    static func configured(for configuration: ImageOcrConfiguration) -> Self? {
        switch configuration.mode {
        case .local:
            return nil
        case .custom:
            return httpsEndpoint(configuration.endpoint).map { Self(url: $0, token: nil) }
        case .official:
            break
        }
        var endpoint = Bundle.main.object(forInfoDictionaryKey: "AegisOCRServiceURL") as? String
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        endpoint = env["AEGIS_OCR_TEST_URL"] ?? endpoint
        if let testEndpoint = env["AEGIS_OCR_TEST_URL"], let token = env["AEGIS_OCR_TEST_TOKEN"],
           let url = endpointURL(testEndpoint, scheme: "http"), url.host == "127.0.0.1" {
            return Self(url: url, token: token)
        }
        #endif
        return endpoint.flatMap(httpsEndpoint).map { Self(url: $0, token: nil) }
    }

    nonisolated static func localText(_ data: Data) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = try request.supportedRecognitionLanguages()
        let languages = ["zh-Hans", "zh-Hant", "en-US"].filter(supported.contains)
        if !languages.isEmpty { request.recognitionLanguages = languages }
        try VNImageRequestHandler(data: data).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    func recognize(_ png: Data) async throws -> String {
        guard png.count <= 8 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = png
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 16
        let session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (body, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in body {
            guard data.count < 128 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        struct Result: Decodable { let text: String }
        return try JSONDecoder().decode(Result.self, from: data).text
    }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
