import CoreFoundation
import Foundation
import Network

/// Compatibility name for the native DEV/internal Alpha single-node path.
public typealias AccessInternalTestNode = AccessOutboundNode

extension AccessOutboundNode {
    public static func parseSingleShareURI(_ input: String) throws -> Self {
        guard input.utf8.count <= 8_192 else { throw AccessLocalV2RayConfigError.invalidJSON }
        let link = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = link.range(of: "://").map({ link[..<$0.lowerBound].lowercased() }),
           ["vmess", "trojan", "hysteria2", "hy2"].contains(scheme) {
            return .additionalTLS(try AccessAdditionalTLSParameters.parse(link, scheme: scheme))
        }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard link.lowercased().hasPrefix("vless://"),
              link.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else {
            throw AccessLocalV2RayConfigError.invalidJSON
        }
        let uri = link.prefix(while: { $0 != "#" })
        let share = String(uri)
        let hints = URLComponents(string: share)?.queryItems ?? []
        let permitted: Set<String>
        if hints.contains(where: { $0.name == "type" && $0.value == "ws" }) {
            permitted = ["type", "security", "host", "sni", "fp", "path", "encryption", "alpn"]
        } else if hints.contains(where: { $0.name == "type" && $0.value == "grpc" }) {
            permitted = ["type", "security", "sni", "fp", "path", "serviceName", "pbk", "sid", "encryption"]
        } else if hints.contains(where: { $0.name == "security" && $0.value == "tls" }) {
            permitted = ["type", "security", "host", "sni", "fp", "flow", "headerType", "encryption"]
        } else {
            do {
                return .realityVision(try AccessLocalV2RayConfigLoader.parseSingleShareURI(input))
            } catch AccessLocalV2RayConfigError.unsupportedNetwork,
                    AccessLocalV2RayConfigError.unsupportedSecurity,
                    AccessLocalV2RayConfigError.unsupportedFlow {
                // The legacy errors carry the query value. Never surface it from an internal share.
                throw AccessLocalV2RayConfigError.invalidJSON
            }
        }
        // Only a WS request target may contain a nested URL. The display label
        // is discarded, but may not contain a concatenated link.
        guard !link[uri.endIndex...].contains("://"),
              let components = URLComponents(string: share, encodingInvalidCharacters: false),
              components.percentEncodedPassword == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/" else {
            throw AccessLocalV2RayConfigError.invalidJSON
        }
        let items = components.queryItems ?? []
        let names = Set(items.map(\.name))
        guard names.count == items.count, names.isSubset(of: permitted),
              items.allSatisfy({ $0.value != nil }),
              let host = components.encodedHost,
              let address = AccessInternalNodeFields.dialAddress(from: host),
              let rawPort = components.port, let port = UInt16(exactly: rawPort),
              let id = components.user else { throw AccessLocalV2RayConfigError.invalidJSON }
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard [nil, "", "none"].contains(query["encryption"]), let serverName = query["sni"] else {
            throw AccessLocalV2RayConfigError.invalidJSON
        }
        switch (query["type"], query["security"]) {
        case ("ws", "tls"):
            return .vlessWebSocketTLS(try AccessVLESSWebSocketTLSParameters(
                address: address, port: port, userID: id, serverName: serverName,
                requestHost: query["host"] ?? serverName, path: query["path"] ?? "/",
                fingerprint: query["fp"] ?? "", alpn: query["alpn"] ?? ""
            ))
        case ("tcp", "tls"):
            let hostHint = query["host"] ?? ""
            // RAW with no header has no HTTP Host. Only the explicit SNI goes to TLS.
            guard query["flow"] == AccessRealityVisionParameters.admittedFlow,
                  (query["headerType"] ?? "none") == "none",
                  hostHint.isEmpty || AccessInternalNodeFields.isHTTPAuthority(hostHint) else {
                throw AccessLocalV2RayConfigError.invalidJSON
            }
            return .vlessTCPTLSVision(try AccessVLESSTCPTLSVisionParameters(
                address: address, port: port, userID: id, serverName: serverName,
                fingerprint: query["fp"] ?? AccessRealityVisionParameters.defaultFingerprint
            ))
        case ("grpc", "reality"):
            guard let serviceName = query["serviceName"] ?? query["path"],
                  (query["path"] ?? serviceName).utf8.elementsEqual(serviceName.utf8),
                  let publicKey = query["pbk"], let shortID = query["sid"] else {
                throw AccessLocalV2RayConfigError.invalidJSON
            }
            return .vlessGRPCReality(try AccessVLESSGRPCRealityParameters(
                address: address, port: port, userID: id, serverName: serverName, publicKey: publicKey,
                shortID: shortID, fingerprint: query["fp"] ?? AccessRealityVisionParameters.defaultFingerprint,
                serviceName: serviceName
            ))
        default:
            throw AccessLocalV2RayConfigError.invalidJSON
        }
    }
}

