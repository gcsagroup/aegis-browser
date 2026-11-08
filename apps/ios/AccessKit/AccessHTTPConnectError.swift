import Foundation

/// Fail-closed errors for HTTP CONNECT handling on the inbound listener (F4).
public enum AccessHTTPConnectError: Error, Equatable, Sendable {
    case incompleteRequest
    case malformedRequestLine
    case methodNotConnect(String)
    case malformedTarget(String)
    case invalidTargetPort(UInt16)
    case headersTooLarge
    case responseWriteFailed
}
