# Aegis

**English** | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

[![CI](https://github.com/quinn521/aegis-browser/actions/workflows/quality.yml/badge.svg?branch=develop&event=push)](https://github.com/quinn521/aegis-browser/actions/workflows/quality.yml?query=branch%3Adevelop) [![C++ Unit Tests](https://github.com/quinn521/aegis-browser/actions/workflows/cpp-unit-tests.yml/badge.svg?branch=develop&event=push)](https://github.com/quinn521/aegis-browser/actions/workflows/cpp-unit-tests.yml?query=branch%3Adevelop) [![Codacy Grade](https://app.codacy.com/project/badge/Grade/72c871eba82e471ebc05eaacd4d45218?branch=develop)](https://app.codacy.com/gh/quinn521/aegis-browser/dashboard) [![License: Apache-2.0](assets/badges/license.svg)](LICENSE) [![Current platform: macOS](https://img.shields.io/badge/current-macOS-555?logo=apple&logoColor=white)](apps/browser)

**A local-first privacy and security browser with a controllable AI Agent. macOS comes first; iPhone and iPad are next.**

Aegis integrates privacy controls, security checks, native browser capabilities and an AI Agent directly into the browser rather than treating an extension as the product. The project is still under active development and is not release-qualified.

## Platform priority

| Platform | Priority | Current direction |
| --- | --- | --- |
| **macOS** | **Now** | Finish the Chromium product, Access Service, runtime regression coverage, stability and a signed/notarized distribution candidate. |
| **iOS / iPadOS** | **Next** | Continue from the existing native SwiftUI/WKWebView code and recorded Simulator baseline, then complete real-device and distribution work. |
| Windows / Android / Linux | Later | Keep existing source and manual validation entry points; no near-term release commitment. |

The full milestone definition is in the [roadmap](docs/roadmap.md). macOS may reach release qualification independently; it does not wait for iOS distribution readiness.

## What Aegis contains

- **Privacy and tracking controls:** tracker rules, link cleanup, cookie classification, phishing signals and selected fingerprinting mitigations.
- **Browser Agent:** model configuration, visible plans, browser-controlled tool execution and explicit user takeover for sensitive actions.
- **Access Service:** native policy and proxy-routing components, including fail-closed route handling and NetworkContext integration work.
- **Native downloads and browser integration:** Chromium-native download and settings surfaces rather than a separate extension product.
- **Native iOS product:** an existing SwiftUI/WKWebView codebase with isolated standard/private profiles, embedded Safari/Share extensions and AgentKit.

See [Browser](apps/browser/README.md), [iOS](apps/ios/README.md) and [Architecture](docs/architecture.md) for detailed boundaries.

## Current engineering evidence

The badges above intentionally report different scopes:

- **CI** is the repository quality gate for the current development branch.
- **C++ Unit Tests** runs the standalone C++20 Access tests plus Chromium GoogleTest wiring/patch contracts. It does **not** claim that the full Chromium GoogleTest binary or every browser runtime scenario passed.
- **Codacy Grade** is static analysis, not runtime or release acceptance.

Full Chromium builds, current browser runtime behavior, real-network scenarios, Developer ID signing, notarization, installation and upgrade acceptance remain separate macOS release gates.

## macOS development

Use the pinned toolchain from [.mise.toml](.mise.toml):

```bash
mise install
mise exec -- node --version
mise exec -- pnpm --version
mise exec -- python3 --version
mise exec -- pnpm --filter @gcsa-aegis/browser status
```

For the full local quality gate and repository workflow, follow the [CI and development guide (Chinese)](docs/development/ci.zh-CN.md). Preparing Chromium requires a separate large checkout; follow the [Browser local workflow](apps/browser/README.md#local-workflow) and [workspace guide (Chinese)](WORKSPACES.zh-CN.md).

## Development workflow

This `develop` branch is the maintenance and integration line. Normal changes follow:

```text
latest develop → feature branch → local validation → PR → review / CI → merge → develop push CI
```

Public promotion to the repository's default `main` and then to upstream is a separate reviewed step. The exact branch, review, CI and upstream-export rules are maintained in the [CI and development guide (Chinese)](docs/development/ci.zh-CN.md).

## Roadmap

1. **MAC-1 — Core browser and Access Service:** close current Chromium integration, routing and regression gaps.
2. **MAC-2 — Stability and release candidate:** reproducible current-source build, representative runtime/privacy/performance checks and installed-App acceptance.
3. **MAC-3 — macOS distribution:** Developer ID signing, notarization, packaging, clean install/upgrade/rollback and explicit release authorization.
4. **IOS-1 — Real-device baseline:** refresh the existing native iOS code against the current source and complete iPhone/iPad device and lifecycle validation.
5. **IOS-2 — Product completion:** finish embedded extension, policy, privacy and Agent integration on device.
6. **IOS-3 — Distribution:** entitlement/provisioning, signing, Archive, TestFlight and App Store readiness.

Windows and Android remain later evaluation tracks and do not block the macOS → iOS roadmap.

## Documentation and license

| Documentation | License & acknowledgements |
| --- | --- |
| [Roadmap](docs/roadmap.md) | GCSA-authored source uses [Apache-2.0](LICENSE). |
| [Documentation index](docs/README.md) | Chromium, libtorrent and other third-party components retain their own licenses. |
| [Architecture](docs/architecture.md) | [Third-party acknowledgements](THIRD_PARTY_NOTICES.md) |
| [Browser engineering guide](apps/browser/README.md) | |
| [iOS engineering guide](apps/ios/README.md) | |
| [Research and limitations](docs/research-map.md) | |
| [Historical audit records](docs/audit/README.md) | |
| [Changelog](CHANGELOG.md) | |
