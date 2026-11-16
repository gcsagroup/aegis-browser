import SwiftUI

/// A single entry point preserves the distinction between account and shared test data.
struct AccessUsagePage: View {
    let isPrivate: Bool
    @EnvironmentObject private var account: AccessAccountSession
    @EnvironmentObject private var subscription: AccessSubscriptionUsageSession

    var body: some View {
        Form {
            if isPrivate {
                Section {
                    Label("私密会话不显示普通账户的额度；请在普通窗口查询。", systemImage: "lock")
                        .accessibilityIdentifier("access-usage-private")
                }
            } else if subscription.isSelected {
                AccessSubscriptionUsageView(session: subscription)
            } else {
                AccessAccountUsageView(session: account)
            }
        }
        .localizedNavigationTitle("隐藏地理位置服务")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("access-usage-page")
    }
}
