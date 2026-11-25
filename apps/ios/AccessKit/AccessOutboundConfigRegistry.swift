import CoreFoundation
import Foundation

/// Generates one outbound from typed input and validates the complete Xray
/// document before it reaches the bridge.
enum AccessOutboundConfigRegistry {
    private struct Entry: Sendable {
        let outbound: Rule
        let generate: @Sendable (AccessOutboundNode) throws -> [String: Any]
        let diagnosticSecrets: @Sendable (AccessOutboundNode) throws -> AccessDiagnosticLog.RedactionSecrets
    }

    private static let realityTag = AccessRealityVisionOutboundConfig.outboundTag
    private static let webSocketTag = "internal_vless_ws_tls"
    // Written out so the validator cannot follow a change to the generator constant.
    private static let visionFlow = "xtls-rprx-vision"

    private static let entries: [AccessOutboundProfileKey: Entry] = [
        .vlessRawReality: Entry(
            outbound: vlessRule(tag: realityTag, vision: true, stream: .object([
                "network": .literal("tcp"),
                "security": .literal("reality"),
                "realitySettings": .object([
                    "serverName": .string, "fingerprint": .string, "publicKey": .string,
                    "shortId": .string, "spiderX": .string,
                ]),
            ])),
            generate: { node in
                guard case .realityVision(let params) = node else { throw invalidProfile }
                return try vlessOutbound(for: node, tag: realityTag, stream: [
                    "network": AccessRealityVisionParameters.admittedNetwork,
                    "security": AccessRealityVisionParameters.admittedSecurity,
                    "realitySettings": [
                        "serverName": params.serverName, "fingerprint": params.fingerprint,
                        "publicKey": params.publicKey, "shortId": params.shortID, "spiderX": params.spiderX,
                    ],
                ])
            },
            diagnosticSecrets: { node in
                guard case .realityVision(let params) = node else { throw invalidProfile }
                return .init(credentials: [params.userID, params.publicKey, params.shortID])
            }
        ),
        .vlessWsTls: Entry(
            outbound: vlessRule(tag: webSocketTag, vision: false, stream: .object([
                "network": .literal("ws"),
                "security": .literal("tls"),
                "tlsSettings": .object([
                    "serverName": .string, "useSystemCA": .trueBoolean,
                ], optional: [
                    "fingerprint": .string, "alpn": .single(.literal("http/1.1")),
                ]),
                "wsSettings": .object(["host": .string, "path": .string]),
            ])),
            generate: { node in
                guard case .vlessWebSocketTLS(let params) = node else { throw invalidProfile }
                var tls: [String: Any] = ["serverName": params.serverName, "useSystemCA": true]
                if !params.fingerprint.isEmpty { tls["fingerprint"] = params.fingerprint }
                if !params.alpn.isEmpty { tls["alpn"] = [params.alpn] }
                return try vlessOutbound(for: node, tag: webSocketTag, stream: [
                    "network": "ws", "security": "tls", "tlsSettings": tls,
                    "wsSettings": ["host": params.requestHost, "path": params.path],
                ])
            },
            diagnosticSecrets: { node in
                guard case .vlessWebSocketTLS(let params) = node else { throw invalidProfile }
                return .init(credentials: [params.userID], queryValues: querySecrets(in: params.path))
            }
        ),
    ]

    private static let invalidProfile = AccessRealityVisionOutboundConfigError.fieldNotCanonical("profile")

    private static func entry(for profile: AccessOutboundProfileKey) throws -> Entry {
        guard let entry = entries[profile] else { throw invalidProfile }
        return entry
    }

    static func outboundJSONObject(for node: AccessOutboundNode) throws -> [String: Any] {
        let entry = try entry(for: node.profileKey)
        let root = ["outbounds": [try entry.generate(node)]]
        try assertFailClosed(root, profile: node.profileKey)
        return root
    }

    private static func vlessOutbound(
        for node: AccessOutboundNode, tag: String, stream: [String: Any]
    ) throws -> [String: Any] {
        let endpoint = node.endpoint
        guard case .vless(let userID, let encryption, let flow) = node.credentials else { throw invalidProfile }
        var user = ["id": userID, "encryption": encryption]
        user["flow"] = flow
        return [
            "tag": tag,
            "protocol": "vless",
            "settings": ["vnext": [["address": endpoint.address, "port": Int(endpoint.port), "users": [user]]]],
            "streamSettings": stream,
        ]
    }

