import XCTest
@testable import Aegis
@testable import AgentKit
@testable import BrowserKit

final class CapabilitySecurityTests: XCTestCase {
    @MainActor
    func testPersistentRecoveryNoticeSurvivesRecreationUntilExplicitTakeover() {
        let defaults = UserDefaults.standard
        let key = "aegis.incompleteTask"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(true, forKey: key)

        let first = AgentCenterModel(
            profileID: UUID(),
            isPrivateProfile: false,
            dataStore: BrowserDataStore(persistenceURL: nil)
        )
        XCTAssertEqual(first.wireState, .recovering)
        XCTAssertNotNil(first.recoveryNotice)
        first.cancelForLifecycle()
        first.cancelForLifecycle()
        XCTAssertTrue(defaults.bool(forKey: key))
        first.prepare(.research, currentURL: nil)
        XCTAssertEqual(first.screen, .catalog)

        let second = AgentCenterModel(
            profileID: UUID(),
            isPrivateProfile: false,
            dataStore: BrowserDataStore(persistenceURL: nil)
        )
        XCTAssertEqual(second.wireState, .recovering)
        second.dismissRecovery()
        XCTAssertFalse(defaults.bool(forKey: key))
        XCTAssertNil(second.recoveryNotice)
        XCTAssertEqual(second.wireState, .userTakeover)
    }

    @MainActor
    func testBrowserManagerModelWaitsForSecondClickThenAppliesAndUndoesRealStore() async throws {
        let original = Self.disorderedBookmarks
        let store = BrowserDataStore(persistenceURL: nil, initialBookmarks: original)
        let model = AgentCenterModel(
            profileID: UUID(),
            isPrivateProfile: false,
            dataStore: store
        )

        model.prepare(.browserManager, currentURL: nil)
        let reachedConsent = await waitUntil { model.screen == .consent }
        XCTAssertTrue(reachedConsent)
        XCTAssertEqual(
            Set(model.consent?.tools ?? []),
            Set(["bookmarks.list", "bookmarks.plan", "bookmarks.apply"]),
            "普通整理 task grant 不应预授予撤销权限"
        )
        model.approve()
        let reachedApplyApproval = await waitUntil { model.screen == .actionApproval }
        XCTAssertTrue(reachedApplyApproval)
        XCTAssertEqual(model.wireState, .awaitingActionApproval)
        XCTAssertNil(model.result)
        XCTAssertEqual(store.bookmarks, original, "未点第二次确认前不能修改收藏")
        XCTAssertEqual(model.pendingActionApproval?.tool, "bookmarks.apply")

        model.confirmPendingAction()
        let applied = await waitUntil { model.screen == .result }
        XCTAssertTrue(applied)
        XCTAssertEqual(store.bookmarks.count, 3)
        XCTAssertNotEqual(store.bookmarks, original)
        XCTAssertEqual(model.undoLineage?.rootID, store.bookmarkRootID)

        model.applyUndo()
        let reachedUndoConsent = await waitUntil {
            model.screen == .consent
                && model.consent?.tools == ["bookmarks.undo"]
        }
        XCTAssertTrue(reachedUndoConsent)
        XCTAssertNil(model.pendingActionApproval, "撤销 task 尚未授权时不能生成动作批准")
        XCTAssertNotEqual(store.bookmarks, original, "撤销 task 授权前仍不能恢复收藏")

        model.approve()
        let reachedUndoApproval = await waitUntil {
            model.screen == .actionApproval
                && model.pendingActionApproval?.tool == "bookmarks.undo"
        }
        XCTAssertTrue(reachedUndoApproval)
        XCTAssertNotEqual(store.bookmarks, original, "撤销确认前仍不能恢复收藏")
        model.confirmPendingAction()
        let undone = await waitUntil { model.screen == .result && model.undoWasApplied }
        XCTAssertTrue(undone)
        XCTAssertEqual(store.bookmarks, original)
    }

    @MainActor
    func testRapidPrepareKeepsOnlyLatestBrokerGeneration() async {
        let model = AgentCenterModel(
            profileID: UUID(),
            isPrivateProfile: false,
            dataStore: BrowserDataStore(persistenceURL: nil)
        )

        model.prepare(.research, currentURL: URL(string: "https://first.example"))
        model.prepare(.shopping, currentURL: URL(string: "https://latest.example/product"))

        let reachedLatestConsent = await waitUntil {
            model.screen == .consent
                && model.selectedKind == .shopping
                && model.consent?.origins == ["https://latest.example"]
        }
        XCTAssertTrue(reachedLatestConsent)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.selectedKind, .shopping)
        XCTAssertEqual(model.consent?.goal, "比较报价并停在最终提交前")
        XCTAssertEqual(model.consent?.origins, ["https://latest.example"])
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testPrivateProfileModelIsRejectedByBroker() async {
        let model = AgentCenterModel(
            profileID: UUID(),
            isPrivateProfile: true,
            dataStore: BrowserDataStore(persistenceURL: nil)
        )
        model.prepare(.research, currentURL: URL(string: "https://example.com"))
        let rejected = await waitUntil { model.errorMessage != nil }
        XCTAssertTrue(rejected)
        XCTAssertEqual(model.errorMessage, AgentContractError.privateProfileDenied.localizedDescription)
        XCTAssertEqual(model.screen, .catalog)
        XCTAssertNil(model.consent)
    }

