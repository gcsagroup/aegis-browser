import Foundation

/// Firebase 13.1.1 has no public not-found code. Match only its exact local-store
/// absence error for this named app; network, Keychain and unknown errors retry.
/// Revalidate against FIRInstallationsErrorUtil when upgrading the pinned SDK.
enum FirebaseInstallationCleanup {
    static func isAlreadyAbsent(_ error: Error, appID: String, appName: String) -> Bool {
        let error = error as NSError
        return error.domain == "com.firebase.installations" && error.code == 0
            && error.userInfo[NSUnderlyingErrorKey] == nil
            && error.userInfo[NSLocalizedFailureReasonErrorKey] as? String
                == "Installation for appID \(appID) appName \(appName) not found"
    }
}
