# Aegis browser

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/brand/final/svg/gcsa-aegis-logo-reversed.svg">
    <source media="(prefers-color-scheme: light)" srcset="assets/brand/final/svg/gcsa-aegis-logo-color.svg">
    <img src="assets/brand/final/svg/gcsa-aegis-logo-color.svg" alt="Aegis logo" width="112">
  </picture>
</p>

**English** | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

[![CI](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml/badge.svg?branch=main&event=push)](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml) [![C++ Unit Tests](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml/badge.svg?branch=main&event=push)](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml) [![Codacy Grade](https://app.codacy.com/project/badge/Grade/7b3008e649154ca0a7d5906c514488cc?branch=main)](https://app.codacy.com/gh/gcsagroup/aegis-browser/dashboard?branch=main) [![License: Apache-2.0](assets/badges/license.svg)](LICENSE) [![App Store 1.0.0](https://img.shields.io/badge/App_Store-1.0.0-007AFF?logo=apple&logoColor=white)](https://apps.apple.com/us/app/gcsa-aegis/id6827988433)

**A local-first privacy and security browser with a controllable AI Agent.**

[Getting started](#getting-started) · [Platform progress](#platform-progress) · [Roadmap](docs/roadmap.md) · [Documentation](docs/README.md)

Aegis Browser 1.0.0 is available for iPhone and iPad. Join the external beta through [TestFlight](https://testflight.apple.com/join/EwUW1VDx). See the [changelog](CHANGELOG.md) for earlier development milestones.

The iOS 1.0.1 candidate adds an Open Source Licenses & Acknowledgements page in Settings. See the [changelog](CHANGELOG.md#ios--ipados-101--testflight) for build status.

## Core capabilities

| Capability | What it does | Platform and current stage |
| --- | --- | --- |
| Privacy browsing | Reduces tracking and risky navigation through link, cookie, phishing and selected fingerprint protections; the native app isolates standard and private profiles. | macOS: in source, runtime acceptance pending. iOS/iPadOS: supports private browsing with separate session state and confirmation before saving content or sending it to a model. |
| Controllable Agent | Shows plans, keeps actions under browser policy and asks before sensitive operations. | macOS: in source, runtime acceptance pending. iOS/iPadOS: confirmed page-to-model requests and separately authorized organization of saved bookmarks. |
| Native downloads | Uses Chromium's browser download surfaces and bounded download paths. | macOS: in source, runtime acceptance pending. |
| Access policy | Routes selected traffic through native proxy components and fails closed when a required route is unavailable. | macOS: in source, integration and real-network acceptance pending. |

## Getting started

### Prepare the development environment

Install Git, [mise](https://mise.jdx.dev/), ripgrep (`rg`) and a C++20 compiler (`clang++` by default). On macOS: `xcode-select --install` for Command Line Tools and `brew install ripgrep` if using Homebrew. Review [`.mise.toml`](.mise.toml) before trusting its pinned toolchain.

```bash
git clone https://github.com/gcsagroup/aegis-browser.git
cd aegis-browser
mise trust .mise.toml
mise install
mise exec -- pnpm install --frozen-lockfile
mise exec -- pnpm run quality:fast
```

This runs shared workspace checks, without fetching Chromium or building either native app.

### Build the macOS browser from source

The [Browser guide](apps/browser/README.md) covers host dependencies, `depot_tools`, the separate Chromium checkout, patch replay, builds and verification.

### Open the iOS project

Open `apps/ios/Aegis.xcodeproj`; follow the [iOS guide](apps/ios/README.md) for Xcode and iPhone/iPad Simulator setup. XcodeGen is needed only to regenerate the project.

## Platform progress

| Platform | Stage | Status |
| --- | --- | --- |
| macOS | Now | Chromium integration and Access Service work continue; current-source runtime and distribution qualification remain open. |
| iOS / iPadOS | Available | Native SwiftUI/WKWebView app. [App Store 1.0.0](https://apps.apple.com/us/app/gcsa-aegis/id6827988433) · [TestFlight Beta](https://testflight.apple.com/join/EwUW1VDx) |
| Windows / Android / Linux | Later | Source and evaluation entry points exist; no near-term release commitment. |

macOS can qualify independently of iOS. See the [roadmap](docs/roadmap.md) for release criteria.

## Privacy and AI

Page summaries use a bounded snapshot that the browser validates and redacts; sensitive pages fall back to an on-device heuristic. A remote summary request can send bounded, redacted page content to a user-selected compatible model endpoint. Non-loopback use requires explicit destination selection and confirmation. Browser Agent actions remain under browser-owned policy, with separate confirmation for sensitive actions. The iOS page assistant can request user-configured models after redaction preview and destination confirmation. Synthetic-model tests do not establish external service quality; the model cannot invoke browser action tools. These controls do not establish a general data-loss-prevention boundary; see the [architecture and privacy boundaries](docs/architecture.md).

## Architecture

| Directory | Responsibility |
| --- | --- |
| [`packages/core`](packages/core) | Shared TypeScript policies, generated assets and Agent contracts. |
| [`apps/browser`](apps/browser) | Chromium fork, native services, builds and desktop packaging. |
| [`apps/ios`](apps/ios) | Native SwiftUI/WKWebView app and embedded extensions. |

## Contributing and documentation

### Contributing

Fork [`gcsagroup/aegis-browser`](https://github.com/gcsagroup/aegis-browser) and open a focused PR against upstream `main`, with validation results and known limitations.

### Documentation

[Documentation index](docs/README.md) · [Architecture](docs/architecture.md) · [Research](docs/research-map.md) · [Historical audits](docs/audit/README.md) · [Changelog](CHANGELOG.md)

### License and acknowledgements

GCSA-authored source uses [Apache-2.0](LICENSE). Third-party components retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).

<details>
<summary>What the badges show</summary>

- **CI:** public `main` quality checks.
- **C++ Unit Tests:** standalone Access tests, Chromium GoogleTest wiring and patch checks.
- **Codacy Grade:** upstream `main` static analysis, not test coverage.
- **App Store:** the public iOS/iPadOS version.

The CI and analysis badges describe source checks.

</details>
