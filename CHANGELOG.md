# Changelog

**English** | [简体中文](CHANGELOG.zh-CN.md) | [繁體中文](CHANGELOG.zh-TW.md)

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project intends to use [Semantic Versioning](https://semver.org/).

The package version remains `0.1.0`, but no `0.1.0` release, Git tag, or binary distribution has been published. Everything below remains **Unreleased**.

## [Unreleased]

### Release status

- Synchronized Browser Agent v2 to 92 top-level Chromium patches plus 2 nested V8 patches and replayed them exactly to `583cd38ab586ee30e948f0599bb79537dc1632e1`.
- The 57-, 65-, and 67-patch records remain historical evidence and do not qualify v2 artifacts.
- The project remains release No-Go. Source synchronization does not authorize a tag, GitHub Release, binary, signing, notarization, Play upload, or production deployment.

### Added

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

- Converged the product on a Chromium fork; the historical Extension and Electron directions are no longer deliverables.
- Separated source integration, automated tests, build-tree artifacts, runtime evidence, and release qualification in public status wording.
- Kept optional remote summary services provider-compatible rather than binding behavior to a product name.

### Fixed

- Made detached Chromium fetch logs and the vpython wheel/proxy cache follow the checkout selected by `CHROMIUM_ROOT` or `.chromium-root`, instead of silently writing to the retired legacy checkout path.
- Made the accepted Browser Agent toolbar/side-panel entry visible on normal startup without feature flags, including a one-time pin migration for existing profiles.
- Fixed the missing Agent WebUI readiness signal that left toolbar and settings entry clicks waiting forever, and added a regression test that keeps the production readiness wait enabled.
- First-task setup can enable the user-selected provider/model in a regular Profile; experimental WebMCP/transaction capabilities remain disabled by default.
- Replaced technical planning failures with one bounded schema repair, allowlisted read-only recovery, and novice-readable retry guidance.

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

- No trusted build attestation, product Developer ID signature, hardened-runtime notarization, stapling, or installed-App acceptance.
- Android and Windows current-source build/device qualification is in progress; no package is accepted until its exact identity and runtime record are complete.
- Chromium egress, telemetry, updater, crash-reporting, and representative feature-behavior audits remain incomplete.
- Phase 2 research uses a synthetic formal fixture. Phase 3 is a separate 13-sample operator-blinded public pilot with recall `1/3`; neither is generalizable production accuracy, false-positive, or security proof.
