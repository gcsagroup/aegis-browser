import Foundation

/// Source-shared, module-internal localization policy. No dependency on app/UI state.
enum AegisLanguageFamily: String, CaseIterable, Sendable {
    case de, en, es, fr, id, it, ja, ko, ms, pt, th, vi
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    var autonym: String {
        switch self {
        case .de: "Deutsch"
        case .en: "English"
        case .es: "Español"
        case .fr: "Français"
        case .id: "Bahasa Indonesia"
        case .it: "Italiano"
        case .ja: "日本語"
        case .ko: "한국어"
        case .ms: "Bahasa Melayu"
        case .pt: "Português"
        case .th: "ไทย"
        case .vi: "Tiếng Việt"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        }
    }
}

protocol AegisLanguageDefaults {
    func string(forKey defaultName: String) -> String?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: AegisLanguageDefaults {}

struct AegisLanguagePreferenceStore {
    static let key = "browser.languageFamily.v1"
    static let appGroup = "group.com.gcsa.aegis.ios.share-inbox"
    static let testSuite = "com.gcsa.aegis.ios.ui-tests"
    let defaults: any AegisLanguageDefaults

    var family: AegisLanguageFamily? {
        defaults.string(forKey: Self.key).flatMap(AegisLanguageFamily.init(rawValue:))
    }

    func setFamily(_ family: AegisLanguageFamily?) {
        if let family { defaults.set(family.rawValue, forKey: Self.key) }
        else { defaults.removeObject(forKey: Self.key) }
    }

    static var runtime: Self {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            return Self(defaults: UserDefaults(suiteName: testSuite)!)
        }
#endif
        return Self(defaults: UserDefaults(suiteName: appGroup)!)
    }
}

struct AegisLocalizationSnapshot: Equatable, Sendable {
    let family: AegisLanguageFamily
    let dialect: String
    /// UI language with the system's independent regional/formatting overrides.
    let locale: Locale
    let systemLocale: Locale

    var resourceCandidates: [String] {
        var result: [String] = []
        for value in [dialect, family.rawValue, "en"] where !result.contains(value) {
            result.append(value)
        }
        return result
    }

    static func resolve(family selected: AegisLanguageFamily?, preferences: [String],
                        systemLocale: Locale) -> Self {
        let preferences = preferences.compactMap { Preference($0, systemRegion: systemLocale.region?.identifier) }
        let family = selected ?? preferences.first?.family ?? .simplifiedChinese
        // Explicit regional preferences precede generic ones, preserving their order.
        let explicit = preferences.first { $0.family == family && $0.region != nil }
        let region = explicit?.region ?? systemLocale.region?.identifier
        let dialect: String
        switch family {
        case .en:
            dialect = region.map { "en-\($0)" } ?? "en"
        case .traditionalChinese:
            dialect = region.map { "zh-Hant-\($0)" } ?? "zh-Hant"
        case .simplifiedChinese:
            dialect = region.map { "zh-Hans-\($0)" } ?? "zh-Hans"
        default:
            dialect = explicit?.region.map { "\(family.rawValue)-\($0)" } ?? family.rawValue
        }
        var components = Locale.Components(identifier: systemLocale.identifier)
        components.languageComponents = Locale.Language.Components(identifier: dialect)
        // `region` is the Unicode rg override, independent of languageComponents.region.
        components.region = systemLocale.region
        components.calendar = systemLocale.calendar.identifier
        components.currency = systemLocale.currency
        components.numberingSystem = systemLocale.numberingSystem
        components.firstDayOfWeek = systemLocale.firstDayOfWeek
        components.hourCycle = systemLocale.hourCycle
        components.measurementSystem = systemLocale.measurementSystem
        components.timeZone = systemLocale.timeZone
        return Self(family: family, dialect: dialect, locale: Locale(components: components), systemLocale: systemLocale)
    }

    private struct Preference {
        let family: AegisLanguageFamily
        let region: String?

        init?(_ identifier: String, systemRegion: String?) {
            let components = Locale.Language.Components(identifier: identifier.replacingOccurrences(of: "_", with: "-"))
            region = components.region?.identifier.uppercased()
            guard let code = components.languageCode?.identifier else { return nil }
            if code == "zh" {
                switch components.script?.identifier {
                case "Hans": family = .simplifiedChinese
                case "Hant": family = .traditionalChinese
                default:
                    family = ["HK", "TW", "MO"].contains(region ?? systemRegion ?? "")
                        ? .traditionalChinese : .simplifiedChinese
                }
            } else {
                guard let supported = AegisLanguageFamily(rawValue: code) else { return nil }
                family = supported
            }
        }
    }
}

