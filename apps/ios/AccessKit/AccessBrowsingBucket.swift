import Foundation

/// Browsing lane that owns Access registration, lease, proxy config, and credentials.
///
/// Ordinary and private browsing must never share live Access state. F9 exposed
/// the WebKit write boundary (`applyToOrdinaryStore` / `applyToPrivateStore`);
/// this bucket is the product isolation key those call sites bind to.
public enum AccessBrowsingBucket: String, Codable, Sendable, Equatable, Hashable {
    case ordinary
    case privateBrowsing

    /// Canonical `AccessOwner.profile` string for this bucket.
    public var ownerProfile: String {
        switch self {
        case .ordinary:
            return "ordinary"
        case .privateBrowsing:
            return "private"
        }
    }

    /// Matching F9 ProxyConfiguration data-store kind.
    public var dataStoreKind: AccessProxyDataStoreKind {
        switch self {
        case .ordinary:
            return .ordinary
        case .privateBrowsing:
            return .privateBrowsing
        }
    }

    public static func from(dataStoreKind: AccessProxyDataStoreKind) -> AccessBrowsingBucket {
        switch dataStoreKind {
        case .ordinary:
            return .ordinary
        case .privateBrowsing:
            return .privateBrowsing
        }
    }

    public static func from(ownerProfile: String) throws -> AccessBrowsingBucket {
        switch ownerProfile {
        case AccessBrowsingBucket.ordinary.ownerProfile:
            return .ordinary
        case AccessBrowsingBucket.privateBrowsing.ownerProfile:
            return .privateBrowsing
        default:
            throw AccessBrowsingIsolationError.unknownOwnerProfile(ownerProfile)
        }
    }
}
