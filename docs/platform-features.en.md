# Feature comparison across four platforms

[简体中文](platform-features.zh-CN.md) · [繁體中文](platform-features.zh-TW.md) · [English](platform-features.en.md) · [JSON](platform-features.json)

This catalog describes the current working tree and does not establish release eligibility. Validation scope is recorded per feature; consult its linked report for exact tests and unverified items. Source integration, Simulator results and physical-device acceptance are recorded separately.

Source: supported by source or the product contract. Partial: defined differences remain. Not ported: unavailable in this port. System: managed by the platform. The JSON records the reasons, source paths and validation state for all four platforms.

| Feature | macOS | Windows | Android | iOS |
| --- | --- | --- | --- | --- |
| Master control and persistence | Source | Source | Source | Partial |
| Tracker blocking | Source | Source | Source | Partial |
| Phishing warning | Source | Source | Source | Partial |
| Fingerprint protection | Source | Source | Source | Partial |
| Mining protection | Source | Source | Source | Partial |
| Bytecode inspection | Source | Source | Source | Not ported |
| Filter list updates | Source | Source | Source | Partial |
| Link cleanup | Source | Source | Source | Source |
| Cookie cleanup | Source | Source | Source | Partial |
| CNAME detection | Source | Source | Source | Not ported |
| Bounce tracking protection | Source | Source | Source | System |
| Policy execution | Source | Source | Source | Partial |
| Privacy AI | Source | Source | Source | Partial |
| AI permissions | Source | Source | Source | Partial |
| Browser agent and private data isolation | Source | Source | Source | Partial |
| Agent page actions | Source | Source | Source | Partial |
| Agent browser tools | Source | Source | Source | Partial |
| WebMCP experiment disabled | Source | Source | Source | Not ported |
| Agent workflows | Source | Source | Source | Partial |
| Transaction experiment disabled | Source | Source | Source | Not ported |
| Network access rules and permissions | Source | Source | Source | Partial |
| Profile and restart compatibility | Source | Source | Source | Partial |
| Updates, integrity and recovery | Source | Source | Source | System |
| Desktop mouse gestures | Source | Source | Not ported | Not ported |
| Search, home page and startup | Source | Source | Source | Source |
| Page display and site permissions | Source | Source | Source | Partial |
| Site storage management | Source | Source | Source | Source |
| Bookmarks and history | Source | Source | Source | Source |
| Tabs, windows and workspaces | Source | Source | Source | Partial |
| HTTP downloads and integrity | Source | Source | Source | Source |
| Metalink and mirrors | Source | Source | Source | Partial |
| Download network and size limits | Partial | Partial | Partial | Source |
| BitTorrent and magnet downloads | Source | Source | Source | Not ported |
| Reading library and notes | Partial | Partial | Partial | Source |
| Reading translation and comparison | Partial | Partial | Partial | Partial |
| PDF text-layer notes | Partial | Partial | Partial | Partial |
| Foreground page change checks | Source | Source | Source | Partial |
| Third-party extension installation | Source | Source | Source | Not ported |
| Cross-device sync | Not ported | Not ported | Not ported | Not ported |
| Default browser and language | Source | Source | Source | System |
| WebKit system hardening | Not ported | Not ported | Not ported | Partial |
| Per-site website enhancements | Partial | Source | Not ported | Partial |
| User scripts and AI drafts | Partial | Source | Not ported | Partial |
| Built-in Markdown reader | Partial | Source | Not ported | Partial |
| Unified settings and legacy routes | Source | Source | Source | Source |

## iOS scope and evidence

### Master control and persistence

`kAegisEnabled` — Separate protection options; no equivalent Chromium master switch.

