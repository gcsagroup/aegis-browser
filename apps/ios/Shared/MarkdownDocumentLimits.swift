import Foundation

enum MarkdownDocumentLimits {
    static let maximumBytes = 16 * 1024 * 1024

    struct TooLarge: LocalizedError {
        var errorDescription: String? {
            AegisLocalization.string("文档超过 16 MiB，请查看原文件。")
        }
    }
}
