import XCTest
@testable import AgentKit

final class AgentContractTests: XCTestCase {
    func testConsentRequiredBeforePageRead() async throws {
        let profileID = UUID()
        let broker = AgentBroker(profileID: profileID, isPrivateProfile: false)

        do {
            try await broker.authorizeRead(tool: "page.observe", topOrigin: "https://aegis.test")
            XCTFail("同意前不应允许页面读取")
        } catch {
            XCTAssertEqual(error as? AgentContractError, .consentRequired)
        }

        let draft = try await broker.makeLocalConsentDraft(
            goal: "核对当前页面",
            origins: ["https://aegis.test"],
            tools: ["page.observe"],
            dataClasses: ["visible_text"],
            risk: .readOnly
        )
        XCTAssertEqual(draft.origins, ["https://aegis.test"])
        let awaitingState = await broker.state
        XCTAssertEqual(awaitingState, .awaitingTaskConsent)

        try await broker.approve(Self.makeGrant(profileID: profileID))
        try await broker.authorizeRead(tool: "page.observe", topOrigin: "https://aegis.test")
        let runningState = await broker.state
        XCTAssertEqual(runningState, .running)
    }

    func testPrivateProfileAlwaysRejectsAgent() async {
        let broker = AgentBroker(profileID: UUID(), isPrivateProfile: true)
        do {
            _ = try await broker.makeLocalConsentDraft(
                goal: "不应运行",
                origins: [],
                tools: [],
                dataClasses: [],
                risk: .readOnly
            )
            XCTFail("私密 Profile 不应生成授权草案")
        } catch {
            XCTAssertEqual(error as? AgentContractError, .privateProfileDenied)
        }
    }

    func testApprovalCannotExpandConsentRiskOrScope() async throws {
        let profileID = UUID()
        let broker = AgentBroker(profileID: profileID, isPrivateProfile: false)
        _ = try await broker.makeLocalConsentDraft(
            goal: "只读核对",
            origins: ["https://aegis.test"],
            tools: ["page.observe"],
            dataClasses: ["visible_text"],
            risk: .readOnly
        )
        let expanded = Self.makeGrant(
            profileID: profileID,
            tools: ["page.observe", "page.click"],
            risk: .externalOrSensitive
        )

        do {
            try await broker.approve(expanded)
            XCTFail("审批后的 Grant 不得扩大用户看到的范围")
        } catch {
            XCTAssertEqual(error as? AgentContractError, .capabilityMismatch)
        }
        let activeGrant = await broker.activeGrant
        let state = await broker.state
        XCTAssertNil(activeGrant)
        XCTAssertEqual(state, .awaitingTaskConsent)
    }

    func testRecoveryNeverAutomaticallyReturnsToRunning() async throws {
        let profileID = UUID()
        let broker = AgentBroker(profileID: profileID, isPrivateProfile: false)
        _ = try await broker.makeLocalConsentDraft(
            goal: "整理标签",
            origins: ["aegis://native"],
            tools: ["browser.tabs.create"],
            dataClasses: ["tab_metadata"],
            risk: .localReversible
        )
        try await broker.approve(Self.makeGrant(
            profileID: profileID,
            origins: ["aegis://native"],
            tools: ["browser.tabs.create"],
            dataClasses: ["tab_metadata"],
            risk: .localReversible
        ))
        await broker.recoverAfterProcessRestart()
        let recoveringState = await broker.state
        let recoveredGrant = await broker.activeGrant
        XCTAssertEqual(recoveringState, .recovering)
        XCTAssertNil(recoveredGrant)
        try await broker.requireUserAfterRecovery()
        let takeoverState = await broker.state
        XCTAssertEqual(takeoverState, .userTakeover)
    }

    static func makeGrant(
        taskID: UUID = UUID(),
        grantID: UUID = UUID(),
        profileID: UUID,
        origins: Set<String> = ["https://aegis.test"],
        tools: Set<String> = ["page.observe"],
        dataClasses: Set<String> = ["visible_text"],
        risk: AgentRisk = .readOnly,
        bookmarkRootIDs: Set<UUID> = [],
        expiresAt: Date = Date().addingTimeInterval(300)
    ) -> TaskGrant {
        TaskGrant(
            taskID: taskID,
            grantID: grantID,
            surface: .aegisBrowser,
            profileID: profileID,
            allowedTopOrigins: origins,
            allowedTools: tools,
            dataClasses: dataClasses,
            riskCeiling: risk,
            maxSteps: 12,
            timeBudgetSeconds: 120,
            byteBudget: 32_768,
            costBudget: 0,
            tabScope: TabScope(
                approvedExistingTabIDs: [],
                mayCreateTabs: tools.contains("browser.tabs.create")
            ),
            bookmarkScope: BookmarkScope(
                rootIDs: bookmarkRootIDs,
                mayWrite: tools.contains("bookmarks.apply") || tools.contains("bookmarks.undo")
            ),
            downloadScope: DownloadScope(
                approvedExistingIDs: [],
                mayStartDownloads: tools.contains("downloads.start")
            ),
            expiresAt: expiresAt,
            policyVersion: "ios-policy-v1",
            modelVersion: "deterministic-local-v1",
            modelDestination: nil
        )
    }
}