Source：[apps/ios/AegisApp/BrowserPreferenceViews.swift](../apps/ios/AegisApp/BrowserPreferenceViews.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Tracker blocking

`kAegisTrackerBlocking` — WebKit content rules filter ads and trackers with different rule syntax coverage.

Source：[apps/ios/BrowserKit/ContentFilterCompiler.swift](../apps/ios/BrowserKit/ContentFilterCompiler.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Phishing warning

`kAegisPhishInterstitial` — Signed local host snapshot, PSL URL checks, bounded structure observation and a native warning. Structure checks start after loading; no real-time threat query.

Source：[apps/ios/BrowserKit/NavigationPolicy.swift](../apps/ios/BrowserKit/NavigationPolicy.swift) · [apps/ios/BrowserKit/PageProtection.swift](../apps/ios/BrowserKit/PageProtection.swift) · [apps/ios/AegisPolicyKit/RegisteredDomain.swift](../apps/ios/AegisPolicyKit/RegisteredDomain.swift)

iOS Simulator evidence：[docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md](../docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md)

### Fingerprint protection

`kAegisFingerprintGuard` — Independent known fingerprint resource rules and optional page API limits. Workers can bypass them; engine-level noise is not ported.

Source：[apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift) · [apps/ios/BrowserKit/SecurityRules.swift](../apps/ios/BrowserKit/SecurityRules.swift) · [apps/ios/BrowserKit/PageProtection.swift](../apps/ios/BrowserKit/PageProtection.swift)

iOS Simulator evidence：[docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md](../docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md)

### Mining protection

`kAegisMinerGuard` — Independent blocking of known mining host resources. Worker/WASM combinations only produce notices, without claiming unknown miner detection.

Source：[apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift) · [apps/ios/BrowserKit/SecurityRules.swift](../apps/ios/BrowserKit/SecurityRules.swift) · [apps/ios/BrowserKit/PageProtection.swift](../apps/ios/BrowserKit/PageProtection.swift)

iOS Simulator evidence：[docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md](../docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md)

### Bytecode inspection

`kAegisBytecodeShadow` — System WebKit does not use this project's V8 bytecode inspection patches.

Source：[apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift)

Runtime acceptance not completed for this item in this work。

### Filter list updates

`kAegisFilterListUpdater` — Manual updates and optional foreground checks; no background schedule guarantee.

Source：[apps/ios/BrowserKit/BrowserPreferences.swift](../apps/ios/BrowserKit/BrowserPreferences.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Link cleanup

`kAegisLinkSanitize` — Configurable tracking parameter cleanup; credentialed URLs remain blocked.

Source：[apps/ios/BrowserKit/NavigationPolicy.swift](../apps/ios/BrowserKit/NavigationPolicy.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Cookie cleanup

`kAegisCookieJanitor` — Per-site and full clearing; automatic cookie cleanup policies are not ported.

Source：[apps/ios/AegisApp/BrowserPreferenceViews.swift](../apps/ios/AegisApp/BrowserPreferenceViews.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### CNAME detection

`kAegisCnameUncloak` — Chromium network-layer CNAME detection is not ported.

Source：[apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift)

Runtime acceptance not completed for this item in this work。

### Bounce tracking protection

`kAegisBounceTracking` — Handled by WebKit tracking protection; no separate Aegis bounce tracking module.

Source：[apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift)

Runtime acceptance not completed for this item in this work。

### Policy execution

`kAegisPolicyWorker` — Swift policies, capability tokens and source checks use a different execution architecture.

Source：[apps/ios/AgentKit/AgentBroker.swift](../apps/ios/AgentKit/AgentBroker.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Privacy AI

`kAegisPrivacyAi` — Redaction and preview before sending; no bundled on-device inference model.

Source：[apps/ios/AegisPolicyKit/PIIScanner.swift](../apps/ios/AegisPolicyKit/PIIScanner.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### AI permissions

`kAegisAiControl` — Separate read, send and execution confirmations bound to window, mode and sources.

Source：[apps/ios/AgentKit/BrowserOperations.swift](../apps/ios/AgentKit/BrowserOperations.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Browser agent and private data isolation

`kAegisAgent` — Page reading, comparison, task saving and limited browser operations; not all desktop tools.

Source：[apps/ios/AegisApp/PageAssistantView.swift](../apps/ios/AegisApp/PageAssistantView.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Agent page actions

`kAegisAgentPageActions` — Fixed scroll and navigation operations; no automatic form filling, sign-in or payment.

Source：[apps/ios/AgentKit/BrowserOperations.swift](../apps/ios/AgentKit/BrowserOperations.swift)

Runtime acceptance not completed for this item in this work。

### Agent browser tools

`kAegisAgentBrowserTools` — Confirmed grouping, workspaces, user-supplied URLs, reload and close operations.

Source：[apps/ios/AgentKit/BrowserOperations.swift](../apps/ios/AgentKit/BrowserOperations.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### WebMCP experiment disabled

`kAegisAgentWebMcp` — WebMCP is not integrated and has no nonfunctional enable switch.

Source：[apps/ios/AegisApp/BrowserOperationsView.swift](../apps/ios/AegisApp/BrowserOperationsView.swift)

Runtime acceptance not completed for this item in this work。

### Agent workflows

`kAegisAgentWorkflows` — Existing workflows plus foreground page-change checks; background scheduling is not ported.

Source：[apps/ios/BrowserKit/ForegroundPageWatch.swift](../apps/ios/BrowserKit/ForegroundPageWatch.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Transaction experiment disabled

`kAegisAgentTransactionPilot` — No transaction execution interface; users complete purchases.

Source：[apps/ios/AgentKit/BrowserOperations.swift](../apps/ios/AgentKit/BrowserOperations.swift)

Runtime acceptance not completed for this item in this work。

### Network access rules and permissions

`aegis-access` — Per-origin display, script, camera and microphone settings; no Aegis Access proxy routing.

Source：[apps/ios/BrowserKit/BrowserPreferences.swift](../apps/ios/BrowserKit/BrowserPreferences.swift)

Runtime acceptance not completed for this item in this work。

### Profile and restart compatibility

`profile-compatibility` — Normal tab restoration, private isolation, encrypted items and legacy download records; independent formats.

Source：[apps/ios/AegisApp/AegisApp.swift](../apps/ios/AegisApp/AegisApp.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Updates, integrity and recovery

`release-update` — Installation and updates depend on iOS distribution eligibility; no desktop-style updater.

Source：[apps/ios/AegisApp/Info.plist](../apps/ios/AegisApp/Info.plist)

Runtime acceptance not completed for this item in this work。

### Desktop mouse gestures

`MouseGestures` — Uses touch and system navigation; desktop right-button gestures are not ported.

Source：[apps/ios/BrowserKit/BrowserWebView.swift](../apps/ios/BrowserKit/BrowserWebView.swift)

Runtime acceptance not completed for this item in this work。

### Search, home page and startup

`search-home-startup` — Select, remove and restore search engines; an empty list permits direct addresses only. Supports custom HTTPS templates, a home page and regular-tab restore.

Source：[apps/ios/BrowserKit/BrowserPreferences.swift](../apps/ios/BrowserKit/BrowserPreferences.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md) · [docs/audit/ios-search-engines-2026-10-11.zh-CN.md](../docs/audit/ios-search-engines-2026-10-11.zh-CN.md)

### Page display and site permissions

`site-display-permissions` — Global and per-origin zoom, desktop mode, JavaScript and camera/microphone ask or deny; no silent grants.

Source：[apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Site storage management

`site-storage` — Clear normal cookies, cache and storage per site after closing normal tabs across windows.

Source：[apps/ios/AegisApp/BrowserPreferenceViews.swift](../apps/ios/AegisApp/BrowserPreferenceViews.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Bookmarks and history

`bookmarks-history` — Bookmark management and history search; private browsing keeps no history and saving requires confirmation.

Source：[apps/ios/BrowserKit/BrowserDataStore.swift](../apps/ios/BrowserKit/BrowserDataStore.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Tabs, windows and workspaces

`tabs-windows-workspaces` — Tab groups, normal window restoration and iPad multiwindow support; private tabs do not survive relaunch.

Source：[apps/ios/BrowserKit/BrowserWindowStore.swift](../apps/ios/BrowserKit/BrowserWindowStore.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### HTTP downloads and integrity

`http-downloads` — System background HTTP downloads, pause/resume, hashing, export and recycle bin.

Source：[apps/ios/BrowserKit/DownloadManager.swift](../apps/ios/BrowserKit/DownloadManager.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Metalink and mirrors

`metalink-mirrors` — Metalink import, sequential mirror failover and SHA checks; no merged mirror chunks.

Source：[apps/ios/BrowserKit/DownloadPlan.swift](../apps/ios/BrowserKit/DownloadPlan.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Download network and size limits

`download-network-limits` — New tasks capture network policies and size limits; resumes keep their original rules.

Source：[apps/ios/BrowserKit/DownloadManager.swift](../apps/ios/BrowserKit/DownloadManager.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### BitTorrent and magnet downloads

`torrent-magnet` — Requires an iOS-specific transfer backend and background scheduling design; not ported in this work.

Source：[apps/ios/BrowserKit/DownloadManager.swift](../apps/ios/BrowserKit/DownloadManager.swift)

Runtime acceptance not completed for this item in this work。

### Reading library and notes

`reading-library` — Explicit text capture, local AES-GCM storage, quote highlighting, notes, search, archiving and export.

Source：[apps/ios/BrowserKit/ReadingLibrary.swift](../apps/ios/BrowserKit/ReadingLibrary.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Reading translation and comparison

`reading-translation` — Translate page text after a redacted preview; side by side on iPad and stacked on iPhone, persisted only on save.

Source：[apps/ios/AegisApp/ReadingLibraryView.swift](../apps/ios/AegisApp/ReadingLibraryView.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### PDF text-layer notes

`pdf-text-notes` — Import text from a selected page of a local PDF; no OCR or PDF model upload.

Source：[apps/ios/BrowserKit/ReadingLibrary.swift](../apps/ios/BrowserKit/ReadingLibrary.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Foreground page change checks

`foreground-page-watch` — Reload and compare page text at intervals while the panel stays foreground; stopping or leaving the foreground cancels it.

Source：[apps/ios/BrowserKit/ForegroundPageWatch.swift](../apps/ios/BrowserKit/ForegroundPageWatch.swift)

iOS Simulator evidence：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Third-party extension installation

`third-party-extensions` — Bundled WebExtension integration is present; arbitrary third-party installation is unavailable.

Source：[apps/ios/BrowserKit/WebExtensionRuntime.swift](../apps/ios/BrowserKit/WebExtensionRuntime.swift)

Runtime acceptance not completed for this item in this work。

### Cross-device sync

`cross-device-sync` — Local storage only; no account sync service in this work.

Source：[apps/ios/AegisApp/AegisApp.swift](../apps/ios/AegisApp/AegisApp.swift)

Runtime acceptance not completed for this item in this work。

### Default browser and language

`default-browser-language` — Opens system settings; iOS controls browser eligibility, app language and hardware permissions.

Source：[apps/ios/AegisApp/BrowserSettings.swift](../apps/ios/AegisApp/BrowserSettings.swift)

Runtime acceptance not completed for this item in this work。

### WebKit system hardening

`webkit-system-hardening` — Optional public security restriction on iOS 26.4+. Earlier systems retain default protection. System fraud warnings, HTTPS policy and Lockdown remain; Simulator cannot establish MTE effectiveness.

Source：[apps/ios/BrowserKit/PageProtection.swift](../apps/ios/BrowserKit/PageProtection.swift) · [apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift)

iOS Simulator evidence：[docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md](../docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md)

### Per-site website enhancements

`kAegisWebsiteEnhancements` — Integrated with SwiftUI/WKWebView; the report records iPhone/iPad Simulator evidence, not physical-device, minimum-OS runtime or distribution acceptance.

Source：[apps/ios/BrowserKit/UserScriptController.swift](../apps/ios/BrowserKit/UserScriptController.swift)

iOS Simulator evidence：[docs/audit/site-enhancement-markdown-2026-10-13.zh-CN.md](../docs/audit/site-enhancement-markdown-2026-10-13.zh-CN.md)

### User scripts and AI drafts

`kAegisUserScripts` — Integrated with SwiftUI/WKWebView; the report records iPhone/iPad Simulator evidence, not physical-device, minimum-OS runtime or distribution acceptance.

Source：[apps/ios/BrowserKit/WebsiteEnhancements.swift](../apps/ios/BrowserKit/WebsiteEnhancements.swift)

iOS Simulator evidence：[docs/audit/site-enhancement-markdown-2026-10-13.zh-CN.md](../docs/audit/site-enhancement-markdown-2026-10-13.zh-CN.md)

### Built-in Markdown reader

`kAegisMarkdownReader` — Integrated with SwiftUI/WKWebView; the report records iPhone/iPad Simulator evidence, not physical-device, minimum-OS runtime or distribution acceptance.

Source：[apps/ios/AegisApp/MarkdownReaderView.swift](../apps/ios/AegisApp/MarkdownReaderView.swift)

iOS Simulator evidence：[docs/audit/site-enhancement-markdown-2026-10-13.zh-CN.md](../docs/audit/site-enhancement-markdown-2026-10-13.zh-CN.md)

### Unified settings and legacy routes

`unified-settings` — Preserves the SwiftUI categories and forms merged into main. iOS uses WebKit; its acceptance was not rerun in this integration.

Source：[apps/ios/AegisApp/BrowserSettings.swift](../apps/ios/AegisApp/BrowserSettings.swift) · [apps/ios/AegisApp/SettingsFormControls.swift](../apps/ios/AegisApp/SettingsFormControls.swift)

Runtime acceptance not completed for this item in this work。

Maintenance: edit the JSON, run `node scripts/check-platform-features.mjs --write` to generate all three pages, then run `node scripts/check-platform-features.mjs`. A new release-contract feature fails repository checks until every platform has a recorded status and explanation.
