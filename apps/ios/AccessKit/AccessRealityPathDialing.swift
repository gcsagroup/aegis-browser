import Foundation

/// Byte-stream handle for one CONNECT target forwarded through reality_vision.
public protocol AccessRealityPathStream: AnyObject {
    var isOpen: Bool { get }
    func close()
}

/// Opens a reality_vision path for one CONNECT authority.
///
/// Production hosts dial through the running Xray runtime. Unit tests inject a
/// double. Direct origin dial must never be used as a success path.
public protocol AccessRealityPathDialing: AnyObject {
    func dial(host: String, port: UInt16) throws -> AccessRealityPathStream
}
