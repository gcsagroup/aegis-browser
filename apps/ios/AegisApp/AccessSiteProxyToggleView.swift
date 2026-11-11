import AccessKit
import BrowserKit
import SwiftUI

/// Current-page 「本站代理」 toggle: host + switch + intent/connection lines.
///
/// Switch state ≠ connectivity. Closing copy states the browser's original
/// connection is used — never “direct success” without verification.
struct AccessSiteProxyToggleView: View {
    @ObservedObject var store: AccessSiteProxySessionStore
    let url: URL?
    var tab: BrowserTab?

    @Environment(\.locale) private var localizationLocale

    private var snapshot: AccessSiteProxyToggleSnapshot {
        if let tab { return store.snapshot(for: tab) }
        return store.snapshot(for: url)
    }

    private var attachment: AccessProxyAttachment {
        guard let tab else { return .notAttached }
        return store.attachment(tab: tab, url: url)
    }

    var body: some View {
        let _ = localizationLocale
        let snap = snapshot
        Section {
            if let host = snap.host {
                Text(host.rawValue)
                    .font(.headline)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("access-site-proxy-host")
            } else {
                Label("当前页不是可代理的网站", systemImage: "globe")
                    .accessibilityIdentifier("access-site-proxy-no-host")
            }

            Toggle(
                AccessAutoRecoveryCopy.toggleTitle,
                isOn: Binding(
                    get: { snap.autoRecoveryEnabled },
                    set: { enabled in
                        guard let tab else { return }
                        _ = store.setAutoRecoveryEnabled(enabled, for: tab)
                    }
                )
            )
            .disabled(!snap.toggleEnabled || tab == nil)
            .accessibilityIdentifier("access-site-proxy-toggle")
            if let line = snap.autoRecoveryLine {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("access-site-auto-recovery-status")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(AccessSiteProxyToggleModel.intentLine(for: snap.intentStatus))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("access-site-proxy-intent")
                Text(AccessSiteProxyToggleModel.connectionLine(for: snap.connectionStatus))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("access-site-proxy-connection")
                if let attachment = AccessSiteProxyToggleModel.attachmentLine(
                    for: attachment,
                    intent: snap.intent
                ) {
                    Text(attachment)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("access-site-proxy-attachment")
                }
                if let reason = snap.failureReason, !reason.isEmpty {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("access-site-proxy-failure")
                }
            }
        } header: {
            Text("本站代理")
        } footer: {
            Text(AccessAutoRecoveryCopy.explanation)
                .font(.footnote)
            Text(AccessAutoRecoveryCopy.scopeWarning)
                .font(.footnote)
        }
    }
}
