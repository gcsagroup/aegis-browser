# GCSA-aegis

**English** | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

[![Upstream CI](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml/badge.svg?branch=main)](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml) [![License: Apache-2.0](assets/badges/license.svg)](LICENSE) [![Codacy Grade](https://app.codacy.com/project/badge/Grade/72c871eba82e471ebc05eaacd4d45218?branch=main)](https://app.codacy.com/gh/quinn521/aegis-browser/dashboard) [![Current platform: macOS](https://img.shields.io/badge/platform-macOS-555?logo=apple&logoColor=white)](apps/browser)

## Overview

GCSA-aegis is a Chromium-based browser project that brings privacy controls, security checks and an AI Agent into the browser. Its local-first approach aims to reduce unnecessary data sharing and give users more control over browsing and automated tasks.

## Project checks

[![CI](https://github.com/quinn521/aegis-browser/actions/workflows/quality.yml/badge.svg?branch=develop)](https://github.com/quinn521/aegis-browser/actions/workflows/quality.yml?query=branch%3Adevelop) [![License: Apache-2.0](assets/badges/license.svg)](LICENSE) [![Codacy Grade](https://app.codacy.com/project/badge/Grade/72c871eba82e471ebc05eaacd4d45218?branch=develop)](https://app.codacy.com/gh/quinn521/aegis-browser/dashboard) [![Current platform: macOS](https://img.shields.io/badge/platform-macOS-555?logo=apple&logoColor=white)](apps/browser)

CI and Codacy Grade track the personal development repository's `develop` branch. They report different checks; neither badge represents release acceptance.

## Development status

**macOS is the current focus. The project is under development and is not release-qualified.** Automatic CI covers repository quality checks, shared policies, scripts and standalone native tests. Full Chromium builds, current browser runtime behavior, real-network validation, signing, notarization and installed-package acceptance are separate gates.

Linux, Windows, iOS and Android work is deferred. Existing platform code and manual validation entry points remain available through the documentation.

## Implemented capabilities

The source includes the following components, with unit or fixture checks for defined behavior:

- **Privacy and tracking controls:** [shared policies](packages/core/src/policy.ts) combine tracker rules, link-parameter cleanup, cookie classification and text privacy checks.
- **Phishing assessment:** the [detector](packages/core/src/phish/detector.ts) evaluates URL and page signals and returns risk reasons. Its test scope does not establish real-world detection accuracy.
- **Browser Agent:** the [desktop Agent interface](apps/browser/overlay/chrome/browser/resources/aegis_agent/agent.ts) provides task status and model-selection controls, with [UI logic checks](apps/browser/scripts/agent-ui-status_test.mjs). Model configuration and end-to-end runtime verification remain necessary.
- **Access rules:** [native routing and policy components](apps/browser/overlay/components/aegis_access) implement site-rule matching and route planning. Standalone tests do not establish production network behavior.

## Get started on macOS

Use the versions in [.mise.toml](.mise.toml) and follow the [environment and quality guide](docs/development/ci.zh-CN.md). After installing the pinned tools, inspect the environment and browser workspace:

```bash
mise exec -- node --version
mise exec -- pnpm --version
mise exec -- python3 --version
mise exec -- pnpm --filter @gcsa-aegis/browser status
```

For dependency installation and the complete quality gate, use the CI guide above. To prepare and build Chromium, follow the [Mac local build workflow](apps/browser/README.md#local-workflow) and [workspace guide](WORKSPACES.zh-CN.md). Chromium requires a separate, large source checkout; the status command does not download or build it. The pinned version is recorded in [CHROMIUM_VERSION](apps/browser/CHROMIUM_VERSION).

## Development workflow

Create a feature branch from the latest DEV `develop`, submit its PR to `develop`, and verify the merged commit's CI. For a public promotion, first fast-forward the personal `main` to the latest upstream `main`, merge that updated `main` back into `develop`, then promote `develop` to the personal `main` through a reviewed PR. After the personal `main` merge and push CI succeed, submit that exact promoted state to upstream `main` for its own review and CI.

See the [CI and upstream workflow guide](docs/development/ci.zh-CN.md) for the full process. Source integration does not publish a binary or release.

## Documentation, license and credits

- [Documentation index](docs/README.md), [architecture](docs/architecture.md) and [roadmap](docs/roadmap.md)
- [Research and limitations](docs/research-map.md) and [historical audit records](docs/audit/README.md)
- Deferred platforms: [iOS](apps/ios/README.md) and [Android](apps/browser/docs/android.md)
- [Changelog](CHANGELOG.md) and [third-party acknowledgements](THIRD_PARTY_NOTICES.md)

GCSA-authored source uses [Apache-2.0](LICENSE). Chromium, libtorrent and other third-party components retain their own licenses. Thank you to the open-source maintainers and contributors behind these projects.