enum AegisLocalization {
    static var current: AegisLocalizationSnapshot {
        snapshot(store: .runtime)
    }

    static func snapshot(store: AegisLanguagePreferenceStore,
                         preferences: [String] = preferredLanguages,
                         systemLocale: Locale = .current) -> AegisLocalizationSnapshot {
        .resolve(family: store.family, preferences: preferences, systemLocale: systemLocale)
    }

    static var preferredLanguages: [String] {
        let requested = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
        return requested.isEmpty ? Locale.preferredLanguages : requested
    }

    /// Typed input retains compiler extraction, interpolation, plural rules and owner/table bindings.
    static func string(_ resource: LocalizedStringResource,
                       snapshot: AegisLocalizationSnapshot = current) -> String {
        guard let owner = owner(of: resource),
              let localization = resourceLocalization(in: owner, snapshot: snapshot,
                                                      key: resource.key, table: resource.table),
              let folder = localizationURL(in: owner, localization: localization),
              let localizedBundle = Bundle(url: folder) else {
            // No key in the explicit fallback chain: render the typed default using
            // a deliberately absent table, not the process's preferred translation.
            return String(localized: resource.defaultValue, table: "AegisMissingTranslation",
                          bundle: owner(of: resource), locale: snapshot.locale)
        }
        // bundle is get-only on the supported SDK. Ordinary literal/interpolated
        // resources can retain their native LocalizationValue and use an lproj.
        if resource.key == LocalizedStringResource(resource.defaultValue).key {
            return String(localized: resource.defaultValue, table: resource.table,
                          bundle: localizedBundle, locale: snapshot.locale)
        }
        // Generated semantic keys must keep their original key/default/table/owner.
        // Unlike String(LocalizationValue), this native API honors resource.locale.
        var copy = resource
        var components = Locale.Components(identifier: snapshot.locale.identifier)
        components.languageComponents = Locale.Language.Components(identifier: localization)
        copy.locale = Locale(components: components)
        return String(localized: copy)
    }

    static func owner(of resource: LocalizedStringResource) -> Bundle? {
        switch resource.bundle {
        case .main: .main
        case .forClass(let token): Bundle(for: token)
        case .atURL(let url): Bundle(url: url)
        @unknown default: nil
        }
    }

    static func resourceLocalization(in bundle: Bundle, snapshot: AegisLocalizationSnapshot,
                                     key: String? = nil, table: String? = nil) -> String? {
        snapshot.resourceCandidates.first { language in
            guard let folder = localizationURL(in: bundle, localization: language) else { return false }
            guard let key else { return true }
            return inventories.keys(folder: folder, table: table ?? "Localizable").contains(key)
        }
    }

    private static func localizationURL(in bundle: Bundle, localization: String) -> URL? {
        guard bundle.localizations.contains(localization), let root = bundle.resourceURL else { return nil }
        return root.appendingPathComponent("\(localization).lproj", isDirectory: true)
    }

    private static let inventories = ResourceInventories()

    /// Only immutable compiled-resource keys are cached, never preferences or rendered values.
    private final class ResourceInventories: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [URL: Set<String>] = [:]

        func keys(folder: URL, table: String) -> Set<String> {
            let base = folder.appendingPathComponent(table)
            lock.lock()
            if let keys = cache[base] { lock.unlock(); return keys }
            lock.unlock()
            var keys: Set<String> = []
            for suffix in ["strings", "stringsdict"] {
                if let data = try? Data(contentsOf: base.appendingPathExtension(suffix)),
                   let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    keys.formUnion(dictionary.keys)
                }
            }
            lock.lock()
            cache[base] = keys
            lock.unlock()
            return keys
        }
    }
}

/// Ephemeral UI feedback keeps its meaning until presentation; never used in persisted records.
indirect enum AegisLocalizedMessage {
    case resource(LocalizedStringResource)
    case error(any Error)
    case verbatim(String)
    case joined(AegisLocalizedMessage, AegisLocalizedMessage)

    var text: String {
        switch self {
        case .resource(let resource): AegisLocalization.string(resource)
        case .error(let error): error.localizedDescription
        case .verbatim(let text): text
        case .joined(let first, let second): first.text + " " + second.text
        }
    }
}
