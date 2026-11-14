import Foundation

/// Severity threshold understood by the pinned Xray core.
public enum AccessLogLevel: String, CaseIterable, Sendable {
    case debug, info, warning, error, none
}

/// Generated Xray client config document for the admitted `reality_vision` path.
///
/// The document always contains a single VLESS outbound with RAW TCP + REALITY +
/// Vision. Compatible WS+TLS and `allowInsecure` are never emitted.
public struct AccessRealityVisionOutboundConfig: @unchecked Sendable {
    public let profile: AccessOutboundProfile
    public let parameters: AccessRealityVisionParameters
    /// Canonical JSON object tree (not logged; may contain endpoint material).
    public let jsonObject: [String: Any]

    public static let outboundTag = "reality_vision"

    init(parameters: AccessRealityVisionParameters, jsonObject: [String: Any]) {
        self.profile = .realityVision
        self.parameters = parameters
        self.jsonObject = jsonObject
    }

    public func jsonData(prettyPrinted: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if prettyPrinted {
            options.insert(.prettyPrinted)
        }
        return try JSONSerialization.data(withJSONObject: jsonObject, options: options)
    }

    public func jsonUTF8String(prettyPrinted: Bool = false) throws -> String {
        let data = try jsonData(prettyPrinted: prettyPrinted)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AccessRealityVisionOutboundConfigError.fieldNotCanonical("json")
        }
        return text
    }

    /// Document passed to the in-process bridge `Start`. Never injects
    /// freedom / DIRECT. Logging stays quiet without an explicit sink.
    public func embeddedInstanceJSONObject(
        logLevel: AccessLogLevel = .none,
        errorLogPath: String? = nil,
        includeAccessLog: Bool = false
    ) throws -> [String: Any] {
        guard let outbounds = jsonObject["outbounds"] else {
            throw AccessRealityVisionOutboundConfigError.fieldNotCanonical("outbounds")
        }
        // An enabled log must have a controlled sink: Xray otherwise writes
        // to process stdout.
        guard logLevel == .none || (errorLogPath?.hasPrefix("/") == true && errorLogPath != "/") else {
            throw AccessRealityVisionOutboundConfigError.fieldNotCanonical("errorLogPath")
        }
        let log: [String: Any] = [
            "loglevel": logLevel.rawValue,
            "access": logLevel == .none || !includeAccessLog ? "none" : errorLogPath!,
            "error": logLevel == .none ? "none" : errorLogPath!,
        ]
        let root: [String: Any] = [
            "log": log,
            "inbounds": [Any](),
            "outbounds": outbounds,
        ]
        try AccessRealityVisionOutboundConfigBuilder.assertFailClosed(root)
        return root
    }

    public func embeddedInstanceJSONData(
        prettyPrinted: Bool = false,
        logLevel: AccessLogLevel = .none,
        errorLogPath: String? = nil,
        includeAccessLog: Bool = false
    ) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if prettyPrinted {
            options.insert(.prettyPrinted)
        }
        return try JSONSerialization.data(
            withJSONObject: try embeddedInstanceJSONObject(logLevel: logLevel, errorLogPath: errorLogPath, includeAccessLog: includeAccessLog),
            options: options
        )
    }
}
