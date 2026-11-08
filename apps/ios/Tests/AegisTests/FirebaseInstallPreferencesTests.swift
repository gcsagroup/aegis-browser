import Foundation
import XCTest
@testable import Aegis

final class FirebaseInstallPreferencesTests: XCTestCase {
    func testDifferentRegistrationCannotReuseAnInstalledContainer() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = directory.appending(path: "registration")
        let preferences = FirebaseInstallPreferences(defaults: defaults, registration: registration)

        XCTAssertTrue(try preferences.bind(to: "1:123:ios:abc"))
        XCTAssertTrue(try FirebaseInstallPreferences(defaults: defaults, registration: registration).bind(to: "1:123:ios:abc"))
        XCTAssertFalse(try preferences.bind(to: "1:456:ios:def"))
        XCTAssertTrue(try preferences.bind(to: "1:123:ios:abc"))
    }

    func testCollectionDefaultsOnAndChoicesPersistIndependently() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = directory.appending(path: "registration")
        let preferences = FirebaseInstallPreferences(defaults: defaults, registration: registration)
        XCTAssertTrue(preferences.isEnabled(.crashes))
        XCTAssertTrue(preferences.isEnabled(.analytics))
        XCTAssertTrue(preferences.isEnabled(.remoteConfiguration))

        preferences.setEnabled(false, for: .crashes)
        preferences.setEnabled(false, for: .analytics)
        preferences.setEnabled(false, for: .remoteConfiguration)
        let restored = FirebaseInstallPreferences(defaults: defaults, registration: registration)
        XCTAssertFalse(restored.isEnabled(.crashes))
        XCTAssertFalse(restored.isEnabled(.analytics))
        XCTAssertFalse(restored.isEnabled(.remoteConfiguration))
        restored.setEnabled(true, for: .crashes)
        restored.setEnabled(true, for: .analytics)
        XCTAssertTrue(preferences.isEnabled(.crashes))
        XCTAssertTrue(preferences.isEnabled(.analytics))
        XCTAssertFalse(preferences.isEnabled(.remoteConfiguration))
    }
}
