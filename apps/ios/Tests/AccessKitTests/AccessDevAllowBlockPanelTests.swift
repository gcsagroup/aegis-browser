import XCTest
@testable import AccessKit

final class AccessDevAllowBlockPanelTests: XCTestCase {
    func testAdmitsDevAlphaUnknownOnly() {
        XCTAssertTrue(AccessDevAllowBlockPanel.isPanelAdmitted(.dev))
        XCTAssertTrue(AccessDevAllowBlockPanel.isPanelAdmitted(.alpha))
        XCTAssertTrue(AccessDevAllowBlockPanel.isPanelAdmitted(.unknown))
        XCTAssertFalse(AccessDevAllowBlockPanel.isPanelAdmitted(.beta))
        XCTAssertFalse(AccessDevAllowBlockPanel.isPanelAdmitted(.release))
    }

    func testNeverRegistersGeneralRuleEditorOnAnyChannel() {
        for channel in AccessReleaseChannel.allCases {
            XCTAssertFalse(
                AccessDevAllowBlockPanel.isGeneralAccessRuleEditorRegistered(channel)
            )
        }
    }

    func testBetaReleaseRefuseApply() throws {
        var store = AccessSiteIntentStore()
        let blocked = AccessDevAllowBlockPanel.apply(
            store: &store,
            channel: .beta,
            rawHost: "news.example",
            action: .allow
        )
        XCTAssertEqual(blocked.status, .channelNotAdmitted)
        XCTAssertTrue(store.allIntents().isEmpty)

        let release = AccessDevAllowBlockPanel.apply(
            store: &store,
            channel: .release,
            rawHost: "news.example",
            action: .block
        )
        XCTAssertEqual(release.status, .channelNotAdmitted)
        XCTAssertTrue(store.allIntents().isEmpty)
    }

    func testDevAppliesAllowBlockOffOnExplicitHost() throws {
        var store = AccessSiteIntentStore()
        let allow = AccessDevAllowBlockPanel.apply(
            store: &store,
            channel: .dev,
            rawHost: "https://NEWS.Example/path",
            action: .allow
        )
        XCTAssertEqual(allow.status, .applied)
        XCTAssertEqual(allow.host?.rawValue, "news.example")
        XCTAssertEqual(allow.intent, .allow)
        XCTAssertEqual(store.intent(for: try AccessSiteHost("news.example")), .allow)

        let block = AccessDevAllowBlockPanel.apply(
            store: &store,
            channel: .dev,
            rawHost: "news.example",
            action: .block
        )
        XCTAssertEqual(block.status, .applied)
        XCTAssertEqual(block.intent, .block)
        XCTAssertEqual(store.intent(for: try AccessSiteHost("news.example")), .block)
        // Block is product-local refuse — never ordinary DIRECT here.
        XCTAssertEqual(block.intent, .block)
        XCTAssertNotEqual(block.intent, .off)

        let off = AccessDevAllowBlockPanel.apply(
            store: &store,
            channel: .alpha,
            rawHost: "news.example",
            action: .off
        )
        XCTAssertEqual(off.status, .applied)
        XCTAssertEqual(off.intent, .off)
        XCTAssertEqual(store.intent(for: try AccessSiteHost("news.example")), .off)
        XCTAssertTrue(store.allIntents().isEmpty)
    }

    func testRejectsInvalidHost() {
        var store = AccessSiteIntentStore()
        let empty = AccessDevAllowBlockPanel.apply(
            store: &store,
            channel: .dev,
            rawHost: "",
            action: .allow
        )
        XCTAssertEqual(empty.status, .invalidHost)

        let bad = AccessDevAllowBlockPanel.apply(
            store: &store,
            channel: .dev,
            rawHost: "not a host",
            action: .block
        )
        XCTAssertEqual(bad.status, .invalidHost)
        XCTAssertTrue(store.allIntents().isEmpty)
    }

    func testHostNormalizeFromURLAndExact() throws {
        var store = AccessSiteIntentStore()
        let fromURL = AccessDevAllowBlockPanel.apply(
            store: &store,
            channel: .unknown,
            rawHost: "https://WWW.Example.COM:443/story",
            action: .allow
        )
        XCTAssertEqual(fromURL.status, .applied)
        XCTAssertEqual(fromURL.host?.rawValue, "www.example.com")

        let exact = AccessDevAllowBlockPanel.apply(
            store: &store,
            channel: .unknown,
            rawHost: "www.example.com",
            action: .block
        )
        XCTAssertEqual(exact.status, .applied)
        XCTAssertEqual(exact.host?.rawValue, "www.example.com")
    }