extension AccessOutboundNode {
    var diagnosticSecrets: [String] {
        switch self {
        case .realityVision(let parameters):
            [parameters.userID, AccessDiagnosticLog.relayFilter(parameters.address), parameters.publicKey, parameters.shortID]
        case .vlessWebSocketTLS(let parameters): parameters.diagnosticSecrets
        case .vlessTCPTLSVision(let parameters): parameters.diagnosticSecrets
        case .vlessGRPCReality(let parameters): parameters.diagnosticSecrets
        case .additionalTLS(let parameters): parameters.diagnosticSecrets
        }
    }

    /// Swift `String` equality is canonical equivalence. Route authorization
    /// compares exact UTF-8 bytes after applying Xray's fingerprint case normalization.
    public func isWireIdentical(to other: Self) -> Bool {
        let lhs = wireFields, rhs = other.wireFields
        return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    private var wireFields: [String] {
        switch self {
        case .realityVision(let p):
            ["reality", p.address, String(p.port), p.userID, p.serverName, p.publicKey, p.shortID, p.spiderX, p.fingerprint.lowercased()]
        case .vlessWebSocketTLS(let p):
            ["ws-tls", p.address, String(p.port), p.userID, p.serverName, p.requestHost, p.path, p.fingerprint, p.alpn]
        case .vlessTCPTLSVision(let p):
            ["tcp-tls-vision", p.address, String(p.port), p.userID, p.serverName, p.fingerprint.lowercased()]
        case .vlessGRPCReality(let p):
            ["grpc-reality", p.address, String(p.port), p.userID, p.serverName, p.publicKey, p.shortID,
             p.fingerprint.lowercased(), p.serviceName]
        case .additionalTLS(let parameters): parameters.wireFields
        }
    }
}

private enum AccessInternalNodeFields {
    static func dialAddress(from encodedHost: String) -> String? {
        if encodedHost.hasPrefix("[") { return encodedHost }
        guard let host = encodedHost.removingPercentEncoding else { return nil }
        if host.utf8.allSatisfy({ $0 < 128 }) { return host }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        return components.encodedHost
    }

    static func endpoint(address: String, port: UInt16, userID: String) throws -> (address: String, userID: String) {
        guard let uuid = UUID(uuidString: userID) else { throw AccessLocalV2RayConfigError.invalidJSON }
        return (try addressForDial(address, port: port), uuid.uuidString.lowercased())
    }

    static func addressForDial(_ address: String, port: UInt16) throws -> String {
        guard port != 0, !address.contains("%") else {
            throw AccessLocalV2RayConfigError.fieldNotCanonical("address")
        }
        let normalizedAddress: String
        if address.hasPrefix("[") {
            guard address.hasSuffix("]"), let literal = ipv6Literal(address) else {
                throw AccessLocalV2RayConfigError.fieldNotCanonical("address")
            }
            normalizedAddress = literal
        } else {
            guard isDNSName(address, allowsRootLabel: true) || IPv4Address(address) != nil || IPv6Address(address) != nil else {
                throw AccessLocalV2RayConfigError.fieldNotCanonical("address")
            }
            normalizedAddress = address
        }
        return normalizedAddress
    }

    static func isDNSName(_ name: String, allowsRootLabel: Bool = false) -> Bool {
        let hostname = allowsRootLabel && name.hasSuffix(".") ? name.dropLast() : name[...]
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        return hostname.utf8.count <= 253 && labels.count >= 2
            && labels.last?.utf8.contains(where: { (65...90).contains($0) || (97...122).contains($0) }) == true
            && labels.allSatisfy { label in
                (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
                        || (48...57).contains($0) || $0 == 45 }
            }
    }

    private static func ipv6Literal(_ bracketed: String) -> String? {
        let value = String(bracketed.dropFirst().dropLast())
        guard !value.contains("%"), IPv6Address(value) != nil else { return nil }
        return value
    }

