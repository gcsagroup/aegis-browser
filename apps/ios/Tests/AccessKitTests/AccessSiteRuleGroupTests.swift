import XCTest
@testable import AccessKit

final class AccessSiteRuleGroupTests: XCTestCase {
    func testPrimaryIsAlwaysAMemberAndDedupes() throws {
        let primary = try AccessSiteHost("www.example.com")
        let login = try AccessSiteHost("login.example.com")
        let group = try AccessSiteRuleGroup(
            scopeID: "ordinary",
            isPrivate: false,
            primaryHost: primary,
            memberHosts: [primary, login, login],
            generation: 1
        )
        XCTAssertEqual(group.memberHosts, [primary, login])
        XCTAssertTrue(group.contains(login))
        XCTAssertFalse(group.contains(try AccessSiteHost("cdn.example.com")))
        XCTAssertEqual(group.hostStoreKeys().count, 2)
    }

    func testRejectsEmptyScopeAndZeroGeneration() throws {
        let host = try AccessSiteHost("example.com")
        XCTAssertThrowsError(
            try AccessSiteRuleGroup(
                scopeID: " ",
                isPrivate: false,
                primaryHost: host,
                memberHosts: [],
                generation: 1
            )
        )
        XCTAssertThrowsError(
            try AccessSiteRuleGroup(
                scopeID: "ordinary",
                isPrivate: false,
                primaryHost: host,
                memberHosts: [],
                generation: 0
            )
        )
    }

    func testRegistryPublishLookupAndRevoke() throws {
        let registry = AccessSiteRuleGroupRegistry()
        let www = try AccessSiteHost("www.example.com")
        let login = try AccessSiteHost("login.example.com")
        let group = try AccessSiteRuleGroup(
            scopeID: "ordinary",
            isPrivate: false,
            primaryHost: www,
            memberHosts: [login],
            generation: 2
        )
        XCTAssertNil(registry.publish(group))
        XCTAssertEqual(registry.group(containing: login, scopeID: "ordinary", isPrivate: false)?.generation, 2)
        XCTAssertNil(registry.group(containing: login, scopeID: "other", isPrivate: false))

        let revoked = registry.revoke(primaryHost: www, scopeID: "ordinary", isPrivate: false)
        XCTAssertEqual(revoked?.groupID, group.groupID)
        XCTAssertNil(registry.group(containing: www, scopeID: "ordinary", isPrivate: false))
    }

    func testChannelLimitRejectsOnePastTheCapAndAllowsTheBoundary() throws {
        let primary = try AccessSiteHost("primary.example")
        for (channel, limit) in [
            (AccessReleaseChannel.release, 16),
            (AccessReleaseChannel.unknown, 16),
            (AccessReleaseChannel.beta, 32),
            (AccessReleaseChannel.alpha, 64),
            (AccessReleaseChannel.dev, 128)
        ] {
            let boundary = try hosts(count: limit - 1, prefix: channel.rawValue)
            let accepted = try AccessSiteRuleGroup(
                scopeID: "ordinary",
                isPrivate: false,
                primaryHost: primary,
                memberHosts: boundary,
                generation: 1,
                channel: channel
            )
            XCTAssertEqual(accepted.memberHosts.count, limit)
            XCTAssertTrue(accepted.isExecutable(on: channel))
            let overflow = try hosts(count: limit, prefix: channel.rawValue)
            XCTAssertThrowsError(
                try AccessSiteRuleGroup(
                    scopeID: "ordinary",
                    isPrivate: false,
                    primaryHost: primary,
                    memberHosts: overflow,
                    generation: 1,
                    channel: channel
                )
            )
        }
        let wide = try AccessSiteRuleGroup(
            scopeID: "ordinary",
            isPrivate: false,
            primaryHost: primary,
            memberHosts: try hosts(count: 16, prefix: "wide"),
            generation: 1,
            channel: .dev
        )
        XCTAssertFalse(wide.isExecutable(on: .release))
    }

    private func hosts(count: Int, prefix: String) throws -> [AccessSiteHost] {
        try (0..<count).map { try AccessSiteHost("\($0).\(prefix).example") }
    }

