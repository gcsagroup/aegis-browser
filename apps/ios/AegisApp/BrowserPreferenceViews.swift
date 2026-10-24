import BrowserKit
import SwiftUI
import WebKit

struct BrowserGeneralSettingsView: View {
    @ObservedObject var preferences: BrowserPreferences
    @State private var draft = BrowserPreferenceValues()
    @State private var message: String?

    var body: some View {
        Form {
            Section("搜索") {
                SettingsPicker("搜索引擎", selection: $draft.searchEngine, value: draft.searchEngine?.title ?? "未启用搜索") {
                    if draft.availableSearchEngines.isEmpty {
                        Text("未启用搜索").tag(Optional<SearchEngine>.none)
                    }
                    ForEach(draft.availableSearchEngines, id: \.self) { Text($0.title).tag(Optional($0)) }
                }.accessibilityIdentifier("search-engine-picker")
                DisclosureGroup("管理搜索引擎") {
                    ForEach(draft.availableSearchEngines, id: \.self) { engine in
                        HStack {
                            Text(engine.title)
                            Spacer()
                            Button(role: .destructive) { draft.removeSearchEngine(engine); message = nil } label: {
                                Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("删除搜索引擎：\(engine.title)"))
                            .accessibilityIdentifier("remove-search-engine-\(engine.rawValue)")
                        }
                    }
                    Button("恢复预置引擎") { draft.restoreSearchEngines(); message = nil }
                        .accessibilityIdentifier("restore-search-engines")
                    Text("删除当前引擎后会切换到剩余的第一个；全部删除后只打开网址。点击“保存浏览设置”后生效。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if draft.searchEngine == .custom {
                    SettingsField("HTTPS 搜索模板") {
                        TextField("HTTPS 搜索模板", text: $draft.customSearch)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .accessibilityIdentifier("custom-search-template")
                    }
                    Text("用 {searchTerms} 表示搜索内容，例如 https://www.google.com/search?q={searchTerms}。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("主页与启动") {
                SettingsPicker("启动时", selection: $draft.startup, value: draft.startup.title) {
                    ForEach(BrowserStartup.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("startup-picker")
                SettingsField("主页网址") {
                    TextField("主页网址", text: $draft.homepage)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("homepage-field")
                }
                Toggle("新标签使用主页", isOn: $draft.newTabsUseHomepage)
                Text("启动方式在下次创建浏览窗口时生效；更改不会立即关闭当前标签。私密标签不恢复。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("网页显示") {
                SettingsPicker("默认网页缩放", selection: $draft.zoom, value: "\(Int(draft.zoom * 100))%") {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                }.accessibilityIdentifier("default-zoom-picker")
                Toggle("默认请求桌面网站", isOn: $draft.desktop).accessibilityIdentifier("desktop-default-toggle")
                Toggle("允许 JavaScript", isOn: $draft.javaScript)
                Toggle("允许脚本打开新标签", isOn: $draft.allowPopups)
                Toggle("播放媒体前需要操作", isOn: $draft.requireMediaGesture)
                Text("网站专用设置优先。脚本和桌面模式在重新载入后生效，弹窗与媒体选项在新标签中生效。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("历史记录") {
                Toggle("保存普通浏览历史", isOn: $draft.saveHistory)
                Text("关闭后不新增历史；已有记录继续保留，可在隐私设置中清除。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("保存浏览设置") {
                    do { try preferences.save(draft); message = String(localized: "浏览设置已保存。") }
                    catch { message = error.localizedDescription }
                }.accessibilityIdentifier("save-browser-preferences")
                if let message { Text(message).accessibilityIdentifier("browser-preferences-status") }
                if let error = preferences.error { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("浏览设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = preferences.values }
    }
}

struct ProtectionOptionsView: View {
    @ObservedObject var preferences: BrowserPreferences
    @State private var message: String?
    var body: some View {
        Form {
            Section("导航保护") {
                Toggle("链接追踪参数清理", isOn: binding(\.linkSanitization))
                Toggle("高风险网址检查", isOn: binding(\.phishingProtection))
                Text("关闭后不再执行对应的 Aegis 导航检查。系统 WebKit 的保护不受这些开关控制。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("WebKit 安全保护") {
                Toggle("已知挖矿资源拦截", isOn: optionalBinding(\.miningProtection, fallback: true)).accessibilityIdentifier("mining-protection")
                Toggle("已知指纹资源拦截", isOn: optionalBinding(\.fingerprintProtection, fallback: true)).accessibilityIdentifier("fingerprint-protection")
                Toggle("系统加固", isOn: optionalBinding(\.hardenedSecurity, fallback: false)).accessibilityIdentifier("hardened-security")
                if #available(iOS 26.4, *) {
                    Text("系统加固关闭网页 JIT，并使用系统可用的内存保护；设备支持范围不同，可能影响性能。重新载入页面后生效。")
                } else {
                    Text("当前系统保留默认 WebKit 保护；系统加固需 iOS 26.4 或更高版本。")
                }
                Toggle("严格指纹限制（实验）", isOn: optionalBinding(\.strictFingerprinting, fallback: false)).accessibilityIdentifier("strict-fingerprinting")
                Text("限制 Canvas、WebGL 和音频结果读取，可能影响绘图、游戏和音频。可在网站设置中恢复；Worker 等路径仍可能绕过。重新载入后生效。")
                Text("安全资源规则独立于广告过滤。规则快照随 App 更新，不发送网址查询；页面检查只读取结构，不读取表单输入。")
                if let version = LocalThreatDatabase.version {
                    Text("安全规则版本：\(String(version))")
                    if LocalThreatDatabase.isExpired { Text("安全规则快照已过期，继续使用现有规则，请更新 App。") }
                } else { Text("安全规则校验失败，网页保护无法准备完成，请更新 App。") }
            }.font(.callout)
            Section("过滤规则更新") {
                Toggle("自动检查过滤规则更新", isOn: binding(\.automaticFilterUpdates))
                    .accessibilityIdentifier("automatic-filter-updates")
                Text("在普通浏览进入前台时检查，成功更新间隔至少 24 小时，失败后至少 1 小时再试。只请求 EasyList 规则，不发送浏览历史；关闭 App 后不承诺定时运行。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("当前保护范围") {
                Text("已支持独立安全资源规则、网址与页面结构检查、系统加固和可选指纹限制。页面结构观察限加载后的前一分钟。")
                Text("iOS 使用系统 WebKit；没有移植 V8 字节码或完整 CNAME 检查。行为提示不能证明未知挖矿，严格指纹限制也不是不可绕过的引擎保护。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let message { Text(message).foregroundStyle(.red) }
        }.navigationTitle("保护选项").navigationBarTitleDisplayMode(.inline)
    }
    private func optionalBinding(_ key: WritableKeyPath<BrowserPreferenceValues, Bool?>, fallback: Bool) -> Binding<Bool> {
        Binding(get: { preferences.values[keyPath: key] ?? fallback }, set: { value in
            var next = preferences.values; next[keyPath: key] = value
            do { try preferences.save(next) } catch { message = error.localizedDescription }
        })
    }
    private func binding(_ key: WritableKeyPath<BrowserPreferenceValues, Bool>) -> Binding<Bool> {
        Binding(get: { preferences.values[keyPath: key] }, set: { value in
            var next = preferences.values; next[keyPath: key] = value
            do { try preferences.save(next) } catch { message = error.localizedDescription }
        })
    }
}

struct WebsiteSettingsView: View {
    @EnvironmentObject private var browser: BrowserSession
    @ObservedObject var preferences: BrowserPreferences
    var body: some View {
        List {
            if let url = browser.activeTab?.url, let origin = BrowserPreferences.origin(url) {
                Section("当前网站") {
                    NavigationLink(origin) { SitePreferenceEditor(preferences: preferences, url: url) }
                        .accessibilityIdentifier("current-site-settings")
                }
            }
            Section("已保存的网站设置") {
                if preferences.values.sites.isEmpty { Text("尚无网站专用设置。") }
                ForEach(preferences.values.sites.keys.sorted(), id: \.self) { origin in
                    if let url = URL(string: origin) {
                        NavigationLink(origin) { SitePreferenceEditor(preferences: preferences, url: url) }
                    }
                }
            }
            Section {
                Text("网站设置按协议、主机和端口分别保存。相机和麦克风的“询问”仍需系统许可；定位等权限由系统提示管理。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("网站设置与权限").navigationBarTitleDisplayMode(.inline)
    }
}

struct SitePreferenceEditor: View {
    @EnvironmentObject private var browser: BrowserSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var preferences: BrowserPreferences
    let url: URL
    @State private var draft = SitePreferences()
    @State private var message: String?
    @State private var confirmsSave = false
    var body: some View {
        Form {
            Section { Text(BrowserPreferences.origin(url) ?? "").textSelection(.enabled) }
            Section("网页显示") {
                SettingsPicker("网页缩放", selection: $draft.zoom, value: draft.zoom.map { "\(Int($0 * 100))%" } ?? "跟随默认设置") {
                    Text("跟随默认设置").tag(Optional<Double>.none)
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { Text("\(Int($0 * 100))%").tag(Optional($0)) }
                }
                SettingsPicker("网站模式", selection: $draft.desktop, value: draft.desktop.map { $0 ? "桌面网站" : "移动网站" } ?? "跟随默认设置") {
                    Text("跟随默认设置").tag(Optional<Bool>.none)
                    Text("移动网站").tag(Optional(false))
                    Text("桌面网站").tag(Optional(true))
                }
                SettingsPicker("JavaScript", selection: $draft.javaScript, value: draft.javaScript.map { $0 ? "允许" : "阻止" } ?? "跟随默认设置") {
                    Text("跟随默认设置").tag(Optional<Bool>.none)
                    Text("允许").tag(Optional(true))
                    Text("阻止").tag(Optional(false))
                }
            }
            Section("网页安全") {
                SettingsPicker("系统加固", selection: $draft.hardenedSecurity, value: draft.hardenedSecurity.map { $0 ? "开启" : "系统默认" } ?? "跟随默认设置") {
                    Text("跟随默认设置").tag(Optional<Bool>.none)
                    Text("开启").tag(Optional(true))
                    Text("系统默认").tag(Optional(false))
                }
                SettingsPicker("严格指纹限制（实验）", selection: $draft.strictFingerprinting, value: draft.strictFingerprinting.map { $0 ? "开启" : "恢复兼容" } ?? "跟随默认设置") {
                    Text("跟随默认设置").tag(Optional<Bool>.none)
                    Text("开启").tag(Optional(true))
                    Text("恢复兼容").tag(Optional(false))
                }
            }
            Section("媒体权限") {
                SettingsPicker("相机", selection: $draft.camera, value: draft.camera.title) { ForEach(SitePermission.allCases, id: \.self) { Text($0.title).tag($0) } }
                SettingsPicker("麦克风", selection: $draft.microphone, value: draft.microphone.title) { ForEach(SitePermission.allCases, id: \.self) { Text($0.title).tag($0) } }
            }
            Section {
                Button("保存网站设置") {
                    if browser.profile.isPrivate { confirmsSave = true } else { save() }
                }.accessibilityIdentifier("save-site-preferences")
                Button("恢复此网站默认设置") {
                    do { try preferences.setSite(nil, for: url); dismiss() }
                    catch { message = error.localizedDescription }
                }
                Text("保存后重新载入页面，以应用网站模式、脚本及权限规则。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let message { Text(message) }
            }
        }.navigationTitle("网站设置").navigationBarTitleDisplayMode(.inline)
            .onAppear { draft = preferences.site(for: url) }
            .alert("保存私密网站的设置？", isPresented: $confirmsSave) {
                Button("确认保存") { save() }
                Button("取消", role: .cancel) { }
            } message: { Text("网站地址与设置会保留在本机，普通和私密浏览均会使用。\n\(BrowserPreferences.origin(url) ?? "")") }
    }
    private func save() {
        do { try preferences.setSite(draft, for: url); message = String(localized: "网站设置已保存。") }
        catch { message = error.localizedDescription }
    }
}

struct WebsiteDataSettingsView: View {
    @EnvironmentObject private var browser: BrowserSession
    @State private var records: [WKWebsiteDataRecord] = []
    @State private var selection: WKWebsiteDataRecord?
    @State private var busy = false
    @State private var confirmsRemoval = false
    @State private var message: String?
    var body: some View {
        List {
            Section {
                Text("管理普通浏览的 Cookie、缓存和网站存储。清除前会关闭所有普通浏览窗口中的标签，避免页面立即重新写入；收藏、工作区和阅读资料不受影响。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("website-data-description")
                if browser.profile.isPrivate { Text("请切换到普通浏览后管理持久网站数据。") }
            }
            Section("网站数据") {
                if records.isEmpty { Text("没有可显示的网站数据。") }
                ForEach(records, id: \.displayName) { record in
                    Button { selection = record; confirmsRemoval = true } label: {
                        HStack { Text(record.displayName); Spacer(); Image(systemName: "trash") }
                    }.disabled(busy || browser.profile.isPrivate)
                }
            }
            if let message { Text(message) }
        }.navigationTitle("网站数据管理").navigationBarTitleDisplayMode(.inline)
            .task { await refresh() }
            .refreshable { await refresh() }
            .alert("清除此网站的数据？", isPresented: $confirmsRemoval) {
                Button("关闭普通标签并清除", role: .destructive) {
                    guard let selection else { return }
                    busy = true
                    Task { @MainActor in
                        await browser.clearWebsiteData(records: [selection])
                        await refresh(); busy = false; message = String(localized: "所选网站的数据已清除。")
                    }
                }
                Button("取消", role: .cancel) { selection = nil }
            } message: { Text(selection?.displayName ?? "") }
    }
    private func refresh() async {
        guard !browser.profile.isPrivate else { records = []; return }
        records = await WKWebsiteDataStore.default().dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}
