import AccessKit
import BrowserKit
import SwiftUI

struct OverseasAccelerationSettingsView: View {
    @EnvironmentObject private var browser: BrowserSession
    @EnvironmentObject private var hostStores: AccessHostStoreCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode: AccessOverseasSelection.Mode = .categories
    @State private var categories: Set<AccessOverseasCategory> = []
    @State private var confirmation: AccessHostStoreCoordinator.OverseasSettingsConfirmation?
    @State private var preparing: Task<Void, Never>?
    @State private var saving: Task<Void, Never>?
    @State private var message: LocalizedStringKey?
    @State private var isWaitingForRules = false
    let tab: BrowserTab

    private var canEdit: Bool {
        browser.activeTab === tab && hostStores.offersWebsiteAcceleration(for: tab)
    }

    var body: some View {
        Form {
            if canEdit {
                let state = hostStores.overseasSettings
                Section {
                    if state.selection.enabled {
                        Text(state.remotelyPaused ? "海外加速已暂停。" : (state.ready ? "已启用" : "连接暂不可用"))
                        if state.ready, state.ceiling == nil,
                           let policy = state.pendingPolicy ?? state.policy, let tag = state.pendingTag ?? state.activeTag {
                            NavigationLink("当前保护范围") {
                                OverseasScopeDetails(version: state.bundledTag ?? tag, policy: policy,
                                                     bundled: state.usingBundledRules)
                                    .localizedNavigationTitle("当前保护范围")
                            }
                        }
                        Button("关闭", role: .destructive, action: disable)
                            .accessibilityIdentifier("overseas-disable")
                    } else {
                        Text("未启用")
                            .accessibilityIdentifier("overseas-disabled")
                    }
                    if state.awaitingExpansion { Text("等待确认") }
                    if state.usingBundledRules { Text("已使用内置规则。") }
                    if state.unsaved { Text("设置未保存，请重试。") }
                } footer: {
                    Text("按网站主机选择连接。页面内资源可能共用该连接。本站选择优先。")
                }
                if let preview = hostStores.overseasPreview {
                    selectionControls(preview)
                    if preview.bundled { onlineRulesSection(state) }
                } else if !state.remotelyPaused {
                    onlineRulesSection(state)
                }
                if let message { Section { Text(message).foregroundStyle(.secondary) } }
                if !hostStores.offersLocationService { Section { Text("加速服务未配置。") } }
            }
        }
        .localizedNavigationTitle("海外加速（针对大陆地区）")
        .onChange(of: hostStores.overseasSettings.selection, initial: true) { _, persisted in
            mode = persisted.mode
            categories = Set(persisted.categories)
        }
        .onChange(of: hostStores.overseasSettings.previewTag) { _, version in
            if version != nil { isWaitingForRules = false }
        }
        .onChange(of: browser.tabSelectionRevision) { _, _ in invalidateConfirmation() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { invalidateConfirmation() }
        }
        .onDisappear(perform: invalidateConfirmation)
        .sheet(item: $confirmation, onDismiss: { saving?.cancel() }) { confirmation in
            let offer = confirmation.offer
            NavigationStack {
                OverseasScopeDetails(version: offer.release, policy: offer.policy,
                                     bundled: offer.bundled,
                                     addedRules: offer.newRules, removedExclusions: offer.removedExclusions)
                    .localizedNavigationTitle(offer.selection.mode == .all ? "全部名单" : "分类范围")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消", action: invalidateConfirmation)
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("确认启用") { save(confirmation) }
                                .disabled(saving != nil)
                                .accessibilityIdentifier("overseas-confirm")
                        }
                    }
            }
        }
    }

    private func onlineRulesSection(_ state: AccessGeoSiteCache.OverseasView) -> some View {
        Section {
            Button("获取官方规则", action: requestRules)
                .disabled(!hostStores.canFetchOverseasPreview || state.previewRequested)
                .accessibilityIdentifier("overseas-fetch-rules")
            if isWaitingForRules {
                Text(state.refreshFailed ? "下载失败" : "正在更新规则…")
            }
            if state.previewRequested && !state.selection.enabled {
                Button("取消") {
                    hostStores.cancelOverseasPreview(for: tab)
                    isWaitingForRules = false
                }
            }
        }
    }

    private func selectionControls(_ preview: AccessGeoSiteCache.OverseasPreview) -> some View {
        Section {
            if preview.bundled { Text("内置规则") }
            Picker("加速范围", selection: $mode) {
                Text("按分类").tag(AccessOverseasSelection.Mode.categories)
                Text("全部名单").tag(AccessOverseasSelection.Mode.all)
            }
            if mode == .categories {
                ForEach(AccessOverseasCategory.allCases, id: \.self) { category in
                    categoryButton(category, hosts: preview.catalogue.hosts[category] ?? [])
                }
            } else {
                Text("使用本版本已通过校验的网站规则，含未归类网站。")
            }
            NavigationLink {
                OverseasScopeDetails(version: preview.release, policy: preview.fullPolicy,
                                     bundled: preview.bundled,
                                     counts: preview.catalogue.counts, projections: preview.catalogue.hosts,
                                     unused: preview.catalogue.unusedRules)
                    .localizedNavigationTitle("全部名单")
            } label: {
                Text("分类范围")
            }
            Button("检查并应用", action: prepareConfirmation)
                .disabled(preparing != nil)
                .accessibilityIdentifier("overseas-review-choice")
        }
    }

    private func categoryButton(_ category: AccessOverseasCategory, hosts: Set<String>) -> some View {
        Toggle(isOn: Binding(get: { categories.contains(category) }, set: { selected in
            if selected { categories.insert(category) } else { categories.remove(category) }
        })) {
            VStack(alignment: .leading, spacing: 4) {
                Text(category.localizedTitle)
                if !hosts.isEmpty {
                    Text(verbatim: hosts.sorted().joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("overseas-category-" + category.rawValue)
    }

    private func requestRules() {
        guard canEdit else { return }
        do {
            try hostStores.requestOverseasPreview(for: tab)
            isWaitingForRules = true
            message = nil
        } catch { message = "连接暂不可用" }
    }

    private func prepareConfirmation() {
        guard canEdit, preparing == nil, scenePhase == .active else { return }
        let choice = AccessOverseasSelection(enabled: true, mode: mode, categories: categories)
        preparing = Task { @MainActor in
            defer { preparing = nil }
            do {
                let prepared = try await hostStores.overseasConfirmation(choice, for: browser)
                try Task.checkCancellation()
                guard canEdit, scenePhase == .active, choice.mode == mode, Set(choice.categories) == categories else { return }
                confirmation = prepared
                message = nil
            } catch is CancellationError {
                return
            } catch AccessGeoSiteCache.Failure.expansionTooLarge {
                message = "新增范围过大，无法批准。"
            } catch { message = "连接暂不可用" }
        }
    }

    private func save(_ offer: AccessHostStoreCoordinator.OverseasSettingsConfirmation) {
        guard saving == nil, canEdit, scenePhase == .active else { return }
        saving = Task { @MainActor in
            defer { saving = nil }
            do {
                try await hostStores.confirmOverseas(offer, for: browser) {
                    canEdit && scenePhase == .active && confirmation?.id == offer.id
                }
                confirmation = nil
            } catch is CancellationError {
                return
            } catch {
                confirmation = nil
                message = "设置未保存，请重试。"
            }
        }
    }

    private func disable() {
        guard canEdit else { return }
        do {
            try hostStores.disableOverseas(for: tab)
            message = nil
        } catch { message = "设置未保存，请重试。" }
    }

    private func invalidateConfirmation() {
        preparing?.cancel()
        saving?.cancel()
        confirmation = nil
    }
}

private struct OverseasScopeDetails: View {
    let version: String
    let policy: AccessOverseasCatalogue.Policy
    var bundled = false
    var counts: AccessOverseasCatalogue.Counts?
    var projections: [AccessOverseasCategory: Set<String>] = [:]
    var unused: [AccessOverseasCatalogue.UnusedRule] = []
    var addedRules: [AccessOverseasCatalogue.Record] = []
    var removedExclusions: [AccessOverseasCatalogue.Record] = []
    @State private var search = ""

    var body: some View {
        List {
            Section {
                LabeledContent("版本", value: version)
                if bundled { Text("内置规则") }
                if let counts {
                    LabeledContent("来源规则", value: counts.source.formatted())
                    LabeledContent("通过主机校验", value: counts.admitted.formatted())
                    LabeledContent("分类入口", value: projections.values.reduce(0) { $0 + $1.count }.formatted())
                }
                LabeledContent("范围", value: policy.rules.count.formatted())
                LabeledContent("例外规则", value: policy.exclusions.count.formatted())
            }
            if !addedRules.isEmpty { rows(addedRules, title: "新增范围") }
            if !removedExclusions.isEmpty { rows(removedExclusions, title: "取消的例外") }
            ForEach(AccessOverseasCategory.allCases, id: \.self) { category in
                let hosts = (projections[category] ?? []).sorted().filter(includes)
                if !hosts.isEmpty {
                    Section(category.localizedTitle) {
                        ForEach(hosts, id: \.self) { Text(verbatim: $0) }
                    }
                }
            }
            rows(policy.rules, title: "范围")
            rows(policy.exclusions, title: "例外规则")
            if !unused.isEmpty {
                let results = unused.filter { includes($0.value) }
                Section("未采用的规则") {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, row in
                        LabeledContent {
                            Text(row.reason == .hostRejected ? "主机校验未通过" : "未支持的规则")
                        } label: { Text(verbatim: row.value) }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "搜索")
    }

    private func rows(_ rules: [AccessOverseasCatalogue.Record], title: LocalizedStringKey) -> some View {
        Section(title) {
            ForEach(rules.filter { includes($0.value) }, id: \.self) { rule in
                LabeledContent {
                    switch rule.kind {
                    case .domain: Text("包含子域名")
                    case .full: Text("仅匹配所列域名。")
                    case .keyword: Text("关键词")
                    case .regexp: Text("未支持的规则")
                    }
                } label: { Text(verbatim: rule.value) }
            }
        }
    }

    private func includes(_ value: String) -> Bool {
        search.isEmpty || value.localizedCaseInsensitiveContains(search)
    }
}

private extension AccessOverseasCategory {
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .video: "视频与直播"
        case .ai: "AI 工具"
        case .web: "网页与搜索"
        case .social: "社交与通讯"
        case .news: "新闻资讯"
        case .development: "开发与代码"
        case .reference: "百科与学术"
        case .cloud: "办公与网盘"
        }
    }
}
