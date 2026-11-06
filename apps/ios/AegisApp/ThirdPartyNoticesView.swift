import Foundation
import SwiftUI

// Keep the generated text intact; upstream licenses also contain shorter separators.
// This delimiter matches include() in scripts/licenses/third_party_notices.py.
struct ThirdPartyNoticesDocument {
    static let sectionDelimiter = "\n" + String(repeating: "=", count: 72) + "\n"

    struct Notice: Identifiable {
        let id: Int
        let text: String

        var title: String { String(text.prefix(while: { $0 != "\n" })) }
        var body: String { String(text.dropFirst(title.count)) }

        // Only the generator's leading header is presentation metadata. Never
        // search or filter the legal body, which can itself contain source URLs.
        var generatedHeader: (source: String, content: String)? {
            let parts = body.components(separatedBy: "\n\n")
            guard parts.count > 1 else { return nil }
            let lines = parts[0].components(separatedBy: "\n").dropFirst()
            guard let sourceLine = lines.last, sourceLine.hasPrefix("Source file: ") else { return nil }
            let source = String(sourceLine.dropFirst("Source file: ".count))
            let prefixes = [ThirdPartyNoticesDocument.webVendor,
                            "apps/ios/BrowserKit/Resources/",
                            "apps/browser/overlay/chrome/browser/resources/aegis_agent/local_ai/",
                            "scripts/licenses/sdk-licenses/"]
            guard prefixes.contains(where: { source.hasPrefix($0) }),
                  lines.count == 1 || (lines.count == 2
                    && source.hasPrefix("scripts/licenses/sdk-licenses/")
                    && lines.first?.hasPrefix("https://") == true) else { return nil }
            return (source, parts.dropFirst().joined(separator: "\n\n"))
        }
    }

    struct PresentedNotice: Identifiable {
        let notice: Notice
        let title: String
        var version: String? = nil
        var license: String? = nil
        var website: URL? = nil
        var id: Int { notice.id }
        var body: String { notice.generatedHeader?.content ?? notice.body }
        var subtitle: String? {
            guard let version, let license else { return nil }
            return "\(version) · \(license)"
        }
    }

    private static let webVendor = "apps/browser/overlay/chrome/browser/resources/aegis/enhancements_shared/vendor/"

    var presentedNotices: [PresentedNotice] {
        let fallback = notices.map { PresentedNotice(notice: $0, title: $0.title) }
        let inventories = notices.filter { $0.generatedHeader?.source == Self.webVendor + "NOTICE.txt" }
        guard inventories.count == 1, let inventory = inventories.first,
              let content = inventory.generatedHeader?.content else { return fallback }
        let lines = content.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        // Recognize the entire inventory grammar. New entries, prose or ambiguous
        // associations retain the original page instead of silently losing notices.
        let packaging = "所有运行资源在本机打包，不使用 CDN。highlight.js 仅包含 JavaScript、TypeScript、Python、Bash、JSON、XML、CSS、C++、Swift、SQL、Markdown、YAML。各文件摘要见 manifest.json。"
        let files = ["markdown-it": "markdown-it-LICENSE", "DOMPurify": "DOMPurify-LICENSE",
                     "markdown-it-task-lists": "task-lists-LICENSE", "acorn": "acorn-LICENSE",
                     "highlight.js": "highlight-LICENSE"]
        guard lines.count == files.count + 3, lines.first == "网页增强内置资源",
              lines[lines.count - 2].isEmpty, lines.last == packaging else { return fallback }
        var associated: [Int: PresentedNotice] = [:]
        var identities = Set<String>()
        for line in lines.dropFirst().prefix(files.count) {
            let fields = line.components(separatedBy: " — ")
            guard fields.count == 3,
                  let split = fields[0].lastIndex(of: " ") else { return fallback }
            let identity = String(fields[0][..<split])
            let version = String(fields[0][fields[0].index(after: split)...])
            guard let filename = files[identity], identities.insert(identity).inserted,
                  !version.isEmpty, !fields[1].isEmpty,
                  let website = URL(string: fields[2]), website.scheme == "https",
                  website.host != nil else { return fallback }
            let matches = notices.filter { $0.generatedHeader?.source == Self.webVendor + filename }
            guard matches.count == 1, let notice = matches.first,
                  let legal = notice.generatedHeader?.content,
                  !legal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
            associated[notice.id] = PresentedNotice(notice: notice, title: identity,
                                                   version: version, license: fields[1], website: website)
        }
        guard associated.count == files.count else { return fallback }
        return fallback.filter { $0.id != inventory.id }.map { associated[$0.id] ?? $0 }
    }

    let introduction: String
    let notices: [Notice]

    init(text: String) {
        let sections = text.components(separatedBy: Self.sectionDelimiter)
        introduction = sections[0]
        notices = sections.dropFirst().enumerated().map { Notice(id: $0.offset, text: $0.element) }
    }

    var presentedIntroduction: String {
        // Remove only the generator's exact first title line. Preserve all
        // remaining introduction bytes, including future or unfamiliar notes.
        let generatedTitle = "GCSA Aegis — Third-party licenses and acknowledgements\n"
        guard introduction.hasPrefix(generatedTitle) else { return introduction }
        return String(introduction.dropFirst(generatedTitle.count))
    }

    var fullText: String {
        ([introduction] + notices.map(\.text)).joined(separator: Self.sectionDelimiter)
    }
}

struct ThirdPartyNoticesView: View {
    private let document: ThirdPartyNoticesDocument? = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        .map { ThirdPartyNoticesDocument(text: $0) }

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        List {
            Section {
                if let document {
                    ForEach(document.presentedNotices) { notice in
                        NavigationLink {
                            ThirdPartyNoticeDetailView(notice: notice)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: notice.title)
                                    .font(.body)
                                if let subtitle = notice.subtitle {
                                    Text(verbatim: subtitle)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityIdentifier("third-party-notices-component-\(notice.id)")
                    }
                } else {
                    ContentUnavailableView("无法载入许可文件", systemImage: "doc.text")
                }
            } header: {
                Text("开源许可与鸣谢")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .textCase(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("third-party-notices-title")
            } footer: {
                if let document {
                    Text(verbatim: document.presentedIntroduction)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("third-party-notices-introduction-0")
                }
            }
        }
        .accessibilityIdentifier("third-party-notices-list")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ThirdPartyNoticeDetailView: View {
    let notice: ThirdPartyNoticesDocument.PresentedNotice

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text(verbatim: notice.title)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("third-party-notice-detail-title")
                if let subtitle = notice.subtitle {
                    Text(verbatim: subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("third-party-notice-detail-metadata")
                }
                if let website = notice.website {
                    Link("官方网站", destination: website)
                        .frame(minHeight: 44, alignment: .leading)
                        .accessibilityIdentifier("third-party-notice-detail-website")
                }
                NoticeParagraphs(text: notice.body, identifier: "third-party-notice-detail-paragraph")
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("third-party-notice-detail-scroll")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NoticeParagraphs: View {
    let text: String
    let identifier: String

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        let paragraphs = text.components(separatedBy: "\n\n")
        ForEach(paragraphs.indices, id: \.self) { index in
            Text(verbatim: paragraphs[index])
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("\(identifier)-\(index)")
        }
    }
}
