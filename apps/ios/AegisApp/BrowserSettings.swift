import AgentKit
import AccessKit
import BrowserKit
import SwiftUI

struct ImageOcrConfiguration: Codable {
    enum Mode: String, CaseIterable, Codable {
        case official
        case custom
        case local

        var label: LocalizedStringKey {
            switch self {
            case .official: "使用 Aegis 服务"
            case .custom: "自定义服务器"
            case .local: "仅本机识别"
            }
        }
    }

    static let storageKey = "browser.imageOCR"
    var mode: Mode = .official
    var endpoint = ""
}

@MainActor
final class BrowserSettings: ObservableObject {
    @Published var model: ModelConfiguration {
        didSet { if let data = try? JSONEncoder().encode(model) { defaults.set(data, forKey: "model.configuration.v1") } }
    }
    @Published var appearance: String { didSet { defaults.set(appearance, forKey: "browser.appearance") } }
    @Published var imageOCR: ImageOcrConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(imageOCR) {
                defaults.set(data, forKey: ImageOcrConfiguration.storageKey)
            }
        }
    }
    let browserPreferences: BrowserPreferences
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        browserPreferences = BrowserPreferences(defaults: defaults)
        model = defaults.data(forKey: "model.configuration.v1").flatMap { try? JSONDecoder().decode(ModelConfiguration.self, from: $0) } ?? ModelConfiguration()
        appearance = defaults.string(forKey: "browser.appearance") ?? "system"
        imageOCR = defaults.data(forKey: ImageOcrConfiguration.storageKey)
            .flatMap { try? JSONDecoder().decode(ImageOcrConfiguration.self, from: $0) } ?? ImageOcrConfiguration()
    }
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }
}

struct BrowserSettingsView: View {
    @EnvironmentObject private var settings: BrowserSettings
    @EnvironmentObject private var browser: BrowserSession
    @EnvironmentObject private var hostStores: AccessHostStoreCoordinator
    @Environment(\.dismiss) private var dismiss

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        NavigationStack {
            Form {
                Section("浏览") {
                    NavigationLink("搜索、主页与浏览方式") { BrowserGeneralSettingsView(preferences: browser.preferences) }
                        .accessibilityIdentifier("general-browser-settings")
                    if let tab = browser.activeTab, hostStores.offersWebsiteAcceleration(for: tab) {
                        NavigationLink("国内加速") {
                            if let current = browser.activeTab { DomesticAccelerationSettingsView(tab: current) }
                        }
                        .accessibilityIdentifier("domestic-acceleration-link")
                    }
                    Button("打开系统 App 设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section("隐私保护") {
                    NavigationLink {
                        AccessUsagePage(isPrivate: browser.profile.isPrivate)
                    } label: { Label("隐藏地理位置服务", systemImage: "location.slash") }
                        .accessibilityIdentifier("access-usage-link")
                    AccessTestNodeOptionsLink(isPrivate: browser.profile.isPrivate)
                    NavigationLink("网站设置与权限") { WebsiteSettingsView(preferences: browser.preferences) }
                        .accessibilityIdentifier("website-settings")
                    NavigationLink("网站数据管理") { WebsiteDataSettingsView() }
                        .accessibilityIdentifier("website-data-settings")
                }
                Section("Aegis 功能") {
                    NavigationLink { AegisFeatureSettingsView() } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Aegis 设置").font(.headline)
                            Text("隐私防护、网站增强、阅读、AI 与下载")
                                .font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }.padding(.vertical, 5)
                    }.accessibilityIdentifier("aegis-feature-settings")
                    NavigationLink("服务诊断") { AccessDiagnosticsView() }
                        .accessibilityIdentifier("access-diagnostics-settings")
                }
                Section("外观") {
                    SettingsPicker("主题", selection: $settings.appearance,
                                   value: settings.appearance == "dark" ? "深色" : settings.appearance == "light" ? "浅色" : "跟随系统") {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    NavigationLink("语言") { LanguageSettingsView() }
                        .accessibilityIdentifier("language-settings-link")
                }
                Section("关于") {
                    LabeledContent(
                        "应用",
                        value: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Aegis Browser"
                    )
                    LabeledContent("版本", value: version)
                    LabeledContent("网页引擎") { Text("系统 WebKit") }
                    NavigationLink("开源许可与鸣谢") { ThirdPartyNoticesView() }
                        .accessibilityIdentifier("third-party-notices-link")
                    if let website = URL(string: "https://www.gcsa.com/") {
                        Link("官方网站", destination: website)
                            .accessibilityIdentifier("aegis-website-link")
                    }
                    if let support = URL(string: "https://www.gcsa.com/about#contact") {
                        Link("技术支持", destination: support)
                            .accessibilityIdentifier("aegis-support-link")
                    }
                    if let privacyPolicy = URL(string: "https://gist.github.com/GCSA-ToolsTeam/7d8772461740216defce94e5be654cc5") {
                        Link("隐私政策", destination: privacyPolicy)
                            .accessibilityIdentifier("aegis-privacy-policy-link")
                    }
#if DEBUG
                    Text("开发测试版")
#endif
                    Text("私密浏览不自动保存历史和会话。主动保存的收藏、工作区、下载和分析结果会继续保留。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .localizedNavigationTitle("设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("settings-done") } }
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "Ver \(info["CFBundleShortVersionString"] as? String ?? "2.0") (\(info["CFBundleVersion"] as? String ?? "0"))"
    }
}


// 功能名称与桌面一致，使用 iOS 的导航、触控尺寸和动态字号。
private struct DomesticAccelerationSettingsView: View {
    @EnvironmentObject private var browser: BrowserSession
    @EnvironmentObject private var hostStores: AccessHostStoreCoordinator
    @ObservedObject var tab: BrowserTab

