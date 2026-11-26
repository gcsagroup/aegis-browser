import Foundation

/// Minimal importer for local Access tests: `vless://` share URI or flat JSON.
///
/// iOS stays small on purpose. Full Xray Core / sing-box client documents are
/// handled by `scripts/access_local_v2ray_config.py` on macOS.
///
/// Admitted matrix only: VLESS + TCP + REALITY + `xtls-rprx-vision`.
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

    /// The signed app channel selects the source for the product publisher.
    public static func productPath(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        switch bundle.object(forInfoDictionaryKey: "AegisAccessReleaseChannel") as? String {
        case "dev":
            return configuredPath(environment: environment)
                ?? bundle.url(forResource: "AegisPrivateTestNode", withExtension: "vless")?.path
        case "alpha", "beta":
            return bundle.url(forResource: "AegisPrivateTestNode", withExtension: "vless")?.path
        default:
            return nil
        }
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

    /// Parses UTF-8 file bytes: share URI line, or flat JSON object.
    public static func parse(data: Data) throws -> AccessRealityVisionParameters {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AccessLocalV2RayConfigError.invalidJSON
        }
        return try parse(text: text)
    }

    public static func parse(text: String) throws -> AccessRealityVisionParameters {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AccessLocalV2RayConfigError.invalidJSON
        }

        // One-line share URI (optionally with trailing newline already trimmed).
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        if firstLine.lowercased().hasPrefix("vless://") {
            return try parseShareURI(firstLine)
        }

        let object: Any
        do {
            guard let data = trimmed.data(using: .utf8) else {
                throw AccessLocalV2RayConfigError.invalidJSON
            }
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw AccessLocalV2RayConfigError.invalidJSON
        }
        guard let root = object as? [String: Any] else {
            throw AccessLocalV2RayConfigError.invalidJSON
        }
        return try parameters(fromFlat: root)
    }

    /// Options accepts one whole share link. Keep the file and subscription parsers' existing contracts.
    public static func parseSingleShareURI(_ input: String) throws -> AccessRealityVisionParameters {
        let link = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard input.utf8.count <= 8_192,
              link.lowercased().hasPrefix("vless://"),
              link.unicodeScalars.allSatisfy({ !forbidden.contains($0) }),
              !link.dropFirst("vless://".count).contains("://"),
              var components = URLComponents(string: link),
              components.password == nil,
              components.path.isEmpty || components.path == "/" else {
            throw AccessLocalV2RayConfigError.invalidJSON
        }
        let items = components.queryItems ?? []
        let acceptedKeys: Set<String> = [
            "type", "security", "flow", "encryption", "headerType", "spx", "pcks",
            "sni", "serverName", "server_name", "pbk", "publicKey", "public_key",
            "sid", "shortId", "short_id", "fp", "fingerprint", "support-x25519mlkem768"
        ]
        let aliasGroups = [
            ["sni", "serverName", "server_name"], ["pbk", "publicKey", "public_key"],
            ["sid", "shortId", "short_id"], ["fp", "fingerprint"]
        ]
        let names = Set(items.map(\.name))
        guard names.count == items.count,
              names.isSubset(of: acceptedKeys),
              items.contains(where: { $0.name == "flow" && $0.value == AccessRealityVisionParameters.admittedFlow }),
              aliasGroups.allSatisfy({ names.intersection($0).count <= 1 }),
              items.allSatisfy({ $0.value != nil && ($0.name != "headerType" || $0.value == "none")
                  && ($0.name != "pcks" || $0.value == "")
                  && ($0.name != "support-x25519mlkem768" || $0.value == "true") }) else {
            throw AccessLocalV2RayConfigError.invalidJSON
        }
        // 3X-UI's REALITY share capability hint is implemented by the pinned
        // native core/fingerprint, not an additional Xray JSON setting. Only
        // its affirmative form is admitted; never silently promise an override.
        // The fragment is untrusted and can itself contain credentials.
        components.fragment = nil
        guard let uri = components.string else { throw AccessLocalV2RayConfigError.invalidJSON }
        let parameters = try parseShareURI(uri)
        try validateManualParameters(parameters)
        return parameters
    }

    /// Manual imports and restored manual revisions share native admission.
    public static func validateManualParameters(_ parameters: AccessRealityVisionParameters) throws {
        // Match the pinned REALITY builder's RawURLEncoding and hex decoding.
        let publicKey = parameters.publicKey
        let base64url = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let base64 = publicKey.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard publicKey.utf8.count == 43,
              publicKey.unicodeScalars.allSatisfy({ base64url.contains($0) }),
              Data(base64Encoded: base64 + "=")?.count == 32 else {
            throw AccessRealityVisionOutboundConfigError.fieldNotCanonical("publicKey")
        }
        guard parameters.shortID.utf8.count.isMultiple(of: 2) else {
            throw AccessRealityVisionOutboundConfigError.fieldNotCanonical("shortID")
        }
        try AccessGoEmbeddedCore.validateRealityClientFields(fingerprint: parameters.fingerprint, spiderX: parameters.spiderX)
    }

    // MARK: - vless:// share URI

    /// `vless://<uuid>@<host>:<port>?flow=...&security=reality&...#name`
    public static func parseShareURI(_ raw: String) throws -> AccessRealityVisionParameters {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "vless" else {
            throw AccessLocalV2RayConfigError.invalidJSON
        }
        guard let userID = url.user, !userID.isEmpty else {
            throw AccessLocalV2RayConfigError.emptyField("userID")
        }
        guard let host = url.host, !host.isEmpty else {
            throw AccessLocalV2RayConfigError.emptyField("address")
        }
        guard let port = url.port, port > 0, port <= Int(UInt16.max) else {
            throw AccessLocalV2RayConfigError.fieldNotCanonical("port")
        }

        let query = Self.queryItems(from: url)
        let flow = query["flow"] ?? AccessRealityVisionParameters.admittedFlow
        guard flow == AccessRealityVisionParameters.admittedFlow else {
            throw AccessLocalV2RayConfigError.unsupportedFlow(flow)
        }
        let security = query["security"] ?? ""
        guard security == AccessRealityVisionParameters.admittedSecurity else {
            throw AccessLocalV2RayConfigError.unsupportedSecurity(security.isEmpty ? "<missing>" : security)
        }
        let network = query["type"] ?? AccessRealityVisionParameters.admittedNetwork
        guard network == AccessRealityVisionParameters.admittedNetwork else {
            throw AccessLocalV2RayConfigError.unsupportedNetwork(network)
        }
        // Some share URIs emit `encryption=` (empty). Treat missing/empty as admitted `none`.
        if let encryption = query["encryption"],
           !encryption.isEmpty,
           encryption != AccessRealityVisionParameters.admittedEncryption {
            throw AccessLocalV2RayConfigError.fieldNotCanonical("encryption")
        }
        if query["allowInsecure"] != nil {
            throw AccessLocalV2RayConfigError.allowInsecureRejected
        }

        let serverName = try requiredQuery(query, keys: ["sni", "serverName", "server_name"], field: "serverName")
        let publicKey = try requiredQuery(query, keys: ["pbk", "publicKey", "public_key"], field: "publicKey")
        guard let shortID = query["sid"] ?? query["shortId"] ?? query["short_id"] else {
            throw AccessLocalV2RayConfigError.emptyField("shortID")
        }
        let fingerprint = query["fp"] ?? query["fingerprint"] ?? AccessRealityVisionParameters.defaultFingerprint

        return try AccessRealityVisionParameters(
            address: host,
            port: UInt16(port),
            userID: userID,
            serverName: serverName,
            publicKey: publicKey,
            shortID: shortID,
            fingerprint: fingerprint,
            spiderX: query["spx"] ?? ""
        )
    }

    // MARK: - Flat JSON

    private static func parameters(fromFlat root: [String: Any]) throws -> AccessRealityVisionParameters {
        if root.keys.contains("allowInsecure") {
            throw AccessLocalV2RayConfigError.allowInsecureRejected
        }
        if root.keys.contains("wsSettings") {
            throw AccessLocalV2RayConfigError.unsupportedNetwork("ws")
        }

        let address = try firstString(root, keys: ["address", "host", "server"], field: "address")
        let port = try portValue(root["port"] ?? root["server_port"], field: "port")
        let userID = try firstString(root, keys: ["id", "userID", "userId", "uuid"], field: "userID")
        let serverName = try firstString(root, keys: ["serverName", "server_name", "sni"], field: "serverName")
        let publicKey = try firstString(root, keys: ["publicKey", "public_key", "pbk"], field: "publicKey")
        let shortID = try firstString(root, keys: ["shortId", "short_id", "sid"], field: "shortID")
        let fingerprint = (try? firstString(root, keys: ["fingerprint", "fp"], field: "fingerprint"))
            ?? AccessRealityVisionParameters.defaultFingerprint

        if let flow = root["flow"] as? String, flow != AccessRealityVisionParameters.admittedFlow {
            throw AccessLocalV2RayConfigError.unsupportedFlow(flow)
        }
        if let network = root["network"] as? String ?? root["type"] as? String,
           network != AccessRealityVisionParameters.admittedNetwork {
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

    private static func queryItems(from url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return [:]
        }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value, !value.isEmpty || ["sid", "shortId", "short_id"].contains(item.name) else { continue }
            result[item.name] = value
        }
        return result
    }

    private static func requiredQuery(_ query: [String: String], keys: [String], field: String) throws -> String {
        for key in keys {
            if let value = query[key], !value.isEmpty {
                return value
            }
        }
        throw AccessLocalV2RayConfigError.emptyField(field)
    }

    private static func firstString(_ dict: [String: Any], keys: [String], field: String) throws -> String {
        for key in keys {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard trimmed == value else {
                    throw AccessLocalV2RayConfigError.fieldNotCanonical(field)
                }
                return trimmed
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