    static func isHTTPAuthority(_ authority: String) -> Bool {
        guard !authority.contains("%") else { return false }
        let hostEnd: String.Index
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return false }
            hostEnd = authority.index(after: close)
            guard ipv6Literal(String(authority[..<hostEnd])) != nil else { return false }
        } else {
            hostEnd = authority.firstIndex(of: ":") ?? authority.endIndex
            let host = String(authority[..<hostEnd])
            guard isDNSName(host, allowsRootLabel: true) || IPv4Address(host) != nil else { return false }
        }
        let suffix = authority[hostEnd...]
        if suffix.isEmpty { return true }
        let digits = suffix.dropFirst()
        guard suffix.first == ":", digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = UInt16(digits), port > 0 else { return false }
        return true
    }
}

public struct AccessVLESSWebSocketTLSParameters: Equatable, Sendable {
    public let address: String
    public let port: UInt16
    public let userID: String
    public let serverName: String
    public let requestHost: String
    public let path: String
    public let fingerprint: String
    public let alpn: String

    public init(address: String, port: UInt16, userID: String, serverName: String,
                requestHost: String, path: String, fingerprint: String, alpn: String) throws {
        let endpoint = try AccessInternalNodeFields.endpoint(address: address, port: port, userID: userID)
        guard AccessInternalNodeFields.isDNSName(serverName), AccessInternalNodeFields.isHTTPAuthority(requestHost) else {
            throw AccessLocalV2RayConfigError.fieldNotCanonical("tls-host")
        }
        guard Self.isWebSocketRequestTarget(path) else {
            throw AccessLocalV2RayConfigError.fieldNotCanonical("path")
        }
        guard ["", "chrome", "firefox", "safari", "ios", "android", "edge"].contains(fingerprint),
              ["", "http/1.1"].contains(alpn) else { throw AccessLocalV2RayConfigError.invalidJSON }
        self.address = endpoint.address
        self.port = port
        self.userID = endpoint.userID
        self.serverName = serverName
        self.requestHost = requestHost
        self.path = path
        self.fingerprint = fingerprint
        self.alpn = alpn
    }

    fileprivate static func isWebSocketRequestTarget(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("#"), !path.contains("\\"),
              path.utf8.count <= 2_048, path.utf8.allSatisfy({ (33...126).contains($0) }),
              let decoded = decodedRequestTargetForValidation(path),
              URLComponents(string: path, encodingInvalidCharacters: false)?.string == path else { return false }
        // A callback URL can be a path value. A second proxy share cannot.
        let withoutWebSchemes = decoded.replacingOccurrences(of: #"(?i)(?<![a-z0-9+.-])https?://"#, with: "",
                                                         options: .regularExpression)
        guard withoutWebSchemes.range(of: #"[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) == nil else {
            return false
        }
        guard let query = path.firstIndex(of: "?") else { return true }
        // Decode names independently to match Xray's Go query lookup even
        // when an unrelated value contains an opaque, non-UTF-8 octet.
        return path[path.index(after: query)...].split(separator: "&").allSatisfy { field in
            let name = String(field.prefix(while: { $0 != "=" }))
            return name.removingPercentEncoding != "ed"
        }
    }

    /// Classify nested schemes without altering the original wire target.
    private static func decodedRequestTargetForValidation(_ path: String) -> String? {
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: byte - 48
            case 65...70: byte - 55
            case 97...102: byte - 87
            default: nil
            }
        }
        var input = path.utf8.makeIterator()
        var decoded: [UInt8] = []
        while let byte = input.next() {
            if byte == 37 {
                guard let high = input.next().flatMap(nibble), let low = input.next().flatMap(nibble) else { return nil }
                let unescaped = (high << 4) | low
                guard unescaped >= 32, unescaped != 127 else { return nil }
                decoded.append(unescaped)
            } else {
                decoded.append(byte)
            }
        }
        return String(decoding: decoded, as: UTF8.self)
    }
}

extension AccessVLESSWebSocketTLSParameters {
    var diagnosticSecrets: [String] { [userID, AccessDiagnosticLog.relayFilter(address)] }
}

public struct AccessVLESSTCPTLSVisionParameters: Equatable, Sendable {
    public let address: String
    public let port: UInt16
    public let userID: String
    public let serverName: String
    public let fingerprint: String

