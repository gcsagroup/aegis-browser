import Foundation

/// Opaque handle for a launched Xray process.
public protocol AccessXrayProcessHandle: AnyObject {
    var isRunning: Bool { get }
    func terminate()
}

/// Process controller seam so unit tests never exec a real core binary.
public protocol AccessXrayProcessControlling: AnyObject {
    func launch(executableURL: URL, configData: Data) throws -> AccessXrayProcessHandle
}
