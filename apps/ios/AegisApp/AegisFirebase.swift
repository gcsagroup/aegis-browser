import Combine
import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics
import Foundation

@MainActor
final class AegisFirebase: ObservableObject {
    enum Status {
        case unavailable, active, registrationChanged
    }

    static let shared = AegisFirebase()

    @Published private(set) var status: Status = .unavailable
    @Published private(set) var crashReportsEnabled: Bool
    @Published private(set) var analyticsEnabled: Bool

    private let preferences = FirebaseInstallPreferences()

    private init() {
        crashReportsEnabled = preferences.isEnabled(.crashes)
        analyticsEnabled = preferences.isEnabled(.analytics)
    }

    func start() {
        let bundle = Bundle.main
        let process = ProcessInfo.processInfo
        guard status == .unavailable,
              process.environment["XCTestConfigurationFilePath"] == nil,
              process.environment["XCTestSessionIdentifier"] == nil,
              !process.arguments.contains("--ui-testing"),
              let channel = bundle.object(forInfoDictionaryKey: "AegisFirebaseChannel") as? String,
              ["dev", "alpha", "beta", "release"].contains(channel),
              let config = bundle.path(forResource: "AegisFirebase", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: config),
              options.bundleID == bundle.bundleIdentifier else { return }

        guard let matches = try? preferences.bind(to: options.googleAppID) else { return }
        guard matches else {
            status = .registrationChanged
            return
        }

        FirebaseApp.configure(options: options)
        status = .active
        Analytics.setAnalyticsCollectionEnabled(analyticsEnabled)

        // Let Aegis decide whether to send on each launch. Crashlytics' automatic
        // collection override persists independently of the app's preference.
        let crashes = Crashlytics.crashlytics()
        if crashReportsEnabled {
            crashes.sendUnsentReports()
        } else {
            crashes.deleteUnsentReports()
        }
    }

    func setCrashReportsEnabled(_ enabled: Bool) {
        guard status == .active else { return }
        preferences.setEnabled(enabled, for: .crashes)
        crashReportsEnabled = enabled
        if !enabled { Crashlytics.crashlytics().deleteUnsentReports() }
    }

    func setAnalyticsEnabled(_ enabled: Bool) {
        guard status == .active else { return }
        preferences.setEnabled(enabled, for: .analytics)
        analyticsEnabled = enabled
        Analytics.setAnalyticsCollectionEnabled(enabled)
        if !enabled { Analytics.resetAnalyticsData() }
    }
}