    var body: some View {
        Form {
            if browser.activeTab === tab, hostStores.offersWebsiteAcceleration(for: tab) {
                Section {
                    modeButton(.manual, title: "手动", id: "website-acceleration-manual")
                    modeButton(.smart, title: "智能", id: "website-acceleration-smart")
                    if let categories = hostStores.websiteCategories(for: tab) {
                        WebsiteCategoriesLink(tab: tab, selected: categories.selected)
                    }
                } header: {
                    Text("网站加速")
                        .accessibilityIdentifier("website-acceleration-section")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        switch hostStores.websiteAccelerationMode {
                        case .manual:
                            Text("自行选择要加速的网站。")
                        case .smart:
                            if hostStores.websiteCategories(for: tab)?.selected.isEmpty == true {
                                Text("未选择加速分类。")
                            } else {
                                Text("按所选分类加速网站。")
                            }
                            if hostStores.smartModeReplacesDefaultLocationPrivacy {
                                Text("选择智能后，其他网站首次打开时不再默认隐藏位置。")
                                    .accessibilityIdentifier("website-acceleration-smart-location-privacy")
                            }
                        }
                        if !hostStores.offersLocationService {
                            Text("加速服务未配置。")
                                .accessibilityIdentifier("website-acceleration-service-unavailable")
                        }
                        switch hostStores.geoSiteStatus {
                        case .unsaved:
                            Text("设置未保存，请重试。")
                        case .unavailable, .clockRollback:
                            Text("连接暂不可用")
                        default:
                            EmptyView()
                        }
                    }
                }
                if let host = hostStores.websiteAccelerationHost(for: tab) {
                    Section {
                        LabeledContent("当前网站", value: host.rawValue)
                        LabeledContent("下次打开时的连接") {
                            switch hostStores.websiteRouteSelection(for: tab) {
                            case .service:
                                Text("使用连接服务")
                            case .original:
                                Text("使用原有连接")
                            case nil:
                                Text("按现有规则选择连接")
                            }
                        }
                        siteButton(.service, title: "使用连接服务", host: host)
                        siteButton(.original, title: "使用原有连接", host: host)
                        siteButton(nil, title: "清除站点选择", host: host)
                    } header: {
                        Text("本站连接")
                    } footer: {
                        Text("站点选择用于此域名的主页面。清除后恢复所选模式和已有隐私设置。")
                    }
                }
            }
        }
        .localizedNavigationTitle("国内加速")
    }