    func testSnapshotHidesPanelOnBetaRelease() {
        let store = AccessSiteIntentStore()
        let url = URL(string: "https://news.example/story")!
        let beta = AccessDevAllowBlockPanel.buildSnapshot(
            channel: .beta,
            store: store,
            url: url
        )
        XCTAssertFalse(beta.panelRegistered)
        XCTAssertFalse(beta.generalRuleEditorRegistered)
        XCTAssertFalse(beta.hasExplicitHost)
        XCTAssertEqual(beta.statusId, .panelNotRegistered)

        let release = AccessDevAllowBlockPanel.buildSnapshot(
            channel: .release,
            store: store,
            url: url
        )
        XCTAssertFalse(release.panelRegistered)
        XCTAssertEqual(release.statusId, .panelNotRegistered)
    }

    func testSnapshotShowsAllowBlockForTrustedHost() throws {
        var store = AccessSiteIntentStore()
        let url = URL(string: "https://news.example/story")!
        let idle = AccessDevAllowBlockPanel.buildSnapshot(
            channel: .dev,
            store: store,
            url: url
        )
        XCTAssertTrue(idle.panelRegistered)
        XCTAssertFalse(idle.generalRuleEditorRegistered)
        XCTAssertTrue(idle.hasExplicitHost)
        XCTAssertEqual(idle.host?.rawValue, "news.example")
        XCTAssertEqual(idle.statusId, .off)

        XCTAssertEqual(
            AccessDevAllowBlockPanel.apply(
                store: &store,
                channel: .dev,
                rawHost: "news.example",
                action: .allow
            ).status,
            .applied
        )
        let allow = AccessDevAllowBlockPanel.buildSnapshot(
            channel: .dev,
            store: store,
            url: url
        )
        XCTAssertEqual(allow.statusId, .allowProxyIntent)

        XCTAssertEqual(
            AccessDevAllowBlockPanel.apply(
                store: &store,
                channel: .dev,
                rawHost: "news.example",
                action: .block
            ).status,
            .applied
        )
        let block = AccessDevAllowBlockPanel.buildSnapshot(
            channel: .dev,
            store: store,
            url: url
        )
        XCTAssertEqual(block.statusId, .blockLocalRefuse)

        let internalPage = AccessDevAllowBlockPanel.buildSnapshot(
            channel: .dev,
            store: store,
            url: URL(string: "about:blank")
        )
        XCTAssertTrue(internalPage.panelRegistered)
        XCTAssertFalse(internalPage.hasExplicitHost)
        XCTAssertEqual(internalPage.statusId, .noTrustedHost)
    }

    func testExplicitHostSnapshotIndependentOfURL() throws {
        var store = AccessSiteIntentStore()
        XCTAssertEqual(
            AccessDevAllowBlockPanel.apply(
                store: &store,
                channel: .unknown,
                rawHost: "blocked.example",
                action: .block
            ).status,
            .applied
        )
        let snap = AccessDevAllowBlockPanel.buildSnapshot(
            channel: .unknown,
            store: store,
            rawHost: "blocked.example"
        )
        XCTAssertTrue(snap.panelRegistered)
        XCTAssertTrue(snap.hasExplicitHost)
        XCTAssertEqual(snap.host?.rawValue, "blocked.example")
        XCTAssertEqual(snap.statusId, .blockLocalRefuse)
    }

    func testParsesReleaseChannelStrings() {
        XCTAssertEqual(AccessReleaseChannel.parse("dev"), .dev)
        XCTAssertEqual(AccessReleaseChannel.parse("Alpha"), .alpha)
        XCTAssertEqual(AccessReleaseChannel.parse("beta"), .beta)
        XCTAssertEqual(AccessReleaseChannel.parse("release"), .release)
        XCTAssertEqual(AccessReleaseChannel.parse(nil), .unknown)
        XCTAssertEqual(AccessReleaseChannel.parse("nightly"), .unknown)
    }
}
