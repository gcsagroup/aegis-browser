import AegisPolicyKit
import AgentKit
import BrowserKit
import Combine
import CryptoKit
import SwiftUI

/// One sheet's selection, document consent and asynchronous operation. No state
/// survives a revoked window lifetime, even if an injected service ignores cancel.
@MainActor
final class PageAssistantModel: ObservableObject {
    typealias ReadPage = @MainActor (BrowserTab, Bool) async throws -> PageSnapshot
    typealias Stream = @MainActor (ModelConfiguration, String, String, [String], String,
                                  @escaping @MainActor @Sendable (String) -> Void) async throws -> String
    struct SourceIdentity: Equatable {
        let tabID: UUID
        let instanceID: UUID
        let epoch: UInt64
        let webViewGeneration: UInt64
        let url: URL
        @MainActor init?(_ tab: BrowserTab) {
            guard !tab.isDisposed, let url = tab.url else { return nil }
            tabID = tab.id; instanceID = tab.instanceID; epoch = tab.navigationEpoch
            webViewGeneration = tab.webViewGeneration; self.url = url
        }
        @MainActor func matches(_ tab: BrowserTab) -> Bool { Self(tab) == self && !tab.isLoading }
    }
    struct Consent {
        let configuration: ModelConfiguration
        let goal: String
        let sources: [PageSnapshot]
        let identities: [SourceIdentity]
        let profile: BrowserProfile
        let privateSessionID: UUID
        let lifetime: UUID
        let credentialDigest: String
    }

    @Published private(set) var selected: Set<UUID> = []
    @Published var goal = AegisLocalization.string("总结主要内容，并给出来源引用。")
    @Published private(set) var snapshots: [PageSnapshot] = []
    @Published private(set) var output = ""
    @Published private(set) var outputComplete = false
    @Published var status: LocalizedStringResource = "准备中"
    @Published var error: (any Error)?
    @Published private(set) var busy = false
    @Published private(set) var consent: Consent?
    @Published private(set) var taskID: UUID?
    private(set) var resultGoal = ""
    let lifetime: AssistantOperationLifetime
    private weak var browser: BrowserSession?
    private weak var settings: BrowserSettings?
    private weak var tasks: AssistantTaskStore?
    private let readPage: ReadPage
    private let stream: Stream
    private let credential: @MainActor (ModelConfiguration) -> String
    private var generation = UUID()
    private var streamingGeneration: UUID?
    private var identities: [SourceIdentity] = []
    private var environmentObservers: Set<AnyCancellable> = []
    private var documentObservers: Set<AnyCancellable> = []