    private func modeButton(_ mode: AccessWebsiteAccelerationMode, title: LocalizedStringKey, id: String) -> some View {
        choiceButton(title, selected: hostStores.websiteAccelerationMode == mode) {
            guard browser.activeTab === tab else { return }
            hostStores.setWebsiteAccelerationMode(mode, for: tab)
        }
        .accessibilityIdentifier(id)
    }

    private func siteButton(_ choice: AccessWebsiteRouteChoice?, title: LocalizedStringKey, host: AccessSiteHost) -> some View {
        choiceButton(title, selected: hostStores.websiteRouteChoice(for: tab) == choice) {
            guard browser.activeTab === tab else { return }
            hostStores.setWebsiteRouteChoice(choice, for: tab, displayedHost: host)
        }
    }

    private func choiceButton(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension AccessGeoSiteCategory {
    var displayName: LocalizedStringResource {
        switch self {
        case .debian: "Debian"
        case .douban: "豆瓣"
        case .meituan: "美团"
        }
    }
}

private struct WebsiteCategoriesLink: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var textSize
    let tab: BrowserTab
    let selected: Set<AccessGeoSiteCategory>

    var body: some View {
        let title = AegisLocalization.string("加速分类")
        let names = AccessGeoSiteCategory.allCases.filter { selected.contains($0) }
            .map { AegisLocalization.string($0.displayName) }
        let summary = names.isEmpty ? AegisLocalization.string("未选择")
            : names.formatted(.list(type: .and).locale(locale))
        let layout = textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 10))
        NavigationLink {
            WebsiteCategoriesView(tab: tab)
        } label: {
            layout {
                Text(titleWithBeta(title))
                    .fixedSize(horizontal: false, vertical: true)
                if !textSize.isAccessibilitySize { Spacer(minLength: 0) }
                Text(verbatim: summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityLabel(Text(verbatim: title + " Beta"))
        .accessibilityValue(Text(verbatim: summary))
        .accessibilityIdentifier("website-acceleration-categories")
    }

    private func titleWithBeta(_ name: String) -> AttributedString {
        var title = AttributedString(name + " ")
        var beta = AttributedString("Beta")
        beta.font = .caption.weight(.semibold)
        beta.foregroundColor = .secondary
        title.append(beta)
        return title
    }
}

private struct WebsiteCategoriesView: View {
    @EnvironmentObject private var browser: BrowserSession
    @EnvironmentObject private var hostStores: AccessHostStoreCoordinator
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var tab: BrowserTab
    @State private var approval: Task<Void, Never>?
    @State private var unsavedApproval: AccessGeoSiteCache.Proposal?

    var body: some View {
        Form {
            if browser.activeTab === tab, let categories = hostStores.websiteCategories(for: tab) {
                Section {
                    ForEach(AccessGeoSiteCategory.allCases, id: \.self) { category in
                        if categories.scopes != nil || categories.catalogue.groups[category] != nil {
                            categoryButton(category, categories: categories)
                        }
                    }
                }
                Section("分类范围") {
                    ForEach(AccessGeoSiteCategory.allCases, id: \.self) { category in
                        if categories.scopes != nil || categories.catalogue.groups[category] != nil {
                            DisclosureGroup {
                                scopeDetails(category, categories: categories)
                            } label: {
                                Text(verbatim: AegisLocalization.string(category.displayName))
                                    .accessibilityIdentifier("website-acceleration-details-\(category.rawValue)")
                            }
                        }
                    }
                }
            }
        }
        .localizedNavigationTitle("加速分类")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { approval?.cancel() }
        .onChange(of: browser.tabSelectionRevision) { _, _ in approval?.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { approval?.cancel() } }
    }

    private func categoryButton(_ category: AccessGeoSiteCategory,
                                categories: AccessHostStoreCoordinator.WebsiteCategories) -> some View {
        let selected = categories.selected.contains(category)
        let pending = selected && categories.staged[category] != nil
        let includesDianping = category == .meituan
        let details = [includesDianping ? AegisLocalization.string("含大众点评") : nil,
                       pending ? AegisLocalization.string("等待确认") : nil].compactMap { $0 }
        return Button {
            guard browser.activeTab === tab else { return }
            hostStores.setWebsiteCategory(category, selected: !selected, from: categories, for: tab)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: AegisLocalization.string(category.displayName))
                    if includesDianping { Text("含大众点评").font(.footnote).foregroundStyle(.secondary) }
                    if pending { Text("等待确认").font(.footnote).foregroundStyle(.secondary) }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(verbatim: AegisLocalization.string(category.displayName)))
        .accessibilityValue(Text(verbatim: ListFormatter.localizedString(byJoining: details)))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("website-acceleration-category-\(category.rawValue)")
    }

    @ViewBuilder
    private func scopeDetails(_ category: AccessGeoSiteCategory,
                              categories: AccessHostStoreCoordinator.WebsiteCategories) -> some View {
        switch categories.scopes?[category] {
        case .available(let group, let version):
            LabeledContent("版本", value: version?.release.tag ?? categories.catalogue.tag)
            if let version { expiry(version.expiry) }
            LabeledContent("域名数", value: group.rules.count.formatted(.number.locale(locale)))
            typedRules(group.rules)
        case .withdrawn(let tag):
            LabeledContent("版本", value: tag)
            Text("暂无规则")
        case .expired(_, let version):
            LabeledContent("版本", value: version.release.tag)
            expiry(version.expiry)
            Text("暂不可用")
        case .unavailable:
            Text("暂不可用")
        case nil:
            if let group = categories.catalogue.groups[category] {
                LabeledContent("版本", value: categories.catalogue.tag)
                LabeledContent("域名数", value: group.rules.count.formatted(.number.locale(locale)))
                typedRules(group.rules)
            }
        }
        if let staged = categories.staged[category] {
            stagedDetails(staged, category: category)
        }
    }

    private func expiry(_ date: Date) -> some View {
        LabeledContent("到期时间") { Text(date, format: .dateTime.year().month().day().hour().minute()) }
    }

    @ViewBuilder
    private func stagedDetails(_ staged: AccessGeoSiteCache.StagedScope, category: AccessGeoSiteCategory) -> some View {
        LabeledContent("等待确认", value: staged.release.tag)
            .accessibilityIdentifier("website-acceleration-candidate-\(category.rawValue)")
        expiry(staged.expiry)
        LabeledContent("新增域名数", value: staged.addedRules.count.formatted(.number.locale(locale)))
        if staged.addedRules.count > 32 {
            Text("新增范围过大，无法批准。").font(.footnote)
        } else {
            typedRules(staged.addedRules)
            Text("页面资源随主页面使用同一连接。").font(.footnote).foregroundStyle(.secondary)
            if let proposal = hostStores.websiteCategoryProposal(category, for: browser) {
                Button("批准新增范围") { approve(proposal) }
                    .disabled(approval != nil || scenePhase != .active)
                    .accessibilityIdentifier("website-acceleration-approve-\(category.rawValue)")
                    .onDisappear { approval?.cancel() }
                if unsavedApproval == proposal { Text("设置未保存，请重试。").font(.footnote) }
            }
        }
    }

    private func approve(_ proposal: AccessGeoSiteCache.Proposal) {
        guard approval == nil, scenePhase == .active, browser.activeTab === tab else { return }
        unsavedApproval = nil
        approval = Task { @MainActor in
            let accepted = await hostStores.confirmWebsiteCategory(proposal, for: browser)
            if !accepted, !Task.isCancelled { unsavedApproval = proposal }
            approval = nil
        }
    }

    @ViewBuilder
    private func typedRules(_ rules: [AccessGeoSiteCatalogue.Rule]) -> some View {
        let domains = rules.filter { $0.kind == .domain }
        let exact = rules.filter { $0.kind == .full }
        if !domains.isEmpty {
            Text("含所列域名的子域名。").font(.footnote).foregroundStyle(.secondary)
            domainList(domains)
        }
        if !exact.isEmpty {
            Text("仅匹配所列域名。").font(.footnote).foregroundStyle(.secondary)
            domainList(exact)
        }
    }

    private func domainList(_ rules: [AccessGeoSiteCatalogue.Rule]) -> some View {
        Text(verbatim: rules.map(\.host).joined(separator: "\n"))
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AegisFeatureSettingsView: View {
    @EnvironmentObject private var browser: BrowserSession
    @State private var showsDownloads = false

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        Form {
            Section {
                NavigationLink { AegisProtectionSettingsView() } label: {
                    row("隐私与防护", "保护选项、广告过滤与网站数据", "hand.raised")
                }.accessibilityIdentifier("aegis-privacy-settings")
                NavigationLink { WebsiteEnhancementsView(embedded: true) } label: {
                    row("网站增强与脚本", "网站规则与已安装脚本", "puzzlepiece.extension")
                }.accessibilityIdentifier("enhancement-settings")
                NavigationLink {
                    Form {
                        Section {
                            NavigationLink("阅读外观与图片权限") { ReadingPreferencesView() }
                                .accessibilityIdentifier("reading-preferences-settings")
                            NavigationLink("Markdown 自动预览网站") { WebsiteSettingsView(preferences: browser.preferences) }
                        }
                    }.localizedNavigationTitle("阅读与 Markdown").navigationBarTitleDisplayMode(.inline)
                } label: { row("阅读与 Markdown", "阅读外观、图片权限与自动预览", "doc.text") }
                    .accessibilityIdentifier("aegis-reading-settings")
                NavigationLink { ModelSettingsView() } label: {
                    row("AI 与模型", "模型服务与连接设置", "sparkles")
                }.accessibilityIdentifier("model-service-settings")
                Button { showsDownloads = true } label: {
                    HStack {
                        row("下载增强", "下载任务、网络选项与存储", "arrow.down.circle")
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.secondary).accessibilityHidden(true)
                    }
                }.accessibilityIdentifier("aegis-downloads-settings")
                NavigationLink { ImageOcrSettingsView() } label: {
                    row("图片文字识别", "设置本机识别与服务器兜底", "text.viewfinder")
                }.accessibilityIdentifier("image-ocr-settings")
                NavigationLink {
                    Form {
                        Section("网站实验选项") {
                            NavigationLink("网站设置与权限") { WebsiteSettingsView(preferences: browser.preferences) }
                        }
                    }.localizedNavigationTitle("实验功能").navigationBarTitleDisplayMode(.inline)
                } label: { row("实验功能", "严格指纹限制（实验）", "flask") }
                    .accessibilityIdentifier("aegis-experiments-settings")
            }
        }
        .localizedNavigationTitle("Aegis 设置")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsDownloads) { DownloadsView() }
    }

