import Foundation

struct PolicyCase: Decodable {
    let name: String
    let selected: String?
    let preferences: [String]
    let systemLocale: String
    let family: String
    let dialect: String
    let appResource: String
    let agentResource: String
    let nativeDialect: String?
    let nativeAgentResource: String?
}

final class MemoryDefaults: AegisLanguageDefaults {
    var values: [String: Any] = ["unrelated": "preserve"]
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

func table(_ owner: Bundle, _ language: String, _ name: String) throws -> [String: String] {
    let url = owner.resourceURL!.appendingPathComponent("\(language).lproj/\(name).strings")
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
    guard let strings = plist as? [String: String] else {
        throw NSError(domain: "AegisLanguageProbe", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Expected a string-to-string table at \(url.path)"])
    }
    return strings
}

let args = CommandLine.arguments
let cases = try JSONDecoder().decode([PolicyCase].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let app = Bundle(url: URL(fileURLWithPath: args[2]))!
let agent = Bundle(url: URL(fileURLWithPath: args[3]))!
let share = Bundle(url: URL(fileURLWithPath: args[4]))!
for name in ["BadArray", "BadValue"] {
    do {
        _ = try table(app, "en", name)
        preconditionFailure("Malformed resource accepted: \(name)")
    } catch let error as NSError {
        precondition(error.domain == "AegisLanguageProbe" && error.code == 1, "Expected checked table conversion failure")
        precondition(error.localizedDescription.contains("\(name).strings"))
    }
}
for item in cases {
    let snapshot = AegisLocalizationSnapshot.resolve(choice: item.selected.flatMap(AegisLanguageChoice.init(rawValue:)),
        preferences: item.preferences, systemLocale: Locale(identifier: item.systemLocale))
    precondition(snapshot.family.rawValue == item.family, item.name)
    precondition(snapshot.dialect == item.dialect, item.name)
    precondition(AegisLocalization.resourceLocalization(in: app, snapshot: snapshot) == item.appResource, item.name)
    precondition(AegisLocalization.resourceLocalization(in: agent, snapshot: snapshot) == item.agentResource, item.name)
    let selectedDefaults = MemoryDefaults()
    selectedDefaults.set(item.selected, forKey: AegisLanguagePreferenceStore.key)
    let native = AegisLocalization.snapshot(store: .init(defaults: selectedDefaults), preferences: item.preferences,
                                           systemLocale: Locale(identifier: item.systemLocale))
    precondition(native.dialect == (item.nativeDialect ?? item.dialect), item.name + ": persisted dialect")
    precondition(AegisLocalization.resourceLocalization(in: agent, snapshot: native) == (item.nativeAgentResource ?? item.agentResource),
                 item.name + ": persisted resource")
    for owner in [app, share] {
        let resource = LocalizedStringResource("搜索或输入网址", bundle: .atURL(owner.bundleURL))
        let expected = try table(owner, item.appResource, "Localizable")[resource.key]!
        precondition(AegisLocalization.string(resource, snapshot: snapshot) == expected, item.name)
    }
    let semantic = LocalizedStringResource("agent.error.consentRequired", defaultValue: "default consent",
        table: "AgentErrors", bundle: .atURL(agent.bundleURL))
    let expected = try table(agent, item.agentResource, "AgentErrors")[semantic.key]!
    precondition(AegisLocalization.string(semantic, snapshot: snapshot) == expected, item.name + ": semantic owner")
}

let defaults = MemoryDefaults()
let store = AegisLanguagePreferenceStore(defaults: defaults)
let choices = AegisLanguageChoice.displayOrder
precondition(choices.map(\.rawValue) == ["zh-Hans", "zh-Hant-TW", "zh-Hant-HK", "en-US", "en-GB", "id", "th", "ja", "ko", "vi", "ms", "de", "fr", "es", "it", "pt"])
precondition(Set(choices.map(\.rawValue)).count == choices.count)
precondition(AegisLanguageChoice.traditionalChineseTaiwan.autonym == "中文（台湾）")
for choice in choices {
    store.setChoice(choice)
    precondition(AegisLanguagePreferenceStore(defaults: defaults).choice == choice)
    precondition(store.family == choice.family)
}
for family in AegisLanguageFamily.allCases {
    store.setFamily(family)
    precondition(store.family == family)
    precondition(defaults.string(forKey: AegisLanguagePreferenceStore.key) == AegisLanguageChoice.family(family).selectableChoice.rawValue)
}
store.setFamily(.en)
for region in ["en_GB", "en_HK"] {
    let snapshot = AegisLocalization.snapshot(store: store, preferences: ["en"], systemLocale: Locale(identifier: region))
    precondition(snapshot.dialect == "en-US")
    precondition(defaults.string(forKey: AegisLanguagePreferenceStore.key) == "en-US")
}
defaults.set("en-GB", forKey: AegisLanguagePreferenceStore.key)
precondition(store.choice == .englishUnitedKingdom)
for (legacy, expected) in [("en", AegisLanguageChoice.englishUnitedStates), ("zh-Hant", .traditionalChineseTaiwan)] {
    defaults.set(legacy, forKey: AegisLanguagePreferenceStore.key)
    precondition(store.choice == expected)
    precondition(defaults.string(forKey: AegisLanguagePreferenceStore.key) == legacy, "Reading preferences does not rewrite storage")
}
defaults.set("unsupported-language", forKey: AegisLanguagePreferenceStore.key)
precondition(store.family == nil)
store.setFamily(nil)
precondition(defaults.values.count == 1 && defaults.string(forKey: "unrelated") == "preserve")

let system = Locale(identifier: "th-TH-u-ca-buddhist-hc-h23-nu-thai-tz-usnyc")
let formatted = AegisLocalizationSnapshot.resolve(family: .en, preferences: ["en-GB"], systemLocale: system)
precondition(formatted.locale.language.region?.identifier == "GB")
precondition(formatted.locale.region == system.region)
precondition(formatted.locale.calendar.identifier == system.calendar.identifier)
precondition(formatted.locale.hourCycle == system.hourCycle)
precondition(formatted.locale.numberingSystem == system.numberingSystem)
precondition(formatted.locale.firstDayOfWeek == system.firstDayOfWeek)
precondition(formatted.locale.measurementSystem == system.measurementSystem)
precondition(formatted.locale.timeZone == system.timeZone)
store.setChoice(.traditionalChineseTaiwan)
let taiwan = AegisLocalization.snapshot(store: store, preferences: ["zh-HK"], systemLocale: system)
precondition(taiwan.dialect == "zh-Hant-TW")
precondition(taiwan.resourceCandidates == ["zh-Hant-TW", "zh-Hant", "en"])
precondition(taiwan.locale.language.region?.identifier == "TW")
precondition(taiwan.locale.region == system.region)
precondition(taiwan.locale.calendar.identifier == system.calendar.identifier)
precondition(taiwan.locale.numberingSystem == system.numberingSystem)
store.setFamily(.traditionalChinese)
precondition(AegisLocalization.snapshot(store: store, preferences: ["zh-HK"], systemLocale: system).dialect == "zh-Hant-TW")
store.setChoice(nil)
precondition(store.choice == nil && defaults.string(forKey: AegisLanguagePreferenceStore.key) == nil)
precondition(AegisLocalization.snapshot(store: store, preferences: ["zh-HK"], systemLocale: system).dialect == "zh-Hant-HK")

let english = AegisLocalizationSnapshot.resolve(family: .en, preferences: ["en-US"], systemLocale: Locale(identifier: "en_US"))
let german = AegisLocalizationSnapshot.resolve(family: .de, preferences: ["de"], systemLocale: Locale(identifier: "en_US"))
let count = 3
let interpolated = LocalizedStringResource("已保存 \(count) 个页面。", bundle: .atURL(app.bundleURL))
precondition(AegisLocalization.string(interpolated, snapshot: english) == "Saved 3 pages.")
let identity = LocalizedStringResource("Identity", table: "Adapter", bundle: .atURL(app.bundleURL))
precondition(AegisLocalization.string(identity, snapshot: german) == "Identity", "A value equal to its key is present")
let fallback = LocalizedStringResource("Fallback", table: "Adapter", bundle: .atURL(app.bundleURL))
precondition(AegisLocalization.string(fallback, snapshot: german) == "English fallback")
let argument = "<tag> % @ \""
let missing = LocalizedStringResource("Missing \(argument)", table: "Adapter", bundle: .atURL(app.bundleURL))
precondition(AegisLocalization.string(missing, snapshot: german) == "Missing <tag> % @ \"")
for (number, expected) in [(1, "1 apple"), (3, "3 apples")] {
    let plural = LocalizedStringResource("Aegis apples \(number)", table: "Adapter", bundle: .atURL(app.bundleURL))
    precondition(AegisLocalization.string(plural, snapshot: english) == expected)
}
// Real argument-domain overrides, in an isolated test suite; no persistent writes.
if args.contains("--ui-testing") {
    precondition(AegisLanguagePreferenceStore.runtime.family == .traditionalChinese)
}
print("PASS: \(cases.count) policy cases; sorted choices; Taiwan persistence; app/share/Agent owners; formatting; identity/fallback/interpolation/plurals")
