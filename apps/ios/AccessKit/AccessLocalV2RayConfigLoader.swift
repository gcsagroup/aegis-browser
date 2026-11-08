import Foundation

/// Imports a local V2Ray / Xray client JSON into admitted `reality_vision` parameters.
///
/// Accepted shapes:
/// 1. Full client config with `outbounds[]` (first VLESS + REALITY + Vision wins)
/// 2. A single outbound object (`protocol` / `settings` / `streamSettings`)
/// 3. Flat parameters object (`address`, `port`, `id`/`userID`, `serverName`/`sni`,
///    `publicKey`/`pbk`, `shortId`/`sid`, optional `fingerprint`/`fp`)
///
/// Rejects WS, `allowInsecure`, and non-`reality_vision` matrix values. Does not
/// read secrets from the environment — only a filesystem path.
public enum AccessLocalV2RayConfigLoader {
    /// Resolves the config path from `AEGIS_ACCESS_LOCAL_V2RAY_CONFIG`, else nil.
    public static func configuredPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let raw = environment[AccessLocalV2RayConfig.environmentVariable] else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Loads from the environment variable path. Throws `pathNotSet` when unset.
    public static func loadFromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> AccessLocalV2RayConfig {
        guard let path = configuredPath(environment: environment) else {
            throw AccessLocalV2RayConfigError.pathNotSet
        }
        return try load(path: path, fileManager: fileManager)
    }

