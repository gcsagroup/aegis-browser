import SwiftUI

struct FirebaseControlsView: View {
    @ObservedObject private var firebase = AegisFirebase.shared

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        Section {
            Toggle(isOn: Binding(get: { firebase.crashReportsEnabled }, set: { firebase.setCrashReportsEnabled($0) })) {
                Text("发送崩溃报告")
                if firebase.status == .active && firebase.crashReportsEnabled && !firebase.crashReportingActive {
                    Text("远程配置已暂停此项").font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("firebase-crash-reports")
            Toggle(isOn: Binding(get: { firebase.analyticsEnabled }, set: { firebase.setAnalyticsEnabled($0) })) {
                Text("发送使用分析")
                if firebase.status == .active && firebase.analyticsEnabled && !firebase.analyticsActive {
                    Text("远程配置已暂停此项").font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("firebase-analytics")
        } header: {
            Text("诊断与使用分析")
        } footer: {
            VStack(alignment: .leading) {
                Text("通过 Firebase 发送崩溃诊断和应用使用统计。崩溃报告在下次启动时发送。")
                Text("崩溃报告、使用分析与远程诊断配置默认开启，可随时关闭。")
                Text("已获准发送的崩溃报告无法撤回。")
            }
        }
        Section {
            Toggle("允许远程诊断配置", isOn: Binding(
                get: { firebase.remoteConfigurationEnabled }, set: { firebase.setRemoteConfigurationEnabled($0) }
            )).accessibilityIdentifier("firebase-remote-configuration")
            if let remote = firebase.remoteConfiguration {
                RemoteDiagnosticsStatusView(controller: remote)
            }
            if firebase.status == .registrationChanged {
                Text("此安装曾连接其他诊断环境。崩溃报告与使用分析已暂停。")
            } else if firebase.status == .unavailable {
                Text("此构建未启用诊断服务，已保存的选择将在服务可用时生效。")
            }
        } header: {
            Text("远程诊断配置")
        } footer: {
            Text("仅允许远程暂停诊断上报，不能开启你关闭的采集项。获取配置会向 Firebase 发送安装标识；关闭后恢复本机选择并清理该标识，已开始的请求无法撤回。")
        }
    }
}

private struct RemoteDiagnosticsStatusView: View {
    @ObservedObject var controller: RemoteDiagnosticsController

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        Group {
            switch controller.state {
            case .off:
                Text("使用本机选择")
            case .fetching:
                Text("正在获取远程配置")
            case .ready:
                Text("远程配置已生效")
            case .unavailable, .expired:
                if controller.policy != nil {
                    Text("使用最近一次有效配置")
                } else {
                    Text("远程配置不可用，诊断上报已暂停。")
                }
            case .cleaning:
                Text("正在清理远程配置标识")
            case .cleanupFailed:
                Text("安装标识清理未完成，请重试。")
            }
        }.font(.footnote).foregroundStyle(.secondary)
        if controller.enabled || controller.state == .cleanupFailed {
            Button("重试") { controller.refresh() }
                .disabled(controller.busy)
                .accessibilityIdentifier("firebase-remote-retry")
        }
    }
}
