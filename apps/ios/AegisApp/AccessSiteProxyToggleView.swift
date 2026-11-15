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
    @State private var configuredNodeID: String?
    @State private var didLoadNodeSummary = false

    @EnvironmentObject private var account: AccessAccountSession
    @State private var authorizing = false
    @State private var accountID = ""
    @State private var sessionToken = ""
    @State private var authorizationHost: AccessSiteHost?

    @Environment(\.locale) private var localizationLocale

    private var snapshot: AccessSiteProxyToggleSnapshot {
        if let tab { return store.snapshot(for: tab) }
        return store.snapshot(for: url)
    }

    var body: some View {
        let _ = localizationLocale
        let snap = snapshot
        // The failed target can differ from WebKit's last committed URL. All
        // route labels must describe the same host as the visible site switch.
        let attachment = snap.attachment
        let capability = AccessProxyCapabilityPresentation.make(
            nodeID: configuredNodeID,
            attached: attachment != .notAttached,
            entryReady: attachment == .ready
        )
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("网站级代理，页面内第三方资源随页面连接；不是全设备 VPN。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("access-proxy-capability")
                LabeledContent {
                    if let nodeID = capability.configuredNodeID {
                        Text(verbatim: nodeID).font(.footnote.monospaced())
                    } else {
                        Text("未找到可用节点配置")
                    }
                } label: { Text("已配置节点（匿名标识）") }
                .accessibilityIdentifier("access-proxy-configured-node")
                if capability.configuredNodeID != nil {
                    Text(verbatim: "VLESS · TCP · REALITY · Vision")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(verbatim: AegisLocalization.string(capability.routeText))
                    .font(.footnote)
                    .accessibilityIdentifier("access-proxy-page-route")
                Text("节点标识仅代表本地配置，不证明远端已连接，也不证明与面板查询账户对应。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let host = snap.host {
                Text(host.rawValue)
                    .font(.headline)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("access-site-proxy-host")
            } else {
                Label("当前页不是可代理的网站", systemImage: "globe")
                    .accessibilityIdentifier("access-site-proxy-no-host")
            }

            Toggle("本站使用代理", isOn: Binding(
                get: { snap.toggleOn },
                set: { enabled in
                    guard let tab, let host = snap.host else { return }
                    store.setSiteProxyEnabled(enabled, for: tab, displayedHost: host)
                }
            ))
            .disabled(!snap.toggleEnabled || tab == nil)
            .accessibilityIdentifier("access-site-proxy-toggle")
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
            .accessibilityIdentifier("access-site-auto-recovery-toggle")
            if let tab, account.supportsAccountAuthorization {
                let paidHost = store.paidDownloadHost(for: tab)
                Toggle(
                    "通过账户代理下载本站文件",
                    isOn: Binding(
                        get: { paidHost.map { account.hasSelectedProxy(for: tab.id, host: $0.rawValue) } ?? false },
                        set: { enabled in
                            guard let paidHost else { return }
                            if enabled && tab.profile.isPrivate {
                                authorizationHost = paidHost
                                authorizing = true
                            } else {
                                store.setProxyEnabled(enabled, for: tab, account: account, displayedHost: paidHost)
                            }
                        }
                    )
                )
                .disabled(paidHost == nil)
                .accessibilityIdentifier("access-account-site-download-toggle")
                .sheet(isPresented: $authorizing, onDismiss: { accountID = ""; sessionToken = ""; authorizationHost = nil }) {
                    NavigationStack {
                        Form {
                            TextField("服务账户", text: $accountID).textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField("服务账户会话令牌", text: $sessionToken)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        }
                        .localizedNavigationTitle("授权本次私密会话")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("取消") { authorizing = false } }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("确认") {
                                    if let authorizationHost {
                                        store.setProxyEnabled(true, for: tab, account: account, displayedHost: authorizationHost, privateAccount: accountID, privateToken: sessionToken)
                                    }
                                    authorizing = false
                                }
                                    .disabled(accountID.isEmpty || sessionToken.isEmpty)
                            }
                        }
                    }
                }
            }
            if let line = snap.autoRecoveryLine {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("access-site-auto-recovery-status")
            }
            if !snap.debugMemberHosts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("组成员（只读）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(snap.debugMemberHosts, id: \.self) { member in
                        Text(member)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .accessibilityIdentifier("access-site-debug-members")
            }
            if snap.showsDebugSiteGroupDetails {
                Button(snap.probeBusy ? "正在探测…" : "探测候选（建议）") {
                    guard let tab else { return }
                    _ = store.runAutoRecoveryProbe(for: tab)
                }
                .disabled(tab == nil || snap.probeBusy || !snap.autoRecoveryEnabled)
                .accessibilityIdentifier("access-site-probe-button")
                if !snap.probeSuggestionLines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(snap.probeSuggestionLines, id: \.self) { line in
                            Text(line)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("access-site-probe-suggestions")
                }
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
        .task {
            guard !didLoadNodeSummary else { return }
            didLoadNodeSummary = true
            // Read once per presentation, outside body and off the UI executor.
            configuredNodeID = await Task.detached(priority: .utility) {
                AccessProxyCapabilityPresentation.configuredNodeID()
            }.value
        }
    }
}
