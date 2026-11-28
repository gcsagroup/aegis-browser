import AegisPolicyKit
import CryptoKit
import XCTest
@testable import AccessKit
@testable import Aegis
@testable import BrowserKit

@MainActor
final class AccessGeoSiteSelectionTests: XCTestCase {
    private let selectionKey = "browser.websiteAcceleration.categories"
    private let modeKey = "browser.websiteAcceleration.mode"
    private let exactKey = "browser.websiteAcceleration.siteChoices.v1"

    func testBundledCatalogueContainsTheCompleteOfficialGroups() throws {
        let catalogue = AccessGeoSiteCatalogue.bundled
        XCTAssertEqual(catalogue.tag, "20261127013728")
        XCTAssertEqual(catalogue.publishedAt, "2026-11-27T01:38:41Z")
        XCTAssertEqual(catalogue.rawSHA256, "919a4b32cc9e6619e5bc17831cd388f89df77d9bf9817dab98b489d479162047")
        XCTAssertEqual(Set(catalogue.groups.keys), Set(AccessGeoSiteCategory.allCases))
        let expected: [(AccessGeoSiteCategory, Int, String)] = [
            (.debian, 3, "06c514bb68567fdf422969927719a7e6c19442509cb2c69eb43cb02efbc83aeb"),
            (.douban, 3, "62cfcbf5e006744783206139a2cbb6a3dffb05dbc366f1784a193e887e038619"),
            (.meituan, 19, "7f23061fb1a46f4150077aa56c369188cfda5bb49bd99649264c5bfb7bf8efa9")
        ]
        let policy = AccessWebsiteRoutePolicy()
        for (category, count, digest) in expected {
            let group = try XCTUnwrap(catalogue.groups[category])
            XCTAssertEqual(group.rules.count, count, category.rawValue)
            XCTAssertEqual(group.typedSHA256, digest)
            let canonical = group.rules.map { "\($0.kind.rawValue):\($0.host)\n" }.sorted().joined()
            let actual = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actual, digest, category.rawValue)
            for rule in group.rules {
                XCTAssertEqual(rule.kind, .domain)
                XCTAssertTrue(RegisteredDomain.allowsGeoSiteHost(rule.host, includingDescendants: true))
                let member = try XCTUnwrap(URL(string: "https://sub.\(rule.host)/"))
                XCTAssertTrue(policy.matches(member, categories: [category]))
                XCTAssertFalse(policy.matches(member, categories: Set(AccessGeoSiteCategory.allCases).subtracting([category])))
                let lookalike = try XCTUnwrap(URL(string: "https://not\(rule.host)/"))
                XCTAssertFalse(policy.matches(lookalike, categories: [category]))
            }
        }
    }

    func testOverlappingRulesKeepProtectionUntilTheLastMatchingCategoryIsRemoved() throws {
        let host = "overlap.geosite.invalid"
        let catalogue = AccessGeoSiteCatalogue(tag: "fixture", publishedAt: "", rawSHA256: "", groups: [
            .douban: .init(typedSHA256: "", rules: [.init(kind: .domain, host: host)]),
            .meituan: .init(typedSHA256: "", rules: [.init(kind: .full, host: host)])
        ])
        let policy = AccessWebsiteRoutePolicy(catalogue: catalogue)
        let apex = try XCTUnwrap(URL(string: "https://\(host)/"))
        let subdomain = try XCTUnwrap(URL(string: "https://sub.\(host)/"))
        XCTAssertTrue(policy.matches(apex, categories: [.douban, .meituan]))
        XCTAssertTrue(policy.matches(apex, categories: [.meituan]))
        XCTAssertTrue(policy.matches(apex, categories: [.douban]))
        XCTAssertFalse(policy.matches(apex, categories: []))
        XCTAssertTrue(policy.matches(subdomain, categories: [.douban, .meituan]))
        XCTAssertFalse(policy.matches(subdomain, categories: [.meituan]))
    }

    func testMigrationEmptyRelaunchAndManualRetainExactChoices() throws {
        for savedMode in [nil, "manual", "smart"] as [String?] {
            let suite = "test.geosite.selection." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(savedMode, forKey: modeKey)
            defaults.set(["www.douban.com": "original", "outside.geosite.invalid": "service"], forKey: exactKey)

            let coordinator = AccessHostStoreCoordinator(channel: .dev, locationPreferences: defaults)
            let owner = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
            let sibling = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), hostCoordinator: coordinator)
            defer { owner.closeWindow(); sibling.closeWindow() }
            let tab = try XCTUnwrap(owner.activeTab)
            let other = try XCTUnwrap(sibling.activeTab)
            let debian = try XCTUnwrap(URL(string: "https://debian.org/"))
            let douban = try XCTUnwrap(URL(string: "https://www.douban.com/"))
            let outside = try XCTUnwrap(URL(string: "https://outside.geosite.invalid/"))
            XCTAssertEqual(coordinator.websiteAccelerationMode, savedMode == "smart" ? .smart : .manual)
            XCTAssertEqual(defaults.stringArray(forKey: selectionKey), ["DEBIAN"])
            XCTAssertEqual(coordinator.requiresProxy(tab: tab, url: debian), savedMode == "smart")

            coordinator.setWebsiteAccelerationMode(.smart, for: tab)
            let initial = try XCTUnwrap(coordinator.websiteCategories(for: tab))
            XCTAssertEqual(initial.selected, [.debian])
            coordinator.setWebsiteCategory(.douban, selected: true, from: initial, for: tab)
            let both = try XCTUnwrap(coordinator.websiteCategories(for: other))
            XCTAssertEqual(both.selected, [.debian, .douban])
            XCTAssertFalse(coordinator.requiresProxy(tab: other, url: douban), "Exact original wins on a selected member")
            XCTAssertTrue(coordinator.requiresProxy(tab: other, url: outside), "Exact service wins on a nonmember")

            coordinator.setWebsiteAccelerationMode(.manual, for: tab)
            XCTAssertNil(coordinator.websiteCategories(for: other))
            XCTAssertFalse(coordinator.requiresProxy(tab: other, url: debian))
            XCTAssertTrue(coordinator.requiresProxy(tab: other, url: outside))
            XCTAssertEqual(defaults.stringArray(forKey: selectionKey), ["DEBIAN", "DOUBAN"])
            coordinator.setWebsiteAccelerationMode(.smart, for: tab)
            coordinator.setWebsiteCategory(.debian, selected: false, from: both, for: other)
            XCTAssertEqual(coordinator.websiteCategories(for: other)?.selected, [.debian, .douban], "The old presentation expired")
            coordinator.setWebsiteCategory(.debian, selected: false, from: try XCTUnwrap(coordinator.websiteCategories(for: other)), for: other)
            coordinator.setWebsiteCategory(.douban, selected: false, from: try XCTUnwrap(coordinator.websiteCategories(for: tab)), for: tab)
            XCTAssertEqual(defaults.stringArray(forKey: selectionKey), [])

            let recreated = AccessHostStoreCoordinator(channel: .dev, locationPreferences: defaults)
            owner.hostCoordinator = recreated
            XCTAssertTrue(try XCTUnwrap(recreated.websiteCategories(for: tab)).selected.isEmpty)
            XCTAssertFalse(recreated.requiresProxy(tab: tab, url: debian))
            XCTAssertTrue(recreated.requiresProxy(tab: tab, url: outside))
            XCTAssertEqual(defaults.dictionary(forKey: exactKey) as? [String: String],
                           ["www.douban.com": "original", "outside.geosite.invalid": "service"])
        }
    }

    func testPrivateUnknownChannelConflictingScopeAndOtherOwnerCannotUseSelections() throws {
        let suite = "test.geosite.owner." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("smart", forKey: modeKey)
        defaults.set(["DOUBAN"], forKey: selectionKey)
        let explicitOriginal = try XCTUnwrap(URL(string: "https://override.douban.com/"))
        let explicitService = try XCTUnwrap(URL(string: "https://override.example.invalid/"))
        defaults.set(["override.douban.com": "original", "override.example.invalid": "service"], forKey: exactKey)
        let owner = AccessHostStoreCoordinator(channel: .dev, locationPreferences: defaults)
        let preferences = BrowserPreferences(defaults: defaults)
        let browser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), preferences: preferences, hostCoordinator: owner)
        defer { browser.closeWindow() }
        let ordinary = try XCTUnwrap(browser.activeTab)
        let presented = try XCTUnwrap(owner.websiteCategories(for: ordinary))
        let target = try XCTUnwrap(URL(string: "https://www.douban.com/"))
        XCTAssertTrue(owner.requiresProxy(tab: ordinary, url: target))
        XCTAssertFalse(owner.requiresProxy(tab: ordinary, url: explicitOriginal))
        XCTAssertTrue(owner.requiresProxy(tab: ordinary, url: explicitService))

        for channel in [AccessReleaseChannel.release, .alpha, .beta, .unknown, .dev] {
            let otherOwner = AccessHostStoreCoordinator(channel: channel, locationPreferences: defaults)
            let otherBrowser = BrowserSession(dataStore: BrowserDataStore(persistenceURL: nil), preferences: preferences,
                                              hostCoordinator: otherOwner)
            defer { otherBrowser.closeWindow() }
            let otherTab = try XCTUnwrap(otherBrowser.activeTab)
            XCTAssertNil(owner.websiteCategories(for: otherTab))
            XCTAssertFalse(owner.requiresProxy(tab: otherTab, url: target))
            XCTAssertFalse(owner.requiresProxy(tab: otherTab, url: explicitService))
            XCTAssertFalse(owner.requiresProxyPreparation(tab: otherTab, url: explicitService))
            for url in [explicitOriginal, explicitService] {
                otherTab.adoptPolicyMainFrameNavigationForTests(url: url)
                otherTab.commitPendingMainFrameForTests()
                XCTAssertFalse(owner.offersWebsiteAcceleration(for: otherTab))
                XCTAssertNil(owner.websiteRouteChoice(for: otherTab))
                XCTAssertNil(owner.websiteRouteSelection(for: otherTab))
            }
            if channel != .dev {
                XCTAssertNil(otherOwner.websiteCategories(for: otherTab))
                XCTAssertFalse(otherOwner.requiresProxy(tab: otherTab, url: target))
            }
            otherOwner.setWebsiteCategory(.douban, selected: false, from: presented, for: otherTab)
        }

        ordinary.browsingScopeID = "unrecognized"
        XCTAssertNil(owner.websiteCategories(for: ordinary))
        XCTAssertFalse(owner.requiresProxy(tab: ordinary, url: target))
        owner.setWebsiteCategory(.douban, selected: false, from: presented, for: ordinary)
        ordinary.browsingScopeID = "ordinary"
        browser.switchProfile(to: .privateMode)
        let privateTab = try XCTUnwrap(browser.activeTab)
        privateTab.browsingScopeID = "ordinary"
        XCTAssertNil(owner.websiteCategories(for: privateTab))
        XCTAssertFalse(owner.requiresProxy(tab: privateTab, url: target))
        owner.setWebsiteCategory(.douban, selected: false, from: presented, for: privateTab)
        XCTAssertEqual(defaults.stringArray(forKey: selectionKey), ["DOUBAN"])
        XCTAssertEqual(owner.websiteCategories(for: ordinary)?.selected, [.douban])
    }
}
