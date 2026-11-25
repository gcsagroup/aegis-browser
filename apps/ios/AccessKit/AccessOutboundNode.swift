import Foundation

/// Combination names for the native generator registry. The frozen product
/// contract continues to use AccessOutboundProfile and its original wire values.
public enum AccessOutboundProfileKey: String, Codable, Sendable {
    case vlessRawReality = "vless.raw.reality"
    case vlessWsTls = "vless.ws.tls"

    private static let aliases: [String: Self] = [
        AccessOutboundProfile.realityVision.rawValue: .vlessRawReality,
        AccessOutboundProfile.reservedWsTlsCompat: .vlessWsTls,
        "vless_ws_tls": .vlessWsTls,
    ]

    public init?(profileName: String) {
        guard let key = Self(rawValue: profileName) ?? Self.aliases[profileName] else { return nil }
        self = key
    }
}

/// A validated outbound. Each case binds its endpoint, security, transport,
/// and credentials so invalid cross-combinations cannot be constructed.
public enum AccessOutboundNode: Codable, Equatable, Sendable {
    case realityVision(AccessRealityVisionParameters)
    case vlessWebSocketTLS(AccessVLESSWebSocketTLSParameters)

    public enum Kind: String, Codable, Sendable {
        case vless
    }

    public struct Endpoint: Codable, Equatable, Sendable {
        public let address: String
        public let port: UInt16
    }

    // Keychain v3 stores these enums with Swift's enum Codable layout. The
    // explicit keys below are the stored wire names: renaming a case or label
    // must keep its raw value, or existing v3 records stop decoding.
    public enum Security: Codable, Equatable, Sendable {
        case reality(serverName: String, fingerprint: String, publicKey: String, shortID: String, spiderX: String)
        case tls(serverName: String, fingerprint: String, alpn: String)

        private enum CodingKeys: String, CodingKey {
            case reality = "reality"
            case tls = "tls"
        }
        private enum RealityCodingKeys: String, CodingKey {
            case serverName = "serverName"
            case fingerprint = "fingerprint"
            case publicKey = "publicKey"
            case shortID = "shortID"
            case spiderX = "spiderX"
        }
        private enum TlsCodingKeys: String, CodingKey {
            case serverName = "serverName"
            case fingerprint = "fingerprint"
            case alpn = "alpn"
        }
    }

    public enum Transport: Codable, Equatable, Sendable {
        case raw
        case ws(path: String, host: String)

        private enum CodingKeys: String, CodingKey {
            case raw = "raw"
            case ws = "ws"
        }
        private enum WsCodingKeys: String, CodingKey {
            case path = "path"
            case host = "host"
        }
    }

    public enum Credentials: Codable, Equatable, Sendable {
        case vless(userID: String, encryption: String, flow: String?)

        private enum CodingKeys: String, CodingKey { case vless = "vless" }
        private enum VlessCodingKeys: String, CodingKey {
            case userID = "userID"
            case encryption = "encryption"
            case flow = "flow"
        }
    }

    public var kind: Kind {
        switch self {
        case .realityVision, .vlessWebSocketTLS: .vless
        }
    }

    public var profileKey: AccessOutboundProfileKey {
        switch self {
        case .realityVision: .vlessRawReality
        case .vlessWebSocketTLS: .vlessWsTls
        }
    }

    public var endpoint: Endpoint {
        switch self {
        case .realityVision(let parameters): Endpoint(address: parameters.address, port: parameters.port)
        case .vlessWebSocketTLS(let parameters): Endpoint(address: parameters.address, port: parameters.port)
        }
    }

    public var security: Security {
        switch self {
        case .realityVision(let parameters):
            .reality(serverName: parameters.serverName, fingerprint: parameters.fingerprint,
                     publicKey: parameters.publicKey, shortID: parameters.shortID, spiderX: parameters.spiderX)
        case .vlessWebSocketTLS(let parameters):
            .tls(serverName: parameters.serverName, fingerprint: parameters.fingerprint, alpn: parameters.alpn)
        }
    }

    public var transport: Transport {
        switch self {
        case .realityVision: .raw
        case .vlessWebSocketTLS(let parameters): .ws(path: parameters.path, host: parameters.requestHost)
        }
    }

    public var credentials: Credentials {
        switch self {
        case .realityVision(let parameters):
            .vless(userID: parameters.userID, encryption: AccessRealityVisionParameters.admittedEncryption,
                   flow: AccessRealityVisionParameters.admittedFlow)
        case .vlessWebSocketTLS(let parameters):
            .vless(userID: parameters.userID, encryption: "none", flow: nil)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, endpoint, security, transport, credentials
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try fields.decode(Kind.self, forKey: .kind)
        let endpoint = try fields.decode(Endpoint.self, forKey: .endpoint)
        let security = try fields.decode(Security.self, forKey: .security)
        let transport = try fields.decode(Transport.self, forKey: .transport)
        let credentials = try fields.decode(Credentials.self, forKey: .credentials)

        switch (kind, security, transport, credentials) {
        // Stored v3 REALITY records carry the Vision flow. A change to the
        // admitted flow requires a migration for those records.
        case (.vless, .reality(let serverName, let fingerprint, let publicKey, let shortID, let spiderX),
              .raw, .vless(let userID, AccessRealityVisionParameters.admittedEncryption,
                          AccessRealityVisionParameters.admittedFlow?)):
            self = .realityVision(try AccessRealityVisionParameters(
                address: endpoint.address, port: endpoint.port, userID: userID, serverName: serverName,
                publicKey: publicKey, shortID: shortID, fingerprint: fingerprint, spiderX: spiderX
            ))
        case (.vless, .tls(let serverName, let fingerprint, let alpn), .ws(let path, let host),
              .vless(let userID, "none", nil)):
            self = .vlessWebSocketTLS(try AccessVLESSWebSocketTLSParameters(
                address: endpoint.address, port: endpoint.port, userID: userID, serverName: serverName,
                requestHost: host, path: path, fingerprint: fingerprint, alpn: alpn
            ))
        default:
            throw AccessLocalV2RayConfigError.invalidJSON
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(kind, forKey: .kind)
        try fields.encode(endpoint, forKey: .endpoint)
        try fields.encode(security, forKey: .security)
        try fields.encode(transport, forKey: .transport)
        try fields.encode(credentials, forKey: .credentials)
    }
}
