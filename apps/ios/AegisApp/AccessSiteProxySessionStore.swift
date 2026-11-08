import AccessKit
import Combine
import Foundation

/// App-owned Access site-session holder for the per-site proxy toggle.
///
/// Keeps a shared `AccessSiteSessionController` + intent store for the window.
/// The default orchestrator fails closed until a later product path injects a
/// reality-ready pipeline — switch-on must never claim DIRECT success.
@MainActor
final class AccessSiteProxySessionStore: ObservableObject {
    let controller: AccessSiteSessionController
    private let orchestrator: AccessSiteSessionOrchestrating
    /// Product channel used to gate the DEV ALLOW/BLOCK debug entry.
    let devAllowBlockChannel: AccessReleaseChannel

    /// Bumps when session state changes so SwiftUI can re-query snapshots.
    @Published private(set) var revision: UInt64 = 0

    init(
        intentStore: AccessSiteIntentStore = AccessSiteIntentStore(),
        orchestrator: AccessSiteSessionOrchestrating? = nil,
        channel: AccessReleaseChannel? = nil
    ) {
        let pipeline = orchestrator ?? AccessSiteProxyFailClosedOrchestrator()
        self.orchestrator = pipeline
        self.controller = AccessSiteSessionController(
            intentStore: intentStore,
            orchestrator: pipeline
        )
        self.devAllowBlockChannel = channel ?? AccessDevAllowBlockSectionModel.resolveChannel()
    }

    func snapshot(for url: URL?) -> AccessSiteProxyToggleSnapshot {
        _ = revision
        return AccessSiteProxyToggleModel.buildSnapshot(url: url, controller: controller)
    }

    func setProxyEnabled(_ enabled: Bool, for url: URL?) {
        guard let host = AccessSiteProxyToggleModel.resolveTrustedHost(from: url) else {
            return
        }
        _ = AccessSiteProxyToggleModel.applyToggle(
            enabled: enabled,
            host: host,
            controller: controller
        )
        revision &+= 1
    }

    /// DEV/Alpha debug snapshot. Beta/Release keep `panelRegistered == false`.
    func devAllowBlockSnapshot(for url: URL?) -> AccessDevAllowBlockPanelSnapshot {
        _ = revision
        return AccessDevAllowBlockSectionModel.buildSnapshot(
            channel: devAllowBlockChannel,
            url: url,
            controller: controller
        )
    }

    @discardableResult
    func applyDevAllowBlock(
        _ action: AccessDevAllowBlockAction,
        for url: URL?
    ) -> AccessDevAllowBlockApplyResult {
        let result = AccessDevAllowBlockSectionModel.apply(
            action: action,
            channel: devAllowBlockChannel,
            url: url,
            controller: controller
        )
        if result.status == .applied {
            revision &+= 1
        }
        return result
    }

    func noteNavigationChanged() {
        revision &+= 1
    }
}

/// Fail-closed pipeline used until production reality wiring is attached.
///
/// Prepare always refuses so enable leaves intent=`allow` with
/// connection=`unavailable` and a readable reason — never DIRECT success.
final class AccessSiteProxyFailClosedOrchestrator: AccessSiteSessionOrchestrating {
    func prepareCandidate(for host: AccessSiteHost) throws -> AccessSiteSessionCandidate {
        _ = host
        throw AccessSiteSessionError.nodeUnavailable
    }

    func publish(_ candidate: AccessSiteSessionCandidate) throws -> AccessSiteSessionPublication {
        _ = candidate
        throw AccessSiteSessionError.publishFailed("Fail-closed orchestrator does not publish")
    }

    func acknowledge(_ publication: AccessSiteSessionPublication) throws -> AccessSiteSessionAck {
        _ = publication
        throw AccessSiteSessionError.ackFailed("Fail-closed orchestrator does not acknowledge")
    }

    func activateRealityPath(
        ack: AccessSiteSessionAck,
        candidate: AccessSiteSessionCandidate
    ) throws {
        _ = ack
        _ = candidate
        throw AccessSiteSessionError.directFallbackNotAdmitted
    }

    func tearDown(registrationID: AccessRegistrationID) throws {
        _ = registrationID
    }
}
