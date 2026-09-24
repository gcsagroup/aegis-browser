# Aegis

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

## Core capabilities

| Capability | What it does | Platform and current stage |
| --- | --- | --- |
| Privacy browsing | Reduces tracking and risky navigation through link, cookie, phishing and selected fingerprint protections; the native app isolates standard and private profiles. | macOS: in source, runtime acceptance pending. iOS/iPadOS: recorded Simulator baseline; current-source validation pending. |
| Controllable Agent | Shows plans, keeps actions under browser policy and asks before sensitive operations. | macOS: in source, runtime acceptance pending. iOS/iPadOS: four offline workflows with a recorded Simulator baseline. |
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
| iOS / iPadOS | Next | Native SwiftUI/WKWebView app has a recorded Simulator baseline; current-source, real-device and distribution work remain open. |
| Windows / Android / Linux | Later | Source and evaluation entry points exist; no near-term release commitment. |

macOS may qualify independently of iOS. See the [roadmap](docs/roadmap.md) for milestone exit criteria. Full browser builds, real-network scenarios, device acceptance, signing, notarization, installation and upgrades are separate release gates.

## Privacy and AI

Page summaries use a bounded snapshot that the browser validates and redacts; sensitive pages fall back to an on-device heuristic. A remote summary request can send bounded, redacted page content to a user-selected compatible model endpoint. Non-loopback use requires explicit destination selection and confirmation. Browser Agent actions remain under browser-owned policy, with separate confirmation for sensitive actions. The iOS Agent workflows are currently offline and have no production remote-model path. These controls do not establish a general data-loss-prevention boundary; see the [architecture and privacy boundaries](docs/architecture.md).

## Architecture

| Directory | Responsibility |
| --- | --- |
| [`packages/core`](packages/core) | Shared TypeScript policy logic, generated assets and Agent contracts. |
| [`apps/browser`](apps/browser) | Chromium integration, native browser services, build scripts and desktop packaging. |
| [`apps/ios`](apps/ios) | Native SwiftUI/WKWebView app, policy and Agent modules, and embedded extensions. |

The desktop browser is a Chromium fork; iOS is a separate native implementation. See the [architecture](docs/architecture.md) and platform guides for implementation details.

## Contributing and documentation

For a public contribution, fork [`gcsagroup/aegis-browser`](https://github.com/gcsagroup/aegis-browser), make a focused change, run relevant checks, and open a pull request against upstream `main`. Include the scope, validation evidence and known limitations. Maintainers working in the GCSA Aegis development fork follow the separate [`develop` workflow](docs/development/ci.zh-CN.md) (Simplified Chinese).

- [Documentation index](docs/README.md) · [Roadmap](docs/roadmap.md) · [Architecture](docs/architecture.md)
- [Browser engineering guide](apps/browser/README.md) · [iOS engineering guide](apps/ios/README.md)
- [Research and limitations](docs/research-map.md) · [Historical audit records](docs/audit/README.md) · [Changelog](CHANGELOG.md)

GCSA-authored source uses [Apache-2.0](LICENSE). Chromium, libtorrent and other third-party components retain their own licenses. See the [third-party acknowledgements](THIRD_PARTY_NOTICES.md).

<details>
<summary>What the badges show</summary>

- **CI** reports the public `main` quality workflow; it does not prove Chromium runtime or distribution acceptance.
- **C++ Unit Tests** covers standalone C++20 Access tests and targeted Chromium GoogleTest wiring and patch checks, not full Chromium GoogleTest or browser runtime coverage.
- **Codacy Grade** reports static analysis for upstream `gcsagroup/aegis-browser` on `main`, not test coverage or runtime acceptance.
- **License** identifies repository licensing. The platform badge shows product priority, not release status.

</details>
