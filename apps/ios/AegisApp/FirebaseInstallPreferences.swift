import Foundation

struct FirebaseInstallPreferences {
    enum Collection: String {
        case crashes, analytics

        var key: String { "firebase.collection." + rawValue }
    }

    private let defaults: UserDefaults
    private let registration: URL

    init(defaults: UserDefaults = .standard,
         registration: URL = .applicationSupportDirectory.appending(path: "AegisFirebase/registration")) {
        self.defaults = defaults
        self.registration = registration
    }

    func bind(to appID: String) throws -> Bool {
        // Crashlytics namespaces its cache by bundle ID. Persist the original
        // registration before starting the SDK so an update cannot send its queue.
        do {
            return try String(contentsOf: registration, encoding: .utf8) == appID
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            try FileManager.default.createDirectory(at: registration.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(appID.utf8).write(to: registration, options: .atomic)
            return true
        }
    }

    func isEnabled(_ collection: Collection) -> Bool {
        guard let value = defaults.object(forKey: collection.key) else { return true }
        return (value as? Bool) == true
    }

    func setEnabled(_ enabled: Bool, for collection: Collection) {
        defaults.set(enabled, forKey: collection.key)
    }
}
