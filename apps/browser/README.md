[**English**](./README.md) | [简体中文](./README.zh-CN.md) | [繁體中文](./README.zh-TW.md)

# GCSA-aegis Browser

GCSA-aegis Browser is a Chromium fork that integrates privacy and security controls in the browser and engine layers. It is not an Electron shell and does not treat an extension as the product.

Policy logic originates in `packages/core` and is integrated through generated rule snapshots, an embedded policy worker, Chromium browser services, and Blink/V8 hooks.

## Current status

- The combined source tree lists **67 top-level Chromium patches** plus **2 nested V8 patches**.
- The earlier 57-patch diagnostic manifest and 65-patch Agent acceptance remain historical snapshots. Neither binds or qualifies the combined 67-patch head.
- A fresh combined-source replay, identity-bound build, affected runtime acceptance, and release gates remain required. There is no current product-signed, notarized, packaged, installed, or published desktop release.
- Android has **not been built from the current source**. There is no current-source APK or AAB.

The repository therefore has no release-ready desktop or Android artifact.

## Pinned Chromium base

| File | Meaning |
|---|---|
| [CHROMIUM_VERSION](./CHROMIUM_VERSION) | Pinned Mac Stable version, currently `151.0.7922.77` |
| [CHROMIUM_COMMIT](./CHROMIUM_COMMIT) | Exact Chromium commit used as the patch base |

The pin is a fixed snapshot. It does not track newer Stable releases automatically.

## Documentation

- [Fork architecture](./docs/fork-architecture.md)
- [Android build and acceptance status](./docs/android.md)
- [Play Store readiness draft](./docs/play-store.md)

- [Overlay synchronization rules](./docs/overlay.md)
- [Chromium tree layout](./docs/tree-layout.md)
- [Patch maintenance notes](./patches/README.md)

For operational truth, use `patches/series`, `patches/v8/series`, and the scripts under `scripts/`. A historical status note is not a substitute for a fresh replay, build, or runtime check.

## Repository layout

```text
apps/browser/
  args/                 GN configurations
  overlay/              expected integration source
  patches/series        ordered Chromium patch list
  patches/v8/series     ordered nested V8 patch list
  scripts/              fetch, replay, build, run, verify, and package tools
  docs/                 public and development documentation
```

Chromium source is kept outside this repository. A typical local setup is:

```bash
export REPO_ROOT="$HOME/Projects/GCSA-aegis"
export CHROMIUM_ROOT="$HOME/Projects/GCSA-aegis-chromium"
```

The Chromium root may also be recorded in `apps/browser/.chromium-root`, which is ignored by Git.

## Local workflow

Run commands from the repository root. Bootstrap, fetch, sync, and dependency downloads use the network.

```bash
# Prepare depot_tools.
pnpm --filter @gcsa-aegis/browser bootstrap

# Fetch the pinned Chromium source. This requires tens of gigabytes.
pnpm --filter @gcsa-aegis/browser fetch

# Replay the ordered Chromium and nested V8 patch series.
pnpm --filter @gcsa-aegis/browser apply-patches

# Prepare the pinned libtorrent source used by local BT builds.
pnpm --filter @gcsa-aegis/browser bootstrap:libtorrent

# Build and run the component development app.
pnpm --filter @gcsa-aegis/browser build
pnpm --filter @gcsa-aegis/browser run

# Produce a non-component Release build-tree input.
pnpm --filter @gcsa-aegis/browser build:release
pnpm --filter @gcsa-aegis/browser run:release

# Inspect checkout, patch, overlay, and output state.
pnpm --filter @gcsa-aegis/browser status

# Run repository and browser-script gates.
pnpm run quality:fast
pnpm --filter @gcsa-aegis/browser test:scripts
```

The common output locations are:

- `$CHROMIUM_ROOT/src/out/AegisLocalDev`: component development output.
- `$CHROMIUM_ROOT/src/out/AegisRelease`: non-component Release build-tree input.
- `apps/browser/dist`: packaging output, only after identity and release gates pass.

Build success alone does not promote an output to RC or release status.

## Patch and overlay model

`overlay/` records the expected Aegis integration source. It is neither a standalone product nor the applied source of record. Changes must be exported into the ordered patch series and replayed on the exact pinned Chromium base.

The current source accounting is:

- 67 top-level patches listed for Chromium.
- 2 additional patches applied inside the nested V8 checkout.
- Historical identities cover earlier 57-patch and 65-patch snapshots only; neither covers patches 0066–0067.
- The combined 67-patch head requires a fresh exact replay and build identity before any current qualification claim.

“Present in the series” means only that a patch file is listed. It does not prove successful replay, build reproducibility, platform acceptance, signing, packaging, or publication.

## Product boundaries

The current desktop source includes:

- tracker, link, cookie, bounce, and phishing protections;
- Blink fingerprint farbling for selected Canvas, Audio, WebGL, and WebGPU surfaces;
- native HTTP(S), Metalink, Torrent, and Magnet download integration;
- local heuristic summaries and user-configured OpenAI-, Claude (Anthropic)-, or Gemini-compatible APIs;
- a browser-owned Agent with Observe/Ask/Act modes, scoped bookmark/URL/page/download/workflow/monitor tools, exact approvals, audit history, cancellation, and mandatory user takeover before final purchase;
- observe-only MinerGuard signals; and
- an opt-in, disabled-by-default V8 bytecode-shadow research path.

These boundaries matter:

- MinerGuard observes and reports; it does not stop scripts, workers, or network traffic.
- Fingerprint farbling reduces selected stable surfaces; it does not make a browser unidentifiable.
- Remote summary requests require user confirmation and browser-side redaction. HTTPS endpoints are allowed; plain HTTP is restricted to numeric loopback addresses.
- API keys are optional, stored through operating-system encryption for the current browser profile, and are not shown back in plaintext.
- Android page summaries are currently unavailable because the Android handler cannot obtain a normal web-page tab.

Downloads appear in Chromium's native `chrome://downloads` and `chrome://settings/downloads` surfaces. Video extraction, media conversion, FFmpeg, and a bundled download extension are outside the product scope.

## Release boundary

Before any desktop publication, the same candidate must have:

1. a clean replay from the pinned base;
2. a manifest that binds the repository commit, Chromium commit, both patch-series identities, GN arguments, and artifact hashes;
3. passing affected native, script, and runtime tests;
4. product identity, signing, notarization, and packaging;
5. fresh-install and upgrade acceptance on representative systems; and
6. an explicit release decision.

The current local diagnostic build-tree covers patches 0055/0056/0057, but does not satisfy this list. Full patch coverage does not make it an RC or release.
The local RC satisfies the clean replay, identity, and affected-test portions of this list. It does not satisfy product identity, trusted signing, notarization, installed-distribution, or release-authorization gates.

## Android

Android shares the pinned Chromium base, but the current source has not produced an accepted Android build. Android client builds require a supported x86-64 Linux environment; macOS and Windows are not supported Chromium Android build hosts.

See [Android build and acceptance status](./docs/android.md) and [Play Store readiness draft](./docs/play-store.md). The commands are future build entry points, not evidence that an APK exists:

```bash
pnpm --filter @gcsa-aegis/browser build:android
pnpm --filter @gcsa-aegis/browser package:android
```

## Network boundary

Local inspection, patch replay, and most repository tests can run without GitHub. Bootstrap, fetch, sync, EasyList updates, and missing Chromium dependencies may access external services. A running Chromium build may also generate network traffic independently of Git operations.

Always review the exact command and candidate identity before using network, signing, packaging, or publication credentials.
