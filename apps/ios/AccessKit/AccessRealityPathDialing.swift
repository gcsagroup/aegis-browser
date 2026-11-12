import Foundation

/// Byte-stream handle for one CONNECT target forwarded through reality_vision.
public protocol AccessRealityPathStream: AnyObject, Sendable {
    var isOpen: Bool { get }
    /// `nil` is EOF. A live stream does not return an empty chunk.
    func read(maxBytes: Int) async throws -> Data?
    /// Returns only after the whole chunk has been accepted.
    func write(_ data: Data) async throws
    /// Idempotent. Wakes any read or write that is still waiting.
    func close()
}

/// Opens a reality_vision path for one CONNECT authority.
///
/// Production hosts dial through the running Xray runtime. Unit tests inject a
/// double. Direct origin dial must never be used as a success path.
public protocol AccessRealityPathDialing: AnyObject, Sendable {
    func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream
}
