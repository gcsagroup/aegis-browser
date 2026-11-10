import XCTest
@testable import AccessKit

private final class FakeOrchestrator: AccessSiteSessionOrchestrating {
    var nodeAvailable = true
    var runtimeReady = true
    var allowDirectFallback = false
    var failAt: Stage?
    var prepareCount = 0
    var publishCount = 0
    var ackCount = 0
    var activateCount = 0
    var tearDownCount = 0
    var lastTornDown: AccessRegistrationID?
    private var tokenCounter: UInt64 = 0

    enum Stage {
        case prepare
        case publish
        case ack
        case activate
        case tearDown
    }

    func prepareCandidate(for host: AccessSiteHost) throws -> AccessSiteSessionCandidate {
        prepareCount += 1
        guard nodeAvailable else { throw AccessSiteSessionError.nodeUnavailable }
        if failAt == .prepare { throw AccessSiteSessionError.prepareFailed("forced") }
        let registration = try makeRegistration(host: host)
        let fixture = try AccessProxyRegistrationFixture(
            registrationId: registration.id.rawValue,
            dataStoreKind: .ordinary,
            transport: .http,
            loopbackHost: registration.endpoint.host == "::1" ? "::1" : "127.0.0.1",
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
        publishCount += 1
        if failAt == .publish { throw AccessSiteSessionError.publishFailed("forced") }
        tokenCounter += 1
        return AccessSiteSessionPublication(
            candidate: candidate,
            publicationToken: "pub-\(tokenCounter)"
        )
    }

    func acknowledge(_ publication: AccessSiteSessionPublication) throws -> AccessSiteSessionAck {
        ackCount += 1
        if failAt == .ack { throw AccessSiteSessionError.ackFailed("forced") }
        return AccessSiteSessionAck(
            publicationToken: publication.publicationToken,
            registrationID: publication.candidate.registration.id
        )
    }

    func activateRealityPath(
        ack: AccessSiteSessionAck,
        candidate: AccessSiteSessionCandidate
    ) throws {
        activateCount += 1
        _ = ack
        _ = candidate
        if allowDirectFallback {
            throw AccessSiteSessionError.directFallbackNotAdmitted
        }
        guard runtimeReady else { throw AccessSiteSessionError.runtimeNotReady }
        if failAt == .activate {
            throw AccessSiteSessionError.dialSeamNotReady("forced")
        }
    }

    func tearDown(registrationID: AccessRegistrationID) throws {
        tearDownCount += 1
        lastTornDown = registrationID
        if failAt == .tearDown {
            throw AccessSiteSessionError.tearDownFailed("forced")
        }
    }

    private func makeRegistration(host: AccessSiteHost) throws -> AccessRegistration {
        AccessRegistration(
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
    }
}

final class AccessSiteSessionControllerTests: XCTestCase {
    func testEnableRunsPreparePublishAckReady() throws {
        let orchestrator = FakeOrchestrator()
        let controller = AccessSiteSessionController(orchestrator: orchestrator)
        let host = try AccessSiteHost("www.example.com")

        let snap = try controller.enable(host: host)

        XCTAssertEqual(snap.intent, .allow)
        XCTAssertEqual(snap.phase, .ready)
        XCTAssertEqual(snap.connectionState, .ready)
        XCTAssertEqual(snap.registrationID?.rawValue, "reg-www.example.com")
        XCTAssertNil(snap.failureReason)
        XCTAssertEqual(orchestrator.prepareCount, 1)
        XCTAssertEqual(orchestrator.publishCount, 1)
        XCTAssertEqual(orchestrator.ackCount, 1)
        XCTAssertEqual(orchestrator.activateCount, 1)
        XCTAssertEqual(controller.intentStoreSnapshot().intent(for: host), .allow)
    }

    func testFailedTearDownKeepsIdentityUntilRetrySucceeds() throws {
        let orchestrator = FakeOrchestrator()
        let controller = AccessSiteSessionController(orchestrator: orchestrator)
        let host = try AccessSiteHost("www.example.com")
        _ = try controller.enable(host: host)
        orchestrator.failAt = .tearDown

        XCTAssertThrowsError(try controller.disable(host: host)) { error in
            XCTAssertEqual(error as? AccessSiteSessionError, .tearDownFailed("forced"))
        }
        XCTAssertEqual(orchestrator.tearDownCount, 1)

        orchestrator.failAt = nil
        let snap = try controller.disable(host: host)
        XCTAssertEqual(orchestrator.tearDownCount, 2)
        XCTAssertEqual(orchestrator.lastTornDown?.rawValue, "reg-www.example.com")
        XCTAssertEqual(snap.intent, .off)
        XCTAssertEqual(snap.phase, .idle)
    }

    func testDisableTearsDownPublishedSession() throws {
        let orchestrator = FakeOrchestrator()
        let controller = AccessSiteSessionController(orchestrator: orchestrator)
        let host = try AccessSiteHost("www.example.com")
        _ = try controller.enable(host: host)

        let snap = try controller.disable(host: host)

        XCTAssertEqual(snap.intent, .off)
        XCTAssertEqual(snap.phase, .idle)
        XCTAssertEqual(snap.connectionState, .idle)
        XCTAssertEqual(orchestrator.tearDownCount, 1)
        XCTAssertEqual(orchestrator.lastTornDown?.rawValue, "reg-www.example.com")
        XCTAssertEqual(controller.intentStoreSnapshot().intent(for: host), .off)
    }

    func testBlockRefusesProxyAndTearsDownAllowSession() throws {
        let orchestrator = FakeOrchestrator()
        let controller = AccessSiteSessionController(orchestrator: orchestrator)
        let host = try AccessSiteHost("blocked.example")
        _ = try controller.enable(host: host)

        let snap = try controller.block(host: host)

        XCTAssertEqual(snap.intent, .block)
        XCTAssertEqual(snap.phase, .ready)
        XCTAssertEqual(snap.connectionState, .unavailable)
        XCTAssertNotNil(snap.failureReason)
        XCTAssertEqual(orchestrator.tearDownCount, 1)
        XCTAssertEqual(controller.intentStoreSnapshot().intent(for: host), .block)
    }

    func testEnableWithoutNodeFailsClosedWithReadableReason() throws {
        let orchestrator = FakeOrchestrator()
        orchestrator.nodeAvailable = false
        let controller = AccessSiteSessionController(orchestrator: orchestrator)
        let host = try AccessSiteHost("www.example.com")

        XCTAssertThrowsError(try controller.enable(host: host)) { error in
            XCTAssertEqual(error as? AccessSiteSessionError, .nodeUnavailable)
            guard let sessionError = error as? AccessSiteSessionError else {
                XCTFail("expected AccessSiteSessionError")
                return
            }
            XCTAssertFalse(sessionError.readableMessage.isEmpty)
            XCTAssertFalse(sessionError.readableMessage.lowercased().contains("direct success"))
        }

        let snap = controller.snapshot(for: host)
        XCTAssertEqual(snap.intent, .allow)
        XCTAssertEqual(snap.phase, .unavailable)
        XCTAssertEqual(snap.connectionState, .unavailable)
        XCTAssertEqual(snap.failureReason, AccessSiteSessionError.nodeUnavailable.readableMessage)
        XCTAssertEqual(orchestrator.publishCount, 0)
        XCTAssertEqual(orchestrator.activateCount, 0)
    }

    func testDirectFallbackIsRejectedOnActivate() throws {
        let orchestrator = FakeOrchestrator()
        orchestrator.allowDirectFallback = true
        let controller = AccessSiteSessionController(orchestrator: orchestrator)
        let host = try AccessSiteHost("www.example.com")

        XCTAssertThrowsError(try controller.enable(host: host)) { error in
            XCTAssertEqual(error as? AccessSiteSessionError, .directFallbackNotAdmitted)
        }
        let snap = controller.snapshot(for: host)
        XCTAssertEqual(snap.phase, .unavailable)
        XCTAssertEqual(
            snap.failureReason,
            AccessSiteSessionError.directFallbackNotAdmitted.readableMessage
        )
    }

    func testPublishFailureDoesNotClaimReady() throws {
        let orchestrator = FakeOrchestrator()
        orchestrator.failAt = .publish
        let controller = AccessSiteSessionController(orchestrator: orchestrator)
        let host = try AccessSiteHost("www.example.com")

        XCTAssertThrowsError(try controller.enable(host: host)) { error in
            XCTAssertEqual(error as? AccessSiteSessionError, .publishFailed("forced"))
        }
        let snap = controller.snapshot(for: host)
        XCTAssertEqual(snap.phase, .unavailable)
        XCTAssertEqual(snap.connectionState, .unavailable)
        XCTAssertEqual(orchestrator.activateCount, 0)
    }

    func testDevAllowBlockSessionSeamAdmitsDevAndRefusesBeta() throws {
        let orchestrator = FakeOrchestrator()
        let controller = AccessSiteSessionController(orchestrator: orchestrator)

        let refused = controller.applyDevAllowBlock(
            channel: .beta,
            rawHost: "news.example",
            action: .allow
        )
        XCTAssertEqual(refused.status, .channelNotAdmitted)
        XCTAssertTrue(controller.intentStoreSnapshot().allIntents().isEmpty)

        let allow = controller.applyDevAllowBlock(
            channel: .dev,
            rawHost: "https://NEWS.Example/x",
            action: .allow
        )
        XCTAssertEqual(allow.status, .applied)
        XCTAssertEqual(allow.host?.rawValue, "news.example")
        XCTAssertEqual(allow.intent, .allow)
        // Intent-only: no publish/ACK from the DEV panel path.
        XCTAssertEqual(orchestrator.publishCount, 0)

        let block = controller.applyDevAllowBlock(
            channel: .dev,
            rawHost: "news.example",
            action: .block
        )
        XCTAssertEqual(block.status, .applied)
        let snap = controller.snapshot(for: try AccessSiteHost("news.example"))
        XCTAssertEqual(snap.intent, .block)
        XCTAssertEqual(snap.connectionState, .unavailable)
        XCTAssertTrue(snap.failureReason?.contains("Local block") == true)
    }
}
