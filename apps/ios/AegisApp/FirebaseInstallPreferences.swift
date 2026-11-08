import Foundation

struct FirebaseInstallPreferences {
    enum Collection: String {
        case crashes, analytics, remoteConfiguration

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
        // Unset collection choices default on; an explicit saved false remains off.
        guard let value = defaults.object(forKey: collection.key) else { return true }
        return (value as? Bool) == true
    }

    func setEnabled(_ enabled: Bool, for collection: Collection) {
        defaults.set(enabled, forKey: collection.key)
    }

    var remotePolicy: RemoteDiagnosticsPolicy? {
        guard let data = defaults.data(forKey: "firebase.remote.policy.v1") else { return nil }
        return try? JSONDecoder().decode(RemoteDiagnosticsPolicy.self, from: data)
    }

    func saveRemotePolicy(_ policy: RemoteDiagnosticsPolicy?) {
        if let policy, let data = try? JSONEncoder().encode(policy) {
            defaults.set(data, forKey: "firebase.remote.policy.v1")
        } else {
            defaults.removeObject(forKey: "firebase.remote.policy.v1")
        }
    }

    var remoteInstallationUsed: Bool {
        get { defaults.bool(forKey: "firebase.remote.installationUsed.v1") }
        nonmutating set { defaults.set(newValue, forKey: "firebase.remote.installationUsed.v1") }
    }

    var remoteCleanupRequired: Bool {
        get { defaults.bool(forKey: "firebase.remote.cleanupRequired.v1") }
        nonmutating set { defaults.set(newValue, forKey: "firebase.remote.cleanupRequired.v1") }
    }

    var remoteRevokedAt: Date? {
        get { defaults.object(forKey: "firebase.remote.revokedAt.v1") as? Date }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: "firebase.remote.revokedAt.v1") }
            else { defaults.removeObject(forKey: "firebase.remote.revokedAt.v1") }
        }
    }
}
