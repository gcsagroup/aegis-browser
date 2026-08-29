import Foundation

public enum AgentContractMessageType: String, Equatable, Sendable {
    case taskGrant = "task_grant"
    case documentLease = "document_lease"
    case actionDigestInput = "action_digest_input"
}

public enum AgentContractWireValidationError: String, Error, Equatable, LocalizedError, Sendable {
    case invalidMessage = "invalid_message"
    case unsupportedVersion = "unsupported_version"
    case unknownField = "unknown_field"
    case invalidValue = "invalid_value"
    case nonCanonicalSet = "non_canonical_set"

    public var errorDescription: String? { rawValue }
}

/// Agent Contract v1 的严格 JSON wire 校验器。
///
/// 它只接受 snake_case、封闭字段集合和规范化数组；通过校验后，调用方再将
/// payload 转换为进程内领域类型，避免宽松的 `Codable` 解码扩大信任边界。
public enum AgentContractCodec {
    private typealias JSONObject = [String: Any]

    private static let maximumSafeInteger = 9_007_199_254_740_991.0
    private static let risks: Set<String> = ["R0", "R1", "R2", "R3"]
    private static let surfaces: Set<String> = ["aegis_browser", "safari_read_only"]
    private static let tools: Set<String> = [
        "page.observe",
        "page.extract",
        "url.health",
        "bookmarks.list",
        "bookmarks.plan",
        "bookmarks.apply",
        "bookmarks.undo",
        "downloads.verify",
        "downloads.start",
        "downloads.cancel",
        "browser.tabs.create",
        "page.click",
    ]

