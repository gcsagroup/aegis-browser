import SwiftUI

/// Current product usage comes from the same 3X-UI subscription as webpage routing.
struct AccessUsagePage: View {
    let isPrivate: Bool
    @EnvironmentObject private var subscription: AccessSubscriptionUsageSession

    var body: some View {
        Form {
            if isPrivate {
                Section {
                    Label("私密会话不显示普通账户的额度；请在普通窗口查询。", systemImage: "lock")
                        .accessibilityIdentifier("access-usage-private")
                }
            } else {
                AccessSubscriptionUsageView(session: subscription)
            }
        }
        .localizedNavigationTitle("隐藏地理位置服务")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("access-usage-page")
    }
}
