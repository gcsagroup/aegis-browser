import Foundation

/// Parses a cleartext HTTP CONNECT preamble from an inbound buffer.
public enum AccessHTTPConnectParser {
    public static let maxHeaderBytes = 8_192

    /// Header bytes and any tunnel payload that arrived in the same buffer.
    /// The size limit applies to the header only.
    public static func split(buffer: Data) throws -> (AccessHTTPConnectRequest, Data)? {
        guard let headerEnd = indexOfHeaderTerminator(in: buffer) else {
            if buffer.count > maxHeaderBytes {
                throw AccessHTTPConnectError.headersTooLarge
            }
            return nil
        }
        if headerEnd > maxHeaderBytes {
            throw AccessHTTPConnectError.headersTooLarge
        }
        let headerLength = headerEnd + 4
        let header = Data(buffer.prefix(headerLength))
        guard let request = try parse(buffer: header) else { return nil }
        return (request, Data(buffer.dropFirst(headerLength)))
    }

    /// Returns a request once the header block is complete (`\r\n\r\n`).
    public static func parse(buffer: Data) throws -> AccessHTTPConnectRequest? {
        guard let headerEnd = indexOfHeaderTerminator(in: buffer) else {
            if buffer.count > maxHeaderBytes {
                throw AccessHTTPConnectError.headersTooLarge
            }
            return nil
        }
        if headerEnd > maxHeaderBytes {
            throw AccessHTTPConnectError.headersTooLarge
        }
        let headerData = buffer.prefix(headerEnd)
        guard let text = String(data: headerData, encoding: .utf8) else {
            throw AccessHTTPConnectError.malformedRequestLine
        }
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            throw AccessHTTPConnectError.malformedRequestLine
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw AccessHTTPConnectError.malformedRequestLine
        }
        let method = String(parts[0])
        guard method == "CONNECT" else {
            throw AccessHTTPConnectError.methodNotConnect(method)
        }
        let (host, port) = try parseAuthority(String(parts[1]))
        return try AccessHTTPConnectRequest(
            host: host,
            port: port,
            httpVersion: String(parts[2])
        )
    }

    public static func successResponse(httpVersion: String = "HTTP/1.1") -> Data {
        Data("\(httpVersion) 200 Connection Established\r\n\r\n".utf8)
    }

    public static func methodNotAllowedResponse(httpVersion: String = "HTTP/1.1") -> Data {
        Data("\(httpVersion) 405 Method Not Allowed\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
    }

    public static func badRequestResponse(httpVersion: String = "HTTP/1.1") -> Data {
        Data("\(httpVersion) 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
    }

    private static func indexOfHeaderTerminator(in buffer: Data) -> Int? {
        let pattern = Data("\r\n\r\n".utf8)
        if let range = buffer.range(of: pattern) {
            return range.lowerBound
        }
        return nil
    }

    private static func parseAuthority(_ authority: String) throws -> (String, UInt16) {
        // Strip optional brackets for IPv6 literals: [::1]:443
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else {
                throw AccessHTTPConnectError.malformedTarget(authority)
            }
            let host = String(authority[authority.index(after: authority.startIndex)..<close])
            let rest = authority[authority.index(after: close)...]
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()), port > 0 else {
                throw AccessHTTPConnectError.malformedTarget(authority)
            }
            return (host, port)
        }
        guard let colon = authority.lastIndex(of: ":") else {
            throw AccessHTTPConnectError.malformedTarget(authority)
        }
        let host = String(authority[..<colon])
        let portText = String(authority[authority.index(after: colon)...])
        guard let port = UInt16(portText), port > 0 else {
            throw AccessHTTPConnectError.malformedTarget(authority)
        }
        guard !host.isEmpty else {
            throw AccessHTTPConnectError.malformedTarget(authority)
        }
        return (host, port)
    }
}
