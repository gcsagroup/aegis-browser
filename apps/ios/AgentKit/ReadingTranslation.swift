import AegisPolicyKit
import Foundation

public enum ReadingTranslation {
    public static func preparedText(_ text: String) throws -> String {
        guard !text.isEmpty, text.count <= 24_000 else { throw ModelClientError.tooLarge }
        let scan = PIIScanner.scan(text)
        guard !scan.blocked else { throw ModelClientError.sensitiveData }
        return scan.redacted
    }

    public static func decode(_ output: String) throws -> String {
        struct Reply: Decodable { let translation: String }
        guard output.utf8.count <= 200_000, let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["translation"],
              let value = try? JSONDecoder().decode(Reply.self, from: data),
              !value.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.translation.count <= 48_000 else { throw ModelClientError.invalidResponse }
        return value.translation
    }
}