    private func row(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, _ icon: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            // 装饰图标固定尺寸；辅助字号放大文字时不挤占文本或越出卡片。
            Image(systemName: icon).font(.system(size: 20)).frame(width: 24)
                .foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).foregroundStyle(Color.primary)
                Text(subtitle).font(.footnote).foregroundStyle(Color.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ImageOcrSettingsView: View {
    @EnvironmentObject private var settings: BrowserSettings
    @State private var draft = ImageOcrConfiguration()
    @State private var message: LocalizedStringKey?

    var body: some View {
        Form {
            Section {
                Picker("服务器兜底", selection: $draft.mode) {
                    ForEach(ImageOcrConfiguration.Mode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }.accessibilityIdentifier("image-ocr-mode")
                if draft.mode == .custom {
                    TextField("HTTPS 接口地址", text: $draft.endpoint,
                              prompt: Text("https://ocr.example.com/v1/ocr"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("image-ocr-endpoint")
                }
                if draft.mode == .official {
                    if let service = OCRService.configured(for: ImageOcrConfiguration()) {
                        Text(service.destination).foregroundStyle(.secondary)
                    } else {
                        Text("此版本尚未配置 Aegis 服务器。").foregroundStyle(.secondary)
                    }
                }
                Button("保存") { save() }.accessibilityIdentifier("image-ocr-save")
                if let message { Text(message).accessibilityIdentifier("image-ocr-settings-status") }
            } footer: {
                Text("优先在本机识别。使用服务器时，每次发送前都需要确认。")
            }
        }
        .localizedNavigationTitle("图片文字识别")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = settings.imageOCR }
    }

    private func save() {
        if draft.mode == .custom {
            guard let url = OCRService.httpsEndpoint(draft.endpoint) else {
                message = "请输入以 /v1/ocr 结尾的 HTTPS 接口地址。"
                return
            }
            draft.endpoint = url.absoluteString
        } else {
            draft.endpoint = settings.imageOCR.endpoint
        }
        settings.imageOCR = draft
        message = "设置已保存。"
    }
}

private struct AegisProtectionSettingsView: View {
    @EnvironmentObject private var browser: BrowserSession
    @State private var clearing = false
    @State private var clearingWebsites = false
    @State private var deletingWebsites = false
    @State private var message: AegisLocalizedMessage?

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        Form {
            Section("隐私与保护") {
                NavigationLink("保护选项") { ProtectionOptionsView(preferences: browser.preferences) }
                    .accessibilityIdentifier("protection-options")
                NavigationLink("广告与跟踪过滤") { ContentFilterSettingsView() }
                    .accessibilityIdentifier("content-filter-settings")
                if let url = browser.activeTab?.url, ["http", "https"].contains(url.scheme ?? ""), !browser.profile.isPrivate {
                    Button(TrackingProtection.isExcepted(url) ? "恢复当前网站的跟踪拦截" : "为当前网站暂停跟踪拦截") {
                        TrackingProtection.setException(!TrackingProtection.isExcepted(url), for: url)
                        browser.activeTab?.reload()
                        message = .resource("已更新当前网站的设置并重新加载。")
                    }
                    Text(url.host ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Text("网址检查基于本地规则，不能保证识别所有风险。网页内容仍由系统 WebKit 加载。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("清除浏览历史", role: .destructive) { clearing = true }
                Button("清除网站数据", role: .destructive) { clearingWebsites = true }
                    .disabled(browser.profile.isPrivate || deletingWebsites)
            }
            Section {
                NavigationLink {
                    Form { FirebaseControlsView() }
                        .localizedNavigationTitle("诊断与使用分析")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("诊断与使用分析")
                        Text("崩溃报告、使用分析与远程诊断配置默认开启，可随时关闭。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("firebase-data-collection-details")
            } header: {
                Text("诊断与使用分析")
            }
            if let message { Text(message.text).foregroundStyle(.secondary) }
        }
        .localizedNavigationTitle("隐私与防护")
        .navigationBarTitleDisplayMode(.inline)
        .alert("清除网站数据？", isPresented: $clearingWebsites) {
            Button("清除并关闭普通标签", role: .destructive) {
                deletingWebsites = true
                Task { @MainActor in
                    await browser.clearWebsiteData()
                    deletingWebsites = false
                    message = .resource("网站数据已清除。")
                }
            }
            Button("取消", role: .cancel) { }
        } message: { Text("将关闭普通标签并清除 Cookie、网站存储和缓存。网站登录会退出，收藏和工作区会保留。") }
        .confirmationDialog("清除全部浏览历史？", isPresented: $clearing, titleVisibility: .visible) {
            Button("清除历史", role: .destructive) {
                guard !browser.profile.isPrivate else { return }
                browser.dataStore.clearHistory()
                message = .verbatim(browser.dataStore.history.isEmpty ? "浏览历史已清除。" : "浏览历史未能清除，请重启后重试。")
            }
        }
    }
}

struct ModelSettingsView: View {
    @EnvironmentObject private var settings: BrowserSettings
    @State private var configuration = ModelConfiguration()
    @State private var key = ""
    @State private var models: [String] = []
    @State private var message: AegisLocalizedMessage?
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @FocusState private var editing: Bool

    @Environment(\.locale) private var localizationLocale
    var body: some View {
        let _ = localizationLocale
        Form {
            Section("连接设置") {
                SettingsPicker("接口类型", selection: $configuration.provider, value: configuration.provider.title) {
                    ForEach(ModelProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                SettingsField("服务地址（包含 API 版本路径）") {
                    TextField("服务地址（包含 API 版本路径）", text: $configuration.endpoint)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("model-endpoint")
                        .focused($editing)
                }
                SettingsField("API 密钥（本机服务可留空）") {
                    SecureField("API 密钥（本机服务可留空）", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($editing)
                }
                SettingsField("模型名称") {
                    TextField("模型名称", text: $configuration.model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("model-name")
                        .focused($editing)
                }
                Text("兼容接口示例：https://服务地址/v1。密钥保存在系统钥匙串，仅用于当前服务。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button(busy ? "正在连接…" : "检测可用模型") { detect() }.disabled(busy)
                    .accessibilityIdentifier("detect-models")
                ForEach(models, id: \.self) { name in
                    Button { configuration.model = name } label: {
                        HStack { Text(name); Spacer(); if name == configuration.model { Image(systemName: "checkmark") } }
                    }
                }
                Button("保存设置") {
                    editing = false
                    do {
                        _ = try configuration.validatedURL()
                        guard !configuration.model.isEmpty else { throw ModelClientError.missingModel }
                        try ModelCredentialStore.save(key, for: configuration)
                        settings.model = configuration
                        message = .resource("模型设置已保存。")
                    } catch { message = .error(error) }
                }.disabled(busy).accessibilityIdentifier("save-model")
                if let message { Text(message.text).font(.callout).textSelection(.enabled).accessibilityIdentifier("model-status") }
            }
        }
        .localizedNavigationTitle("模型服务")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { configuration = settings.model; key = ModelCredentialStore.read(for: configuration) }
        .onChange(of: configuration.endpoint) { _, _ in key = ModelCredentialStore.read(for: configuration); models = []; message = nil }
        .onChange(of: configuration.provider) { _, _ in key = ModelCredentialStore.read(for: configuration); models = []; message = nil }
        .onDisappear { operation?.cancel() }
    }

    private func detect() {
        editing = false
        busy = true
        message = nil
        let client = ModelClient(configuration: configuration, key: key)
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let values = try await client.models()
                try Task.checkCancellation()
                models = values
                if configuration.model.isEmpty { configuration.model = values[0] }
                message = .resource("连接成功，请选择模型并保存。")
            } catch is CancellationError { } catch { message = .error(error) }
        }
    }
}

private struct AccessDiagnosticsView: View {
    @AppStorage(AccessDiagnosticLog.preferenceKey) private var level = AccessDiagnosticLog.defaultLevel.rawValue
    @State private var log = ""
    @State private var unavailable = false
    @State private var persistenceProblem = false
    @State private var clearing = false
    @State private var storageClearing = false
    @State private var clearMessage: String?
    @State private var share: AccessDiagnosticShare?
    @State private var presentedShareURL: URL?
    @State private var archiveCleanupPending = AccessDiagnosticArchive.hasPendingCleanup
    @State private var showShareConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("日志级别") {
                Picker("级别", selection: $level) {
                    Text("调试 (debug)").tag(AccessLogLevel.debug.rawValue)
                    Text("信息 (info)").tag(AccessLogLevel.info.rawValue)
                    Text("警告 (warning)").tag(AccessLogLevel.warning.rawValue)
                    Text("错误 (error)").tag(AccessLogLevel.error.rawValue)
                    Text("关闭 (none)").tag(AccessLogLevel.none.rawValue)
                }
                Text("关闭立即生效并清空日志；其他级别在代理核心下次启动时生效。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("诊断日志") {
                Text("日志保存在本机，重启后可查看，保留最近约 256 KB。为保护凭据，仅显示部分诊断信息和访问目标；普通和私密会话的目标都可能写入磁盘，分享前请确认接收方可信。")
                    .font(.footnote).foregroundStyle(.secondary)
                if persistenceProblem {
                    Text("磁盘日志读取或保存失败；当前内存日志仍可查看。清理后可重试。")
                        .foregroundStyle(.secondary)
                }
                if archiveCleanupPending {
                    Text("压缩日志的临时文件清理失败。清理成功后可再次分享。")
                        .foregroundStyle(.secondary)
                    Button("重试清理压缩日志", action: retryArchiveCleanup)
                }
                if unavailable {
                    Text("日志接收器不可用；代理仍可使用。请重新启动代理后重试。")
                        .foregroundStyle(.secondary)
                }
                if log.isEmpty {
                    Text("暂无日志").foregroundStyle(.secondary)
                } else {
                    Text(log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .accessibilityIdentifier("access-diagnostics-log")
                }
                Button(clearing || storageClearing ? "正在清理…" : "清理内存和磁盘日志", action: clearLogs)
                    .disabled(clearing || storageClearing)
                    .accessibilityIdentifier("access-diagnostics-clear")
                if let clearMessage { Text(clearMessage).font(.footnote).foregroundStyle(.secondary) }
                Button("压缩并分享") { showShareConfirmation = true }
                    .disabled(log.isEmpty || archiveCleanupPending || presentedShareURL != nil)
                    .accessibilityIdentifier("access-diagnostics-share")
                    .confirmationDialog("日志可能包含普通和私密会话的访问目标，确认压缩并分享？", isPresented: $showShareConfirmation, titleVisibility: .visible) {
                        Button("继续分享", action: prepareShare)
                        Button("取消", role: .cancel) { }
                    }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .localizedNavigationTitle("服务诊断")
        .onChange(of: level) { _, value in
            if value == AccessLogLevel.none.rawValue { AccessDiagnosticLog.shared.disableAndClear(); log = "" }
        }
        .task {
            while !Task.isCancelled {
                log = AccessDiagnosticLog.shared.snapshot()
                unavailable = AccessDiagnosticLog.shared.unavailable
                persistenceProblem = AccessDiagnosticLog.shared.persistenceUnavailable
                storageClearing = AccessDiagnosticLog.shared.isClearingStorage
                archiveCleanupPending = AccessDiagnosticArchive.hasPendingCleanup
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .sheet(item: $share, onDismiss: {
            if let url = presentedShareURL { finishShare(url) }
        }) { item in
            AccessDiagnosticShareSheet(url: item.url) { finishShare(item.url) }
        }
    }

    private func prepareShare() {
        do {
            let url = try AccessDiagnosticArchive.createTemporary(snapshot: AccessDiagnosticLog.shared.snapshot())
            errorMessage = nil
            presentedShareURL = url
            share = AccessDiagnosticShare(url: url)
        } catch AccessDiagnosticArchive.ArchiveError.cleanupRequired {
            archiveCleanupPending = true
        } catch AccessDiagnosticArchive.ArchiveError.shareInProgress {
            errorMessage = "请先结束另一个窗口中的日志分享。"
        } catch {
            errorMessage = "无法生成压缩日志，请重试。"
        }
    }

    private func finishShare(_ url: URL) {
        guard presentedShareURL == url else { return }
        presentedShareURL = nil
        do {
            try AccessDiagnosticArchive.removeTemporary(url)
        } catch {
            archiveCleanupPending = true
        }
    }

    private func retryArchiveCleanup() {
        do {
            try AccessDiagnosticArchive.retryTemporaryCleanup()
        } catch {
            archiveCleanupPending = true
            return
        }
        archiveCleanupPending = AccessDiagnosticArchive.hasPendingCleanup
    }

    private func clearLogs() {
        clearing = true
        clearMessage = nil
        errorMessage = nil
        Task {
            do {
                try await AccessDiagnosticLog.shared.clearStoredLogs()
                log = AccessDiagnosticLog.shared.snapshot()
                retryArchiveCleanup()
                if !archiveCleanupPending {
                    clearMessage = "已清理历史日志；新日志仍会继续记录。"
                }
            } catch {
                errorMessage = "未能删除磁盘日志，请重试。"
            }
            clearing = false
        }
    }
}

private struct AccessDiagnosticShare: Identifiable {
    let id = UUID()
    let url: URL
}

private struct AccessDiagnosticShareSheet: UIViewControllerRepresentable {
    let url: URL
    let finished: @MainActor @Sendable () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in finished() }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
