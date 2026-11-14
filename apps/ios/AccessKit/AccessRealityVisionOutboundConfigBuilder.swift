import Foundation

/// Builds fail-closed Xray JSON for `reality_vision` only.
///
/// Does not load the pinned core binary (F6) and does not start a runtime (F8).
public enum AccessRealityVisionOutboundConfigBuilder {
    /// Generates a client config for the admitted profile.
    public static func build(
        profile: AccessOutboundProfile = .realityVision,
        parameters: AccessRealityVisionParameters
    ) throws -> AccessRealityVisionOutboundConfig {
        guard profile == .realityVision else {
            throw AccessRealityVisionOutboundConfigError.profileNotAdmitted(profile.rawValue)
        }
        return try build(parameters: parameters)
    }

    /// Convenience that parses an outbound profile string first (rejects `ws_tls_compat`).
    public static func build(
        profileRawValue: String,
        parameters: AccessRealityVisionParameters
    ) throws -> AccessRealityVisionOutboundConfig {
        let profile = try AccessOutboundProfile.parse(rawValue: profileRawValue)
        return try build(profile: profile, parameters: parameters)
    }

    public static func build(
        parameters: AccessRealityVisionParameters
    ) throws -> AccessRealityVisionOutboundConfig {
        // Explicit guards keep the admitted matrix visible in one place.
        let flow = AccessRealityVisionParameters.admittedFlow
        let network = AccessRealityVisionParameters.admittedNetwork
        let security = AccessRealityVisionParameters.admittedSecurity
        let encryption = AccessRealityVisionParameters.admittedEncryption

        guard flow == "xtls-rprx-vision" else {
            throw AccessRealityVisionOutboundConfigError.unsupportedFlow(flow)
        }
        guard network == "tcp" else {
            throw AccessRealityVisionOutboundConfigError.unsupportedNetwork(network)
        }
        guard security == "reality" else {
            throw AccessRealityVisionOutboundConfigError.unsupportedSecurity(security)
        }

        let outbound: [String: Any] = [
            "tag": AccessRealityVisionOutboundConfig.outboundTag,
            "protocol": "vless",
            "settings": [
                "vnext": [
                    [
                        "address": parameters.address,
                        "port": Int(parameters.port),
                        "users": [
                            [
                                "id": parameters.userID,
                                "encryption": encryption,
                                "flow": flow,
                            ],
                        ],
                    ],
                ],
            ],
            "streamSettings": [
                "network": network,
                "security": security,
                "realitySettings": [
                    "serverName": parameters.serverName,
                    "fingerprint": parameters.fingerprint,
                    "publicKey": parameters.publicKey,
                    "shortId": parameters.shortID,
                    "spiderX": parameters.spiderX,
                ],
            ],
        ]

        // Never emit allowInsecure / ws settings. Presence of those keys is a hard error
        // if a future edit introduces them accidentally — checked below.
        let root: [String: Any] = [
            "outbounds": [outbound],
        ]
        try assertFailClosed(root)

        return AccessRealityVisionOutboundConfig(parameters: parameters, jsonObject: root)
    }

    /// Scans the generated tree so WS / allowInsecure cannot ship by mistake.
    static func assertFailClosed(_ root: [String: Any]) throws {
        var stack: [Any] = [root]
        while let current = stack.popLast() {
            if let dict = current as? [String: Any] {
                if dict.keys.contains("allowInsecure") {
                    throw AccessRealityVisionOutboundConfigError.allowInsecureRejected
                }
                if let network = dict["network"] as? String, network != "tcp" {
                    throw AccessRealityVisionOutboundConfigError.unsupportedNetwork(network)
                }
                if let security = dict["security"] as? String, security != "reality" {
                    throw AccessRealityVisionOutboundConfigError.unsupportedSecurity(security)
                }
                if let flow = dict["flow"] as? String, flow != "xtls-rprx-vision" {
                    throw AccessRealityVisionOutboundConfigError.unsupportedFlow(flow)
                }
                if dict.keys.contains("wsSettings") {
                    throw AccessRealityVisionOutboundConfigError.unsupportedNetwork("ws")
                }
                stack.append(contentsOf: dict.values)
            } else if let array = current as? [Any] {
                stack.append(contentsOf: array)
            }
        }
    }
}
