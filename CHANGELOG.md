# Changelog

**English** | [简体中文](CHANGELOG.zh-CN.md) | [繁體中文](CHANGELOG.zh-TW.md)

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project intends to use [Semantic Versioning](https://semver.org/).

The package version remains `0.1.0`, but no `0.1.0` release, Git tag, or binary distribution has been published. Everything below remains **Unreleased**.

## [Unreleased]

### Release status

- Synchronized the combined source integration to 67 top-level Chromium patches plus 2 nested V8 patches.
- The earlier 57-patch diagnostic manifest and 65-patch Agent acceptance remain historical evidence; neither binds or qualifies the combined 67-patch head.
- The project remains release No-Go. Source synchronization does not authorize a tag, GitHub Release, binary, signing, notarization, Play upload, or production deployment.

### Added

- Browser-level Agent task bootstrap: goals entered from a blank or internal page now open an explicit URL directly or search with the user's default provider; bookmark-only steward tasks no longer require a web page.
- Chromium-native privacy and security controls, site protection UI, phishing explanations, and bounded session activity.
- Local threat-feed indexing, bounded phishing page signals, and credential-intent checks.
- HTTP(S) parallel-download controls, Metalink support, and BT/Magnet integration with bounded defaults.
- Fingerprint mitigations for Canvas, OffscreenCanvas, Audio, WebGL, and selected WebGPU surfaces.
- Observe-only MinerGuard signals and research-only AST, provenance-flow, federated-simulation, and V8 bytecode-shadow prototypes.
- User-configured OpenAI-, Claude (Anthropic)-, and Gemini-compatible model APIs, plus an in-page summary shortcut with exact-document session binding.
- A browser-owned Agent with Observe/Ask/Act modes, bookmark and URL maintenance, bounded browsing/download/workflow/monitor tools, approval receipts, cancellation, audit history, and user takeover before final purchase.
- Trilingual public documentation in English, Simplified Chinese, and Traditional Chinese.

### Changed

- Converged the product on a Chromium fork; the historical Extension and Electron directions are no longer deliverables.
- Separated source integration, automated tests, build-tree artifacts, runtime evidence, and release qualification in public status wording.
- Kept optional remote summary services provider-compatible rather than binding behavior to a product name.

### Fixed

- Made detached Chromium fetch logs and the vpython wheel/proxy cache follow the checkout selected by `CHROMIUM_ROOT` or `.chromium-root`, instead of silently writing to the retired legacy checkout path.
- Made the accepted Browser Agent toolbar/side-panel entry visible on normal startup without feature flags, including a one-time pin migration for existing profiles.
- Fixed the missing Agent WebUI readiness signal that left toolbar and settings entry clicks waiting forever, and added a regression test that keeps the production readiness wait enabled.
- Per-profile execution remains opt-in and experimental WebMCP/transaction capabilities remain disabled by default.

- Hardened profile shutdown, cross-sequence report delivery, patch replay, build identity, packaging guards, and local signing checks.
- Bound summary, WebUI, and toolbar access to the owning regular profile; secondary and off-the-record profiles now fail closed.
- Moved local ad-hoc signing before build-identity finalization so launching a verified App no longer mutates its bound bytes.
- Made Android packaging reject symlink/path escapes and publish outputs atomically without overwriting existing artifacts.
- Reduced selected filter-list and Canvas hot-path overhead and corrected several browser lifecycle and WebUI issues.

### Security

- Applied exact-document authorization and remote-origin propagation to selected local CDP paths.
- Added fail-closed summary redaction checks, sensitive-page fallback, explicit remote-destination confirmation, and non-echoing system-encrypted API credentials.
- Release verification now checks the sealed schema, current source and dependency state, build graph, and complete artifact tree; only local `.DS_Store` metadata is excluded explicitly.
- Kept MinerGuard and V8 bytecode-shadow work observe-only; neither authorizes script blocking or a general malicious-JavaScript claim.
- Enforced Browser Agent scope, document binding, profile isolation, secret redaction, SSRF controls, exact approvals, browser-side result verification, and fail-closed recovery below the model layer.

### Known limitations

- No trusted build attestation, product Developer ID signature, hardened-runtime notarization, stapling, or installed-App acceptance.
- No current-source Android APK/AAB or qualified Linux Android build environment.
- Chromium egress, telemetry, updater, crash-reporting, and representative feature-behavior audits remain incomplete.
- Phase 2 research uses a synthetic formal fixture. Phase 3 is a separate 13-sample operator-blinded public pilot with recall `1/3`; neither is generalizable production accuracy, false-positive, or security proof.
