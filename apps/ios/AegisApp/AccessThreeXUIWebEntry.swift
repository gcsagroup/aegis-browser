import AccessKit
import Foundation

/// The current product uses one signed 3X-UI subscription for both webpages and
/// usage. Missing setup or a failed query cannot select a static bundled node.
@MainActor
enum AccessThreeXUIWebEntry {
    static func makePublisher(
        for usage: AccessSubscriptionUsageSession,
        lockData: Data? = nil,
        verifiedCore: (any AccessEmbeddedCoreControlling)? = nil
    ) -> any AccessProxyEntryPublishing {
        guard usage.isSelected, usage.managesConnections else { return AccessFailClosedProxyEntryPublisher() }
        return AccessEmbeddedProxyEntryFactory.makeProductPublisher(
            lockData: lockData,
            configPath: nil,
            verifiedCore: verifiedCore,
            parameters: { try await usage.connectionParameters() },
            connectionAllowed: { usage.permitsExistingConnection }
        )
    }
}
