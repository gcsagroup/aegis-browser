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
}

final class MemoryDefaults: AegisLanguageDefaults {
    var values: [String: Any] = ["unrelated": "preserve"]
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

func table(_ owner: Bundle, _ language: String, _ name: String) throws -> [String: String] {
    let url = owner.resourceURL!.appendingPathComponent("\(language).lproj/\(name).strings")
    return try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: String]
}

let args = CommandLine.arguments
let cases = try JSONDecoder().decode([PolicyCase].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let app = Bundle(url: URL(fileURLWithPath: args[2]))!
let agent = Bundle(url: URL(fileURLWithPath: args[3]))!
let share = Bundle(url: URL(fileURLWithPath: args[4]))!
for item in cases {
    let snapshot = AegisLocalizationSnapshot.resolve(family: item.selected.flatMap(AegisLanguageFamily.init(rawValue:)),
        preferences: item.preferences, systemLocale: Locale(identifier: item.systemLocale))
    precondition(snapshot.family.rawValue == item.family, item.name)
    precondition(snapshot.dialect == item.dialect, item.name)
    precondition(AegisLocalization.resourceLocalization(in: app, snapshot: snapshot) == item.appResource, item.name)
    precondition(AegisLocalization.resourceLocalization(in: agent, snapshot: snapshot) == item.agentResource, item.name)
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
for family in AegisLanguageFamily.allCases {
    store.setFamily(family)
    precondition(store.family == family)
    precondition(defaults.string(forKey: AegisLanguagePreferenceStore.key) == family.rawValue)
}
store.setFamily(.en)
for (region, expected) in [("en_GB", "en-GB"), ("en_HK", "en-HK")] {
    let snapshot = AegisLocalization.snapshot(store: store, preferences: ["en"], systemLocale: Locale(identifier: region))
    precondition(snapshot.dialect == expected)
    precondition(defaults.string(forKey: AegisLanguagePreferenceStore.key) == "en")
}
defaults.set("en-GB", forKey: AegisLanguagePreferenceStore.key)
precondition(store.family == nil, "Only families may be persisted")
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
print("PASS: \(cases.count) policy cases; app/share/Agent owners; persistence; formatting; identity/fallback/interpolation/plurals")
