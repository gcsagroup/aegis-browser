import Foundation

public enum AccessSiteIntentError: Error, Equatable, Sendable {
    case emptyHost
    case hostNotCanonical
    case hostContainsSchemeOrPath
    case unknownIntent(String)
}
