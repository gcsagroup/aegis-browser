import Foundation

/// Combination names for the native generator registry. The frozen product
/// contract continues to use AccessOutboundProfile and its original wire values.
public enum AccessOutboundProfileKey: String, Codable, Sendable {
    case vlessRawReality = "vless.raw.reality"
    case vlessWsTls = "vless.ws.tls"
    case vlessRawTls = "vless.raw.tls"
    case vlessGrpcReality = "vless.grpc.reality"

    case vmessWsTls = "vmess.ws.tls"
    case vmessHTTPUpgradeTLS = "vmess.httpupgrade.tls"
    case trojanRawTLS = "trojan.raw.tls"
    case hysteria2 = "hysteria2"

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
    case vlessTCPTLSVision(AccessVLESSTCPTLSVisionParameters)
    case vlessGRPCReality(AccessVLESSGRPCRealityParameters)

    case additionalTLS(AccessAdditionalTLSParameters)

    public enum Kind: String, Codable, Sendable {
        case vless, vmess, trojan, hysteria2
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
        case grpc(serviceName: String)
        case httpupgrade(path: String, host: String)
        case hysteria(upMbps: Int, downMbps: Int)

        private enum CodingKeys: String, CodingKey {
            case raw = "raw"
            case ws = "ws"
            case grpc = "grpc"
            case httpupgrade, hysteria
        }
        private enum WsCodingKeys: String, CodingKey {
            case path = "path"
            case host = "host"
        }
        private enum HttpupgradeCodingKeys: String, CodingKey { case path, host }
        private enum HysteriaCodingKeys: String, CodingKey { case upMbps, downMbps }
        private enum GrpcCodingKeys: String, CodingKey {
            case serviceName = "serviceName"
        }
    }

    public enum Credentials: Codable, Equatable, Sendable {
        case vless(userID: String, encryption: String, flow: String?)

        case vmess(userID: String, security: String)
        case trojan(password: String)
        case hysteria2(password: String)

        private enum CodingKeys: String, CodingKey { case vless, vmess, trojan, hysteria2 }
        private enum VmessCodingKeys: String, CodingKey { case userID, security }
        private enum TrojanCodingKeys: String, CodingKey { case password }
        private enum Hysteria2CodingKeys: String, CodingKey { case password }
        private enum VlessCodingKeys: String, CodingKey {
            case userID = "userID"
            case encryption = "encryption"
            case flow = "flow"
        }
    }

    public var kind: Kind {
        if case .additionalTLS(let parameters) = self { return parameters.kind }
        return .vless
    }

    public var profileKey: AccessOutboundProfileKey {
        switch self {
        case .realityVision: .vlessRawReality
        case .vlessWebSocketTLS: .vlessWsTls
        case .vlessTCPTLSVision: .vlessRawTls
        case .vlessGRPCReality: .vlessGrpcReality
        case .additionalTLS(let parameters): parameters.profileKey
        }
    }

    public var endpoint: Endpoint {
        switch self {
        case .realityVision(let parameters): Endpoint(address: parameters.address, port: parameters.port)
        case .vlessWebSocketTLS(let parameters): Endpoint(address: parameters.address, port: parameters.port)
        case .vlessTCPTLSVision(let parameters): Endpoint(address: parameters.address, port: parameters.port)
        case .vlessGRPCReality(let parameters): Endpoint(address: parameters.address, port: parameters.port)
        case .additionalTLS(let parameters): parameters.endpoint
        }
    }

    public var security: Security {
        switch self {
        case .additionalTLS(let parameters): parameters.security
        case .realityVision(let parameters):
            .reality(serverName: parameters.serverName, fingerprint: parameters.fingerprint,
                     publicKey: parameters.publicKey, shortID: parameters.shortID, spiderX: parameters.spiderX)
        case .vlessWebSocketTLS(let parameters):
            .tls(serverName: parameters.serverName, fingerprint: parameters.fingerprint, alpn: parameters.alpn)
        case .vlessTCPTLSVision(let parameters):
            .tls(serverName: parameters.serverName, fingerprint: parameters.fingerprint, alpn: "")
        case .vlessGRPCReality(let parameters):
            .reality(serverName: parameters.serverName, fingerprint: parameters.fingerprint,
                     publicKey: parameters.publicKey, shortID: parameters.shortID, spiderX: "")
        }
    }

    public var transport: Transport {
        switch self {
        case .realityVision, .vlessTCPTLSVision: .raw
        case .vlessWebSocketTLS(let parameters): .ws(path: parameters.path, host: parameters.requestHost)
        case .vlessGRPCReality(let parameters): .grpc(serviceName: parameters.serviceName)
        case .additionalTLS(let parameters): parameters.transport
        }
    }

    public var credentials: Credentials {
        switch self {
        case .additionalTLS(let parameters): parameters.credentials
        case .realityVision(let parameters):
            .vless(userID: parameters.userID, encryption: AccessRealityVisionParameters.admittedEncryption,
                   flow: AccessRealityVisionParameters.admittedFlow)
        case .vlessWebSocketTLS(let parameters):
            .vless(userID: parameters.userID, encryption: "none", flow: nil)
        case .vlessTCPTLSVision(let parameters):
            .vless(userID: parameters.userID, encryption: AccessRealityVisionParameters.admittedEncryption,
                   flow: AccessRealityVisionParameters.admittedFlow)
        case .vlessGRPCReality(let parameters):
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
        case (.vless, .tls(let serverName, let fingerprint, ""), .raw,
              .vless(let userID, AccessRealityVisionParameters.admittedEncryption,
                          AccessRealityVisionParameters.admittedFlow?)):
            self = .vlessTCPTLSVision(try AccessVLESSTCPTLSVisionParameters(
                address: endpoint.address, port: endpoint.port, userID: userID,
                serverName: serverName, fingerprint: fingerprint
            ))
        case (.vless, .reality(let serverName, let fingerprint, let publicKey, let shortID, ""),
              .grpc(let serviceName), .vless(let userID, "none", nil)):
            self = .vlessGRPCReality(try AccessVLESSGRPCRealityParameters(
                address: endpoint.address, port: endpoint.port, userID: userID, serverName: serverName,
                publicKey: publicKey, shortID: shortID, fingerprint: fingerprint, serviceName: serviceName
            ))
        case (.vmess, .tls, .ws, .vmess), (.vmess, .tls, .httpupgrade, .vmess),
             (.trojan, .tls, .raw, .trojan), (.hysteria2, .tls, .hysteria, .hysteria2):
            self = .additionalTLS(try AccessAdditionalTLSParameters(endpoint: endpoint, security: security,
                                                                  transport: transport, credentials: credentials))
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