    init(lifetime: AssistantOperationLifetime = AssistantOperationLifetime(),
         credential: @escaping @MainActor (ModelConfiguration) -> String = { ModelCredentialStore.read(for: $0) },
         readPage: @escaping ReadPage = { try await $0.snapshot(privateReadConfirmed: $1) },
         stream: @escaping Stream = { configuration, key, goal, sources, language, onText in
             try await ModelClient(configuration: configuration, key: key).streamComplete(
                 goal: goal, sources: sources, language: language, onText: onText)
         }) {
        self.lifetime = lifetime; self.credential = credential; self.readPage = readPage; self.stream = stream
        lifetime.sceneDeactivated.sink { [weak self] in self?.revoke(clearSources: true) }.store(in: &environmentObservers)
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in self?.revoke(clearSources: true) }.store(in: &environmentObservers)
    }

    func attach(browser: BrowserSession, settings: BrowserSettings, tasks: AssistantTaskStore) {
        guard self.browser !== browser else { return }
        revoke(clearSources: true)
        self.browser = browser; self.settings = settings; self.tasks = tasks
        if let id = browser.activeTab?.id { selected = [id] }
        browser.$profile.dropFirst().sink { [weak self] _ in self?.revoke(clearSources: true) }.store(in: &environmentObservers)
        browser.$standardTabs.dropFirst().sink { [weak self] tabs in self?.tabsChanged(tabs, profile: .standard) }.store(in: &environmentObservers)
        browser.$privateTabs.dropFirst().sink { [weak self] tabs in self?.tabsChanged(tabs, profile: .privateMode) }.store(in: &environmentObservers)
        settings.$model.dropFirst().sink { [weak self] _ in self?.revoke(clearSources: true) }.store(in: &environmentObservers)
    }

    private func tabsChanged(_ tabs: [BrowserTab], profile: BrowserProfile) {
        guard let browser, browser.profile == profile else { return }
        let live = Set(tabs.filter { !$0.isDisposed }.map(\.id))
        if browser.isWindowClosed || !selected.isSubset(of: live) { revoke(clearSources: true) }
        selected.formIntersection(live)
    }

    func select(_ id: UUID, included: Bool) {
        revoke(clearSources: true)
        if included && selected.count < 5 { selected.insert(id) } else { selected.remove(id) }
    }

    func restore(_ record: AssistantTaskRecord) {
        guard let browser else { return }
        revoke(clearSources: true); goal = record.goal; selected = []
        for url in record.sources.prefix(5) {
            if let tab = browser.visibleTabs.first(where: { $0.url == url }) { selected.insert(tab.id) }
            else if browser.visibleTabs.count < 50 { let tab = browser.newTab(); tab.load(url); selected.insert(tab.id) }
        }
        status = "任务已恢复，请重新读取页面并确认发送。"
    }

    private func active(_ token: UUID, profile: BrowserProfile, lifetimeToken: UUID) -> Bool {
        guard generation == token, lifetime.isCurrent(lifetimeToken), !Task.isCancelled,
              let browser, !browser.isWindowClosed, browser.profile == profile, browser.agentIsAvailable else { return false }
        return true
    }

    private func sourcesMatch(_ values: [SourceIdentity]) -> Bool {
        guard let browser, !browser.isWindowClosed else { return false }
        return !values.isEmpty && values.allSatisfy { identity in
            browser.visibleTabs.contains { identity.matches($0) }
        }
    }

    private func observeDocuments(_ values: [SourceIdentity]) {
        documentObservers.removeAll()
        guard let browser else { return }
        for identity in values {
            guard let tab = browser.visibleTabs.first(where: { $0.id == identity.tabID }) else { continue }
            tab.$navigationEpoch.dropFirst().sink { [weak self] epoch in
                if epoch != identity.epoch { self?.revoke(clearSources: true) }
            }.store(in: &documentObservers)
            tab.$url.dropFirst().sink { [weak self] url in
                if url != identity.url { self?.revoke(clearSources: true) }
            }.store(in: &documentObservers)
        }
    }

    func readPages() {
        guard let browser, !browser.isWindowClosed else { return }
        revoke(clearSources: true)
        let profile = browser.profile, lifetimeToken = lifetime.generation, token = generation
        guard active(token, profile: profile, lifetimeToken: lifetimeToken) else { return }
        let tabs = browser.visibleTabs.filter { selected.contains($0.id) }
        guard !tabs.isEmpty, tabs.count <= 5 else { return }
        error = nil; busy = true; status = "正在读取页面"
        browser.protectAssistantTabs(Set(tabs.map(\.id)))
        lifetime.operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var values: [PageSnapshot] = [], captured: [SourceIdentity] = []
                for tab in tabs {
                    guard active(token, profile: profile, lifetimeToken: lifetimeToken), !tab.isDisposed,
                          browser.visibleTabs.contains(where: { $0 === tab }) else { throw PageSnapshotError.changed }
                    let source = try await readPage(tab, profile.isPrivate)
                    guard active(token, profile: profile, lifetimeToken: lifetimeToken),
                          let identity = SourceIdentity(tab), identity.matches(tab),
                          source.id == identity.tabID, source.url == identity.url, source.navigationEpoch == identity.epoch else { throw PageSnapshotError.changed }
                    values.append(source); captured.append(identity)
                    // A captured source can change while the next read ignores cancellation.
                    observeDocuments(captured)
                }
                guard active(token, profile: profile, lifetimeToken: lifetimeToken), sourcesMatch(captured) else {
                    revokeIfCurrent(token)
                    return
                }
                snapshots = values; identities = captured; busy = false; status = "等待确认发送"
                lifetime.operation = nil
                observeDocuments(captured)
            } catch {
                guard active(token, profile: profile, lifetimeToken: lifetimeToken) else {
                    revokeIfCurrent(token)
                    return
                }
                documentObservers.removeAll()
                self.error = error; busy = false; status = "读取失败"; lifetime.operation = nil
                browser.protectAssistantTabs([])
            }
        }
    }

    func requestConsent() {
        guard let browser, let settings, !busy, sourcesMatch(identities), lifetime.isCurrent(lifetime.generation) else {
            error = PageSnapshotError.changed; return
        }
        consent = Consent(configuration: settings.model, goal: goal, sources: snapshots, identities: identities,
                          profile: browser.profile, privateSessionID: browser.privateSessionID,
                          lifetime: lifetime.generation, credentialDigest: digest(credential(settings.model)))
    }
    func dismissConsent() { consent = nil }

    private func valid(_ consent: Consent) -> Bool {
        guard let browser, let settings, !browser.isWindowClosed, browser.profile == consent.profile,
              browser.privateSessionID == consent.privateSessionID, browser.agentIsAvailable,
              settings.model == consent.configuration, lifetime.isCurrent(consent.lifetime),
              digest(credential(consent.configuration)) == consent.credentialDigest else { return false }
        return sourcesMatch(consent.identities)
    }
    private func revokeIfCurrent(_ token: UUID) {
        if generation == token { revoke(clearSources: true) }
    }
    private func digest(_ key: String) -> String { SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() }

    private func sealStream(_ token: UUID) {
        if streamingGeneration == token { streamingGeneration = nil }
    }

    func send() {
        guard let approved = consent else { return }
        consent = nil
        guard valid(approved), let browser, let tasks else { error = PageSnapshotError.changed; return }
        generation = UUID()
        let token = generation
        let key = credential(approved.configuration)
        taskID = nil // A new operation must never interrupt a prior completed record.
        busy = true; error = nil; output = ""; outputComplete = false; status = "正在连接模型服务"
        resultGoal = approved.goal
        lifetime.operation = Task { @MainActor [weak self] in
            guard let self else { return }
            // Consent can be revoked between the confirm tap and the task's first turn.
            guard active(token, profile: approved.profile, lifetimeToken: approved.lifetime), valid(approved) else { revokeIfCurrent(token); return }
            do {
                taskID = nil
                if !approved.profile.isPrivate { taskID = try tasks.begin(goal: approved.goal, sources: approved.sources.map(\.url)) }
                let recordID = taskID
                let sourceTexts = approved.sources.enumerated().map { "来源 [\($0.offset + 1)]：\($0.element.title)\n\($0.element.text)" }
                guard active(token, profile: approved.profile, lifetimeToken: approved.lifetime), valid(approved) else { revokeIfCurrent(token); return }
                streamingGeneration = token
                let text = try await stream(approved.configuration, key, approved.goal, sourceTexts, AegisLocalization.current.dialect) { [weak self] partial in
                    guard let self, self.streamingGeneration == token,
                          self.active(token, profile: approved.profile, lifetimeToken: approved.lifetime), self.valid(approved) else { return }
                    self.output = partial; self.status = "正在生成回答"
                }
                // Seal before publishing or persisting a terminal state. Generation
                // validity alone also permits a completed result to remain saveable.
                sealStream(token)
                guard active(token, profile: approved.profile, lifetimeToken: approved.lifetime), valid(approved) else { revokeIfCurrent(token); return }
                if let recordID { try tasks.finish(recordID, state: .completed) }
                output = text; outputComplete = true; busy = false; status = "已完成"; lifetime.operation = nil
            } catch {
                sealStream(token)
                guard active(token, profile: approved.profile, lifetimeToken: approved.lifetime), valid(approved) else { revokeIfCurrent(token); return }
                if let taskID { try? tasks.finish(taskID, state: .failed) }
                if let failure = error as? ModelClientError, [.invalidCitation, .invalidResponse, .sensitiveData].contains(failure) { output = "" }
                self.error = error; busy = false; status = "分析失败"; lifetime.operation = nil
            }
            browser.protectAssistantTabs([])
        }
    }

    func cancel() { revoke(clearSources: false) }
    func revoke(clearSources: Bool) {
        generation = UUID() // Revoke before cancelling an uncooperative dependency.
        streamingGeneration = nil
        lifetime.invalidate()
        if busy, let taskID, let tasks { try? tasks.finish(taskID, state: .interrupted) }
        lifetime.operation = nil; consent = nil; taskID = nil
        browser?.protectAssistantTabs([])
        let wasBusy = busy
        if busy { outputComplete = false; status = "已暂停，可重新运行" }
        busy = false
        if clearSources {
            snapshots = []; identities = []; output = ""; outputComplete = false; error = nil
            documentObservers.removeAll()
            if !wasBusy { status = "准备中" }
        }
    }

    var report: String {
        output + "\n\n" + snapshots.enumerated().map { "[\($0.offset + 1)] \($0.element.title)\n\($0.element.url.absoluteString)\n\($0.element.capturedAt.formatted())" }.joined(separator: "\n\n")
    }
    func saveResult() {
        guard outputComplete, sourcesMatch(identities), let browser, let tasks else { return }
        do {
            if let taskID { try tasks.saveReport(report, for: taskID) }
            else if browser.profile.isPrivate { taskID = try tasks.saveCompletedReport(goal: resultGoal, sources: snapshots.map(\.url), report: report) }
            else { return }
            status = "研究结果已加密保存。"
        } catch { self.error = error }
    }
}
