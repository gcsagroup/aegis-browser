# Changelog

**English** | [简体中文](CHANGELOG.zh-CN.md) | [繁體中文](CHANGELOG.zh-TW.md)

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project intends to use [Semantic Versioning](https://semver.org/).

The workspace package remains `0.1.0`; the iOS product line uses `2.2`. The iOS source prerelease below does not establish signing or store qualification.

## [ios-v2.2.0-preview.1](https://github.com/gcsagroup/aegis-browser/releases/tag/ios-v2.2.0-preview.1) — 2026-10-03

### Added

- Native iPhone/iPad page assistant with bounded page reads, redaction preview, destination confirmation, source citations, encrypted task recovery and saved results; OpenAI-compatible, Anthropic and Gemini interfaces.
- HTTP(S) background downloads, pause/resume, mirror retries, Metalink, SHA-256/SHA-512 checks and export to Files.
- Bundled EasyList/EasyPrivacy rules, manual updates, cosmetic filtering and site exceptions; bookmark checks and workspace import/export.
- Persistent tab groups and independent iPad windows with restore; removed the permanent iPad sidebar.

### Fixed and verified

- Hardened validation scripts with fixed file paths, loopback-only HTTP self-tests, and checks that remain active under Python optimization; generated rules remain byte-identical.

- Moved initial window persistence out of view construction to remove SwiftUI runtime warnings. Private pages and groups stay out of window records.
- Preserved upstream Swift coverage and input hash checks; freeze inputs after version updates and project generation, and reuse the fixed build directory from isolated worktrees.
- See the [release notes](docs/releases/ios-2.2.0-preview.1.zh-CN.md) for localization, privacy manifests and simulator evidence. This GitHub source prerelease has no installable signed IPA. Device, full VoiceOver, TestFlight and App Store acceptance remain open.

## [Unreleased]

### 2026-10-09 源码整合：Quinn 功能与 Chromium 155 主线

- 在同一源码整合中保留桌面鼠标手势，纳入 Quinn develop 的双节点租约、双 relay、本地 SM-00 预检与工作流文档，并纳入其 PR #203 的 Agent 接管、监控订阅、研究来源绑定及 iOS 下载持久化/恢复修复。
- 适配新增研究测试到 Chromium 155；固定租约 SQL 查询并增加非法表名拒绝回归。Mac 候选提升为 Ver 2.2 (144)，276 个补丁和 506 项 overlay 完整重放通过；iOS 下载定向测试在 iPhone/iPad 模拟器各通过 43 项。
- 合入路径统一为 [#32](https://github.com/gcsagroup/aegis-browser/pull/32)；[#33](https://github.com/gcsagroup/aegis-browser/pull/33) 已并入该整合分支。下方 141 记录保留为历史证据；最新范围和验证见[整合记录](docs/audit/main-quinn-integration-2026-10-09.zh-CN.md)。本次不创建正式发行，原型与模拟器结果不代表生产接入或实机验收。

### 2026-10-09 源码更新：桌面鼠标手势与 Chromium 155 适配

- 新增原生右键手势、方向绑定、轨迹提示、识别距离、网站排除及不执行真实动作的练习区；普通网页、设置页和内置 PDF 使用一致的通用动作，PDF 另可绑定翻页、适合宽度和整页。
- 保留右键轻点菜单及左键点击、拖选；Esc、导航、失焦和离开内容区会取消手势。修复跨框架测试的输入时序，以及 Chromium 155 设置项改名后的旧测试取值。
- Mac ARM64 验收版 Ver 2.2 (141)：33 项测试及跨框架额外 5 次复测通过；273 个桌面补丁完整重放，506 项 overlay 核对通过，并完成实际 App 设置保存回读。具体版本和证据范围见[验收记录](docs/audit/mouse-gestures-acceptance-2026-10-09.zh-CN.md)。
- 上游同步改为分别跟踪源码 PR、主线兼容验收和正式发行；鼠标手势纳入持续功能回归。代码位于依赖 [#32](https://github.com/gcsagroup/aegis-browser/pull/32) 的 [#33](https://github.com/gcsagroup/aegis-browser/pull/33) 草稿 PR，记录时 main 尚未升级。Windows/Android 兼容验收、上游 PR 扫描问题及正式签名、公证仍待完成。
- [鼠标手势使用指南](apps/browser/docs/mouse-gestures.zh-CN.md)。本次补充文档不重新编译 App，验收收据仍绑定原构建提交。

### 2026-09-14 source update: UI corrections and browser updates

- Patches 0109–0113 add GitHub Release checking and installer downloads with size and SHA-256 verification, shared product-update state, accurate model-configuration status, and trilingual settings and built-in page corrections. Download verification does not replace release signing, notarization, or installation acceptance.
- Historical local macOS acceptance on 2026-09-13: Ver 1.1 (018), 32 findings addressed, 18 native tests and 116 UI checks passed; 170 changed messages and translation placeholders checked. Ver 1.1 (018) identifies the local test App, not a published release or the repository package version. These results cover that test App and the recorded scope, not later source revisions. Windows/Android device acceptance and a real Release installation remain unverified. No binary or tag was published with this source update.
- The 2026-09-14 source-submission record confirms that replaying patches 0109–0113 onto the historical 108-patch tree `319366182c31108e29e62d2f2199aff29a0b86e8` produced tree `6032269758860056c1371ed5d6f9ed6902c23596`. This is a dated replay result, not current-source or release qualification.
- [018 验收记录](docs/ui-copy-acceptance.zh-CN.md) · [更新流程](docs/github-browser-updates.zh-CN.md)

### Release status

- Consolidated development history into `main` on 2026-09-10. Patches 0107–0108 cover startup monitor recovery and verified runtime/summary fixes. [Verification record](docs/audit/main-consolidation-2026-09-10.md); no App build or binary release was performed.

- Historical 2026-09-10 baseline: Browser Agent v2 contained 108 top-level Chromium patches plus 2 nested V8 patches, replayed exactly to source tree `319366182c31108e29e62d2f2199aff29a0b86e8`. The 2026-09-14 update above records the subsequent replay result; neither tree identifies the current source by itself.
- Patch 0106 fixes blocking locale lookup on Windows UI threads without removing the remote-control warning; rebuilt platform regression acceptance remains pending.
- The 57-, 65-, 67-, 95-, and 97-patch records remain historical evidence and do not qualify the current v2 artifacts.
- The project remains release No-Go. Source synchronization does not authorize a tag, GitHub Release, binary, signing, notarization, Play upload, or production deployment.

### Added

- Development-only ASCII-smuggling protection: normalize hidden Unicode before phishing checks and model requests, reject hidden tool arguments, and preserve legitimate emoji. macOS native/UI and local-Qwen checks passed; updated Windows/Android package acceptance is pending.
- Browser Agent v2 native hybrid runtime: model-first goal routing and planning, browser-owned execution/observation/verification, deterministic named-site targets, and safe R0 read-only recovery after one bounded model-format repair.
- Desktop and Android novice entry points, current-page binding, common tasks for summaries/comparison/bookmarks/URL checks/downloads/research, and a separate scheduled-automation workspace.
- Chromium-native privacy and security controls, site protection UI, phishing explanations, and bounded session activity.
- Local threat-feed indexing, bounded phishing page signals, and credential-intent checks.
- HTTP(S) parallel-download controls, Metalink support, and BT/Magnet integration with bounded defaults.
- Fingerprint mitigations for Canvas, OffscreenCanvas, Audio, WebGL, and selected WebGPU surfaces.
- Observe-only MinerGuard signals and research-only AST, provenance-flow, federated-simulation, and V8 bytecode-shadow prototypes.
- User-configured OpenAI-, Claude (Anthropic)-, and Gemini-compatible model APIs, plus an in-page summary shortcut with exact-document session binding.
- A browser-owned Agent with scoped bookmark/URL/page/download/monitor tools, approval receipts, cancellation, audit history, and user takeover before final purchase.
- Trilingual public documentation in English, Simplified Chinese, and Traditional Chinese.

### Changed

- Read the non-coalescing `Retry-After` response header through Chromium's enumeration API, preventing the assertion-enabled Windows browser crash during bounded same-origin bookmark URL checks.
- Converged the product on a Chromium fork; the historical Extension and Electron directions are no longer deliverables.
- Separated source integration, automated tests, build-tree artifacts, runtime evidence, and release qualification in public status wording.
- Kept optional remote summary services provider-compatible rather than binding behavior to a product name.

### Fixed

- Made detached Chromium fetch logs and the vpython wheel/proxy cache follow the checkout selected by `CHROMIUM_ROOT` or `.chromium-root`, instead of silently writing to the retired legacy checkout path.
- Made the accepted Browser Agent toolbar/side-panel entry visible on normal startup without feature flags, including a one-time pin migration for existing profiles.
- Fixed the missing Agent WebUI readiness signal that left toolbar and settings entry clicks waiting forever, and added a regression test that keeps the production readiness wait enabled.
- First-task setup can enable the user-selected provider/model in a regular Profile; experimental WebMCP/transaction capabilities remain disabled by default.
- Replaced technical planning failures with one bounded schema repair, allowlisted read-only recovery, and novice-readable retry guidance.
- Bound model-proposed tab/document capabilities to the browser's live approved task context, so harmless model ID drift no longer breaks a single-tab read-only task while ambiguous or higher-risk actions still fail closed.
- Moved Agent task persistence to a dedicated blocking-capable sequence, eliminating the UI-sequence SQLite crash while preserving redacted task records and bounded shutdown.
- Made bookmark URL checks finish deterministically after a same-origin HTTP 429 by recording the server retry window for all remaining URLs on that origin instead of waiting serially.

- Hardened profile shutdown, cross-sequence report delivery, patch replay, build identity, packaging guards, and local signing checks.
- Added Aegis core, Agent, Actor, settings/menu/toolbar/side-panel, and download surfaces to a distinct primary Incognito Profile; Guest, System, and auxiliary OTR Profiles remain fail closed.
- Moved local ad-hoc signing before build-identity finalization so launching a verified App no longer mutates its bound bytes.
- Made Android packaging reject symlink/path escapes and publish outputs atomically without overwriting existing artifacts.
- Reduced selected filter-list and Canvas hot-path overhead and corrected several browser lifecycle and WebUI issues.

### Security

- Applied exact-document authorization and remote-origin propagation to selected local CDP paths.
- Added fail-closed summary redaction checks, sensitive-page fallback, explicit remote-destination confirmation, and non-echoing system-encrypted API credentials.
- Release verification now checks the sealed schema, current source and dependency state, build graph, and complete artifact tree; only local `.DS_Store` metadata is excluded explicitly.
- Kept MinerGuard and V8 bytecode-shadow work observe-only; neither authorizes script blocking or a general malicious-JavaScript claim.
- Enforced Browser Agent scope, document binding, profile isolation, secret redaction, SSRF controls, exact approvals, browser-side result verification, and fail-closed recovery below the model layer.
- Added a process-wide remote-CDP latch on desktop and Android: creating a primary Incognito Profile stops and blocks desktop HTTP/pipe and Android HTTP/socket transports before deferred startup or target-ownership checks. Desktop recovery requires an explicit enable action from a regular Profile; Android remains latched until process restart.
- Redacted model API-key headers from default NetLog captures and suppressed private Actor journals, diagnostics, and traces. NetLog captures explicitly requested with Chromium's sensitive mode retain Chromium's sensitive-data semantics and must be handled as secret-bearing.
- Used opaque exact-Profile network/CNAME partitions and memory-only Incognito Advanced/Torrent ownership. Closing Incognito cancels active Agent downloads and torrent transfers and revokes control, while retaining already-written torrent bytes and Chromium's native persistence for completed downloads and approved bookmark writes.

### Known limitations

- Formal release qualification remains incomplete: no trusted build attestation, product Developer ID signature, hardened-runtime notarization, stapling, or end-to-end installation and upgrade acceptance for a formal release package. The local 018 test App installation and macOS checks above do not establish release qualification.
- Android and Windows current-source build/device qualification is in progress; no package is accepted until its exact identity and runtime record are complete.
- Chromium egress, telemetry, updater, crash-reporting, and representative feature-behavior audits remain incomplete.
- Phase 2 research uses a synthetic formal fixture. Phase 3 is a separate 13-sample operator-blinded public pilot with recall `1/3`; neither is generalizable production accuracy, false-positive, or security proof.