    func testPrivateSessionRevokeAll() throws {
        let registry = AccessSiteRuleGroupRegistry()
        let a = try AccessSiteHost("a.example.com")
        let b = try AccessSiteHost("b.example.com")
        _ = registry.publish(
            try AccessSiteRuleGroup(
                scopeID: "priv-1",
                isPrivate: true,
                primaryHost: a,
                memberHosts: [],
                generation: 1
            )
        )
        _ = registry.publish(
            try AccessSiteRuleGroup(
                scopeID: "priv-1",
                isPrivate: true,
                primaryHost: b,
                memberHosts: [],
                generation: 1
            )
        )
        _ = registry.publish(
            try AccessSiteRuleGroup(
                scopeID: "ordinary",
                isPrivate: false,
                primaryHost: a,
                memberHosts: [],
                generation: 1
            )
        )
        let removed = registry.revokeAll(scopeID: "priv-1", isPrivate: true)
        XCTAssertEqual(removed.count, 2)
        XCTAssertEqual(registry.activeGroups().count, 1)
    }

    func testStalePublishKeepsTheCurrentGeneration() throws {
        let registry = AccessSiteRuleGroupRegistry()
        let primary = try AccessSiteHost("www.example.com")
        let login = try AccessSiteHost("login.example.com")
        let first = try AccessSiteRuleGroup(
            scopeID: "ordinary",
            isPrivate: false,
            primaryHost: primary,
            memberHosts: [login],
            generation: 1
        )
        XCTAssertEqual(registry.publish(first, expectedPriorGeneration: 0), .published(replaced: nil))
        let stale = try AccessSiteRuleGroup(
            scopeID: "ordinary",
            isPrivate: false,
            primaryHost: primary,
            memberHosts: [],
            generation: 1
        )
        XCTAssertEqual(
            registry.publish(stale, expectedPriorGeneration: 0),
            .rejectedStale(current: first)
        )
        XCTAssertEqual(registry.group(groupID: first.groupID)?.memberHosts, [primary, login])
    }

    func testRevokeRemovesOnlyThatGroupsContribution() throws {
        let registry = AccessSiteRuleGroupRegistry()
        let login = try AccessSiteHost("login.example.com")
        let shop = try AccessSiteRuleGroup(
            scopeID: "ordinary",
            isPrivate: false,
            primaryHost: try AccessSiteHost("shop.example.com"),
            memberHosts: [login],
            generation: 1
        )
        let account = try AccessSiteRuleGroup(
            scopeID: "ordinary",
            isPrivate: false,
            primaryHost: try AccessSiteHost("account.example.com"),
            memberHosts: [login],
            generation: 1
        )
        _ = registry.publish(shop)
        _ = registry.publish(account)
        let listed = registry.groups(containing: login, scopeID: "ordinary", isPrivate: false)
        XCTAssertEqual(Set(listed.map(\.groupID)), Set([shop.groupID, account.groupID]))
        _ = registry.remove(groupID: shop.groupID)
        let remaining = registry.groups(containing: login, scopeID: "ordinary", isPrivate: false)
        XCTAssertEqual(remaining.map(\.groupID), [account.groupID])
    }

    func testProbePlanCapsDevAndSkipsHostsThatAlreadyRequireProxy() throws {
        let direct = try AccessSiteHost("direct.example")
        let proxied = try AccessSiteHost("proxied.example")
        let second = try AccessSiteHost("second.example")
        let third = try AccessSiteHost("third.example")
        let fourth = try AccessSiteHost("fourth.example")
        let plan = AccessSiteProbePlan.make(
            candidates: [proxied, direct, direct, second, third, fourth],
            alreadyRequiringProxy: [proxied],
            channel: .dev
        )
        XCTAssertEqual(plan?.hosts, [direct, second, third])
        XCTAssertEqual(AccessSiteProbePlan.budget, .seconds(15))
        XCTAssertNil(AccessSiteProbePlan.make(candidates: [direct], alreadyRequiringProxy: [], channel: .release))
        XCTAssertNil(AccessSiteProbePlan.make(candidates: [direct], alreadyRequiringProxy: [], channel: .beta))
        XCTAssertNil(AccessSiteProbePlan.make(candidates: [proxied], alreadyRequiringProxy: [proxied], channel: .alpha))
    }
}
