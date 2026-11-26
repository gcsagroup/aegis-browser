import Foundation
import Network

/// Compatibility name for the native DEV/internal Alpha single-node path.
public typealias AccessInternalTestNode = AccessOutboundNode

extension AccessOutboundNode {
    public static func parseSingleShareURI(_ input: String) throws -> Self {
        let link = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard input.utf8.count <= 8_192,
              link.lowercased().hasPrefix("vless://"),
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
        guard !address.contains("%") else {
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
        guard port != 0, let uuid = UUID(uuidString: userID) else { throw AccessLocalV2RayConfigError.invalidJSON }
        return (normalizedAddress, uuid.uuidString.lowercased())
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

    private static func isWebSocketRequestTarget(_ path: String) -> Bool {
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
