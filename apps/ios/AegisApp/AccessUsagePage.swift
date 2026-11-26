import SwiftUI

/// Current product usage comes from the same 3X-UI subscription as webpage routing.
struct AccessUsagePage: View {
    let isPrivate: Bool
    @EnvironmentObject private var subscription: AccessSubscriptionUsageSession
    @ObservedObject private var alphaNodes: AccessAlphaNodeCatalogue

    init(isPrivate: Bool, alphaNodes: AccessAlphaNodeCatalogue = .shared) {
        self.isPrivate = isPrivate
        self.alphaNodes = alphaNodes
    }

    var body: some View {
        Form {
            if isPrivate {
                Section {
                    Label("私密会话不显示普通账户的额度；请在普通窗口查询。", systemImage: "lock")
                        .accessibilityIdentifier("access-usage-private")
                }
            } else {
                if alphaNodes.isConfigured {
                    Section("可用连接") {
                        if alphaNodes.entries.isEmpty {
                            Text("暂不可用")
                        }
                        ForEach(alphaNodes.entries) { entry in
                            let available = subscription.isAlphaRouteSelectable(entry.id)
                            let selected = alphaNodes.selectedIndex == entry.id
                            Button {
                                guard subscription.isAlphaRouteSelectable(entry.id) else { return }
                                alphaNodes.select(entry.id)
                            } label: {
                                HStack {
                                    Text(verbatim: entry.displayName)
                                    Spacer()
                                    if !available {
                                        Text("暂不可用")
                                    }
                                    if selected {
                                        Image(systemName: "checkmark").accessibilityHidden(true)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .disabled(!available)
                            .accessibilityValue(available ? (selected ? Text("已启用") : Text("未选择")) : Text("暂不可用"))
                            .accessibilityIdentifier("access-alpha-node-\(entry.id)")
                        }
                    }
                }
                AccessSubscriptionUsageView(session: subscription, usesAlphaNodeSelection: alphaNodes.isConfigured)
            }
        }
        .localizedNavigationTitle("隐藏地理位置服务")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("access-usage-page")
    }
}
