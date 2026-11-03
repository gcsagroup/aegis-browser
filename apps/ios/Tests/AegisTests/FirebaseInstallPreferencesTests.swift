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

        preferences.setEnabled(false, for: .analytics)
        let restored = FirebaseInstallPreferences(defaults: defaults, registration: registration)
        XCTAssertTrue(restored.isEnabled(.crashes))
        XCTAssertFalse(restored.isEnabled(.analytics))
        restored.setEnabled(false, for: .crashes)
        restored.setEnabled(true, for: .analytics)
        XCTAssertFalse(preferences.isEnabled(.crashes))
        XCTAssertTrue(preferences.isEnabled(.analytics))
    }
}
