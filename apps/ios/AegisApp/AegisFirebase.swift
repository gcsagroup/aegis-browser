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
    @Published private(set) var remoteConfigurationEnabled: Bool
    @Published private(set) var crashReportingActive = false
    @Published private(set) var analyticsActive = false
    @Published private(set) var remoteConfiguration: RemoteDiagnosticsController?

    private let preferences: FirebaseInstallPreferences
    private var launchReports = DiagnosticsLaunchDecision()
    private var lastAppliedAnalytics: Bool?

    private init() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), let defaults = UserDefaults(suiteName: "com.gcsa.aegis.firebase.ui-tests") {
            if !arguments.contains("--ui-testing-preferences-keep") {
                defaults.removePersistentDomain(forName: "com.gcsa.aegis.firebase.ui-tests")
            }
            preferences = FirebaseInstallPreferences(defaults: defaults)
        } else {
            preferences = FirebaseInstallPreferences()
        }
#else
        preferences = FirebaseInstallPreferences()
#endif
        crashReportsEnabled = preferences.isEnabled(.crashes)
        analyticsEnabled = preferences.isEnabled(.analytics)
        remoteConfigurationEnabled = preferences.isEnabled(.remoteConfiguration)
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

        let remote = RemoteDiagnosticsController(preferences: preferences,
            source: FirebaseRemoteDiagnosticsSource(options: options))
        remoteConfiguration = remote
        remote.onChange = { [weak self] in self?.applyCollectionPolicy() }
        // Analytics persists its own override. Apply the current permission before
        // configuring Firebase, so a previous session cannot bypass today's gate.
        Analytics.setAnalyticsCollectionEnabled(false)
        FirebaseApp.configure(options: options)
        status = .active
        applyCollectionPolicy()
        remote.start()
    }

    func refreshOnForeground() {
        guard status == .active else { return }
        remoteConfiguration?.invalidateIfExpired()
        applyCollectionPolicy()
        remoteConfiguration?.refresh()
    }

    private func applyCollectionPolicy() {
        guard status == .active, let remote = remoteConfiguration else { return }
        crashReportingActive = remote.permits(.crashes, localChoice: crashReportsEnabled)
        analyticsActive = remote.permits(.analytics, localChoice: analyticsEnabled)
        Analytics.setAnalyticsCollectionEnabled(analyticsActive)
        if !analyticsActive, lastAppliedAnalytics != false { Analytics.resetAnalyticsData() }
        lastAppliedAnalytics = analyticsActive

        // Let Aegis decide whether to send on each launch. Crashlytics' automatic
        // collection override persists independently of the app's preference.
        // Both SDK calls resolve the same one-shot promise. Decide once, after
        // the initial remote attempt settles; a later opt-out cannot revoke it.
        switch launchReports.resolve(allowed: crashReportingActive,
                                     policySettled: !remote.enabled || remote.initialRefreshCompleted) {
        case .send: Crashlytics.crashlytics().sendUnsentReports()
        case .delete: Crashlytics.crashlytics().deleteUnsentReports()
        case nil: break
        }
    }

    func setCrashReportsEnabled(_ enabled: Bool) {
        preferences.setEnabled(enabled, for: .crashes)
        crashReportsEnabled = enabled
        applyCollectionPolicy()
    }

    func setAnalyticsEnabled(_ enabled: Bool) {
        preferences.setEnabled(enabled, for: .analytics)
        analyticsEnabled = enabled
        applyCollectionPolicy()
    }

    func setRemoteConfigurationEnabled(_ enabled: Bool) {
        remoteConfigurationEnabled = enabled
        if let remoteConfiguration {
            remoteConfiguration.setEnabled(enabled)
        } else {
            preferences.setEnabled(enabled, for: .remoteConfiguration)
            if !enabled {
                preferences.saveRemotePolicy(nil)
                if preferences.remoteInstallationUsed { preferences.remoteCleanupRequired = true }
            }
        }
    }
}
