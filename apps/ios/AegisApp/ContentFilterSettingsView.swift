import BrowserKit
import SwiftUI

struct ContentFilterSettingsView: View {
    @EnvironmentObject private var browser: BrowserSession
    @ObservedObject private var protection = TrackingProtection.shared
    @State private var enabled = TrackingProtection.enabled
    @State private var exceptions = TrackingProtection.exceptionHosts
    @State private var updateTask: Task<Void, Never>?
    var body: some View {
        Form {
            Section("广告与跟踪过滤") {
                Toggle("启用过滤", isOn: $enabled).accessibilityIdentifier("content-filter-toggle")
                    .onChange(of: enabled) { _, value in TrackingProtection.enabled = value; browser.activeTab?.reload() }
                Text("在本浏览器内拦截广告和跟踪请求，隐藏规则匹配的广告元素。规则随 App 提供，可手动更新。")
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("网络规则", value: "\(protection.networkCount)").accessibilityIdentifier("filter-network-count")
                LabeledContent("元素隐藏规则", value: "\(protection.cosmeticCount)").accessibilityIdentifier("filter-cosmetic-count")
                LabeledContent("未支持的规则", value: "\(protection.skippedCount)")
                Text("部分高级订阅语法无法转换为 WebKit 规则，会跳过处理。视频网站插播广告等内容不保证全部过滤。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("规则来源") {
                ForEach(TrackingProtection.sources, id: \.self) { Link($0.lastPathComponent, destination: $0) }
                if let date = protection.updatedAt { LabeledContent("最近更新") { Text(date, style: .date) } }
                else { Text("当前使用随 App 提供的规则。") }
                Button(protection.updating ? "正在更新规则…" : "更新过滤规则") {
                    updateTask = Task {
                        await protection.update()
                        if protection.failure == nil { browser.activeTab?.reload() }
                    }
                }.disabled(protection.updating).accessibilityIdentifier("update-content-filters")
                Text("更新只向 easylist.to 请求规则文件，不发送浏览记录。成功后重新加载当前页面，其余页面在下次加载时使用新规则。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let failure = protection.failure { Text(failure).foregroundStyle(.red) }
                Text("规则来自 The EasyList authors，按 CC BY-SA 3.0 许可使用；转换后的规则数据沿用相同许可。")
                    .font(.footnote).foregroundStyle(.secondary)
                Link("规则来源与许可", destination: URL(string: "https://easylist.to/pages/licence.html")!)
            }
            Section("暂停过滤的网站") {
                if let url = browser.activeTab?.url, ["http", "https"].contains(url.scheme ?? ""), !browser.profile.isPrivate {
                    Button(TrackingProtection.isExcepted(url) ? "恢复当前网站的过滤" : "为当前网站暂停过滤") {
                        TrackingProtection.setException(!TrackingProtection.isExcepted(url), for: url)
                        exceptions = TrackingProtection.exceptionHosts; browser.activeTab?.reload()
                    }.accessibilityIdentifier("content-filter-site-exception")
                }
                ForEach(exceptions, id: \.self) { host in
                    HStack {
                        Text(host)
                        Spacer()
                        Button("恢复过滤") {
                            TrackingProtection.removeException(host: host); exceptions = TrackingProtection.exceptionHosts
                            if browser.activeTab?.url?.host == host { browser.activeTab?.reload() }
                        }
                    }
                }
            }
        }
        .navigationTitle("广告过滤")
        .task { _ = try? await protection.ruleList() }
        .onDisappear { updateTask?.cancel() }
    }
}
