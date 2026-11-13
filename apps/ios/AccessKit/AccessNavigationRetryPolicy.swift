import Foundation

public enum AccessNavigationRetryTrigger: String, Sendable, Equatable {
    case automatic
    case userRetry
    case userToggle
}

public struct AccessNavigationRetryTicket: Sendable, Equatable {
    public var tabID: String
    public var scopeID: String
    public var navigationID: String
    public var host: AccessSiteHost
    public var url: URL
    public var method: String
    public var hasReplayableBody: Bool
    public var switchGeneration: UInt64
    public var retryConsumed: Bool
    public var failureID: UUID
    public var operationID: UUID
    public var trigger: AccessNavigationRetryTrigger

    public init(
        tabID: String,
        scopeID: String,
        navigationID: String,
        host: AccessSiteHost,
        url: URL,
        method: String,
        hasReplayableBody: Bool,
        switchGeneration: UInt64,
        retryConsumed: Bool = false,
        failureID: UUID = UUID(),
        operationID: UUID = UUID(),
        trigger: AccessNavigationRetryTrigger = .automatic
    ) {
        self.tabID = tabID
        self.scopeID = scopeID
        self.navigationID = navigationID
        self.host = host
        self.url = url
        self.method = method.uppercased()
        self.hasReplayableBody = hasReplayableBody
        self.switchGeneration = switchGeneration
        self.retryConsumed = retryConsumed
        self.failureID = failureID
        self.operationID = operationID
        self.trigger = trigger
    }
}

public enum AccessNavigationRetryDecision: Sendable, Equatable {
    case ineligible
    case consumeAndRetry
    case alreadyConsumed
}

public enum AccessNavigationRetryPolicy {
    /// Network failures of the main frame may create a ticket. Cancellation,
    /// policy blocks, and certificate errors do not.
    public static func admitsNetworkFailure(
        isMainFrame: Bool,
        isCancellation: Bool,
        isCertificateError: Bool,
        isPolicyBlock: Bool
    ) -> Bool {
        isMainFrame && !isCancellation && !isCertificateError && !isPolicyBlock
    }

    public static func evaluate(
        ticket: AccessNavigationRetryTicket,
        currentTabID: String,
        currentNavigationID: String,
        currentSwitchGeneration: UInt64,
        endpointReady: Bool,
        currentFailureID: UUID? = nil
    ) -> AccessNavigationRetryDecision {
        guard ticket.tabID == currentTabID,
              ticket.navigationID == currentNavigationID,
              ticket.switchGeneration == currentSwitchGeneration,
              endpointReady,
              !ticket.hasReplayableBody,
              ticket.method == "GET" || ticket.method == "HEAD",
              currentFailureID == nil || ticket.failureID == currentFailureID
        else {
            return .ineligible
        }
        return ticket.retryConsumed ? .alreadyConsumed : .consumeAndRetry
    }

    /// The quota is consumed before the retry is sent. A later failure of that
    /// same ticket cannot mint another attempt.
    public static func consume(
        _ ticket: AccessNavigationRetryTicket
    ) -> AccessNavigationRetryTicket {
        var next = ticket
        next.retryConsumed = true
        return next
    }
}