    public init(address: String, port: UInt16, userID: String, serverName: String,
                fingerprint: String = AccessRealityVisionParameters.defaultFingerprint) throws {
        let endpoint = try AccessInternalNodeFields.endpoint(address: address, port: port, userID: userID)
        guard AccessInternalNodeFields.isDNSName(serverName) else {
            throw AccessLocalV2RayConfigError.fieldNotCanonical("tls-host")
        }
        try AccessGoEmbeddedCore.validateRealityClientFields(fingerprint: fingerprint, spiderX: "")
        self.address = endpoint.address
        self.port = port
        self.userID = endpoint.userID
        self.serverName = serverName
        self.fingerprint = fingerprint
    }
}

extension AccessVLESSTCPTLSVisionParameters {
    var diagnosticSecrets: [String] { [userID, AccessDiagnosticLog.relayFilter(address), serverName] }
}

public struct AccessVLESSGRPCRealityParameters: Equatable, Sendable {
    public let address: String
    public let port: UInt16
    public let userID: String
    public let serverName: String
    public let publicKey: String
    public let shortID: String
    public let fingerprint: String
    public let serviceName: String

    public init(address: String, port: UInt16, userID: String, serverName: String, publicKey: String,
                shortID: String, fingerprint: String = AccessRealityVisionParameters.defaultFingerprint,
                serviceName: String) throws {
        let endpoint = try AccessInternalNodeFields.endpoint(address: address, port: port, userID: userID)
        guard AccessInternalNodeFields.isDNSName(serverName) else {
            throw AccessLocalV2RayConfigError.fieldNotCanonical("serverName")
        }
        guard Self.isServiceName(serviceName) else { throw AccessLocalV2RayConfigError.fieldNotCanonical("serviceName") }
        // The REALITY fields have the same constraints regardless of the transport.
        let reality = try AccessRealityVisionParameters(address: endpoint.address, port: port, userID: endpoint.userID,
            serverName: serverName, publicKey: publicKey, shortID: shortID, fingerprint: fingerprint)
        try AccessLocalV2RayConfigLoader.validateManualParameters(reality)
        self.address = reality.address
        self.port = reality.port
        self.userID = reality.userID
        self.serverName = reality.serverName
        self.publicKey = reality.publicKey
        self.shortID = reality.shortID
        self.fingerprint = reality.fingerprint
        self.serviceName = serviceName
    }

    private static func isServiceName(_ name: String) -> Bool {
        guard (1...2_048).contains(name.utf8.count) else { return false }
        // Xray also accepts literal custom service/method paths beginning with '/'.
        let parts = (name.hasPrefix("/") ? name.dropFirst() : name[...]).split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || $0 == 45 || $0 == 46 || $0 == 95 || $0 == 126
            }
        }
    }
}

extension AccessVLESSGRPCRealityParameters {
    var diagnosticSecrets: [String] {
        [userID, AccessDiagnosticLog.relayFilter(address), serverName, publicKey, shortID, serviceName]
    }
}

extension AccessOutboundNode {
    /// The built-in test catalogue is tied to the signed single-account anchor.
    /// Password protocols still compare the credential's exact bytes for route membership.
    public var testSubscriptionIdentity: UUID? {
        switch credentials {
        case .vless(let id, _, _), .vmess(let id, _): UUID(uuidString: id)
        case .trojan(let password), .hysteria2(let password): UUID(uuidString: password)
        }
    }

    public var protocolDisplayName: String {
        switch profileKey {
        case .vlessRawReality: "VLESS / TCP / REALITY / Vision"
        case .vlessRawTls: "VLESS / TCP / TLS / Vision"
        case .vlessWsTls: "VLESS / WS / TLS"
        case .vlessGrpcReality: "VLESS / gRPC / REALITY"
        case .vmessWsTls: "VMess / WS / TLS"
        case .vmessHTTPUpgradeTLS: "VMess / HTTPUpgrade / TLS"
        case .trojanRawTLS: "Trojan / TCP / TLS"
        case .hysteria2: "Hysteria2 / QUIC / TLS"
        }
    }
}

public struct AccessAdditionalTLSParameters: Equatable, Sendable {
    typealias Node = AccessOutboundNode

    let kind: Node.Kind
    let profileKey: AccessOutboundProfileKey
    let endpoint: Node.Endpoint
    let serverName: String
    let fingerprint: String
    let alpn: String
    let transport: Node.Transport
    let credentials: Node.Credentials

