# Aegis

**English** | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

[![CI](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml/badge.svg?branch=main&event=push)](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml) [![C++ Unit Tests](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml/badge.svg?branch=main&event=push)](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml) [![License: Apache-2.0](assets/badges/license.svg)](LICENSE) [![Current platform: macOS](https://img.shields.io/badge/current-macOS-555?logo=apple&logoColor=white)](apps/browser)

**A local-first privacy and security browser with a controllable AI Agent. macOS comes first; iPhone and iPad are next.**

Aegis integrates privacy controls, security checks, native browser capabilities and an AI Agent directly into the browser. The project is under active development and is not release-qualified.

## Platform priority

| Platform | Priority | Current direction |
| --- | --- | --- |
| **macOS** | **Now** | Finish Chromium integration, Access Service, runtime regression coverage, stability and a signed/notarized distribution candidate. |
| **iOS / iPadOS** | **Next** | Continue from the existing native SwiftUI/WKWebView code and recorded Simulator baseline, then complete real-device and distribution work. |
| Windows / Android / Linux | Later | Keep existing source and evaluation entry points; no near-term release commitment. |

See the [roadmap](docs/roadmap.md) for milestone exit criteria. macOS may qualify independently; it does not wait for iOS distribution readiness.

## What Aegis contains

- **Privacy and tracking controls:** tracker rules, link cleanup, cookie classification, phishing signals and selected fingerprinting mitigations.
- **Browser Agent:** model configuration, visible plans, browser-controlled tool execution and explicit user takeover for sensitive actions.
- **Access Service:** native policy and proxy-routing components, including fail-closed routing and NetworkContext integration.
- **Native browser integration:** Chromium-native download, settings and browser surfaces rather than a standalone extension product.
- **Native iOS product:** SwiftUI/WKWebView, isolated standard/private profiles, embedded Safari/Share extensions and AgentKit.

Detailed engineering boundaries live in the [Browser guide](apps/browser/README.md), [iOS guide](apps/ios/README.md) and [architecture](docs/architecture.md).

## Engineering evidence

The badges above report different scopes:

- **CI** is the repository quality gate for public `main`.
- **C++ Unit Tests** runs standalone C++20 Access tests plus Chromium GoogleTest wiring/patch contracts. It does **not** claim that the full Chromium GoogleTest binary or every browser runtime scenario passed.
- **License** and platform badges describe repository metadata and current product priority, not release status.

Full Chromium builds, current browser runtime behavior, real-network scenarios, Developer ID signing, notarization, installation and upgrade acceptance remain separate macOS release gates.

## Quick start

The repository pins Node.js `22.23.1`, pnpm `9.15.0` and Python `3.11.9`.

```bash
pnpm install --frozen-lockfile
pnpm run quality:fast
pnpm --filter @gcsa-aegis/browser status
```

Chromium development requires a separate large checkout; start with the [Browser engineering guide](apps/browser/README.md). Native Apple-platform work starts with the [iOS engineering guide](apps/ios/README.md).

## Roadmap

1. **MAC-1 — Core browser and Access Service:** close current Chromium integration, routing and regression gaps.
2. **MAC-2 — Stability and release candidate:** reproducible current-source build, representative runtime/privacy/performance checks and installed-App acceptance.
3. **MAC-3 — macOS distribution:** Developer ID signing, notarization, packaging, clean install/upgrade/rollback and explicit release authorization.
4. **IOS-1 — Real-device baseline:** refresh the existing native iOS code against current source and complete iPhone/iPad device and lifecycle validation.
5. **IOS-2 — Product completion:** finish embedded extension, policy, privacy and Agent integration on device.
6. **IOS-3 — Distribution:** entitlement/provisioning, signing, Archive, TestFlight and App Store readiness.

Windows, Android and Linux remain later evaluation tracks and do not block the macOS → iOS roadmap.

## Contributing

Contributions are welcome. Keep each pull request focused and include the tests or evidence relevant to the change.

1. Fork this repository.
2. Create a topic branch from the current `main`.
3. Make one focused change and add or update relevant tests.
4. Run the applicable local checks documented for the affected component.
5. Push the branch to your fork and open a pull request against this repository's `main`.
6. In the PR description, explain the problem, scope, test evidence and any remaining limitations.
7. Address review feedback on the same PR; do not rewrite unrelated history.

For Chromium changes, read the [Browser guide](apps/browser/README.md). For iOS changes, read the [iOS guide](apps/ios/README.md).

## Documentation and license

- [Roadmap](docs/roadmap.md) · [Documentation index](docs/README.md) · [Architecture](docs/architecture.md)
- [Browser engineering guide](apps/browser/README.md) · [iOS engineering guide](apps/ios/README.md)
- [Research and limitations](docs/research-map.md) · [Historical audit records](docs/audit/README.md)
- [Changelog](CHANGELOG.md) · [Third-party acknowledgements](THIRD_PARTY_NOTICES.md)

GCSA-authored source uses [Apache-2.0](LICENSE). Chromium, libtorrent and other third-party components retain their own licenses.
