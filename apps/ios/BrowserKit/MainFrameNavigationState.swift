import Foundation
import WebKit

/// Owns request identity and replay provenance independently of WebKit effects.
/// BrowserTab remains the delegate and performs loading, store routing and UI updates.
@MainActor
final class MainFrameNavigationState {
    struct Attempt {
        var navigationID: String
        var url: URL
        var method: String
        var hasReplayableBody: Bool
        var allowSequence: UInt64
        var failureID: UUID?
        var recoveryOperationID: UUID?
        var policyType: WKNavigationType?

        func acceptsRedirectPolicy(_ type: WKNavigationType?) -> Bool {
            type != nil && (type == .other || type == policyType)
        }
    }

    private var nextAllowSequence: UInt64 = 0
    private(set) var current = Attempt(navigationID: UUID().uuidString, url: URL(string: "about:blank")!,
                                      method: "GET", hasReplayableBody: false, allowSequence: 0)
    private var bound: [ObjectIdentifier: Attempt] = [:]
    private var unbound: [Attempt] = []
    var pendingNavigation: WKNavigation?
    var programmaticPolicyNavigationID: String?
    private var confirmedRedirectPolicy: (navigationID: String, url: URL)?

    func updateCurrent(_ update: (inout Attempt) -> Void) { update(&current) }
    func replaceCurrent(_ value: Attempt) { current = value }
    var hasBoundAttempts: Bool { !bound.isEmpty }
    var uniqueCurrentUnbound: Attempt? {
        unbound.count == 1 && isLatest(unbound[0]) ? unbound[0] : nil
    }
    func recorded(for navigation: WKNavigation) -> Attempt? { bound[ObjectIdentifier(navigation)] }
    func isLatest(_ value: Attempt) -> Bool {
        value.navigationID == current.navigationID && value.allowSequence == current.allowSequence
    }
    func isCurrent(_ navigation: WKNavigation?, isLoading: Bool) -> Bool {
        guard let navigation else { return pendingNavigation == nil && isLoading && uniqueCurrentUnbound != nil }
        return recorded(for: navigation).map(isLatest) == true
    }

    func begin(url: URL, method: String, unsafeReplay: Bool, policyType: WKNavigationType?) {
        programmaticPolicyNavigationID = nil
        confirmedRedirectPolicy = nil
        nextAllowSequence &+= 1
        current = Attempt(navigationID: UUID().uuidString, url: url, method: method.uppercased(),
                          hasReplayableBody: unsafeReplay, allowSequence: nextAllowSequence, policyType: policyType)
        // Each approved sibling keeps its own FIFO slot until didStart or explicit retirement.
        unbound.append(current)
    }

    func retireUnbound(_ id: String) { unbound.removeAll { $0.navigationID == id } }
    func bind(_ navigation: WKNavigation, to value: Attempt) {
        bound[ObjectIdentifier(navigation)] = value
        retireUnbound(value.navigationID)
    }
    func bindNext(_ navigation: WKNavigation) -> Attempt? {
        if let recorded = recorded(for: navigation) { return recorded }
        guard !unbound.isEmpty else { return nil }
        let next = unbound.removeFirst()
        bind(navigation, to: next)
        return next
    }
    @discardableResult func retire(_ navigation: WKNavigation?) -> Attempt? {
        guard let navigation, let retired = bound.removeValue(forKey: ObjectIdentifier(navigation)) else { return nil }
        if programmaticPolicyNavigationID == retired.navigationID { programmaticPolicyNavigationID = nil }
        if confirmedRedirectPolicy?.navigationID == retired.navigationID { confirmedRedirectPolicy = nil }
        return retired
    }
    func retireAll() {
        bound.removeAll(); unbound.removeAll(); pendingNavigation = nil
        programmaticPolicyNavigationID = nil; confirmedRedirectPolicy = nil
    }
    func clearRedirectConfirmation() { confirmedRedirectPolicy = nil }

    /// Update a continuing app load without adding a second allow slot.
    func continueLoad(url: URL, method: String, unsafeReplay: Bool) {
        current.url = url; current.method = method
        current.hasReplayableBody = current.hasReplayableBody || unsafeReplay
        if let index = unbound.lastIndex(where: { $0.navigationID == current.navigationID }) { unbound[index] = current }
        else { unbound.append(current) }
    }

    /// Returns true only for a confirmed chain continuation or an acknowledgment
    /// of the app-issued request. Other policy actions must begin a fresh attempt.
    func adoptPolicy(url: URL, method: String, continues: Bool, unsafeReplay: Bool, policyType: WKNavigationType?) -> Bool {
        let confirmed = current.acceptsRedirectPolicy(policyType)
            && confirmedRedirectPolicy?.navigationID == current.navigationID && confirmedRedirectPolicy?.url == url
        if continues || confirmed {
            confirmedRedirectPolicy = nil
            func redirected(_ previous: Attempt) -> Attempt {
                var value = previous
                value.url = url
                if confirmed, value.method != method { value.hasReplayableBody = true }
                else { value.method = method }
                value.hasReplayableBody = value.hasReplayableBody || unsafeReplay
                return value
            }
            if let pendingNavigation, let previous = recorded(for: pendingNavigation) {
                let value = redirected(previous)
                bound[ObjectIdentifier(pendingNavigation)] = value
                if current.navigationID == value.navigationID { current = value }
                return true
            }
            if let previous = unbound.last {
                let value = redirected(previous)
                unbound[unbound.count - 1] = value
                if current.navigationID == value.navigationID { current = value }
                return true
            }
        }
        let history = current.policyType == .backForward && (policyType == .backForward || policyType == .formResubmitted)
        guard current.url == url, programmaticPolicyNavigationID == current.navigationID,
              history || (current.policyType != .backForward && current.method == method) else { return false }
        programmaticPolicyNavigationID = nil
        if history { current.method = method; current.hasReplayableBody = unsafeReplay }
        else { current.hasReplayableBody = current.hasReplayableBody || unsafeReplay }
        current.policyType = policyType
        if let pendingNavigation, recorded(for: pendingNavigation)?.navigationID == current.navigationID {
            bound[ObjectIdentifier(pendingNavigation)] = current
        }
        if let index = unbound.lastIndex(where: { $0.navigationID == current.navigationID }) { unbound[index] = current }
        return true
    }

    /// A redirect callback proves the chain, but provides no redirected method.
    /// Never promote POST/body/header provenance to a safe GET on URL evidence.
    @discardableResult func confirmRedirect(_ navigation: WKNavigation, url: URL) -> Bool {
        guard var recorded = recorded(for: navigation) else { return false }
        recorded.url = url
        let allowed = unbound.filter {
            recorded.acceptsRedirectPolicy($0.policyType) && $0.url == url
                && $0.allowSequence == recorded.allowSequence &+ 1 && isLatest($0)
        }
        if navigation === pendingNavigation, unbound.count == 1, let next = allowed.first {
            recorded.allowSequence = next.allowSequence
            if recorded.method != next.method { recorded.hasReplayableBody = true }
            recorded.hasReplayableBody = recorded.hasReplayableBody || next.hasReplayableBody
            retireUnbound(next.navigationID)
            current = recorded
            confirmedRedirectPolicy = nil
        } else if isLatest(recorded) { confirmedRedirectPolicy = (recorded.navigationID, url) }
        bound[ObjectIdentifier(navigation)] = recorded
        if isLatest(recorded) { current = recorded; return true }
        return false
    }
}
