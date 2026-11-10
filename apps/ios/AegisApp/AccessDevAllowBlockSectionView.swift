import AccessKit
import SwiftUI

/// DEV/Alpha-only ALLOW / BLOCK debug section for an explicit navigation host.
///
/// Renders only when `panel_registered` is true. Never exposes a general Access
/// rule editor. BLOCK is local refuse — not silent DIRECT.
struct AccessDevAllowBlockSectionView: View {
    @ObservedObject var store: AccessSiteProxySessionStore
    let url: URL?

    @Environment(\.locale) private var localizationLocale

    private var channel: AccessReleaseChannel {
        store.devAllowBlockChannel
    }

    private var snapshot: AccessDevAllowBlockPanelSnapshot {
        store.devAllowBlockSnapshot(for: url)
    }

    var body: some View {
        let _ = localizationLocale
        let snap = snapshot
        if snap.panelRegistered {
            Section {
                if let host = snap.host {
                    Text(host.rawValue)
                        .font(.subheadline)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("access-dev-allow-block-host")
                } else {
                    Text(AccessDevAllowBlockSectionModel.statusLine(for: .noTrustedHost))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("access-dev-allow-block-no-host")
                }

                Text(AccessDevAllowBlockSectionModel.statusLine(for: snap.statusId))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("access-dev-allow-block-status")

                HStack(spacing: 12) {
                    Button("ALLOW") {
                        store.applyDevAllowBlock(.allow, for: url)
                    }
                    .disabled(!snap.hasExplicitHost)
                    .accessibilityIdentifier("access-dev-allow-block-allow")

                    Button("BLOCK", role: .destructive) {
                        store.applyDevAllowBlock(.block, for: url)
                    }
                    .disabled(!snap.hasExplicitHost)
                    .accessibilityIdentifier("access-dev-allow-block-block")

                    Button("清除") {
                        store.applyDevAllowBlock(.off, for: url)
                    }
                    .disabled(!snap.hasExplicitHost)
                    .accessibilityIdentifier("access-dev-allow-block-off")
                }
            } header: {
                Text("DEV ALLOW / BLOCK")
            } footer: {
                Text("仅 DEV/Alpha 调试入口。对明确 host 提交意图；BLOCK 为本地拒绝，不是直连成功。非通用规则编辑器。")
                    .font(.footnote)
            }
        }
    }
}
