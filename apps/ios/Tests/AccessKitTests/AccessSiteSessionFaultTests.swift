import XCTest
@testable import AccessKit

private final class FaultFakeOrchestrator: AccessSiteSessionOrchestrating {
    var nodeAvailable = true
    var runtimeReady = true
    var allowDirectFallback = false
    var prepareCount = 0
    var publishCount = 0
    var ackCount = 0
    var activateCount = 0
    var tearDownCount = 0
    private var tokenCounter: UInt64 = 0

    func prepareCandidate(for host: AccessSiteHost) throws -> AccessSiteSessionCandidate {
        prepareCount += 1
        guard nodeAvailable else { throw AccessSiteSessionError.nodeUnavailable }
        let registration = try makeRegistration(host: host)
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
        publishCount += 1
        tokenCounter += 1
        return AccessSiteSessionPublication(
            candidate: candidate,
            publicationToken: "pub-\(tokenCounter)"
        )
    }

    func acknowledge(_ publication: AccessSiteSessionPublication) throws -> AccessSiteSessionAck {
        ackCount += 1
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
    }

    func tearDown(registrationID: AccessRegistrationID) throws {
        tearDownCount += 1
        _ = registrationID
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

final class AccessSiteSessionFaultTests: XCTestCase {
    func testRuntimeFaultFailClosedKeepsAllowWithoutDirect() throws {
        let orchestrator = FaultFakeOrchestrator()
        let controller = AccessSiteSessionController(orchestrator: orchestrator)
        let host = try AccessSiteHost("www.example.com")
        _ = try controller.enable(host: host)
        let publishesBefore = orchestrator.publishCount
        let tearDownsBefore = orchestrator.tearDownCount

        let fault = controller.notifyRuntimeFault(
            host: host,
            mode: .failClosed,
            detail: "node offline"
        )

        XCTAssertEqual(fault.intent, .allow)
        XCTAssertEqual(fault.faultMode, .failClosed)
        XCTAssertEqual(fault.phase, .unavailable)
        XCTAssertEqual(fault.connectionState, .unavailable)
        XCTAssertEqual(fault.registrationID?.rawValue, "reg-www.example.com")
        XCTAssertNotNil(fault.failureReason)
        XCTAssertTrue(fault.failureReason?.lowercased().contains("fault") == true)
        XCTAssertFalse(fault.failureReason?.lowercased().contains("direct success") == true)
        // Fault must not republish or tear down the PROXY selection.
        XCTAssertEqual(orchestrator.publishCount, publishesBefore)
        XCTAssertEqual(orchestrator.tearDownCount, tearDownsBefore)
        XCTAssertEqual(controller.intentStoreSnapshot().intent(for: host), .allow)

        let plan = AccessSiteSessionRequestRoute.plan(for: fault)
        XCTAssertEqual(plan.action, .fail)
        XCTAssertEqual(plan.intent, .allow)
        XCTAssertTrue(plan.forbidDirect)
        XCTAssertNotEqual(plan.action, .preserveNative)
    }

    func testRuntimeFaultWaitHoldsRequestsWithoutDirect() throws {
        let orchestrator = FaultFakeOrchestrator()
        let controller = AccessSiteSessionController(orchestrator: orchestrator)
        let host = try AccessSiteHost("www.example.com")
        _ = try controller.enable(host: host)

        let fault = controller.notifyRuntimeFault(
            host: host,
            mode: .wait,
            detail: "runtime recovering"
        )

        XCTAssertEqual(fault.intent, .allow)
        XCTAssertEqual(fault.faultMode, .wait)
        XCTAssertEqual(fault.phase, .preparingCandidate)
        XCTAssertEqual(fault.connectionState, .connecting)
        XCTAssertEqual(orchestrator.publishCount, 1)
        XCTAssertEqual(orchestrator.tearDownCount, 0)

        let plan = AccessSiteSessionRequestRoute.plan(for: fault)
        XCTAssertEqual(plan.action, .wait)
        XCTAssertTrue(plan.forbidDirect)
        XCTAssertNotEqual(plan.action, .preserveNative)
    }

    func testRecoverFromFaultRestoresReadyViaProxy() throws {
        let orchestrator = FaultFakeOrchestrator()
        let controller = AccessSiteSessionController(orchestrator: orchestrator)
        let host = try AccessSiteHost("www.example.com")
        _ = try controller.enable(host: host)
        _ = controller.notifyRuntimeFault(host: host, mode: .failClosed, detail: "node offline")

        let recovered = try controller.recoverFromFault(host: host)

        XCTAssertEqual(recovered.intent, .allow)
        XCTAssertEqual(recovered.phase, .ready)
        XCTAssertEqual(recovered.connectionState, .ready)
        XCTAssertEqual(recovered.faultMode, .none)
        XCTAssertNil(recovered.failureReason)
        XCTAssertEqual(orchestrator.publishCount, 2)
        XCTAssertEqual(orchestrator.activateCount, 2)

        let plan = AccessSiteSessionRequestRoute.plan(for: recovered)
        XCTAssertEqual(plan.action, .useProxy)
        XCTAssertTrue(plan.forbidDirect)
        XCTAssertNotEqual(plan.action, .preserveNative)
    }

    func testRecoveryRejectsDirectFallbackAsAccessSuccess() throws {
        let orchestrator = FaultFakeOrchestrator()
        let controller = AccessSiteSessionController(orchestrator: orchestrator)
        let host = try AccessSiteHost("www.example.com")
        _ = try controller.enable(host: host)
        _ = controller.notifyRuntimeFault(host: host, mode: .failClosed)
        orchestrator.allowDirectFallback = true

        XCTAssertThrowsError(try controller.recoverFromFault(host: host)) { error in
            XCTAssertEqual(error as? AccessSiteSessionError, .directFallbackNotAdmitted)
        }
        let snap = controller.snapshot(for: host)
        XCTAssertEqual(snap.intent, .allow)
        XCTAssertEqual(snap.phase, .unavailable)
        XCTAssertNotEqual(snap.connectionState, .ready)
        XCTAssertEqual(
            snap.failureReason,
            AccessSiteSessionError.directFallbackNotAdmitted.readableMessage
        )
    }

    func testProductFaultDrillHealthyOnFaultRecoveryOff() throws {
        let orchestrator = FaultFakeOrchestrator()
        let controller = AccessSiteSessionController(orchestrator: orchestrator)
        let host = try AccessSiteHost("target.example")

        let steps = try AccessSiteSessionFaultFixture.runProductDrill(
            controller: controller,
            host: host,
            faultMode: .failClosed
        )

        XCTAssertEqual(steps.count, 5)
        XCTAssertEqual(steps[0].stage, .healthy)
        XCTAssertEqual(steps[0].expectedAction, .preserveNative)
        XCTAssertFalse(steps[0].forbidDirect)

        XCTAssertEqual(steps[1].stage, .on)
        XCTAssertEqual(steps[1].snapshot.phase, .ready)
        XCTAssertEqual(steps[1].expectedAction, .useProxy)
        XCTAssertTrue(steps[1].forbidDirect)
        XCTAssertEqual(
            AccessSiteSessionRequestRoute.plan(for: steps[1].snapshot).action,
            .useProxy
        )

        XCTAssertEqual(steps[2].stage, .fault)
        XCTAssertEqual(steps[2].expectedAction, .fail)
        XCTAssertTrue(steps[2].forbidDirect)
        XCTAssertEqual(steps[2].snapshot.faultMode, .failClosed)
        XCTAssertEqual(
            AccessSiteSessionRequestRoute.plan(for: steps[2].snapshot).action,
            .fail
        )

        XCTAssertEqual(steps[3].stage, .recovery)
        XCTAssertEqual(steps[3].snapshot.phase, .ready)
        XCTAssertEqual(steps[3].snapshot.faultMode, .none)
        XCTAssertEqual(
            AccessSiteSessionRequestRoute.plan(for: steps[3].snapshot).action,
            .useProxy
        )

        XCTAssertEqual(steps[4].stage, .off)
        XCTAssertEqual(steps[4].snapshot.intent, .off)
        XCTAssertEqual(
            AccessSiteSessionRequestRoute.plan(for: steps[4].snapshot).action,
            .preserveNative
        )
    }

    func testProductFaultDrillWaitModeHoldsDuringFault() throws {
        let orchestrator = FaultFakeOrchestrator()
        let controller = AccessSiteSessionController(orchestrator: orchestrator)
        let host = try AccessSiteHost("wait.example")

        let steps = try AccessSiteSessionFaultFixture.runProductDrill(
            controller: controller,
            host: host,
            faultMode: .wait
        )

        XCTAssertEqual(steps[2].stage, .fault)
        XCTAssertEqual(steps[2].expectedAction, .wait)
        XCTAssertEqual(steps[2].snapshot.faultMode, .wait)
        XCTAssertEqual(steps[2].snapshot.connectionState, .connecting)
        XCTAssertEqual(
            AccessSiteSessionRequestRoute.plan(for: steps[2].snapshot).action,
            .wait
        )
        XCTAssertEqual(steps[3].snapshot.phase, .ready)
    }

    func testToggleSurfacesUnavailableDistinctFromAllowIntent() throws {
        // Session-layer proof the UI already binds: allow intent + unavailable
        // connection must not read as Access ready / DIRECT success.
        let orchestrator = FaultFakeOrchestrator()
        let controller = AccessSiteSessionController(orchestrator: orchestrator)
        let host = try AccessSiteHost("www.example.com")
        _ = try controller.enable(host: host)
        let fault = controller.notifyRuntimeFault(host: host, mode: .failClosed, detail: "down")

        XCTAssertEqual(fault.intent, .allow)
        XCTAssertEqual(fault.connectionState, .unavailable)
        XCTAssertNotEqual(fault.connectionState, .ready)
        XCTAssertEqual(fault.faultMode, .failClosed)

        let plan = AccessSiteSessionRequestRoute.plan(for: fault)
        XCTAssertEqual(plan.action, .fail)
        XCTAssertTrue(plan.forbidDirect)
    }
}
