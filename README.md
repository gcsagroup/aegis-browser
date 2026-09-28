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

[Getting started](#getting-started) · [Platform progress](#platform-progress) · [Roadmap](docs/roadmap.md) · [Documentation](docs/README.md)

Aegis is in development; no release-qualified build is available yet.

## Core capabilities

| Capability | Scope |
| --- | --- |
| Privacy browsing | macOS link, cookie, phishing and selected fingerprint protections; separate standard/private profiles on iOS. |
| Controllable Agent | Visible plans, browser-enforced policy and approval for sensitive actions; four offline workflows on iOS. |
| Native downloads | Chromium download UI with bounded download paths on macOS. |
| Access policy | Selected-traffic proxy routing on macOS; required routes fail closed when unavailable. |

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

| Platform | Priority | Status |
| --- | --- | --- |
| macOS | Now | Chromium and Access integration in progress; current-source runtime, real-network and distribution validation pending. |
| iOS / iPadOS | Next | Recorded Simulator baseline; current-source, real-device and distribution validation pending. |
| Windows / Android / Linux | Later | Source and evaluation tools retained; no near-term release commitment. |

macOS can qualify independently of iOS. See the [roadmap](docs/roadmap.md) for release criteria.

## Privacy and AI

Remote summaries send bounded, browser-validated and redacted page content to the selected model endpoint; non-loopback destinations require explicit selection and confirmation. Sensitive pages use on-device heuristics. Browser policy constrains Agent actions, with separate approval for sensitive operations. iOS Agent workflows are offline. See [privacy boundaries](docs/architecture.md); these controls are not a general data-loss-prevention system.

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

These badges do not establish browser runtime or release qualification.

</details>
