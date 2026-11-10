import Foundation

/// SOCKS5 no-auth greeting + CONNECT request parser (RFC 1928 subset).
///
/// Admitted: version 5, method `0x00`, command CONNECT.
/// Rejected: username/password (`0x02`), BIND, UDP ASSOCIATE.
public enum AccessSOCKS5InboundParser {
    public static let version: UInt8 = 0x05
    public static let methodNoAuth: UInt8 = 0x00
    public static let methodUsernamePassword: UInt8 = 0x02
    public static let methodNoneAcceptable: UInt8 = 0xFF
    public static let commandConnect: UInt8 = 0x01
    public static let atypIPv4: UInt8 = 0x01
    public static let atypDomain: UInt8 = 0x03
    public static let atypIPv6: UInt8 = 0x04
    public static let replySucceeded: UInt8 = 0x00
    public static let replyCommandNotSupported: UInt8 = 0x07
    public static let replyAddressNotSupported: UInt8 = 0x08

    /// Returns selected method bytes once the greeting is complete.
    public static func parseGreeting(buffer: Data) throws -> Data? {
        guard !buffer.isEmpty else { return nil }
        guard buffer[0] == version else {
            throw AccessSOCKS5InboundError.malformedGreeting
        }
        guard buffer.count >= 2 else { return nil }
        let nmethods = Int(buffer[1])
        let total = 2 + nmethods
        guard buffer.count >= total else { return nil }
        guard nmethods > 0 else {
            throw AccessSOCKS5InboundError.malformedGreeting
        }
        let methods = buffer.subdata(in: 2..<total)
        if methods.contains(methodNoAuth) {
            return Data([version, methodNoAuth])
        }
        if methods.contains(methodUsernamePassword) && !methods.contains(methodNoAuth) {
            throw AccessSOCKS5InboundError.usernamePasswordNotAdmitted
        }
        throw AccessSOCKS5InboundError.noAcceptableAuthMethod
    }

    /// Returns a CONNECT request once the request buffer is complete.
    public static func parseConnectRequest(buffer: Data) throws -> (AccessSOCKS5ConnectRequest, Int)? {
        guard !buffer.isEmpty else { return nil }
        guard buffer[0] == version else {
            throw AccessSOCKS5InboundError.malformedRequest
        }
        guard buffer.count >= 4 else { return nil }
        let command = buffer[1]
        guard buffer[2] == 0x00 else {
            throw AccessSOCKS5InboundError.malformedRequest
        }
        guard command == commandConnect else {
            throw AccessSOCKS5InboundError.unsupportedCommand(command)
        }
        let atyp = buffer[3]
        switch atyp {
        case atypIPv4:
            let need = 4 + 4 + 2
            guard buffer.count >= need else { return nil }
            let b = buffer.subdata(in: 4..<8)
            let host = "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
            let port = UInt16(buffer[8]) << 8 | UInt16(buffer[9])
            let request = try AccessSOCKS5ConnectRequest(address: .ipv4(host), port: port)
            return (request, need)
        case atypDomain:
            guard buffer.count >= 5 else { return nil }
            let len = Int(buffer[4])
            let need = 5 + len + 2
            guard buffer.count >= need else { return nil }
            let hostData = buffer.subdata(in: 5..<(5 + len))
            guard let host = String(data: hostData, encoding: .utf8), !host.isEmpty else {
                throw AccessSOCKS5InboundError.malformedRequest
            }
            let port = UInt16(buffer[5 + len]) << 8 | UInt16(buffer[6 + len])
            let request = try AccessSOCKS5ConnectRequest(address: .domain(host), port: port)
            return (request, need)
        case atypIPv6:
            let need = 4 + 16 + 2
            guard buffer.count >= need else { return nil }
            var parts: [String] = []
            for i in stride(from: 4, to: 20, by: 2) {
                let value = UInt16(buffer[i]) << 8 | UInt16(buffer[i + 1])
                parts.append(String(format: "%x", value))
            }
            let host = parts.joined(separator: ":")
            let port = UInt16(buffer[20]) << 8 | UInt16(buffer[21])
            let request = try AccessSOCKS5ConnectRequest(address: .ipv6(host), port: port)
            return (request, need)
        default:
            throw AccessSOCKS5InboundError.unsupportedAddressType(atyp)
        }
    }

    public static func successReply() -> Data {
        // BND.ADDR = 0.0.0.0, BND.PORT = 0 — tunnel endpoint only; no direct dial.
        Data([version, replySucceeded, 0x00, atypIPv4, 0, 0, 0, 0, 0, 0])
    }

    public static func commandNotSupportedReply() -> Data {
        Data([version, replyCommandNotSupported, 0x00, atypIPv4, 0, 0, 0, 0, 0, 0])
    }

    public static func noAcceptableMethodReply() -> Data {
        Data([version, methodNoneAcceptable])
    }
}
