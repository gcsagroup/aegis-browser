import AccessKit
import XCTest
@testable import Aegis

private final class ToggleTestOrchestrator: AccessSiteSessionOrchestrating {
    var nodeAvailable = true
    private var tokenCounter: UInt64 = 0

    func prepareCandidate(for host: AccessSiteHost) throws -> AccessSiteSessionCandidate {
        guard nodeAvailable else { throw AccessSiteSessionError.nodeUnavailable }
        let registration = AccessRegistration(
            id: try AccessRegistrationID("reg-\(host.rawValue)"),
            owner: try AccessOwner(channel: 1, profile: "ordinary", partition: "default"),
            transport: .http,
            endpoint: try AccessEndpoint(host: "127.0.0.1", port: 18_301),
            credentialSlot: try AccessCredentialSlot(id: "cred-\(host.rawValue)"),
            lease: try AccessLease(
                generation: 1,
                expiresAt: Date(timeIntervalSince1970: 1_700_000_000 + 3_600)
            )
        )
        let fixture = try AccessProxyRegistrationFixture(
            registrationId: registration.id.rawValue,
            dataStoreKind: .ordinary,
            transport: .http,
            loopbackHost: "127.0.0.1",
            port: registration.endpoint.port,
            isActive: true
        )
        return AccessSiteSessionCandidate(
            host: host,
            registration: registration,
            proxyFixture: fixture
        )
    }

    func publish(_ candidate: AccessSiteSessionCandidate) throws -> AccessSiteSessionPublication {
        tokenCounter += 1
        return AccessSiteSessionPublication(
            candidate: candidate,
            publicationToken: "pub-\(tokenCounter)"
        )
    }

    func acknowledge(_ publication: AccessSiteSessionPublication) throws -> AccessSiteSessionAck {
        AccessSiteSessionAck(
            publicationToken: publication.publicationToken,
            registrationID: publication.candidate.registration.id
        )
    }

    func activateRealityPath(
        ack: AccessSiteSessionAck,
        candidate: AccessSiteSessionCandidate
    ) throws {
        _ = ack
        _ = candidate
    }

    func tearDown(registrationID: AccessRegistrationID) throws {
        _ = registrationID
    }
}

final class AccessSiteProxyToggleModelTests: XCTestCase {
    func testTrustedHostFromHTTPSNavigation() throws {
        let host = AccessSiteProxyToggleModel.resolveTrustedHost(
            from: URL(string: "https://Example.COM:443/path?q=1")
        )
        XCTAssertEqual(host?.rawValue, "example.com")
    }

    func testInternalPagesHaveNoTrustedHost() {
        XCTAssertNil(
            AccessSiteProxyToggleModel.resolveTrustedHost(from: URL(string: "aegis://start"))
        )
        XCTAssertNil(
            AccessSiteProxyToggleModel.resolveTrustedHost(from: URL(string: "file:///tmp/x.html"))
        )
        XCTAssertNil(AccessSiteProxyToggleModel.resolveTrustedHost(from: nil))
    }

    func testSwitchOnDoesNotImplyConnectionReady() throws {
        let orchestrator = ToggleTestOrchestrator()
        orchestrator.nodeAvailable = false
        let controller = AccessSiteSessionController(orchestrator: orchestrator)
        let host = try AccessSiteHost("blocked.example")
        let after = AccessSiteProxyToggleModel.applyToggle(
            enabled: true,
            host: host,
            controller: controller
        )
        XCTAssertTrue(after.toggleOn)
        XCTAssertEqual(after.intent, .allow)
        XCTAssertEqual(after.connection, .unavailable)
        XCTAssertEqual(after.intentStatus, .allowNotConnected)
        XCTAssertEqual(after.connectionStatus, .unavailable)
        XCTAssertEqual(
            AccessSiteProxyToggleModel.intentLine(for: after.intentStatus),
            "本站代理已开启 · 连接尚未就绪"
        )
        XCTAssertFalse(
            AccessSiteProxyToggleModel.intentLine(for: after.intentStatus)
                .contains("直连成功")
        )
    }

    func testToggleOffUsesBrowserDefaultCopy() throws {
        let controller = AccessSiteSessionController(orchestrator: ToggleTestOrchestrator())
        let host = try AccessSiteHost("news.example")
        _ = try controller.enable(host: host)
        let off = AccessSiteProxyToggleModel.applyToggle(
            enabled: false,
            host: host,
            controller: controller
        )
        XCTAssertFalse(off.toggleOn)
        XCTAssertEqual(off.intent, .off)
        XCTAssertEqual(off.connection, .idle)
        XCTAssertEqual(off.intentStatus, .offBrowserDefault)
        XCTAssertEqual(
            AccessSiteProxyToggleModel.intentLine(for: .offBrowserDefault),
            "未使用本服务代理 / 使用浏览器原有连接"
        )
    }

    func testReadyPathKeepsIntentAndConnectionLinesDistinct() throws {
        let controller = AccessSiteSessionController(orchestrator: ToggleTestOrchestrator())
        let url = URL(string: "https://ready.example/article")!
        let host = try XCTUnwrap(AccessSiteProxyToggleModel.resolveTrustedHost(from: url))
        _ = try controller.enable(host: host)
        let snap = AccessSiteProxyToggleModel.buildSnapshot(url: url, controller: controller)
        XCTAssertTrue(snap.toggleOn)
        XCTAssertEqual(snap.intentStatus, .allowConnected)
        XCTAssertEqual(snap.connectionStatus, .ready)
        XCTAssertNotEqual(
            AccessSiteProxyToggleModel.intentLine(for: snap.intentStatus),
            AccessSiteProxyToggleModel.connectionLine(for: snap.connectionStatus)
        )
    }

    @MainActor
    func testFailClosedAppOrchestratorNeverClaimsReady() {
        let store = AccessSiteProxySessionStore()
        let url = URL(string: "https://fail.example/")!
        store.setProxyEnabled(true, for: url)
        let snap = store.snapshot(for: url)
        XCTAssertTrue(snap.toggleOn)
        XCTAssertEqual(snap.intent, .allow)
        XCTAssertEqual(snap.connection, .unavailable)
        XCTAssertEqual(snap.connectionStatus, .unavailable)
        XCTAssertNotNil(snap.failureReason)
    }
}