    static func embeddedInstanceJSONData(
        for node: AccessOutboundNode, logLevel: AccessLogLevel = .none, errorLogPath: String? = nil,
        logCaptureGeneration: Int64? = nil
    ) throws -> Data {
        var root = try outboundJSONObject(for: node)
        root["inbounds"] = [Any]()
        root["log"] = try AccessRealityVisionOutboundConfig.embeddedLog(
            logLevel: logLevel, errorLogPath: errorLogPath, includeAccessLog: true
        )
        root["aegisLogCaptureGeneration"] = logCaptureGeneration
        try assertFailClosed(root, profile: node.profileKey)
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    static func diagnosticSecrets(for node: AccessOutboundNode) throws -> AccessDiagnosticLog.RedactionSecrets {
        try entry(for: node.profileKey).diagnosticSecrets(node)
    }

    private static func querySecrets(in path: String) -> [String] {
        guard let queryStart = path.firstIndex(of: "?") else { return [] }
        return path[path.index(after: queryStart)...].split(separator: "&").flatMap { field -> [String] in
            guard let equals = field.firstIndex(of: "=") else { return [] }
            let encoded = String(field[field.index(after: equals)...])
            // Retain the wire value even when percent escapes are opaque bytes.
            // Go also interprets '+' as a space when it parses query values.
            return [encoded, encoded.removingPercentEncoding,
                    encoded.replacingOccurrences(of: "+", with: " ").removingPercentEncoding]
                .compactMap { $0 }
        }
    }

    private static func vlessRule(tag: String, vision: Bool, stream: Rule) -> Rule {
        var user: [String: Rule] = ["id": .string, "encryption": .literal("none")]
        if vision { user["flow"] = .literal(visionFlow) }
        return .object([
            "tag": .literal(tag),
            "protocol": .literal("vless"),
            "settings": .object(["vnext": .single(.object([
                "address": .string, "port": .integer(1...Int64(UInt16.max)), "users": .single(.object(user)),
            ]))]),
            "streamSettings": stream,
        ])
    }

    static func assertFailClosed(_ root: [String: Any], profile: AccessOutboundProfileKey) throws {
        let entry = try entry(for: profile)
        let document: Rule = .object(["outbounds": .single(entry.outbound)], optional: [
            "inbounds": .emptyArray,
            "routing": .object([:]),
            "log": .object(["loglevel": .string, "access": .string, "error": .string]),
            "aegisLogCaptureGeneration": .integer(0...Int64.max),
        ])
        try document.validate(root, field: "root")

        if let log = root["log"] as? [String: String] {
            guard let level = log["loglevel"].flatMap(AccessLogLevel.init(rawValue:)),
                  let error = log["error"],
                  log["access"] == "none" || log["access"] == error,
                  level == .none ? error == "none" : error.hasPrefix("/") && error != "/" else {
                throw AccessRealityVisionOutboundConfigError.fieldNotCanonical("log")
            }
        }
    }

    private indirect enum Rule: Sendable {
        case object([String: Rule], optional: [String: Rule] = [:])
        case single(Rule)
        case emptyArray
        case string
        case literal(String)
        case trueBoolean
        case integer(ClosedRange<Int64>)

        func validate(_ value: Any, field: String) throws {
            let invalid = AccessRealityVisionOutboundConfigError.fieldNotCanonical(field)
            switch self {
            case .object(let required, let optional):
                guard let object = value as? [String: Any] else { throw invalid }
                if object.keys.contains("allowInsecure") {
                    throw AccessRealityVisionOutboundConfigError.allowInsecureRejected
                }
                guard required.keys.allSatisfy(object.keys.contains) else { throw invalid }
                // Sorted so a document with several violations always reports the same field.
                for (key, value) in object.sorted(by: { $0.key < $1.key }) {
                    guard let rule = required[key] ?? optional[key] else { throw invalid }
                    try rule.validate(value, field: key)
                }
            case .single(let rule):
                guard let array = value as? [Any], array.count == 1 else { throw invalid }
                try rule.validate(array[0], field: field)
            case .emptyArray:
                guard let array = value as? [Any], array.isEmpty else { throw invalid }
            case .string:
                guard value is String else { throw invalid }
            case .literal(let expected):
                guard value as? String == expected else { throw invalid }
            case .trueBoolean:
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID(),
                      number.boolValue else { throw invalid }
            case .integer(let range):
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      !CFNumberIsFloatType(number as CFNumber),
                      let integer = Int64(number.stringValue), range.contains(integer) else { throw invalid }
            }
        }
    }
}
