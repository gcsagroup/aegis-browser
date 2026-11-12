import Foundation

/// Material resolved from a local V2Ray / Xray client config for Access testing.
///
/// Secrets may be present in `parameters`; never log them. This type does not
/// start Xray or open product traffic.
public struct AccessLocalV2RayConfig: Sendable, Equatable {
    public static let environmentVariable = "AEGIS_ACCESS_LOCAL_V2RAY_CONFIG"
    public static let liveProbeEnvironmentVariable = "AEGIS_ACCESS_LOCAL_V2RAY_LIVE"
    public static let localAuthorizationID = "local-v2ray"

    public let sourcePath: String
    public let parameters: AccessRealityVisionParameters

    public init(sourcePath: String, parameters: AccessRealityVisionParameters) {
        self.sourcePath = sourcePath
        self.parameters = parameters
    }

    /// Controlled-node target derived from the imported outbound endpoint.
    public func probeTarget() throws -> AccessRealityProbeTarget {
        try AccessRealityProbeTarget(
            host: parameters.address,
            port: parameters.port,
            authorizationID: Self.localAuthorizationID
        )
    }
}
