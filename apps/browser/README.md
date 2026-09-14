[**English**](./README.md) | [简体中文](./README.zh-CN.md) | [繁體中文](./README.zh-TW.md)

# GCSA-aegis Browser

GCSA-aegis Browser is a Chromium fork that integrates privacy and security controls in the browser and engine layers. It is not an Electron shell and does not treat an extension as the product.

Policy logic originates in `packages/core` and is integrated through generated rule snapshots, an embedded policy worker, Chromium browser services, and Blink/V8 hooks.

## Current status

- The current source is on `main`. All 108 Chromium patches replay from the pinned base to tree `319366182c31108e29e62d2f2199aff29a0b86e8`; [the 2026-09-10 consolidation record](../../docs/audit/main-consolidation-2026-09-10.md) separates source verification from incomplete platform acceptance.

- The Browser Agent v2 candidate lists **108 top-level Chromium patches** plus **2 nested V8 patches**. Patches 0079–0095 replay to `c930fa41ef7e9522f145848f3080ee0cc1edc4d8`; patch 0096 replays to `f8dff6e3a5dd02527c093b57cde78fc4b0dcb34f`; patch 0097 produces `a3040bb0dea05e87c2a141b9a29a237a96953620`; patch 0098 produces `911f5c45acf3de10741008cf8f40948d57d31b7a`; patch 0099 produces `54f2d8dcf03ecf53b074b4919769ea652fdf5ab5` (tree `915676bbfbd340b8b8feb15aecacc70dfd53861b`); patch 0100 produces `44b79c59cf594b83af5c181842a57c2604d209ed` (tree `b8285fda53d21dff5ee56c39be1455ad3e5c3c82`); patch 0101 produces `1c63ce994b2815fe1f3dc07608ff121d987e0441` (tree `451b3148d12fc2cff2df293cb0f1bb0d6242a908`); and patch 0102 produces committed source `13807aaf086948bdff0370e356718d0c2ac54d27` (tree `4546f1afcabf38013ba9bef7e9e5d078ffd3ca77`).
- The 57-, 65-, 67-, 95-, and 97-patch records remain historical snapshots and do not qualify the 108-patch artifacts.
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
pnpm --filter @gcsa-aegis/browser run fetch

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

Use the shared [Windows UI acceptance script](./scripts/windows-agent-ui-acceptance.ps1), not independently maintained server copies.
First run its [script self-test](./scripts/windows-agent-ui-acceptance_test.ps1) with a Windows Node `-NodePath` and a new `-EvidenceDir`.
This validates process arguments and compiles the window helper; it does not establish UI acceptance. Actual interaction requires an unlocked desktop and must not automatically approve another application's firewall prompt.

The common output locations are:

- `$CHROMIUM_ROOT/src/out/AegisLocalDev`: component development output.
- `$CHROMIUM_ROOT/src/out/AegisRelease`: non-component Release build-tree input.
- `apps/browser/dist`: packaging output, only after identity and release gates pass.

Build success alone does not promote an output to RC or release status.

## Patch and overlay model

`overlay/` records the expected Aegis integration source. It is neither a standalone product nor the applied source of record. Changes must be exported into the ordered patch series and replayed on the exact pinned Chromium base.

The current source accounting is:

- 108 top-level patches listed for Chromium.
- 2 additional patches applied inside the nested V8 checkout.
- The 57-, 65-, 67-, 95-, and 97-patch identities are historical and do not cover the current v2 candidate.
- Patches 0079–0095 passed an exact isolated-index replay on the previously verified 78-patch tree; patch 0096 independently produced the exact 96-patch tree; patch 0097 produced the exact 97-patch tree; patch 0098 produced the exact 98-patch tree `7069e2b065466bbab3e3007e5866a3790e85ed47`; patch 0099 produced the exact 99-patch tree `915676bbfbd340b8b8feb15aecacc70dfd53861b`; patch 0100 produced the exact 100-patch tree `b8285fda53d21dff5ee56c39be1455ad3e5c3c82`; patch 0101 produced the exact 101-patch tree `451b3148d12fc2cff2df293cb0f1bb0d6242a908`; and patch 0102 produced the exact 102-patch tree `4546f1afcabf38013ba9bef7e9e5d078ffd3ca77`. Artifact identity and runtime qualification remain platform-specific.

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

All 108 Chromium patches and both V8 patches passed complete isolated-index replay from their pinned bases. The recent local macOS candidate has 527 native-test results; this source publication did not rebuild or release an App, APK, or Windows package. Final Qwen output, installed-platform acceptance, production signing, and notarization remain separate gates.

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

### Browser updates

About GCSA Aegis checks official GitHub Releases, downloads a matching installer and verifies it. Installation is manual. See [update behavior](../../docs/github-browser-updates.zh-CN.md) and [Ver 1.1 (018) local acceptance](../../docs/ui-copy-acceptance.zh-CN.md).
