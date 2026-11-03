import SwiftUI

struct ThirdPartyNoticesView: View {
    private let notices: String? = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    var body: some View {
        ScrollView {
            if let notices {
                Text(verbatim: notices)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityIdentifier("third-party-notices-text")
            } else {
                ContentUnavailableView("无法载入许可文件", systemImage: "doc.text")
            }
        }
        .navigationTitle("开源许可与鸣谢")
    }
}
