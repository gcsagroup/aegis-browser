import FirebaseCore
import FirebaseInstallations
import FirebaseRemoteConfig
import Foundation

@MainActor
final class FirebaseRemoteDiagnosticsSource: RemoteDiagnosticsSource {
    private static let appName = "AegisDiagnosticsConfig"
    private let options: FirebaseOptions

    init(options: FirebaseOptions) { self.options = options }

    private func app() throws -> FirebaseApp {
        if let existing = FirebaseApp.app(name: Self.appName) { return existing }
        FirebaseApp.configure(name: Self.appName, options: options)
        guard let app = FirebaseApp.app(name: Self.appName) else { throw SourceError.unavailable }
        app.isDataCollectionDefaultEnabled = false
        return app
    }

    func fetch(after revocation: Date?) async throws -> RemoteDiagnosticsResponse {
        let remote = RemoteConfig.remoteConfig(app: try app())
        let settings = RemoteConfigSettings()
        settings.minimumFetchInterval = 12 * 60 * 60
        settings.fetchTimeout = 10
        remote.configSettings = settings
        // No real-time listener, custom signals, defaults that grant consent, or
        // Analytics-backed targeting. Only explicitly fetched values are read.
        // Opting back in requires a backend fetch newer than the revocation fence.
        // Normal launches retain the 12-hour interval; backend throttling still applies.
        let result = try await remote.fetch(withExpirationDuration: revocation == nil ? 12 * 60 * 60 : 0)
        guard result == .success, let fetchedAt = remote.lastFetchTime else { throw SourceError.unavailable }
        _ = try await remote.activate()
        var values: [String: String] = [:]
        for key in RemoteDiagnosticsPolicy.keys {
            let value = remote.configValue(forKey: key)
            if value.source == .remote { values[key] = value.stringValue }
        }
        return RemoteDiagnosticsResponse(values: values, fetchedAt: fetchedAt)
    }

    func deleteInstallation() async throws {
        // This named instance is separate from the default Crashlytics identity.
        // The controller waits for an outstanding fetch before calling delete.
        let instance = try app()
        do {
            try await Installations.installations(app: instance).delete()
        } catch {
            guard FirebaseInstallationCleanup.isAlreadyAbsent(error, appID: options.googleAppID,
                                                                appName: Self.appName) else { throw error }
        }
    }

    private enum SourceError: Error { case unavailable }
}
