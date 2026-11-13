import Foundation

/// Product fault drill stages for P-iOS-5 (A2-3 / A2-4).
///
/// Mirrors macOS `RunSiteProxyFaultProductDrill`:
/// healthy → on → fault → recovery → off.
public enum AccessSiteSessionFaultDrillStage: String, Sendable, Equatable, Hashable {
    case healthy
    case on
    case fault
    case recovery
    case off
}

/// One stage of the product fault drill with the expected request route.
public struct AccessSiteSessionFaultDrillStep: Sendable, Equatable {
    public let stage: AccessSiteSessionFaultDrillStage
    public let snapshot: AccessSiteSessionSnapshot
    public let expectedAction: AccessSiteSessionRequestRouteAction
    /// True when the allow path must reject PreserveNative / DIRECT success.
    public let forbidDirect: Bool

    public init(
        stage: AccessSiteSessionFaultDrillStage,
        snapshot: AccessSiteSessionSnapshot,
        expectedAction: AccessSiteSessionRequestRouteAction,
        forbidDirect: Bool
    ) {
        self.stage = stage
        self.snapshot = snapshot
        self.expectedAction = expectedAction
        self.forbidDirect = forbidDirect
    }
}

/// Runs healthy → on → fault → recovery → off against a session controller.
///
/// `faultMode` selects Fail vs Wait during the fault stage. The fixture never
/// treats DIRECT / native success as Access success on the allow path.
public enum AccessSiteSessionFaultFixture {
    public static func runProductDrill(
        controller: AccessSiteSessionController,
        host: AccessSiteHost,
        faultMode: AccessSiteSessionFaultMode
    ) throws -> [AccessSiteSessionFaultDrillStep] {
        precondition(faultMode != .none, "Drill fault mode must be fail-closed or wait")

        var steps: [AccessSiteSessionFaultDrillStep] = []

        let healthy = controller.snapshot(for: host)
        steps.append(
            makeStep(
                stage: .healthy,
                snapshot: healthy,
                expectedAction: .preserveNative,
                forbidDirect: false
            )
        )

        let on = try controller.enable(host: host)
        steps.append(
            makeStep(
                stage: .on,
                snapshot: on,
                expectedAction: .useProxy,
                forbidDirect: true
            )
        )

        let fault = controller.notifyRuntimeFault(
            host: host,
            mode: faultMode,
            detail: "product drill fault"
        )
        let faultAction: AccessSiteSessionRequestRouteAction =
            faultMode == .wait ? .wait : .fail
        steps.append(
            makeStep(
                stage: .fault,
                snapshot: fault,
                expectedAction: faultAction,
                forbidDirect: true
            )
        )

        let recovery = try controller.recoverFromFault(host: host)
        steps.append(
            makeStep(
                stage: .recovery,
                snapshot: recovery,
                expectedAction: .useProxy,
                forbidDirect: true
            )
        )

        let off = try controller.disable(host: host)
        steps.append(
            makeStep(
                stage: .off,
                snapshot: off,
                expectedAction: .preserveNative,
                forbidDirect: false
            )
        )

        return steps
    }

    private static func makeStep(
        stage: AccessSiteSessionFaultDrillStage,
        snapshot: AccessSiteSessionSnapshot,
        expectedAction: AccessSiteSessionRequestRouteAction,
        forbidDirect: Bool
    ) -> AccessSiteSessionFaultDrillStep {
        AccessSiteSessionFaultDrillStep(
            stage: stage,
            snapshot: snapshot,
            expectedAction: expectedAction,
            forbidDirect: forbidDirect
        )
    }
}
