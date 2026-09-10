# GCSA-aegis

**English** | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

GCSA-aegis is a local-first privacy and security browser project with two product lines: the Chromium fork under [`apps/browser`](apps/browser/README.md) and the native iOS browser under [`apps/ios`](apps/ios/README.md). Core capabilities stay inside each browser product; the project does not revive the retired standalone-extension product.

> **Status — 2026-09-10:** the Browser Agent v2 candidate contains 108 top-level Chromium patches plus 2 nested V8 patches and replays exactly to Chromium source tree `319366182c31108e29e62d2f2199aff29a0b86e8`. The 57-, 65-, 67-, 95-, and 97-patch records remain historical evidence. The native iOS product remains **SIMULATOR_QUALIFIED** only for its recorded Simulator scope. The project is **release No-Go** pending trusted attestation, production signing, notarization, installed-distribution acceptance, and the separately deferred iOS gates.

[2026-09-10 main consolidation and verification](docs/audit/main-consolidation-2026-09-10.md)

The Agent entry is visible in a regular desktop Profile and on Android. The first task can configure and enable the user-selected model without requiring a separate workflow choice or pre-opened page. WebMCP and transaction submission remain default-off, and final checkout/payment always requires user takeover.

## Product shape

- **Chromium product line:** [`apps/browser`](apps/browser/README.md) owns the Chromium pin, patch stack, browser integration, build, and platform packaging boundaries.
- **Native iOS product line:** [`apps/ios`](apps/ios/README.md) implements a SwiftUI/WKWebView browser, isolated standard and private profiles, embedded Safari/Share extensions, and an Agent Broker.
- **Shared policy and contract source:** [`packages/core`](packages/core) provides testable policies, generated assets, and Agent Contract v1 schemas and golden vectors shared by TypeScript and Swift.
- **iOS Agent scope:** four controlled, offline-verifiable workflows—deep research, browser manager, safe download, and shopping assistant—return deterministic results. They are not evidence of a production remote-model path.
- **Extension boundary:** the Safari and Share targets are embedded components of the iOS app. A separate `apps/extension` product remains prohibited.

## Evidence boundary

Synchronized source, a clean external Chromium checkout, and iOS Simulator qualification are different evidence classes. None proves that the corresponding current source has passed every build, runtime, signing, installation, real-device, privacy, store, and release gate.

Historical Chromium test counts, manifests, and artifact hashes remain in dated audit records and must not be combined across patch heads or presented as current release evidence. Research evidence is also split: Phase 2 is a synthetic formal fixture, while Phase 3 is a 13-sample operator-blinded public pilot with recall `1/3`; neither result generalizes to broad malicious-JavaScript detection. For iOS, `SIMULATOR_QUALIFIED` is limited to the named Simulator chain; it is not real-device, distribution, or App Store evidence.

## Quick start

The JavaScript toolchain is pinned to Node.js `24.14.0` and pnpm `9.15.0`.

```bash
pnpm install --frozen-lockfile
pnpm run quality:fast
pnpm --filter @gcsa-aegis/browser status
```

Preparing and building Chromium requires a large external checkout. Read the [Browser guide](apps/browser/README.md) before running network, build, packaging, or runtime commands. For the native app, read the [iOS engineering guide](apps/ios/README.md); its safe default test entry point is:

```bash
bash apps/ios/scripts/run-simulator-tests.sh --dry-run
```

## Repository layout

```text
apps/browser       Chromium pin, overlays, patches, build and verification scripts
apps/ios           Native iOS app, embedded extensions, AgentKit, and Simulator tests
packages/core      Shared policies, detectors, generated assets, and Agent Contract v1
docs/              Architecture, roadmap, research map, product page, and audit records
```

## Documentation

- [Documentation index](docs/README.md)
- [Architecture](docs/architecture.md)
- [Roadmap and release gates](docs/roadmap.md)
- [iOS engineering guide](apps/ios/README.md)
- [Research-to-implementation map](docs/research-map.md)
- [Trilingual product page](docs/product.html)
- [Changelog](CHANGELOG.md)

## GitHub synchronization boundary

On 2026-08-28, authorization was granted to synchronize the source repository to `git@github.com:gcsagroup/aegis-browser.git` over SSH. That authorization covers source branch synchronization only. It does **not** authorize creating or publishing a Git tag, GitHub Release, binary, package, signing credential, notarization submission, Play upload, TestFlight build, App Store submission, or production deployment.

## License

Apache-2.0. See [LICENSE](LICENSE).

## Tests

```bash
pnpm run quality:fast
bash apps/ios/scripts/run-simulator-tests.sh --dry-run
```

These commands cover the repository's fast JavaScript/script gates and a non-mutating iOS Simulator preflight. Native Chromium builds, current-head browser runtime matrices, iOS `--execute` results, real-device checks, signing, packaging, installation, and store acceptance remain separate gates.