    public static func validate(_ data: Data) throws -> AgentContractMessageType {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AgentContractWireValidationError.invalidMessage
        }
        return try validateJSONObject(value)
    }

    public static func validateJSONObject(_ value: Any) throws -> AgentContractMessageType {
        let message = try object(value)

        // 与 TypeScript 校验器保持一致：版本失败优先于顶层字段检查。
        guard let version = number(message["contract_version"]),
              version.doubleValue == 1
        else {
            throw AgentContractWireValidationError.unsupportedVersion
        }

        try exactKeys(message, required: ["contract_version", "message_type", "payload"])
        let messageType = try string(message["message_type"])
        switch messageType {
        case AgentContractMessageType.taskGrant.rawValue:
            try validateTaskGrant(message["payload"])
            return .taskGrant
        case AgentContractMessageType.documentLease.rawValue:
            try validateDocumentLease(message["payload"])
            return .documentLease
        case AgentContractMessageType.actionDigestInput.rawValue:
            try validateActionDigest(message["payload"])
            return .actionDigestInput
        default:
            throw AgentContractWireValidationError.invalidValue
        }
    }

    static func actionDigestData(
        taskID: UUID,
        grantID: UUID,
        profileID: UUID,
        processInstanceID: UUID,
        surface: AgentSurface,
        policyVersion: String,
        tool: String,
        normalizedParameters: String,
        callSequence: UInt64,
        target: ActionTarget,
        confirmationDigest: String?,
        expiresAt: Date
    ) throws -> Data {
        let payload: JSONObject = [
            "task_id": taskID.uuidString.lowercased(),
            "grant_id": grantID.uuidString.lowercased(),
            "profile_id": profileID.uuidString.lowercased(),
            "process_instance_id": processInstanceID.uuidString.lowercased(),
            "surface": surface == .aegisBrowser ? "aegis_browser" : "safari_read_only",
            "policy_version": policyVersion,
            "tool": tool,
            "normalized_parameters": normalizedParameters,
            "call_sequence": callSequence,
            "target": targetObject(target),
            "confirmation_digest": confirmationDigest ?? NSNull(),
            "expires_at": wireTimestamp(expiresAt),
        ]
        let message: JSONObject = [
            "contract_version": 1,
            "message_type": AgentContractMessageType.actionDigestInput.rawValue,
            "payload": payload,
        ]
        _ = try validateJSONObject(message)
        return try JSONSerialization.data(
            withJSONObject: message,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func canonicalNormalizedParameters(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.first == "{" || trimmed.first == "[" else { return trimmed }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let canonical = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let result = String(data: canonical, encoding: .utf8)
        else { throw AgentContractError.capabilityMismatch }
        return result
    }

    static func actionApprovalDigestData(
        approvalID: UUID,
        expiresAt: Date,
        grant: TaskGrant,
        tool: String,
        normalizedParameters: String,
        callSequence: UInt64,
        target: ActionTarget,
        risk: AgentRisk
    ) throws -> Data {
        let modelDestination: Any
        if let destination = grant.modelDestination {
            modelDestination = [
                "provider": destination.provider,
                "exact_https_host": destination.exactHTTPSHost,
                "purpose": destination.purpose,
                "data_classes": destination.dataClasses.sorted(),
                "max_request_bytes": destination.maxRequestBytes,
            ] as JSONObject
        } else {
            modelDestination = NSNull()
        }
        let grantObject: JSONObject = [
            "contract_version": grant.contractVersion,
            "task_id": grant.taskID.uuidString.lowercased(),
            "grant_id": grant.grantID.uuidString.lowercased(),
            "profile_id": grant.profileID.uuidString.lowercased(),
            "surface": grant.surface == .aegisBrowser ? "aegis_browser" : "safari_read_only",
            "allowed_top_origins": grant.allowedTopOrigins.sorted(),
            "allowed_frame_origins": grant.allowedFrameOrigins.sorted(),
            "allowed_tools": grant.allowedTools.sorted(),
            "data_classes": grant.dataClasses.sorted(),
            "risk_ceiling": "R\(grant.riskCeiling.rawValue)",
            "max_steps": grant.maxSteps,
            "time_budget_seconds": grant.timeBudgetSeconds,
            "byte_budget": grant.byteBudget,
            "cost_budget": NSDecimalNumber(decimal: grant.costBudget).stringValue,
            "tab_scope": [
                "approved_existing_tab_ids": grant.tabScope.approvedExistingTabIDs
                    .map { $0.uuidString.lowercased() }.sorted(),
                "may_create_tabs": grant.tabScope.mayCreateTabs,
            ] as JSONObject,
            "bookmark_scope": [
                "root_ids": grant.bookmarkScope.rootIDs
                    .map { $0.uuidString.lowercased() }.sorted(),
                "may_write": grant.bookmarkScope.mayWrite,
            ] as JSONObject,
            "download_scope": [
                "approved_existing_ids": grant.downloadScope.approvedExistingIDs
                    .map { $0.uuidString.lowercased() }.sorted(),
                "may_start_downloads": grant.downloadScope.mayStartDownloads,
            ] as JSONObject,
            "expires_at": wireTimestamp(grant.expiresAt),
            "policy_version": grant.policyVersion,
            "model_version": grant.modelVersion,
            "model_destination": modelDestination,
        ]
        let payload: JSONObject = [
            "approval_id": approvalID.uuidString.lowercased(),
            "expires_at": wireTimestamp(expiresAt),
            "grant": grantObject,
            "tool": tool,
            "normalized_parameters": normalizedParameters,
            "call_sequence": callSequence,
            "target": targetObject(target),
            "risk": "R\(risk.rawValue)",
        ]
        return try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func targetObject(_ target: ActionTarget) -> JSONObject {
        switch target {
        case let .native(native):
            let resourceType = switch native.resourceType {
            case .bookmarkPlan: "bookmark_plan"
            case .bookmarkTransaction: "bookmark_transaction"
            case .tabBatch: "tab_batch"
            case .download: "download"
            }
            return [
                "kind": "native",
                "resource_type": resourceType,
                "registry_revision": native.registryRevision,
                "resource_id": native.resourceID.uuidString.lowercased(),
            ]
        case let .web(web):
            return [
                "kind": "web",
                "lease_id": web.leaseID.uuidString.lowercased(),
                "browser_session_id": web.browserSessionID.uuidString.lowercased(),
                "web_view_id": web.webViewID.uuidString.lowercased(),
                "tab_id": web.tabID.uuidString.lowercased(),
                "frame_id": web.frameID,
                "top_origin": web.topOrigin,
                "frame_origin": web.frameOrigin,
                "navigation_epoch": web.navigationEpoch,
                "document_nonce": web.documentNonce,
                "call_sequence": web.callSequence,
                "document_digest": web.documentDigest,
                "node_fingerprint": web.nodeFingerprint,
            ]
        }
    }

    private static func validateTaskGrant(_ value: Any?) throws {
        let payload = try object(value)
        try exactKeys(payload, required: [
            "task_id",
            "grant_id",
            "surface",
            "profile_id",
            "allowed_top_origins",
            "allowed_frame_origins",
            "allowed_tools",
            "data_classes",
            "risk_ceiling",
            "max_steps",
            "time_budget_seconds",
            "byte_budget",
            "cost_budget",
            "tab_scope",
            "bookmark_scope",
            "download_scope",
            "expires_at",
            "policy_version",
            "model_version",
            "model_destination",
        ])

        try uuid(payload["task_id"])
        try uuid(payload["grant_id"])
        try uuid(payload["profile_id"])
        guard surfaces.contains(try string(payload["surface"])) else {
            throw AgentContractWireValidationError.invalidValue
        }
        try canonicalStrings(payload["allowed_top_origins"])
        try canonicalStrings(payload["allowed_frame_origins"])
        try canonicalStrings(payload["allowed_tools"], allowed: tools)
        try canonicalStrings(payload["data_classes"])
        guard risks.contains(try string(payload["risk_ceiling"])) else {
            throw AgentContractWireValidationError.invalidValue
        }
        try safeInteger(payload["max_steps"], minimum: 1)
        try safeInteger(payload["time_budget_seconds"], minimum: 1)
        try safeInteger(payload["byte_budget"])
        try costBudget(payload["cost_budget"])
        try validateTabScope(payload["tab_scope"])
        try validateBookmarkScope(payload["bookmark_scope"])
        try validateDownloadScope(payload["download_scope"])
        try timestamp(payload["expires_at"])
        _ = try nonEmptyString(payload["policy_version"])
        _ = try nonEmptyString(payload["model_version"])
        try validateModelDestination(payload["model_destination"])
    }

    private static func validateTabScope(_ value: Any?) throws {
        let scope = try object(value)
        try exactKeys(scope, required: ["approved_existing_tab_ids", "may_create_tabs"])
        try canonicalUUIDs(scope["approved_existing_tab_ids"])
        try boolean(scope["may_create_tabs"])
    }

    private static func validateBookmarkScope(_ value: Any?) throws {
        let scope = try object(value)
        try exactKeys(scope, required: ["root_ids", "may_write"])
        try canonicalUUIDs(scope["root_ids"])
        try boolean(scope["may_write"])
    }

    private static func validateDownloadScope(_ value: Any?) throws {
        let scope = try object(value)
        try exactKeys(scope, required: ["approved_existing_ids", "may_start_downloads"])
        try canonicalUUIDs(scope["approved_existing_ids"])
        try boolean(scope["may_start_downloads"])
    }

    private static func validateModelDestination(_ value: Any?) throws {
        if value is NSNull { return }
        let destination = try object(value)
        try exactKeys(destination, required: [
            "provider",
            "exact_https_host",
            "purpose",
            "data_classes",
            "max_request_bytes",
        ])
        _ = try nonEmptyString(destination["provider"])
        _ = try nonEmptyString(destination["exact_https_host"])
        _ = try nonEmptyString(destination["purpose"])
        try canonicalStrings(destination["data_classes"])
        try safeInteger(destination["max_request_bytes"], minimum: 1)
    }

    private static func validateDocumentLease(_ value: Any?) throws {
        let payload = try object(value)
        try exactKeys(payload, required: [
            "lease_id",
            "task_id",
            "grant_id",
            "profile_id",
            "process_instance_id",
            "browser_session_id",
            "web_view_id",
            "tab_id",
            "frame_id",
            "committed_top_origin",
            "frame_origin",
            "navigation_epoch",
            "document_nonce",
            "call_sequence",
            "expires_at",
        ])

        for key in [
            "lease_id",
            "task_id",
            "grant_id",
            "profile_id",
            "process_instance_id",
            "browser_session_id",
            "web_view_id",
            "tab_id",
        ] {
            try uuid(payload[key])
        }
        for key in ["frame_id", "committed_top_origin", "frame_origin", "document_nonce"] {
            _ = try nonEmptyString(payload[key])
        }
        try safeInteger(payload["navigation_epoch"])
        try safeInteger(payload["call_sequence"])
        try timestamp(payload["expires_at"])
    }

    private static func validateActionDigest(_ value: Any?) throws {
        let payload = try object(value)
        try exactKeys(payload, required: [
            "task_id",
            "grant_id",
            "profile_id",
            "process_instance_id",
            "surface",
            "policy_version",
            "tool",
            "normalized_parameters",
            "call_sequence",
            "target",
            "confirmation_digest",
            "expires_at",
        ])

        for key in ["task_id", "grant_id", "profile_id", "process_instance_id"] {
            try uuid(payload[key])
        }
        guard surfaces.contains(try string(payload["surface"])) else {
            throw AgentContractWireValidationError.invalidValue
        }
        _ = try nonEmptyString(payload["policy_version"])
        guard tools.contains(try string(payload["tool"])) else {
            throw AgentContractWireValidationError.invalidValue
        }
        _ = try string(payload["normalized_parameters"])
        try safeInteger(payload["call_sequence"])
        try validateTarget(payload["target"])
        if !(payload["confirmation_digest"] is NSNull) {
            _ = try string(payload["confirmation_digest"])
        }
        try timestamp(payload["expires_at"])
    }

    private static func validateTarget(_ value: Any?) throws {
        let target = try object(value)
        switch try string(target["kind"]) {
        case "native":
            try exactKeys(target, required: ["kind", "resource_type", "registry_revision", "resource_id"])
            let resourceTypes: Set<String> = [
                "bookmark_plan",
                "bookmark_transaction",
                "tab_batch",
                "download",
            ]
            guard resourceTypes.contains(try string(target["resource_type"])) else {
                throw AgentContractWireValidationError.invalidValue
            }
            try safeInteger(target["registry_revision"])
            try uuid(target["resource_id"])
        case "web":
            try exactKeys(target, required: [
                "kind",
                "lease_id",
                "browser_session_id",
                "web_view_id",
                "tab_id",
                "frame_id",
                "top_origin",
                "frame_origin",
                "navigation_epoch",
                "document_nonce",
                "call_sequence",
                "document_digest",
                "node_fingerprint",
            ])
            for key in ["lease_id", "browser_session_id", "web_view_id", "tab_id"] {
                try uuid(target[key])
            }
            for key in [
                "frame_id",
                "top_origin",
                "frame_origin",
                "document_nonce",
                "document_digest",
                "node_fingerprint",
            ] {
                _ = try nonEmptyString(target[key])
            }
            try safeInteger(target["navigation_epoch"])
            try safeInteger(target["call_sequence"])
        default:
            throw AgentContractWireValidationError.invalidValue
        }
    }

    private static func object(_ value: Any?) throws -> JSONObject {
        guard let object = value as? JSONObject else {
            throw AgentContractWireValidationError.invalidMessage
        }
        return object
    }

    private static func exactKeys(_ value: JSONObject, required: [String]) throws {
        let requiredKeys = Set(required)
        guard value.keys.allSatisfy(requiredKeys.contains) else {
            throw AgentContractWireValidationError.unknownField
        }
        guard requiredKeys.allSatisfy(value.keys.contains) else {
            throw AgentContractWireValidationError.invalidValue
        }
    }

    private static func string(_ value: Any?) throws -> String {
        guard let value = value as? String else {
            throw AgentContractWireValidationError.invalidValue
        }
        return value
    }

    private static func nonEmptyString(_ value: Any?) throws -> String {
        let value = try string(value)
        guard !value.isEmpty else {
            throw AgentContractWireValidationError.invalidValue
        }
        return value
    }

    private static func boolean(_ value: Any?) throws {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID()
        else {
            throw AgentContractWireValidationError.invalidValue
        }
    }

    private static func number(_ value: Any?) -> NSNumber? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID()
        else {
            return nil
        }
        return value
    }

    private static func safeInteger(_ value: Any?, minimum: Double = 0) throws {
        guard let value = number(value)?.doubleValue,
              value.isFinite,
              value.rounded(.towardZero) == value,
              value >= minimum,
              value <= maximumSafeInteger
        else {
            throw AgentContractWireValidationError.invalidValue
        }
    }

    private static func canonicalStrings(_ value: Any?, allowed: Set<String>? = nil) throws {
        guard let values = value as? [Any] else {
            throw AgentContractWireValidationError.invalidValue
        }
        var strings: [String] = []
        strings.reserveCapacity(values.count)
        for value in values {
            guard let string = value as? String, !string.isEmpty else {
                throw AgentContractWireValidationError.invalidValue
            }
            strings.append(string)
        }
        let codeUnits = strings.map { Array($0.utf16) }
        guard Set(codeUnits).count == codeUnits.count,
              codeUnits.sorted(by: { $0.lexicographicallyPrecedes($1) }) == codeUnits
        else {
            throw AgentContractWireValidationError.nonCanonicalSet
        }
        if let allowed, strings.contains(where: { !allowed.contains($0) }) {
            throw AgentContractWireValidationError.invalidValue
        }
    }

    private static func canonicalUUIDs(_ value: Any?) throws {
        try canonicalStrings(value)
        for value in value as? [Any] ?? [] {
            try uuid(value)
        }
    }

    private static func uuid(_ value: Any?) throws {
        let value = try string(value)
        guard value.range(
            of: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
            options: .regularExpression
        ) != nil else {
            throw AgentContractWireValidationError.invalidValue
        }
    }

    private static func timestamp(_ value: Any?) throws {
        let value = try string(value)
        guard value.range(
            of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$",
            options: .regularExpression
        ) != nil else {
            throw AgentContractWireValidationError.invalidValue
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard formatter.date(from: value) != nil else {
            throw AgentContractWireValidationError.invalidValue
        }
    }

    private static func costBudget(_ value: Any?) throws {
        let value = try string(value)
        guard value.range(
            of: "^(0|[1-9][0-9]*)(\\.[0-9]+)?$",
            options: .regularExpression
        ) != nil else {
            throw AgentContractWireValidationError.invalidValue
        }
    }

    private static func wireTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }
}