    var security: Node.Security { .tls(serverName: serverName, fingerprint: fingerprint, alpn: alpn) }

    var secret: String {
        switch credentials {
        case .vless(let id, _, _), .vmess(let id, _): id
        case .trojan(let password), .hysteria2(let password): password
        }
    }

    var diagnosticSecrets: [String] {
        [secret, AccessDiagnosticLog.relayFilter(endpoint.address), serverName]
    }

    var wireFields: [String] {
        let route = [profileKey.rawValue, endpoint.address, String(endpoint.port), serverName, fingerprint, alpn, secret]
        switch (transport, credentials) {
        case (.ws(let path, let host), .vmess(_, let cipher)),
             (.httpupgrade(let path, let host), .vmess(_, let cipher)):
            return route + [path, host, cipher]
        case (.hysteria(let up, let down), .hysteria2):
            return route + [String(up), String(down)]
        default:
            return route
        }
    }

    private static let invalid = AccessLocalV2RayConfigError.invalidJSON
    private static let fingerprints = ["", "chrome", "firefox", "safari", "ios", "android", "edge"]
    private static let ciphers = ["auto", "aes-128-gcm", "chacha20-poly1305"]

    init(endpoint: Node.Endpoint, security: Node.Security, transport: Node.Transport, credentials: Node.Credentials) throws {
        guard case .tls(let serverName, let fingerprint, let alpn) = security,
              AccessInternalNodeFields.isDNSName(serverName), Self.fingerprints.contains(fingerprint) else {
            throw Self.invalid
        }

        switch (transport, credentials) {
        case (.ws(let path, let host), .vmess(let id, let cipher)),
             (.httpupgrade(let path, let host), .vmess(let id, let cipher)):
            guard let userID = UUID(uuidString: id)?.uuidString.lowercased(),
                  Self.ciphers.contains(cipher), alpn == "http/1.1",
                  AccessInternalNodeFields.isHTTPAuthority(host),
                  AccessVLESSWebSocketTLSParameters.isWebSocketRequestTarget(path) else { throw Self.invalid }
            kind = .vmess
            if case .ws = transport { profileKey = .vmessWsTls } else { profileKey = .vmessHTTPUpgradeTLS }
            self.credentials = .vmess(userID: userID, security: cipher)
        case (.raw, .trojan(let password)):
            guard Self.validPassword(password), alpn == "http/1.1" else { throw Self.invalid }
            kind = .trojan
            profileKey = .trojanRawTLS
            self.credentials = credentials
        case (.hysteria(let up, let down), .hysteria2(let password)):
            guard Self.validPassword(password), alpn == "h3", fingerprint.isEmpty,
                  (0...100_000).contains(up), (0...100_000).contains(down) else { throw Self.invalid }
            kind = .hysteria2
            profileKey = .hysteria2
            self.credentials = credentials
        default:
            throw Self.invalid
        }

        let address = try AccessInternalNodeFields.addressForDial(endpoint.address, port: endpoint.port)
        self.endpoint = .init(address: address, port: endpoint.port)
        self.serverName = serverName
        self.fingerprint = fingerprint
        self.alpn = alpn
        self.transport = transport
    }

    private static func validPassword(_ password: String) -> Bool {
        (1...256).contains(password.utf8.count) && password.utf8.allSatisfy { (33...126).contains($0) }
    }

