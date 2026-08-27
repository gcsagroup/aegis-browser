# GCSA-aegis

**English** | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

GCSA-aegis is a local-first privacy and security browser built as a Chromium fork. Its privacy, anti-phishing, anti-tracking, download, and optional AI features are integrated into the browser rather than delivered as an Electron shell or a separate extension product.

> **Status — 2026-08-28:** the source integration is synchronized to 56 top-level Chromium patches plus 2 nested V8 patches. The latest identity-bound local build-tree manifest covers only 54 top-level patches plus the 2 V8 patches; patches 0055 and 0056 are not covered by that artifact evidence. The project remains **release No-Go**: there is no trusted build attestation, product-signed and notarized macOS package, installed-App acceptance, or current-source Android package.

## Product shape

- **Only product:** the Chromium fork under [`apps/browser`](apps/browser/README.md).
- **Policy source:** [`packages/core`](packages/core) provides testable policies, detectors, and generated browser assets.
- **Browser integration:** network, storage, fingerprint, phishing, download, WebUI, and local-automation controls live in Chromium integration points.
- **Privacy AI:** desktop builds support an on-device heuristic and user-configured OpenAI-, Claude (Anthropic)-, or Gemini-compatible APIs. Remote use requires an explicit destination and confirmation; this does not constitute a complete no-telemetry claim.

## Evidence boundary

The synchronized source and clean Chromium checkout prove that the patch stack can be reproduced. They do not prove that the current source has passed every build, runtime, signing, installation, Android, privacy, and release gate.

The most recent identity-bound build-tree evidence is local-only and marked `diagnostic-only`. Historical test counts and artifact hashes remain in dated audit records; they must not be combined across different patch heads or presented as current release evidence.

## Quick start

The JavaScript toolchain is pinned to Node.js `24.14.0` and pnpm `9.15.0`.

```bash
pnpm install --frozen-lockfile
pnpm run quality:fast
pnpm --filter @gcsa-aegis/browser status
```

Preparing and building Chromium requires a large external checkout. Read the [Browser guide](apps/browser/README.md) before running network, build, packaging, or runtime commands.

## Repository layout

```text
apps/browser       Chromium pin, overlays, patches, build and verification scripts
packages/core      Policies, detectors, generators, and research-only evaluation code
docs/              Architecture, roadmap, research map, product page, and audit records
```

## Documentation

- [Documentation index](docs/README.md)
- [Architecture](docs/architecture.md)
- [Roadmap and release gates](docs/roadmap.md)
- [Research-to-implementation map](docs/research-map.md)
- [Trilingual product page](docs/product.html)
- [Changelog](CHANGELOG.md)

## GitHub synchronization boundary

On 2026-08-28, authorization was granted to synchronize the source repository to `git@github.com:gcsagroup/aegis-browser.git` over SSH. That authorization covers source branch synchronization only. It does **not** authorize creating or publishing a Git tag, GitHub Release, binary, package, signing credential, notarization submission, Play upload, or production deployment.

## License

Apache-2.0. See [LICENSE](LICENSE).

## Tests

```bash
pnpm run quality:fast
```

This command covers the repository's fast JavaScript and script gates. Native Chromium builds, browser tests, runtime matrices, signing, installed-App checks, and Android device acceptance are separate gates.
