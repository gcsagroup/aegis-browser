import Foundation

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

    /// Document passed to the in-process bridge `Start`. Adds empty inbounds and
    /// quiet logging; never injects freedom / DIRECT.
    public func embeddedInstanceJSONObject() throws -> [String: Any] {
        guard let outbounds = jsonObject["outbounds"] else {
            throw AccessRealityVisionOutboundConfigError.fieldNotCanonical("outbounds")
        }
        let root: [String: Any] = [
            "log": ["loglevel": "none"],
            "inbounds": [Any](),
            "outbounds": outbounds,
        ]
        try AccessRealityVisionOutboundConfigBuilder.assertFailClosed(root)
        return root
    }

    public func embeddedInstanceJSONData(prettyPrinted: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if prettyPrinted {
            options.insert(.prettyPrinted)
        }
        return try JSONSerialization.data(
            withJSONObject: try embeddedInstanceJSONObject(),
            options: options
        )
    }
}
