import Foundation

/// Chooses the in-process core from a frozen lock. Unverified locks stay fail-closed.
@MainActor
public final class AccessEmbeddedCoreAdapter {
    public let manifest: AccessEmbeddedCoreManifest
    public let core: any AccessEmbeddedCoreControlling

    public init(
        manifest: AccessEmbeddedCoreManifest,
        verifiedCore: (any AccessEmbeddedCoreControlling)? = nil
    ) {
        self.manifest = manifest
        if manifest.mayLink, let verifiedCore {
            self.core = verifiedCore
        } else {
            self.core = AccessUnverifiedEmbeddedCore()
        }
    }

    public convenience init(lockData: Data, verifiedCore: (any AccessEmbeddedCoreControlling)? = nil) throws {
        let manifest = try AccessEmbeddedCoreManifest.load(from: lockData)
        self.init(manifest: manifest, verifiedCore: verifiedCore)
    }

    public var mayDial: Bool { manifest.mayLink && !(core is AccessUnverifiedEmbeddedCore) }
}
