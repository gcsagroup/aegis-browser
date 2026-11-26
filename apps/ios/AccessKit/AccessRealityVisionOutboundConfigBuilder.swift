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
        let root = try AccessOutboundConfigRegistry.outboundJSONObject(for: .realityVision(parameters))
        return AccessRealityVisionOutboundConfig(parameters: parameters, jsonObject: root)
    }

    static func assertFailClosed(_ root: [String: Any]) throws {
        try AccessOutboundConfigRegistry.assertFailClosed(root, profile: .vlessRawReality)
    }
}