    public static func load(
        path: String,
        fileManager: FileManager = .default
    ) throws -> AccessLocalV2RayConfig {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AccessLocalV2RayConfigError.emptyField("path")
        }
        guard fileManager.fileExists(atPath: trimmed) else {
            throw AccessLocalV2RayConfigError.fileNotFound(trimmed)
        }
        guard let data = fileManager.contents(atPath: trimmed) else {
            throw AccessLocalV2RayConfigError.unreadableFile(trimmed)
        }
        let parameters = try parse(data: data)
        return AccessLocalV2RayConfig(sourcePath: trimmed, parameters: parameters)
    }

    public static func parse(data: Data) throws -> AccessRealityVisionParameters {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw AccessLocalV2RayConfigError.invalidJSON
        }
        guard let root = object as? [String: Any] else {
            throw AccessLocalV2RayConfigError.invalidJSON
        }
        try rejectPoison(root)

        if let outbounds = root["outbounds"] as? [[String: Any]] {
            for outbound in outbounds {
                if let parameters = try? parameters(fromOutbound: outbound) {
                    return parameters
                }
            }
            throw AccessLocalV2RayConfigError.noAdmittedRealityOutbound
        }

        if root["protocol"] as? String != nil || root["streamSettings"] != nil {
            return try parameters(fromOutbound: root)
        }

        return try parameters(fromFlat: root)
    }

    // MARK: - Shape parsers

    private static func parameters(fromOutbound outbound: [String: Any]) throws -> AccessRealityVisionParameters {
        try rejectPoison(outbound)
        let protocolName = (outbound["protocol"] as? String)?.lowercased() ?? ""
        guard protocolName == "vless" else {
            throw AccessLocalV2RayConfigError.noAdmittedRealityOutbound
        }

        let settings = try dict(outbound["settings"], field: "settings")
        let vnext = try arrayOfDict(settings["vnext"], field: "vnext")
        guard let server = vnext.first else {
            throw AccessLocalV2RayConfigError.emptyField("vnext")
        }
        let address = try string(server["address"], field: "address")
        let port = try portValue(server["port"], field: "port")
        let users = try arrayOfDict(server["users"], field: "users")
        guard let user = users.first else {
            throw AccessLocalV2RayConfigError.emptyField("users")
        }
        let userID = try string(user["id"], field: "userID")
        let flow = (user["flow"] as? String) ?? AccessRealityVisionParameters.admittedFlow
        guard flow == AccessRealityVisionParameters.admittedFlow else {
            throw AccessLocalV2RayConfigError.unsupportedFlow(flow)
        }

        let stream = try dict(outbound["streamSettings"], field: "streamSettings")
        let network = (stream["network"] as? String) ?? AccessRealityVisionParameters.admittedNetwork
        guard network == AccessRealityVisionParameters.admittedNetwork else {
            throw AccessLocalV2RayConfigError.unsupportedNetwork(network)
        }
        let security = (stream["security"] as? String) ?? ""
        guard security == AccessRealityVisionParameters.admittedSecurity else {
            throw AccessLocalV2RayConfigError.unsupportedSecurity(security.isEmpty ? "<missing>" : security)
        }
        if stream["wsSettings"] != nil {
            throw AccessLocalV2RayConfigError.unsupportedNetwork("ws")
        }
        let reality = try dict(stream["realitySettings"], field: "realitySettings")
        try rejectPoison(reality)

        let serverName = try firstString(reality, keys: ["serverName", "server_name", "sni"], field: "serverName")
        let publicKey = try firstString(reality, keys: ["publicKey", "public_key", "pbk"], field: "publicKey")
        let shortID = try firstString(reality, keys: ["shortId", "short_id", "sid"], field: "shortID")
        let fingerprint = (try? firstString(reality, keys: ["fingerprint", "fp"], field: "fingerprint"))
            ?? AccessRealityVisionParameters.defaultFingerprint

        return try AccessRealityVisionParameters(
            address: address,
            port: port,
            userID: userID,
            serverName: serverName,
            publicKey: publicKey,
            shortID: shortID,
            fingerprint: fingerprint
        )
    }

    private static func parameters(fromFlat root: [String: Any]) throws -> AccessRealityVisionParameters {
        try rejectPoison(root)
        let address = try firstString(root, keys: ["address", "host"], field: "address")
        let port = try portValue(root["port"], field: "port")
        let userID = try firstString(root, keys: ["id", "userID", "userId", "uuid"], field: "userID")
        let serverName = try firstString(root, keys: ["serverName", "server_name", "sni"], field: "serverName")
        let publicKey = try firstString(root, keys: ["publicKey", "public_key", "pbk"], field: "publicKey")
        let shortID = try firstString(root, keys: ["shortId", "short_id", "sid"], field: "shortID")
        let fingerprint = (try? firstString(root, keys: ["fingerprint", "fp"], field: "fingerprint"))
            ?? AccessRealityVisionParameters.defaultFingerprint

        if let flow = root["flow"] as? String, flow != AccessRealityVisionParameters.admittedFlow {
            throw AccessLocalV2RayConfigError.unsupportedFlow(flow)
        }
        if let network = root["network"] as? String, network != AccessRealityVisionParameters.admittedNetwork {
            throw AccessLocalV2RayConfigError.unsupportedNetwork(network)
        }
        if let security = root["security"] as? String, security != AccessRealityVisionParameters.admittedSecurity {
            throw AccessLocalV2RayConfigError.unsupportedSecurity(security)
        }

        return try AccessRealityVisionParameters(
            address: address,
            port: port,
            userID: userID,
            serverName: serverName,
            publicKey: publicKey,
            shortID: shortID,
            fingerprint: fingerprint
        )
    }

    // MARK: - Helpers

    private static func rejectPoison(_ value: Any) throws {
        var stack: [Any] = [value]
        while let current = stack.popLast() {
            if let dict = current as? [String: Any] {
                if dict.keys.contains("allowInsecure") {
                    throw AccessLocalV2RayConfigError.allowInsecureRejected
                }
                if dict.keys.contains("wsSettings") {
                    throw AccessLocalV2RayConfigError.unsupportedNetwork("ws")
                }
                stack.append(contentsOf: dict.values)
            } else if let array = current as? [Any] {
                stack.append(contentsOf: array)
            }
        }
    }

    private static func dict(_ value: Any?, field: String) throws -> [String: Any] {
        guard let dict = value as? [String: Any] else {
            throw AccessLocalV2RayConfigError.emptyField(field)
        }
        return dict
    }

    private static func arrayOfDict(_ value: Any?, field: String) throws -> [[String: Any]] {
        guard let array = value as? [[String: Any]] else {
            throw AccessLocalV2RayConfigError.emptyField(field)
        }
        return array
    }

    private static func string(_ value: Any?, field: String) throws -> String {
        guard let text = value as? String else {
            throw AccessLocalV2RayConfigError.emptyField(field)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AccessLocalV2RayConfigError.emptyField(field)
        }
        guard trimmed == text else {
            throw AccessLocalV2RayConfigError.fieldNotCanonical(field)
        }
        return trimmed
    }

    private static func firstString(_ dict: [String: Any], keys: [String], field: String) throws -> String {
        for key in keys {
            if let value = dict[key] {
                return try string(value, field: field)
            }
        }
        throw AccessLocalV2RayConfigError.emptyField(field)
    }

    private static func portValue(_ value: Any?, field: String) throws -> UInt16 {
        if let number = value as? Int {
            guard number > 0, number <= Int(UInt16.max) else {
                throw AccessLocalV2RayConfigError.fieldNotCanonical(field)
            }
            return UInt16(number)
        }
        if let number = value as? NSNumber {
            let intValue = number.intValue
            guard intValue > 0, intValue <= Int(UInt16.max) else {
                throw AccessLocalV2RayConfigError.fieldNotCanonical(field)
            }
            return UInt16(intValue)
        }
        if let text = value as? String {
            guard let number = UInt16(text), number > 0 else {
                throw AccessLocalV2RayConfigError.fieldNotCanonical(field)
            }
            return number
        }
        throw AccessLocalV2RayConfigError.emptyField(field)
    }
}
