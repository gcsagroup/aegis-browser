import XCTest
@testable import AgentKit

final class AgentContractTests: XCTestCase {
    func testContractErrorDescriptionsHonorRequestedSystemLocale() throws {
        // Matrix hosts supply AEGIS_EXPECTED_LANGUAGE independently. Do not override the
        // resource locale: exercise the same LocalizedError/NSError path as callers.
        let errors: [AgentContractError] = [
            .invalidState, .privateProfileDenied, .consentRequired, .expiredGrant,
            .unsupportedVersion, .toolDenied, .originDenied, .riskExceeded, .invalidLease,
            .staleResourceRevision, .capabilityExpired, .capabilityAlreadyConsumed,
            .capabilityMismatch, .invalidTransition, .resourceReuse, .unknownResource,
        ]
        let languages = ["de", "en", "en-GB", "en-HK", "es", "fr", "id", "it", "ja",
                         "ko", "ms", "pt", "th", "vi", "zh-Hans", "zh-Hant", "zh-Hant-HK"]
        let appleLanguages = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
        let requested = appleLanguages.isEmpty ? Locale.preferredLanguages : appleLanguages
        XCTAssertFalse(requested.isEmpty)
        let systemExpected = try XCTUnwrap(Bundle.preferredLocalizations(
            from: languages, forPreferences: requested
        ).first)
        let override = ProcessInfo.processInfo.environment["AEGIS_EXPECTED_LANGUAGE"]
        let expectedLanguage = override ?? systemExpected
        let bundle = try XCTUnwrap(Bundle(identifier: "com.gcsa.aegis.agentkit"))
        let snapshot = AegisLocalization.current
        let selected = try XCTUnwrap(AegisLocalization.resourceLocalization(in: bundle, snapshot: snapshot,
            key: errors[0].localizedResource.key, table: "AgentErrors"))
        let expectedFamily = ProcessInfo.processInfo.environment["AEGIS_EXPECTED_FAMILY"]
            ?? ["en-GB": "en", "en-HK": "en", "zh-Hant-HK": "zh-Hant"][expectedLanguage] ?? expectedLanguage
        let evidence: [String: Any] = [
            "expected": expectedLanguage,
            "expectedSource": override == nil ? "system" : "environment",
            "requested": requested,
            "selected": selected,
            "current": Locale.current.identifier,
            "expectedFamily": expectedFamily,
            "selectedFamily": snapshot.family.rawValue,
            "dialect": snapshot.dialect,
            "region": Locale.current.region?.identifier ?? "",
        ]
        let context = String(decoding: try JSONSerialization.data(
            withJSONObject: evidence, options: [.sortedKeys]
        ), as: UTF8.self)
        print("AEGIS_AGENT_LOCALE \(context)")
        let attachment = XCTAttachment(string: context)
        attachment.name = "AgentContractError requested and selected locales"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(snapshot.family.rawValue, expectedFamily, "Stale family override: \(context)")
        if let expectedRegion = ProcessInfo.processInfo.environment["AEGIS_EXPECTED_REGION"] {
            XCTAssertEqual(Locale.current.region?.identifier, expectedRegion, "Stale formatting region: \(context)")
        }
        XCTAssertTrue(languages.contains(expectedLanguage), context)
        XCTAssertEqual(selected, expectedLanguage, "Stale or misconfigured test host: \(context)")

        let tableURL = bundle.bundleURL.appendingPathComponent("\(expectedLanguage).lproj")
            .appendingPathComponent("AgentErrors.strings")
        let table = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: tableURL), format: nil
        ) as? [String: String])
        XCTAssertEqual(errors.count, 16)
        XCTAssertEqual(Set(table.keys), Set(errors.map { $0.localizedResource.key }), context)
        for error in errors {
            let key = error.localizedResource.key
            let expected = try XCTUnwrap(table[key], "\(context), key=\(key)")
            XCTAssertFalse(expected.isEmpty || expected == key, "\(context), key=\(key)")
            XCTAssertEqual(error.errorDescription, expected, "errorDescription: \(context), key=\(key)")
            XCTAssertEqual((error as NSError).localizedDescription, expected,
                           "NSError.localizedDescription: \(context), key=\(key)")
        }
    }

    func testLocalizedContractErrorsInEverySupportedLocale() throws {
        let errors: [AgentContractError] = [
            .invalidState, .privateProfileDenied, .consentRequired, .expiredGrant,
            .unsupportedVersion, .toolDenied, .originDenied, .riskExceeded, .invalidLease,
            .staleResourceRevision, .capabilityExpired, .capabilityAlreadyConsumed,
            .capabilityMismatch, .invalidTransition, .resourceReuse, .unknownResource,
        ]
        let bundle = try XCTUnwrap(Bundle(identifier: "com.gcsa.aegis.agentkit"))
        let languages = ["de", "en", "en-GB", "en-HK", "es", "fr", "id", "it", "ja",
                         "ko", "ms", "pt", "th", "vi", "zh-Hans", "zh-Hant", "zh-Hant-HK"]
        XCTAssertEqual(Set(errors.map { $0.localizedResource.key }).count, errors.count)
        for language in languages {
            let folder = bundle.bundleURL.appendingPathComponent("\(language).lproj")
            let tableURL = folder.appendingPathComponent("AgentErrors.strings")
            let table = try XCTUnwrap(PropertyListSerialization.propertyList(
                from: Data(contentsOf: tableURL), format: nil
            ) as? [String: String])
            XCTAssertEqual(Set(table.keys), Set(errors.map { $0.localizedResource.key }))
            for error in errors {
                var resource = error.localizedResource
                resource.locale = Locale(identifier: language)
                let expected = try XCTUnwrap(table[resource.key])
                XCTAssertEqual(String(localized: resource), expected, "\(language)/\(resource.key)")
                XCTAssertFalse(expected.isEmpty || expected == resource.key)
            }
        }
    }

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