    fileprivate static func parse(_ link: String, scheme: String) throws -> Self {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        let share = link.prefix(while: { $0 != "#" })
        guard link.utf8.count <= 8_192, link.unicodeScalars.allSatisfy({ !forbidden.contains($0) }),
              !link[share.endIndex...].contains("://"), !link.contains("\\"),
              share.utf8.allSatisfy({ $0 < 128 }) else { throw invalid }
        if scheme == "vmess" { return try parseVMess(share.dropFirst(scheme.count + 3)) }

        guard let uri = URLComponents(string: String(share), encodingInvalidCharacters: false),
              uri.percentEncodedPassword == nil, ["", "/"].contains(uri.percentEncodedPath),
              let host = uri.encodedHost, let address = AccessInternalNodeFields.dialAddress(from: host),
              let port = uri.port.flatMap(UInt16.init(exactly:)), let password = uri.user else { throw invalid }
        let items = uri.queryItems ?? []
        let names = Set(items.map(\.name))
        let trojan = scheme == "trojan"
        let allowed: Set<String> = trojan
            ? ["sni", "peer", "alpn", "fp", "type", "security"]
            : ["sni", "peer", "alpn", "insecure", "upmbps", "downmbps"]
        guard names.count == items.count, names.isSubset(of: allowed), items.allSatisfy({ $0.value != nil }) else {
            throw invalid
        }
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        let name = try tlsName(sni: query["sni"], peer: query["peer"], fallback: address)
        let endpoint = Node.Endpoint(address: address, port: port)
        if trojan {
            guard [nil, "tcp", "raw"].contains(query["type"]), [nil, "tls"].contains(query["security"]) else {
                throw invalid
            }
            return try Self(endpoint: endpoint, security: .tls(serverName: name, fingerprint: query["fp"] ?? "",
                                                               alpn: query["alpn"] ?? "http/1.1"),
                            transport: .raw, credentials: .trojan(password: password))
        }
        guard [nil, "0"].contains(query["insecure"]) else { throw invalid }
        return try Self(endpoint: endpoint, security: .tls(serverName: name, fingerprint: "", alpn: query["alpn"] ?? "h3"),
                        transport: .hysteria(upMbps: try digits(query["upmbps"] ?? "0"),
                                             downMbps: try digits(query["downmbps"] ?? "0")),
                        credentials: .hysteria2(password: password))
    }

    private static func parseVMess(_ payload: Substring) throws -> Self {
        let base = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - base.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: base + padding), let json = String(data: data, encoding: .utf8),
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalid }
        // Tokenize strings whole, so a colon inside a string is never mistaken for a key.
        let strings = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"\s*(:)?"#)
        let keys = strings.matches(in: json, range: NSRange(json.startIndex..., in: json))
            .filter { $0.range(at: 1).location != NSNotFound }
        let allowed: Set<String> = ["v", "ps", "add", "port", "id", "aid", "net", "type", "host", "path",
                                    "tls", "sni", "peer", "fp", "alpn", "scy", "method"]
        guard keys.count == fields.count, Set(fields.keys).isSubset(of: allowed),
              fields.allSatisfy({ ["port", "v", "aid"].contains($0.key) || $0.value is String }),
              ["2", nil].contains(try scalar(fields["v"])),
              ["0", nil].contains(try scalar(fields["aid"])),
              let address = fields["add"] as? String, let port = UInt16(exactly: try digits(try scalar(fields["port"]) ?? "", maxDigits: 5)),
              let id = fields["id"] as? String, let network = fields["net"] as? String,
              ["ws", "httpupgrade"].contains(network), fields["tls"] as? String == "tls",
              [nil, "", "none"].contains(fields["type"] as? String) else { throw invalid }
        let name = try tlsName(sni: fields["sni"] as? String, peer: fields["peer"] as? String, fallback: address)
        let host = nonempty(fields["host"] as? String) ?? name
        let path = nonempty(fields["path"] as? String) ?? "/"
        let transport: Node.Transport = network == "ws" ? .ws(path: path, host: host) : .httpupgrade(path: path, host: host)
        let primary = nonempty(fields["scy"] as? String)
        let alternate = nonempty(fields["method"] as? String)
        guard primary == nil || alternate == nil || primary == alternate else { throw invalid }
        let cipher = primary ?? alternate ?? "auto"
        guard ciphers.contains(cipher) else { throw AccessLocalV2RayConfigError.unsupportedVMessCipher }
        return try Self(endpoint: .init(address: address, port: port),
                        security: .tls(serverName: name, fingerprint: fields["fp"] as? String ?? "",
                                       alpn: nonempty(fields["alpn"] as? String) ?? "http/1.1"),
                        transport: transport, credentials: .vmess(userID: id, security: cipher))
    }

    private static func nonempty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func tlsName(sni: String?, peer: String?, fallback: String) throws -> String {
        let sni = nonempty(sni)
        let peer = nonempty(peer)
        guard sni == nil || peer == nil || sni == peer else { throw invalid }
        return sni ?? peer ?? fallback
    }

    private static func digits(_ value: String, maxDigits: Int = 6) throws -> Int {
        guard (1...maxDigits).contains(value.utf8.count), value.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(value) else { throw invalid }
        return number
    }

    private static func scalar(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           !CFNumberIsFloatType(number as CFNumber) { return number.stringValue }
        throw invalid
    }
}
