# Aegis browser

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/brand/final/svg/gcsa-aegis-logo-reversed.svg">
    <source media="(prefers-color-scheme: light)" srcset="assets/brand/final/svg/gcsa-aegis-logo-color.svg">
    <img src="assets/brand/final/svg/gcsa-aegis-logo-color.svg" alt="Aegis logo" width="112">
  </picture>
</p>

**English** | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

[![CI](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml/badge.svg?branch=main&event=push)](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml) [![C++ Unit Tests](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml/badge.svg?branch=main&event=push)](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml) [![Codacy Grade](https://app.codacy.com/project/badge/Grade/7b3008e649154ca0a7d5906c514488cc?branch=main)](https://app.codacy.com/gh/gcsagroup/aegis-browser/dashboard?branch=main) [![License: Apache-2.0](assets/badges/license.svg)](LICENSE) [![Current platform: macOS](https://img.shields.io/badge/current-macOS-555?logo=apple&logoColor=white)](apps/browser)

**A local-first privacy and security browser with a controllable AI Agent. macOS first; iPhone and iPad next.**

[Getting started](#getting-started) · [Platform progress](#platform-progress) · [Roadmap](docs/roadmap.md) · [Browser guide](apps/browser/README.md) · [iOS guide](apps/ios/README.md) · [Documentation](docs/README.md)

---

Aegis is under active development. **Release No-Go:** neither the macOS browser nor the native iOS/iPadOS app has a qualified distributable build.

> **2026-10-09 · 桌面鼠标手势候选：** Ver 2.2 (141) 基于 Chromium `155.0.8059.40`，支持网页、设置页和内置 PDF 的原生右键手势。Mac ARM64 的 33 项测试及跨框架额外 5 次复测通过；Windows 构建与实机验收尚未完成。[使用指南](apps/browser/docs/mouse-gestures.zh-CN.md) · [验收记录](docs/audit/mouse-gestures-acceptance-2026-10-09.zh-CN.md)。代码位于依赖 [#32](https://github.com/gcsagroup/aegis-browser/pull/32) 的 [#33](https://github.com/gcsagroup/aegis-browser/pull/33) 草稿 PR；记录时 main 尚未升级，未正式发行。

> **2026-10-03 · iOS 2.2.0 source prerelease:** page assistance, filtering, downloads, workspaces, tab groups and independent iPad windows are integrated. See the [release notes](docs/releases/ios-2.2.0-preview.1.zh-CN.md) for validation and usage. No installable signed IPA is available.

## Core capabilities

| Capability | What it does | Platform and current stage |
| --- | --- | --- |
| Privacy browsing | Reduces tracking and risky navigation through link, cookie, phishing and selected fingerprint protections; the native app isolates standard and private profiles. | macOS: in source, runtime acceptance pending. iOS/iPadOS: see the 2.2 simulator validation and prerelease notes above. |
| Controllable Agent | Shows plans, keeps actions under browser policy and asks before sensitive operations. | macOS: in source, runtime acceptance pending. iOS/iPadOS: confirmed page-to-model requests; browser action tools remain unavailable. |
| Native downloads | Uses Chromium's browser download surfaces and bounded download paths. | macOS: in source, runtime acceptance pending. |
| Access policy | Routes selected traffic through native proxy components and fails closed when a required route is unavailable. | macOS: in source, integration and real-network acceptance pending. |

## Getting started

### Prepare the development environment

The repository pins Node.js `22.23.1`, pnpm `9.15.0` and Python `3.11.9` in [`.mise.toml`](.mise.toml). Install Git, [mise](https://mise.jdx.dev/), ripgrep (`rg`) and a C++20 compiler (`clang++` by default). On macOS, install Xcode Command Line Tools with `xcode-select --install`; Homebrew users can install ripgrep with `brew install ripgrep`.

```bash
git clone https://github.com/gcsagroup/aegis-browser.git
cd aegis-browser
mise install
mise exec -- pnpm install --frozen-lockfile
mise exec -- pnpm run quality:fast
```

These commands run shared workspace checks. They do not fetch or build Chromium or validate the native iOS app.

### Build the macOS browser from source

Follow the [Browser engineering guide](apps/browser/README.md) to prepare `depot_tools`, fetch the separate, large pinned Chromium checkout, replay the patch series, and build and run the browser. Chromium also requires additional host dependencies; the guide provides build and verification commands.

### Open the iOS project

The native [iOS engineering guide](apps/ios/README.md) covers Xcode and Simulator prerequisites, the checked-in `apps/ios/Aegis.xcodeproj`, and the iPhone/iPad Simulator workflow. XcodeGen is needed only when project regeneration is required.

## Platform progress

| Platform | Priority | Current state |
| --- | --- | --- |
| macOS | Now | Chromium integration and Access Service work continue; current-source runtime and distribution qualification remain open. |
| iOS / iPadOS | Next | Native SwiftUI/WKWebView 2.2 source prerelease with simulator validation; device and distribution acceptance remain open. |
| Windows / Android / Linux | Later | Source and evaluation entry points exist; no near-term release commitment. |

macOS may qualify independently of iOS. See the [roadmap](docs/roadmap.md) for milestone exit criteria. Full browser builds, real-network scenarios, device acceptance, signing, notarization, installation and upgrades are separate release gates.

## Privacy and AI

Page summaries use a bounded snapshot that the browser validates and redacts; sensitive pages fall back to an on-device heuristic. A remote summary request can send bounded, redacted page content to a user-selected compatible model endpoint. Non-loopback use requires explicit destination selection and confirmation. Browser Agent actions remain under browser-owned policy, with separate confirmation for sensitive actions. The iOS page assistant can request user-configured models after redaction preview and destination confirmation. Synthetic-model tests do not establish external service quality; the model cannot invoke browser action tools. These controls do not establish a general data-loss-prevention boundary; see the [architecture and privacy boundaries](docs/architecture.md).

## Architecture

| Directory | Responsibility |
| --- | --- |
| [`packages/core`](packages/core) | Shared TypeScript policy logic, generated assets and Agent contracts. |
| [`apps/browser`](apps/browser) | Chromium integration, native browser services, build scripts and desktop packaging. |
| [`apps/ios`](apps/ios) | Native SwiftUI/WKWebView app, policy and Agent modules, and embedded extensions. |

The desktop browser is a Chromium fork; iOS is a separate native implementation. See the [architecture](docs/architecture.md) and platform guides for implementation details.

## Contributing and documentation

### Contributing

For a public contribution, fork [`gcsagroup/aegis-browser`](https://github.com/gcsagroup/aegis-browser), make a focused change, run relevant checks, and open a pull request against upstream `main`. Include the scope, validation evidence and known limitations.

### Documentation

- **Project:** [Documentation index](docs/README.md) · [Roadmap](docs/roadmap.md) · [Architecture](docs/architecture.md)
- **Engineering:** [Browser engineering guide](apps/browser/README.md) · [iOS engineering guide](apps/ios/README.md)
- **Reference:** [Research and limitations](docs/research-map.md) · [Historical audit records](docs/audit/README.md) · [Changelog](CHANGELOG.md)

### License and acknowledgements

GCSA-authored source uses [Apache-2.0](LICENSE). Chromium, libtorrent and other third-party components retain their own licenses.

See the [third-party acknowledgements](THIRD_PARTY_NOTICES.md).

<details>
<summary>What the badges show</summary>

- **CI** reports the public `main` quality workflow; it does not prove Chromium runtime or distribution acceptance.
- **C++ Unit Tests** covers standalone C++20 Access tests and targeted Chromium GoogleTest wiring and patch checks, not full Chromium GoogleTest or browser runtime coverage.
- **Codacy Grade** reports static analysis for upstream `gcsagroup/aegis-browser` on `main`, not test coverage or runtime acceptance.
- **License** identifies repository licensing. The platform badge shows product priority, not release status.

</details>
