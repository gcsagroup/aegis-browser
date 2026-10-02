[**English**](./README.md) | [简体中文](./README.zh-CN.md) | [繁體中文](./README.zh-TW.md)

# GCSA Aegis for iPhone and iPad

A native SwiftUI and system WebKit browser for iOS 18.4 and later, developed for worldwide App Store technical requirements, including mainland China. Functionality and testing come first; submission materials will be supplied later. Simulator results do not establish release qualification.

## Features

- Tabs and windows: create, rename, move and ungroup tabs while keeping pages open. Regular groups persist; private groups stay in memory. iPad windows save their own tabs and groups, sharing bookmarks, downloads and settings. Pages use the full window with no permanent sidebar.

- Browsing: search, tabs, regular session recovery, private browsing, bookmarks, history, find, system sharing/printing and workspaces with rename, delete, import preview and JSON export.
- Page assistant: explicitly select up to five pages, read visible text, review redaction and confirm the model destination. Summarize, translate, ask questions or compare sources/products. Open cited pages and export the report. Task metadata is encrypted; reports are saved only on request. Restored tasks require a fresh page read and confirmation.
- Model settings: OpenAI-compatible, Anthropic and Gemini APIs; model discovery and manual entry. Service-specific keys are kept in Keychain. Model requests do not follow redirects.
- Bookmark management: preview, confirm, deduplicate and undo, including recovery after relaunch. Link checking is explicit and never automatically deletes bookmarks.
- Downloads: HTTP(S), progress, pause, resume where supported, cancel, retry, system background transfer, up to 16 fallback mirrors, Metalink import with confirmation, SHA-256/SHA-512 and size verification, and sharing to Files. The per-file limit is 1 GB. HTTPS and loopback HTTP are supported; remote cleartext HTTP remains subject to system transport policy.
- Protection: bundled EasyList/EasyPrivacy, manual updates, network blocking, element hiding and site exceptions, tracking-parameter removal, URL risk checks and history/website-data clearing. Private browsing disables the assistant and persistent data/download operations.
- Interface: Simplified Chinese, Traditional Chinese and English, iPhone controls, iPad full-window browser, light/dark appearance, large text and landscape layouts.
- Extensions: the share extension transfers only short-lived HTTP(S) links. The Safari extension retains its bounded read authorization and hands a URL to the app for a separate open confirmation.

## Build and test

Requires Xcode, an available iOS Simulator runtime, XcodeGen, Node.js and Python 3. This iteration uses Xcode 27.0 / iOS Simulator 26.5. Keep default simulator signing enabled; disabling signing can break Keychain tests.

```bash
bash apps/ios/scripts/run-simulator-tests.sh --dry-run
bash apps/ios/scripts/run-simulator-tests.sh \
  --execute --output-dir /tmp/aegis-ios-YOUR-UNIQUE-RUN
```

The runner increments the build number in `project.yml`, regenerates the project, builds once and tests the same product on both named QA simulators. Build output stays in the sibling directory `GCSA-aegis-build/ios/DerivedData`; the app is always `Build/Products/Debug-iphonesimulator/Aegis.app`. Evidence gets a new directory for each run. Existing simulators and evidence are not erased.

Tests use a loopback-only service at `127.0.0.1:8768`. Pages, downloads and model responses are synthetic; actual HTTP, WebKit and file operations test the integration. Synthetic responses do not establish external model quality. The runner starts and stops only its own fixture process, or reuses an existing matching service.

For a manual demonstration, run `python3 apps/ios/scripts/simulator-fixture-server.py --port 8768`, browse to `http://127.0.0.1:8768/article`, and configure the compatible API at `http://127.0.0.1:8768/v1` with model `aegis-simulator-fixture`.

## Ver 2.2 additions

- Bundled EasyList and EasyPrivacy filters, manual updates, network blocking, element hiding, an overall switch, and website exceptions. Unsupported syntax is counted and skipped; this is not full compatibility with every advanced rule.
- Up to 16 download mirrors with sequential fallback, Metalink import and confirmation, SHA-256/SHA-512 and size verification, and paused download recovery.
- Encrypted task goals and source URLs, explicit resume with renewed page reading and consent, and optional encrypted research reports.
- Workspace rename, removal, JSON import preview, and export.

See the [verification record](../../docs/audit/ios-feature-parity-2026-10-01.zh-CN.md). Filter data retains upstream attribution and licensing.

## Boundaries

Pages are limited to 24,000 characters with an explicit truncation notice. Cross-origin frames, input values, passwords and cookies are excluded. Detected sensitive forms or secrets stop model submission. Models return text only; they cannot purchase, sign in, modify pages or invoke tools. Citation numbers are range-checked; conclusions still need source review.

Assistant tasks stop when closed or backgrounded and require fresh reading/confirmation to run again. Download scheduling is controlled by iOS; force quit, termination, connectivity and server behavior can prevent continuation. Downloads do not reuse website login cookies. The app checks initial/final download URLs; intermediate background redirects are controlled by iOS.

BT/magnet links, multi-connection acceleration, cross-device sync, automatic whole-web research, Chromium-specific protection and arbitrary website automation remain unimplemented. Safari host handoff, live external model quality, long-running background/restart scenarios and full VoiceOver flows need separate qualification.

See the [previous 2026-09-30 simulator report](../../docs/audit/ios-simulator-implementation-2026-09-30.zh-CN.md). Historical simulator evidence applies only to its original build.

See the [tab groups, windows and iPad layout report](../../docs/audit/ios-windows-and-tab-groups-2026-10-01.zh-CN.md).

## Release

The [iOS 2.2.0 prerelease](https://github.com/gcsagroup/aegis-browser/releases/tag/ios-v2.2.0-preview.1) provides source and a validation summary. No signed IPA is available for installation or App Store submission. See the [changelog](../../CHANGELOG.md). Set `AEGIS_IOS_DERIVED_DATA` to reuse the fixed build directory from an isolated worktree. Tests also export Swift coverage and input stability records.
