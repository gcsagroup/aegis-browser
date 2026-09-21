[**English**](./README.md) | [简体中文](./README.zh-CN.md) | [繁體中文](./README.zh-TW.md)

# GCSA-aegis Browser

GCSA-aegis Browser is a Chromium fork that integrates privacy and security controls in the browser and engine layers. It is not an Electron shell and does not treat an extension as the product.

Policy logic originates in `packages/core` and is integrated through generated rule snapshots, an embedded policy worker, Chromium browser services, and Blink/V8 hooks.

The installed macOS candidate is Ver 2.0 (057), Chromium 153.0.8010.53, with 198 Chromium patches and 3 V8 patches. All 535 native checks passed. The unified task result is 75/90, with 2 failures, 9 prerequisite blocks and 4 insufficient-evidence results; the 90% gate is not met. The 100 security cases, input/performance measurements, language checks and release limitations have separate conclusions. See the [final batch record](../../docs/audit/integration-final-batch-2026-09-22.zh-CN.md).

## 历史基线（2026-09-16）

Ver 1.1 (044)的已验收基线为153.0.8010.37，包含140个Chromium补丁与3个V8补丁。完整重放树为`6f6294dfabbb9bfcf69a5a612bad3b2c41334ce5`。Ver 1.1 (044)在固定macOS测试App完成211项原生回归及版本、设置、摘要、Agent、原生下载、无痕和冷重启验收。

[044本地验收](../../docs/audit/m1-local-acceptance-044-2026-09-16.zh-CN.md)列明源码、清单、签名、恢复与限制；[9月10日记录](../../docs/audit/main-consolidation-2026-09-10.md)只保留为历史。当时完整90/100评测及M2/M3尚未完成；最新候选状态见上文。Android/Windows当前版本实机和公开发行仍未验收。

## Pinned Chromium base

| File | Meaning |
|---|---|
| [CHROMIUM_VERSION](./CHROMIUM_VERSION) | Pinned Mac Stable version, currently `153.0.8010.53` |
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
export CHROMIUM_ROOT="$HOME/Projects/GCSA-aegis-build/macos"
```

The Chromium root may also be recorded in `apps/browser/.chromium-root`, which is ignored by Git.

Keep platform workspaces under one sibling `GCSA-aegis-build` directory: `macos`, `android`, and `shared/chromium` for an existing shared checkout. The commands below describe initial setup; an existing linked Mac workspace without its own `.gclient` must not be fetched again. Select `shared/chromium` explicitly for shared dependency updates, and `android` for Android work. Preserve the fixed acceptance App path and historical evidence; moving source directories is not a rebuild or a new release.

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

- 152 top-level patches listed for Chromium, including the M2 candidate awaiting acceptance.
- 3 additional patches applied inside the nested V8 checkout.
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

044本地候选的140/3补丁重放、211项原生回归及关键实机验收已通过；这不替代完整任务/安全评测、跨平台实机、正式发行签名、公证和发布决定。

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
