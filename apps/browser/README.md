[**English**](./README.md) | [简体中文](./README.zh-CN.md) | [繁體中文](./README.zh-TW.md)

# GCSA-aegis Browser

GCSA-aegis Browser is a Chromium fork that integrates privacy and security controls in the browser and engine layers. It is not an Electron shell and does not treat an extension as the product.

Policy logic originates in `packages/core` and is integrated through generated rule snapshots, an embedded policy worker, Chromium browser services, and Blink/V8 hooks.

## Current status

- The Browser Agent v2 candidate lists **95 top-level Chromium patches** plus **2 nested V8 patches**. Patches 0079–0095 were replayed in an isolated Git index on top of commit `6627949a477277dfd916c275267d0bba886f376c`; the resulting tree exactly matches committed source `c930fa41ef7e9522f145848f3080ee0cc1edc4d8` (tree `33bcb50d8cdd08cfb918af071f3d128b874b15f9`).
- The 57-, 65-, and 67-patch records remain historical snapshots and do not qualify v2 artifacts.
- macOS native and browser tests have passed for the candidate source; exact platform manifests and final UI acceptance remain required. There is no product-signed, notarized, installed, or published desktop release.
- Android and Windows candidate builds are in validation; no APK, AAB, or Windows package is accepted until the device/host records are complete.

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

# Optional: verify a keyless local model's native Agent tool-call contract.
node apps/browser/scripts/verify-agent-local-model.mjs \
  --base-url http://127.0.0.1:8000/v1 --model MODEL --rounds 2
```

The local-model preflight stores neither full prompts nor raw responses. It
checks model discovery plus repeated route, plan, and execution calls; it does
not replace an end-to-end run in the actual browser.

The common output locations are:

- `$CHROMIUM_ROOT/src/out/AegisLocalDev`: component development output.
- `$CHROMIUM_ROOT/src/out/AegisRelease`: non-component Release build-tree input.
- `apps/browser/dist`: packaging output, only after identity and release gates pass.

Build success alone does not promote an output to RC or release status.

## Patch and overlay model

`overlay/` records the expected Aegis integration source. It is neither a standalone product nor the applied source of record. Changes must be exported into the ordered patch series and replayed on the exact pinned Chromium base.

The current source accounting is:

- 95 top-level patches listed for Chromium.
- 2 additional patches applied inside the nested V8 checkout.
- The 57-, 65-, and 67-patch identities are historical and do not cover the v2 candidate.
- Patches 0079–0095 passed an exact isolated-index replay on the previously verified 78-patch tree; artifact identity and runtime qualification remain platform-specific.

“Present in the series” means only that a patch file is listed. It does not prove successful replay, build reproducibility, platform acceptance, signing, packaging, or publication.

## Product boundaries

The current desktop source includes:

- tracker, link, cookie, bounce, and phishing protections;
- Blink fingerprint farbling for selected Canvas, Audio, WebGL, and WebGPU surfaces;
- native HTTP(S), Metalink, Torrent, and Magnet download integration;
- local heuristic summaries and user-configured OpenAI-, Claude (Anthropic)-, or Gemini-compatible APIs;
- Browser Agent v2 with model-first goal routing, visible planning, a browser-owned execute/observe/verify loop, common-task shortcuts, scheduled automation, scoped bookmark/URL/page/download tools, exact approvals, and mandatory user takeover before final purchase;
- observe-only MinerGuard signals; and
- an opt-in, disabled-by-default V8 bytecode-shadow research path.

These boundaries matter:

- MinerGuard observes and reports; it does not stop scripts, workers, or network traffic.
- Fingerprint farbling reduces selected stable surfaces; it does not make a browser unidentifiable.
- Remote summary requests require user confirmation and browser-side redaction. HTTPS endpoints are allowed; plain HTTP is restricted to numeric loopback addresses.
- API keys are optional, stored through operating-system encryption for the current browser profile, and are not shown back in plaintext.
- Android page capture and current-page binding exist in v2 source; their runtime qualification depends on the current APK's physical-device acceptance.

Downloads appear in Chromium's native `chrome://downloads` and `chrome://settings/downloads` surfaces. Video extraction, media conversion, FFmpeg, and a bundled download extension are outside the product scope.

## Release boundary

Before any desktop publication, the same candidate must have:

1. a clean replay from the pinned base;
2. a manifest that binds the repository commit, Chromium commit, both patch-series identities, GN arguments, and artifact hashes;
3. passing affected native, script, and runtime tests;
4. product identity, signing, notarization, and packaging;
5. fresh-install and upgrade acceptance on representative systems; and
6. an explicit release decision.

The 95-patch source and both nested V8 patches passed a fresh exact isolated-index replay from their pinned bases. The macOS candidate has passed the named native/browser test scope, but this does not satisfy cross-platform identity, trusted signing, notarization, installed-distribution, or release-authorization gates.

## Android

Android shares the pinned Chromium base and is built from a clean x86-64 Linux checkout. A build becomes accepted only after the exact APK identity and physical-device runtime record are complete; macOS and Windows are not supported Chromium Android build hosts.

See [Android build and acceptance status](./docs/android.md) and [Play Store readiness draft](./docs/play-store.md). These commands are build entry points, not acceptance evidence by themselves:

```bash
pnpm --filter @gcsa-aegis/browser build:android
pnpm --filter @gcsa-aegis/browser package:android
```

## Network boundary

Local inspection, patch replay, and most repository tests can run without GitHub. Bootstrap, fetch, sync, EasyList updates, and missing Chromium dependencies may access external services. A running Chromium build may also generate network traffic independently of Git operations.

Always review the exact command and candidate identity before using network, signing, packaging, or publication credentials.
