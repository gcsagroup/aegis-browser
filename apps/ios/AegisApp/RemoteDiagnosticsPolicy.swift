import Foundation

/// Remote values only constrain local consent. They are never saved as consent.
struct RemoteDiagnosticsPolicy: Codable, Equatable, Sendable {
    static let maximumAge: TimeInterval = 24 * 60 * 60
    static let keys = ["aegis_diagnostics_schema", "aegis_crash_reports_allowed", "aegis_analytics_allowed"]

    let crashesAllowed: Bool
    let analyticsAllowed: Bool
    let fetchedAt: Date

    init?(values: [String: String], fetchedAt: Date, now: Date) {
        guard values[Self.keys[0]] == "1",
              let crashes = Self.boolean(values[Self.keys[1]]),
              let analytics = Self.boolean(values[Self.keys[2]]) else { return nil }
        crashesAllowed = crashes
        analyticsAllowed = analytics
        self.fetchedAt = fetchedAt
        guard isValid(at: now) else { return nil }
    }

    func isValid(at now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age.isFinite && age >= 0 && age < Self.maximumAge
    }

    func permits(_ collection: FirebaseInstallPreferences.Collection, localChoice: Bool, now: Date) -> Bool {
        guard localChoice, isValid(at: now) else { return false }
        switch collection {
        case .crashes: return crashesAllowed
        case .analytics: return analyticsAllowed
        case .remoteConfiguration: return false
        }
    }

    private static func boolean(_ value: String?) -> Bool? {
        switch value {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}

/// Crashlytics resolves send/delete through a single SDK promise per launch.
struct DiagnosticsLaunchDecision {
    enum Action { case send, delete }
    private var decided = false

    mutating func resolve(allowed: Bool, policySettled: Bool) -> Action? {
        guard !decided, policySettled else { return nil }
        decided = true
        return allowed ? .send : .delete
    }
}
