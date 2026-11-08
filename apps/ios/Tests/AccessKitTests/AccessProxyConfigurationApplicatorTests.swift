import WebKit
import XCTest
@testable import AccessKit

@MainActor
final class AccessProxyConfigurationApplicatorTests: XCTestCase {
    func testBuilderPlansHttpCleartextAndHttpsTLS() throws {
        let http = try AccessProxyRegistrationFixture.httpOrdinary(port: 18_101)
        let https = try AccessProxyRegistrationFixture.httpsPrivate(port: 18_443)

        let httpPlan = try XCTUnwrap(AccessProxyConfigurationBuilder.plan(for: http))
        XCTAssertEqual(httpPlan.host, "127.0.0.1")
        XCTAssertEqual(httpPlan.port, 18_101)
        XCTAssertFalse(httpPlan.usesTLSToProxy)

        let httpsPlan = try XCTUnwrap(AccessProxyConfigurationBuilder.plan(for: https))
        XCTAssertEqual(httpsPlan.port, 18_443)
        XCTAssertTrue(httpsPlan.usesTLSToProxy)
    }

    func testInactiveFixtureBuildsEmptyConfigurationList() throws {
        let inactive = try AccessProxyRegistrationFixture.httpOrdinary().deactivated()
        XCTAssertNil(AccessProxyConfigurationBuilder.plan(for: inactive))
        XCTAssertTrue(try AccessProxyConfigurationBuilder.makeConfigurations(from: inactive).isEmpty)
    }

    func testFixtureRejectsNonLoopbackAndZeroPort() {
        XCTAssertThrowsError(
            try AccessProxyRegistrationFixture(
                registrationId: "bad-host",
                dataStoreKind: .ordinary,
                transport: .http,
                loopbackHost: "example.com",
                port: 18_101,
                isActive: true
            )
        ) { error in
            XCTAssertEqual(
                error as? AccessProxyConfigurationError,
                .nonLoopbackHost("example.com")
            )
        }
        XCTAssertThrowsError(
            try AccessProxyRegistrationFixture(
                registrationId: "bad-port",
                dataStoreKind: .ordinary,
                transport: .http,
                loopbackHost: "127.0.0.1",
                port: 0,
                isActive: true
            )
        ) { error in
            XCTAssertEqual(error as? AccessProxyConfigurationError, .invalidPort)
        }
    }

    func testApplyWritesConfigurationAndClearRemovesOldPort() throws {
        let applicator = AccessProxyConfigurationApplicator()
        let store = WKWebsiteDataStore.nonPersistent()
        let first = try AccessProxyRegistrationFixture.httpOrdinary(port: 18_101)
        let second = try AccessProxyRegistrationFixture.httpOrdinary(
            registrationId: "fixture-http-ordinary-2",
            port: 18_202
        )

        try applicator.applyToOrdinaryStore(first, dataStore: store)
        XCTAssertEqual(store.proxyConfigurations.count, 1)

        try applicator.applyToOrdinaryStore(second, dataStore: store)
        XCTAssertEqual(store.proxyConfigurations.count, 1)

        let secondPlan = try XCTUnwrap(AccessProxyConfigurationBuilder.plan(for: second))
        XCTAssertEqual(secondPlan.port, 18_202)

        applicator.clearOrdinaryStore(store)
        XCTAssertTrue(store.proxyConfigurations.isEmpty)

        // Re-applying after clear must not resurrect the previous port selection.
        try applicator.applyToOrdinaryStore(second, dataStore: store)
        XCTAssertEqual(store.proxyConfigurations.count, 1)
        applicator.clear(dataStore: store)
        XCTAssertTrue(store.proxyConfigurations.isEmpty)
    }

    func testDeactivatedRegistrationClearsStore() throws {
        let applicator = AccessProxyConfigurationApplicator()
        let store = WKWebsiteDataStore.nonPersistent()
        let active = try AccessProxyRegistrationFixture.httpOrdinary(port: 19_001)

        try applicator.apply(active, to: store)
        XCTAssertEqual(store.proxyConfigurations.count, 1)

        try applicator.apply(active.deactivated(), to: store)
        XCTAssertTrue(store.proxyConfigurations.isEmpty)
    }

    func testOrdinaryAndPrivateStoreBoundaries() throws {
        let applicator = AccessProxyConfigurationApplicator()
        let ordinaryStore = WKWebsiteDataStore.nonPersistent()
        let privateStore = WKWebsiteDataStore.nonPersistent()
        let ordinary = try AccessProxyRegistrationFixture.httpOrdinary(port: 18_301)
        let privateFixture = try AccessProxyRegistrationFixture.httpsPrivate(port: 18_401)

        try applicator.applyToOrdinaryStore(ordinary, dataStore: ordinaryStore)
        try applicator.applyToPrivateStore(privateFixture, dataStore: privateStore)
        XCTAssertEqual(ordinaryStore.proxyConfigurations.count, 1)
        XCTAssertEqual(privateStore.proxyConfigurations.count, 1)

        XCTAssertThrowsError(
            try applicator.applyToOrdinaryStore(privateFixture, dataStore: ordinaryStore)
        ) { error in
            XCTAssertEqual(
                error as? AccessProxyConfigurationError,
                .dataStoreKindMismatch(expected: .ordinary, actual: .privateBrowsing)
            )
        }
        XCTAssertThrowsError(
            try applicator.applyToPrivateStore(ordinary, dataStore: privateStore)
        ) { error in
            XCTAssertEqual(
                error as? AccessProxyConfigurationError,
                .dataStoreKindMismatch(expected: .privateBrowsing, actual: .ordinary)
            )
        }

        // Cross-lane rejection must not clear an already correctly applied store.
        XCTAssertEqual(ordinaryStore.proxyConfigurations.count, 1)
        XCTAssertEqual(privateStore.proxyConfigurations.count, 1)

        applicator.clearPrivateStore(privateStore)
        XCTAssertTrue(privateStore.proxyConfigurations.isEmpty)
        XCTAssertEqual(ordinaryStore.proxyConfigurations.count, 1)
    }

    func testIpv6LoopbackHttpsFixtureBuildsTLSConfiguration() throws {
        let fixture = try AccessProxyRegistrationFixture(
            registrationId: "fixture-https-v6",
            dataStoreKind: .ordinary,
            transport: .https,
            loopbackHost: "::1",
            port: 18_444,
            isActive: true
        )
        let plan = try XCTUnwrap(AccessProxyConfigurationBuilder.plan(for: fixture))
        XCTAssertEqual(plan.host, "::1")
        XCTAssertTrue(plan.usesTLSToProxy)
        XCTAssertEqual(try AccessProxyConfigurationBuilder.makeConfigurations(from: fixture).count, 1)
    }

    func testFixtureRejectsEmptyRegistrationId() {
        XCTAssertThrowsError(
            try AccessProxyRegistrationFixture(
                registrationId: "  ",
                dataStoreKind: .ordinary,
                transport: .http,
                loopbackHost: "127.0.0.1",
                port: 18_101,
                isActive: true
            )
        ) { error in
            XCTAssertEqual(error as? AccessProxyConfigurationError, .emptyRegistrationId)
        }
    }
}
