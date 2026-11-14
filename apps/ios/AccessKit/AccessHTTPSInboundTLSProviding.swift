import Foundation
import Network

/// Supplies server-side TLS options for the local HTTPS inbound front.
///
/// Production implementations load a browser-owned identity from Keychain.
/// Unit tests inject a double. This protocol never performs site MITM.
public protocol AccessHTTPSInboundTLSProviding: AnyObject {
    func makeServerTLSOptions(identityLabel: String) throws -> NWProtocolTLS.Options
}