    @MainActor
    func testLifecycleCancellationPreventsLateResult() async {
        let model = AgentCenterModel(
            profileID: UUID(),
            isPrivateProfile: false,
            dataStore: BrowserDataStore(persistenceURL: nil)
        )
        model.prepare(.research, currentURL: URL(string: "https://example.com"))
        let reachedConsent = await waitUntil { model.screen == .consent }
        XCTAssertTrue(reachedConsent)
        model.approve()
        model.cancelForLifecycle()
        try? await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.screen, .catalog)
        XCTAssertEqual(model.wireState, .cancelled)
        XCTAssertNil(model.result)
    }

    func testCapabilityIsConsumedExactlyOnce() async throws {
        let processID = UUID()
        let profileID = UUID()
        let rootID = UUID()
        let resourceID = UUID()
        let grant = AgentContractTests.makeGrant(
            profileID: profileID,
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible,
            bookmarkRootIDs: [rootID]
        )
        let registry = ResourceRegistry(taskID: grant.taskID, grantID: grant.grantID)
        let revision = try await registry.append(
            id: resourceID,
            kind: .bookmarkPlan,
            scopeRootID: rootID
        )
        let target = ActionTarget.native(NativeActionTarget(
            resourceType: .bookmarkPlan,
            registryRevision: revision,
            resourceID: resourceID
        ))
        let capabilities = ActionCapabilityBroker(processInstanceID: processID)
        let issued = try await capabilities.issue(
            grant: grant,
            tool: "bookmarks.apply",
            normalizedParameters: #"{"plan":"p1"}"#,
            callSequence: 1,
            target: target,
            registrySnapshot: await registry.snapshot(),
            confirmationDigest: "confirmed-plan-p1"
        )

        try await capabilities.consume(
            issued,
            expectedTool: "bookmarks.apply",
            expectedParameters: #"{"plan":"p1"}"#,
            expectedTarget: target,
            registrySnapshot: await registry.snapshot()
        )
        do {
            try await capabilities.consume(
                issued,
                expectedTool: "bookmarks.apply",
                expectedParameters: #"{"plan":"p1"}"#,
                expectedTarget: target,
                registrySnapshot: await registry.snapshot()
            )
            XCTFail("能力不能重复消费")
        } catch {
            XCTAssertEqual(error as? AgentContractError, .capabilityAlreadyConsumed)
        }
    }

    func testMismatchAlsoBurnsCapability() async throws {
        let profileID = UUID()
        let rootID = UUID()
        let resourceID = UUID()
        let grant = AgentContractTests.makeGrant(
            profileID: profileID,
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible,
            bookmarkRootIDs: [rootID]
        )
        let registry = ResourceRegistry(taskID: grant.taskID, grantID: grant.grantID)
        let revision = try await registry.append(
            id: resourceID,
            kind: .bookmarkPlan,
            scopeRootID: rootID
        )
        let target = ActionTarget.native(NativeActionTarget(
            resourceType: .bookmarkPlan,
            registryRevision: revision,
            resourceID: resourceID
        ))
        let capabilities = ActionCapabilityBroker()
        let issued = try await capabilities.issue(
            grant: grant,
            tool: "bookmarks.apply",
            normalizedParameters: "plan=approved",
            callSequence: 1,
            target: target,
            registrySnapshot: await registry.snapshot(),
            confirmationDigest: "confirmed-plan-v1"
        )

        do {
            try await capabilities.consume(
                issued,
                expectedTool: "bookmarks.apply",
                expectedParameters: "plan=swapped",
                expectedTarget: target,
                registrySnapshot: await registry.snapshot()
            )
            XCTFail("参数偷换必须失败")
        } catch {
            XCTAssertEqual(error as? AgentContractError, .capabilityMismatch)
        }
        let pendingCount = await capabilities.pendingCount()
        XCTAssertEqual(pendingCount, 0)
    }

    func testWebCapabilityBindsLeaseAndDocumentEpoch() async throws {
        let processID = UUID()
        let profileID = UUID()
        let grant = AgentContractTests.makeGrant(
            profileID: profileID,
            origins: ["https://shop.aegis.test"],
            tools: ["page.click"],
            risk: .externalOrSensitive
        )
        let lease = DocumentLease(
            leaseID: UUID(),
            taskID: grant.taskID,
            grantID: grant.grantID,
            profileID: profileID,
            processInstanceID: processID,
            browserSessionID: UUID(),
            webViewID: UUID(),
            tabID: UUID(),
            frameID: "main",
            committedTopOrigin: "https://shop.aegis.test",
            frameOrigin: "https://shop.aegis.test",
            navigationEpoch: 8,
            documentNonce: "not-in-dom",
            callSequence: 3,
            expiresAt: Date().addingTimeInterval(20)
        )
        let target = WebActionTarget(
            leaseID: lease.leaseID,
            browserSessionID: lease.browserSessionID,
            webViewID: lease.webViewID,
            tabID: lease.tabID,
            frameID: lease.frameID,
            topOrigin: lease.committedTopOrigin,
            frameOrigin: lease.frameOrigin,
            navigationEpoch: lease.navigationEpoch + 1,
            documentNonce: lease.documentNonce,
            callSequence: lease.callSequence,
            documentDigest: "document-v2",
            nodeFingerprint: "button-cart-v2"
        )
        let capabilities = ActionCapabilityBroker(processInstanceID: processID)

        do {
            _ = try await capabilities.issue(
                grant: grant,
                tool: "page.click",
                normalizedParameters: "semantic=add-to-cart",
                callSequence: 3,
                target: .web(target),
                documentLease: lease
            )
            XCTFail("导航 epoch 变化后旧 lease 必须失效")
        } catch {
            XCTAssertEqual(error as? AgentContractError, .invalidLease)
        }
    }

    func testWebCapabilityRejectsEverySwappableDocumentIdentityField() async throws {
        let processID = UUID()
        let profileID = UUID()
        let grant = AgentContractTests.makeGrant(
            profileID: profileID,
            origins: ["https://shop.aegis.test"],
            tools: ["page.click"],
            risk: .externalOrSensitive
        )
        let lease = DocumentLease(
            leaseID: UUID(),
            taskID: grant.taskID,
            grantID: grant.grantID,
            profileID: profileID,
            processInstanceID: processID,
            browserSessionID: UUID(),
            webViewID: UUID(),
            tabID: UUID(),
            frameID: "main",
            committedTopOrigin: "https://shop.aegis.test",
            frameOrigin: "https://shop.aegis.test",
            navigationEpoch: 8,
            documentNonce: "document-nonce-v1",
            callSequence: 3,
            expiresAt: Date().addingTimeInterval(20)
        )
        func target(
            session: UUID? = nil,
            webView: UUID? = nil,
            tab: UUID? = nil,
            frame: String? = nil,
            topOrigin: String? = nil,
            frameOrigin: String? = nil,
            nonce: String? = nil,
            sequence: UInt64? = nil
        ) -> ActionTarget {
            .web(WebActionTarget(
                leaseID: lease.leaseID,
                browserSessionID: session ?? lease.browserSessionID,
                webViewID: webView ?? lease.webViewID,
                tabID: tab ?? lease.tabID,
                frameID: frame ?? lease.frameID,
                topOrigin: topOrigin ?? lease.committedTopOrigin,
                frameOrigin: frameOrigin ?? lease.frameOrigin,
                navigationEpoch: lease.navigationEpoch,
                documentNonce: nonce ?? lease.documentNonce,
                callSequence: sequence ?? lease.callSequence,
                documentDigest: "document-v1",
                nodeFingerprint: "button-v1"
            ))
        }
        let swappedTargets = [
            target(session: UUID()),
            target(webView: UUID()),
            target(tab: UUID()),
            target(frame: "child"),
            target(topOrigin: "https://other.aegis.test"),
            target(frameOrigin: "https://other.aegis.test"),
            target(nonce: "swapped"),
            target(sequence: 4),
        ]
        let capabilities = ActionCapabilityBroker(processInstanceID: processID)
        for swapped in swappedTargets {
            await XCTAssertThrowsAgentError(.invalidLease) {
                _ = try await capabilities.issue(
                    grant: grant,
                    tool: "page.click",
                    normalizedParameters: "semantic=add-to-cart",
                    callSequence: 3,
                    target: swapped,
                    documentLease: lease
                )
            }
        }
        let pendingCount = await capabilities.pendingCount()
        XCTAssertEqual(pendingCount, 0)
    }

    func testBrokerRequiresApprovalScopeAndRevokesOnCompletion() async throws {
        let profileID = UUID()
        let rootID = UUID()
        let planID = UUID()
        let broker = AgentBroker(profileID: profileID, isPrivateProfile: false)
        await XCTAssertThrowsAgentError(.consentRequired) {
            _ = try await broker.registerNativeResource(type: .bookmarkPlan)
        }
        _ = try await broker.makeLocalConsentDraft(
            goal: "整理收藏",
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible
        )
        let grant = AgentContractTests.makeGrant(
            profileID: profileID,
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible,
            bookmarkRootIDs: [rootID]
        )
        try await broker.approve(grant)
        let target = try await broker.registerNativeResource(
            type: .bookmarkPlan,
            id: planID,
            scopeRootID: rootID
        )
        let actionTarget = ActionTarget.native(target)
        let approval = try await broker.requestActionApproval(
            tool: "bookmarks.apply",
            normalizedParameters: "plan=v1",
            callSequence: 1,
            target: actionTarget
        )
        try await broker.resumeAfterApproval(
            approvalID: approval.approvalID,
            confirmationDigest: approval.confirmationDigest
        )
        let capability = try await broker.issueAction(
            tool: "bookmarks.apply",
            normalizedParameters: "plan=v1",
            callSequence: 1,
            target: actionTarget,
            approvalID: approval.approvalID,
            confirmationDigest: approval.confirmationDigest
        )
        await XCTAssertThrowsAgentError(.invalidState) {
            try await broker.beginVerification()
        }
        try await broker.consumeAction(
            capability,
            expectedTool: "bookmarks.apply",
            expectedParameters: "plan=v1",
            expectedTarget: actionTarget
        )
        let ticket = try await broker.beginNativeVerification(capability: capability)
        let committed = await broker.commitNativeVerification(ticket)
        XCTAssertTrue(committed)
        await XCTAssertThrowsAgentError(.capabilityMismatch) {
            try await broker.consumeAction(
                capability,
                expectedTool: "bookmarks.apply",
                expectedParameters: "plan=v1",
                expectedTarget: actionTarget
            )
        }
    }

    func testGenericVerificationRejectsWritableGrantEvenWithoutRegisteredResource() async throws {
        let profileID = UUID()
        let rootID = UUID()
        let broker = AgentBroker(profileID: profileID, isPrivateProfile: false)
        _ = try await broker.makeLocalConsentDraft(
            goal: "整理收藏",
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible
        )
        try await broker.approve(AgentContractTests.makeGrant(
            profileID: profileID,
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible,
            bookmarkRootIDs: [rootID]
        ))

        await XCTAssertThrowsAgentError(.invalidState) {
            try await broker.beginVerification()
        }
        let state = await broker.state
        XCTAssertEqual(state, .running)
    }

    func testNativeVerificationCommitCompletesOnlyCurrentActiveResource() async throws {
        let profileID = UUID()
        let rootID = UUID()
        let broker = AgentBroker(profileID: profileID, isPrivateProfile: false)
        _ = try await broker.makeLocalConsentDraft(
            goal: "应用收藏计划",
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible
        )
        let grant = AgentContractTests.makeGrant(
            profileID: profileID,
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible,
            bookmarkRootIDs: [rootID]
        )
        try await broker.approve(grant)
        let target = try await broker.registerNativeResource(
            type: .bookmarkPlan,
            scopeRootID: rootID
        )
        let actionTarget = ActionTarget.native(target)
        let approval = try await broker.requestActionApproval(
            tool: "bookmarks.apply",
            normalizedParameters: #"{"operation":"apply"}"#,
            callSequence: 1,
            target: actionTarget
        )
        try await broker.resumeAfterApproval(
            approvalID: approval.approvalID,
            confirmationDigest: approval.confirmationDigest
        )
        let capability = try await broker.issueAction(
            tool: approval.tool,
            normalizedParameters: approval.normalizedParameters,
            callSequence: approval.callSequence,
            target: approval.target,
            approvalID: approval.approvalID,
            confirmationDigest: approval.confirmationDigest
        )
        try await broker.consumeAction(
            capability,
            expectedTool: approval.tool,
            expectedParameters: approval.normalizedParameters,
            expectedTarget: approval.target
        )

        let ticket = try await broker.beginNativeVerification(capability: capability)
        let verifyingState = await broker.state
        XCTAssertEqual(verifyingState, .verifying)
        let committed = await broker.commitNativeVerification(ticket)
        XCTAssertTrue(committed)
        let completedState = await broker.state
        let completedGrant = await broker.activeGrant
        XCTAssertEqual(completedState, .completed)
        XCTAssertNil(completedGrant)
    }

    func testNativeVerificationTicketFailsClosedAfterCancellation() async throws {
        let profileID = UUID()
        let rootID = UUID()
        let broker = AgentBroker(profileID: profileID, isPrivateProfile: false)
        _ = try await broker.makeLocalConsentDraft(
            goal: "应用收藏计划",
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible
        )
        let grant = AgentContractTests.makeGrant(
            profileID: profileID,
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible,
            bookmarkRootIDs: [rootID]
        )
        try await broker.approve(grant)
        let target = try await broker.registerNativeResource(
            type: .bookmarkPlan,
            scopeRootID: rootID
        )
        let actionTarget = ActionTarget.native(target)
        let approval = try await broker.requestActionApproval(
            tool: "bookmarks.apply",
            normalizedParameters: #"{"operation":"apply"}"#,
            callSequence: 1,
            target: actionTarget
        )
        try await broker.resumeAfterApproval(
            approvalID: approval.approvalID,
            confirmationDigest: approval.confirmationDigest
        )
        let capability = try await broker.issueAction(
            tool: approval.tool,
            normalizedParameters: approval.normalizedParameters,
            callSequence: approval.callSequence,
            target: approval.target,
            approvalID: approval.approvalID,
            confirmationDigest: approval.confirmationDigest
        )
        try await broker.consumeAction(
            capability,
            expectedTool: approval.tool,
            expectedParameters: approval.normalizedParameters,
            expectedTarget: approval.target
        )

        let ticket = try await broker.beginNativeVerification(capability: capability)
        await broker.cancel()

        let committed = await broker.commitNativeVerification(ticket)
        let cancelledState = await broker.state
        XCTAssertFalse(committed)
        XCTAssertEqual(cancelledState, .cancelled)
    }

    func testR1ActionRequiresMatchingOneTimeApprovalDigest() async throws {
        let profileID = UUID()
        let rootID = UUID()
        let planID = UUID()
        let broker = AgentBroker(profileID: profileID, isPrivateProfile: false)
        _ = try await broker.makeLocalConsentDraft(
            goal: "应用收藏夹整理计划",
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible
        )
        let grant = AgentContractTests.makeGrant(
            profileID: profileID,
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible,
            bookmarkRootIDs: [rootID]
        )
        try await broker.approve(grant)
        let target = ActionTarget.native(try await broker.registerNativeResource(
            type: .bookmarkPlan,
            id: planID,
            scopeRootID: rootID
        ))

        await XCTAssertThrowsAgentError(.consentRequired) {
            _ = try await broker.issueAction(
                tool: "bookmarks.apply",
                normalizedParameters: "plan=v1",
                callSequence: 1,
                target: target,
                confirmationDigest: "unapproved"
            )
        }

        let firstApproval = try await broker.requestActionApproval(
            tool: "bookmarks.apply",
            normalizedParameters: "plan=v1",
            callSequence: 1,
            target: target
        )
        await XCTAssertThrowsAgentError(.capabilityMismatch) {
            try await broker.resumeAfterApproval(
                approvalID: firstApproval.approvalID,
                confirmationDigest: "swapped-digest"
            )
        }
        let awaitingState = await broker.state
        XCTAssertEqual(awaitingState, .awaitingActionApproval)
        try await broker.resumeAfterApproval(
            approvalID: firstApproval.approvalID,
            confirmationDigest: firstApproval.confirmationDigest
        )

        await XCTAssertThrowsAgentError(.capabilityMismatch) {
            _ = try await broker.issueAction(
                tool: "bookmarks.apply",
                normalizedParameters: "plan=v1",
                callSequence: 1,
                target: target,
                approvalID: UUID(),
                confirmationDigest: firstApproval.confirmationDigest
            )
        }
        await XCTAssertThrowsAgentError(.consentRequired) {
            _ = try await broker.issueAction(
                tool: "bookmarks.apply",
                normalizedParameters: "plan=v1",
                callSequence: 1,
                target: target,
                approvalID: firstApproval.approvalID,
                confirmationDigest: firstApproval.confirmationDigest
            )
        }

        let secondApproval = try await broker.requestActionApproval(
            tool: "bookmarks.apply",
            normalizedParameters: "plan=v1",
            callSequence: 1,
            target: target
        )
        XCTAssertNotEqual(secondApproval.approvalID, firstApproval.approvalID)
        XCTAssertNotEqual(secondApproval.confirmationDigest, firstApproval.confirmationDigest)
        await XCTAssertThrowsAgentError(.capabilityMismatch) {
            try await broker.resumeAfterApproval(
                approvalID: firstApproval.approvalID,
                confirmationDigest: firstApproval.confirmationDigest
            )
        }
        await XCTAssertThrowsAgentError(.capabilityMismatch) {
            try await broker.resumeAfterApproval(
                approvalID: firstApproval.approvalID,
                confirmationDigest: secondApproval.confirmationDigest
            )
        }
        await XCTAssertThrowsAgentError(.capabilityMismatch) {
            try await broker.resumeAfterApproval(
                approvalID: secondApproval.approvalID,
                confirmationDigest: firstApproval.confirmationDigest
            )
        }
        let rebuiltAwaitingState = await broker.state
        XCTAssertEqual(rebuiltAwaitingState, .awaitingActionApproval)
        try await broker.resumeAfterApproval(
            approvalID: secondApproval.approvalID,
            confirmationDigest: secondApproval.confirmationDigest
        )
        let capability = try await broker.issueAction(
            tool: "bookmarks.apply",
            normalizedParameters: "plan=v1",
            callSequence: 1,
            target: target,
            approvalID: secondApproval.approvalID,
            confirmationDigest: secondApproval.confirmationDigest
        )
        await XCTAssertThrowsAgentError(.consentRequired) {
            _ = try await broker.issueAction(
                tool: "bookmarks.apply",
                normalizedParameters: "plan=v1",
                callSequence: 1,
                target: target,
                approvalID: secondApproval.approvalID,
                confirmationDigest: secondApproval.confirmationDigest
            )
        }
        try await broker.consumeAction(
            capability,
            expectedTool: "bookmarks.apply",
            expectedParameters: "plan=v1",
            expectedTarget: target
        )
    }

    func testActionApprovalExpiresBeforeResumeOrIssue() async throws {
        let now = Date()
        let profileID = UUID()
        let rootID = UUID()
        let broker = AgentBroker(profileID: profileID, isPrivateProfile: false)
        _ = try await broker.makeLocalConsentDraft(
            goal: "验证动作批准时效",
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible
        )
        let grant = AgentContractTests.makeGrant(
            profileID: profileID,
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible,
            bookmarkRootIDs: [rootID]
        )
        try await broker.approve(grant, now: now)
        let target = ActionTarget.native(try await broker.registerNativeResource(
            type: .bookmarkPlan,
            scopeRootID: rootID,
            now: now
        ))

        let issueExpiry = try await broker.requestActionApproval(
            tool: "bookmarks.apply",
            normalizedParameters: "plan=ttl",
            callSequence: 1,
            target: target,
            approvalTTL: 1,
            now: now
        )
        try await broker.resumeAfterApproval(
            approvalID: issueExpiry.approvalID,
            confirmationDigest: issueExpiry.confirmationDigest,
            now: now.addingTimeInterval(0.5)
        )
        await XCTAssertThrowsAgentError(.capabilityExpired) {
            _ = try await broker.issueAction(
                tool: "bookmarks.apply",
                normalizedParameters: "plan=ttl",
                callSequence: 1,
                target: target,
                approvalID: issueExpiry.approvalID,
                confirmationDigest: issueExpiry.confirmationDigest,
                now: issueExpiry.expiresAt
            )
        }
        await XCTAssertThrowsAgentError(.consentRequired) {
            _ = try await broker.issueAction(
                tool: "bookmarks.apply",
                normalizedParameters: "plan=ttl",
                callSequence: 1,
                target: target,
                approvalID: issueExpiry.approvalID,
                confirmationDigest: issueExpiry.confirmationDigest,
                now: now
            )
        }

        let resumeExpiry = try await broker.requestActionApproval(
            tool: "bookmarks.apply",
            normalizedParameters: "plan=ttl",
            callSequence: 1,
            target: target,
            approvalTTL: 1,
            now: now.addingTimeInterval(2)
        )
        await XCTAssertThrowsAgentError(.capabilityExpired) {
            try await broker.resumeAfterApproval(
                approvalID: resumeExpiry.approvalID,
                confirmationDigest: resumeExpiry.confirmationDigest,
                now: resumeExpiry.expiresAt
            )
        }
        let expiredAwaitingState = await broker.state
        let expiredPendingID = await broker.pendingActionApproval?.approvalID
        XCTAssertEqual(expiredAwaitingState, .awaitingActionApproval)
        XCTAssertEqual(expiredPendingID, resumeExpiry.approvalID)
    }

    func testBookmarkTargetOutsideGrantRootsIsRejected() async throws {
        let profileID = UUID()
        let allowedRootID = UUID()
        let rogueRootID = UUID()
        let planID = UUID()
        let broker = AgentBroker(profileID: profileID, isPrivateProfile: false)
        _ = try await broker.makeLocalConsentDraft(
            goal: "应用受控收藏夹计划",
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible
        )
        let grant = AgentContractTests.makeGrant(
            profileID: profileID,
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible,
            bookmarkRootIDs: [allowedRootID]
        )
        try await broker.approve(grant)
        await XCTAssertThrowsAgentError(.toolDenied) {
            _ = try await broker.registerNativeResource(
                type: .bookmarkPlan,
                id: planID,
                scopeRootID: rogueRootID
            )
        }

        let registry = ResourceRegistry(taskID: grant.taskID, grantID: grant.grantID)
        let revision = try await registry.append(
            id: planID,
            kind: .bookmarkPlan,
            scopeRootID: rogueRootID
        )
        let rogueTarget = ActionTarget.native(NativeActionTarget(
            resourceType: .bookmarkPlan,
            registryRevision: revision,
            resourceID: planID
        ))
        let capabilities = ActionCapabilityBroker()
        await XCTAssertThrowsAgentError(.toolDenied) {
            _ = try await capabilities.issue(
                grant: grant,
                tool: "bookmarks.apply",
                normalizedParameters: "plan=rogue",
                callSequence: 1,
                target: rogueTarget,
                registrySnapshot: await registry.snapshot(),
                confirmationDigest: "confirmed-rogue-plan"
            )
        }
    }

    func testApprovedFinalTargetCannotBeReplacedAndApprovalIsBurned() async throws {
        let profileID = UUID()
        let rootID = UUID()
        let approvedPlanID = UUID()
        let replacementPlanID = UUID()
        let broker = AgentBroker(profileID: profileID, isPrivateProfile: false)
        _ = try await broker.makeLocalConsentDraft(
            goal: "应用最终收藏夹计划",
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible
        )
        let grant = AgentContractTests.makeGrant(
            profileID: profileID,
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible,
            bookmarkRootIDs: [rootID]
        )
        try await broker.approve(grant)
        _ = try await broker.registerNativeResource(
            type: .bookmarkPlan,
            id: replacementPlanID,
            scopeRootID: rootID
        )
        let approvedTarget = ActionTarget.native(try await broker.registerNativeResource(
            type: .bookmarkPlan,
            id: approvedPlanID,
            scopeRootID: rootID
        ))
        let approval = try await broker.requestActionApproval(
            tool: "bookmarks.apply",
            normalizedParameters: #"{"plan":"final"}"#,
            callSequence: 7,
            target: approvedTarget
        )
        try await broker.resumeAfterApproval(
            approvalID: approval.approvalID,
            confirmationDigest: approval.confirmationDigest
        )

        guard case let .native(approvedNativeTarget) = approvedTarget else {
            return XCTFail("预期原生 target")
        }
        let replacedTarget = ActionTarget.native(NativeActionTarget(
            resourceType: .bookmarkPlan,
            registryRevision: approvedNativeTarget.registryRevision,
            resourceID: replacementPlanID
        ))
        await XCTAssertThrowsAgentError(.capabilityMismatch) {
            _ = try await broker.issueAction(
                tool: "bookmarks.apply",
                normalizedParameters: #"{"plan":"final"}"#,
                callSequence: 7,
                target: replacedTarget,
                approvalID: approval.approvalID,
                confirmationDigest: approval.confirmationDigest
            )
        }
        await XCTAssertThrowsAgentError(.consentRequired) {
            _ = try await broker.issueAction(
                tool: "bookmarks.apply",
                normalizedParameters: #"{"plan":"final"}"#,
                callSequence: 7,
                target: approvedTarget,
                approvalID: approval.approvalID,
                confirmationDigest: approval.confirmationDigest
            )
        }
    }

    func testUndoImportsExactTransactionAndPreservesLineage() async throws {
        let profileID = UUID()
        let rootID = UUID()
        let planID = UUID()
        let transactionID = UUID()
        let treeBeforeDigest = "tree-before-v1"
        let treeAfterDigest = "tree-after-v1"

        let originalBroker = AgentBroker(profileID: profileID, isPrivateProfile: false)
        _ = try await originalBroker.makeLocalConsentDraft(
            goal: "应用收藏夹整理计划",
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible
        )
        let originalGrant = AgentContractTests.makeGrant(
            profileID: profileID,
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible,
            bookmarkRootIDs: [rootID]
        )
        XCTAssertEqual(originalGrant.bookmarkScope.rootIDs, [rootID])
        try await originalBroker.approve(originalGrant)
        let planTarget = ActionTarget.native(try await originalBroker.registerNativeResource(
            type: .bookmarkPlan,
            id: planID,
            scopeRootID: rootID
        ))
        let applyParameters = "tree_before=tree-before-v1&tree_after=tree-after-v1"
        let applyApproval = try await originalBroker.requestActionApproval(
            tool: "bookmarks.apply",
            normalizedParameters: applyParameters,
            callSequence: 1,
            target: planTarget
        )
        try await originalBroker.resumeAfterApproval(
            approvalID: applyApproval.approvalID,
            confirmationDigest: applyApproval.confirmationDigest
        )
        let applyCapability = try await originalBroker.issueAction(
            tool: "bookmarks.apply",
            normalizedParameters: applyParameters,
            callSequence: 1,
            target: planTarget,
            approvalID: applyApproval.approvalID,
            confirmationDigest: applyApproval.confirmationDigest
        )
        try await originalBroker.consumeAction(
            applyCapability,
            expectedTool: "bookmarks.apply",
            expectedParameters: applyParameters,
            expectedTarget: planTarget
        )
        let applyTicket = try await originalBroker.beginNativeVerification(
            capability: applyCapability
        )
        let applyCommitted = await originalBroker.commitNativeVerification(applyTicket)
        XCTAssertTrue(applyCommitted)

        let lineage = UndoLineage(
            originalTaskID: originalGrant.taskID,
            originalGrantID: originalGrant.grantID,
            transactionID: transactionID,
            rootID: rootID,
            treeBeforeDigest: treeBeforeDigest,
            treeAfterDigest: treeAfterDigest,
            confirmationDigest: applyApproval.confirmationDigest
        )
        XCTAssertEqual(lineage.originalTaskID, originalGrant.taskID)
        XCTAssertEqual(lineage.originalGrantID, originalGrant.grantID)
        XCTAssertEqual(lineage.transactionID, transactionID)
        XCTAssertEqual(lineage.rootID, rootID)
        XCTAssertEqual(lineage.treeBeforeDigest, treeBeforeDigest)
        XCTAssertEqual(lineage.treeAfterDigest, treeAfterDigest)
        XCTAssertEqual(lineage.confirmationDigest, applyApproval.confirmationDigest)
        let undoTaskID = UUID()
        let undoGrantID = UUID()
        let undoBroker = AgentBroker(profileID: profileID, isPrivateProfile: false)
        _ = try await undoBroker.makeLocalConsentDraft(
            goal: "撤销指定收藏夹事务",
            origins: ["aegis://native"],
            tools: ["bookmarks.undo"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible
        )
        let undoGrant = AgentContractTests.makeGrant(
            taskID: undoTaskID,
            grantID: undoGrantID,
            profileID: profileID,
            origins: ["aegis://native"],
            tools: ["bookmarks.undo"],
            dataClasses: ["bookmark_metadata"],
            risk: .localReversible,
            bookmarkRootIDs: [lineage.rootID]
        )
        XCTAssertEqual(undoGrant.bookmarkScope.rootIDs, [rootID])
        XCTAssertNotEqual(undoGrant.taskID, lineage.originalTaskID)
        XCTAssertNotEqual(undoGrant.grantID, lineage.originalGrantID)
        try await undoBroker.approve(undoGrant)
        let undoTarget = ActionTarget.native(try await undoBroker.registerNativeResource(
            type: .bookmarkTransaction,
            id: lineage.transactionID,
            scopeRootID: lineage.rootID
        ))
        let undoParameters = """
        {"operation":"undo","original_confirmation_digest":"\(lineage.confirmationDigest)","original_grant_id":"\(lineage.originalGrantID.uuidString.lowercased())","original_task_id":"\(lineage.originalTaskID.uuidString.lowercased())","root_id":"\(lineage.rootID.uuidString.lowercased())","transaction_id":"\(lineage.transactionID.uuidString.lowercased())","tree_after":"\(lineage.treeAfterDigest)","tree_before":"\(lineage.treeBeforeDigest)"}
        """
        let undoApproval = try await undoBroker.requestActionApproval(
            tool: "bookmarks.undo",
            normalizedParameters: undoParameters,
            callSequence: 1,
            target: undoTarget
        )
        try await undoBroker.resumeAfterApproval(
            approvalID: undoApproval.approvalID,
            confirmationDigest: undoApproval.confirmationDigest
        )
        let undoCapability = try await undoBroker.issueAction(
            tool: "bookmarks.undo",
            normalizedParameters: undoParameters,
            callSequence: 1,
            target: undoTarget,
            approvalID: undoApproval.approvalID,
            confirmationDigest: undoApproval.confirmationDigest
        )
        XCTAssertEqual(undoCapability.confirmationDigest, undoApproval.confirmationDigest)
        try await undoBroker.consumeAction(
            undoCapability,
            expectedTool: "bookmarks.undo",
            expectedParameters: undoParameters,
            expectedTarget: undoTarget
        )
        if case let .native(target) = undoTarget {
            XCTAssertEqual(target.resourceID, transactionID)
        }
        let undoTicket = try await undoBroker.beginNativeVerification(
            capability: undoCapability
        )
        let undoCommitted = await undoBroker.commitNativeVerification(undoTicket)
        XCTAssertTrue(undoCommitted)
        let undoState = await undoBroker.state
        XCTAssertEqual(undoState, .completed)
    }

    func testTwoConcurrentConsumersHaveExactlyOneWinner() async throws {
        let profileID = UUID()
        let rootID = UUID()
        let resourceID = UUID()
        let grant = AgentContractTests.makeGrant(
            profileID: profileID,
            origins: ["aegis://native"],
            tools: ["bookmarks.apply"],
            risk: .localReversible,
            bookmarkRootIDs: [rootID]
        )
        let registry = ResourceRegistry(taskID: grant.taskID, grantID: grant.grantID)
        let revision = try await registry.append(
            id: resourceID,
            kind: .bookmarkPlan,
            scopeRootID: rootID
        )
        let snapshot = await registry.snapshot()
        let target = ActionTarget.native(NativeActionTarget(
            resourceType: .bookmarkPlan,
            registryRevision: revision,
            resourceID: resourceID
        ))
        let capabilities = ActionCapabilityBroker()
        let capability = try await capabilities.issue(
            grant: grant,
            tool: "bookmarks.apply",
            normalizedParameters: "plan=concurrent",
            callSequence: 1,
            target: target,
            registrySnapshot: snapshot,
            confirmationDigest: "confirmed-concurrent-plan"
        )

        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        try await capabilities.consume(
                            capability,
                            expectedTool: "bookmarks.apply",
                            expectedParameters: "plan=concurrent",
                            expectedTarget: target,
                            registrySnapshot: snapshot
                        )
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(results.filter { !$0 }.count, 1)
    }

    func testResourceRegistryIsAppendOnlyAndMonotonic() async throws {
        let taskID = UUID()
        let grantID = UUID()
        let rootID = UUID()
        let resourceID = UUID()
        let registry = ResourceRegistry(taskID: taskID, grantID: grantID)
        let appendedRevision = try await registry.append(
            id: resourceID,
            kind: .bookmarkPlan,
            scopeRootID: rootID
        )
        let closedRevision = try await registry.transition(id: resourceID, to: .closed)
        XCTAssertEqual(appendedRevision, 1)
        XCTAssertEqual(closedRevision, 2)

        do {
            _ = try await registry.append(id: resourceID, kind: .bookmarkPlan)
            XCTFail("已退出的资源 ID 不能复用")
        } catch {
            XCTAssertEqual(error as? AgentContractError, .resourceReuse)
        }
        let snapshot = await registry.snapshot()
        XCTAssertEqual(snapshot.revision, 2)
        XCTAssertEqual(snapshot.resources.single?.state, .closed)
        XCTAssertEqual(snapshot.resources.single?.scopeRootID, rootID)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(3),
        predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    private static let disorderedBookmarks: [BrowserBookmark] = [
        BrowserBookmark(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            title: "Z",
            url: "https://z.example?utm_source=feed",
            createdAt: Date(timeIntervalSince1970: 300)
        ),
        BrowserBookmark(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            title: "重复项",
            url: "https://EXAMPLE.com/item?utm_source=feed&keep=1",
            createdAt: Date(timeIntervalSince1970: 200)
        ),
        BrowserBookmark(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            title: "保留项",
            url: "https://example.com/item?keep=1",
            createdAt: Date(timeIntervalSince1970: 100)
        ),
        BrowserBookmark(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!,
            title: "A",
            url: "https://a.example?fbclid=tracking",
            createdAt: Date(timeIntervalSince1970: 400)
        ),
    ]
}

private func XCTAssertThrowsAgentError(
    _ expected: AgentContractError,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("预期抛出 \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? AgentContractError, expected, file: file, line: line)
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
