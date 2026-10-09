[**English**](./README.md) | [简体中文](./README.zh-CN.md) | [繁體中文](./README.zh-TW.md)

# GCSA-aegis Browser

[![C++ Unit Tests](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml/badge.svg?branch=main)](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml)

GCSA-aegis Browser integrates privacy and security controls into Chromium and its engine.

Policy logic originates in `packages/core` and is integrated through generated rule snapshots, an embedded policy worker, Chromium browser services, and Blink/V8 hooks.

> **2026-10-09 · Chromium 155 与 Quinn 改动整合：** 本次源码更新统一纳入原生鼠标手势、Quinn 的 W2 双节点租约/双 relay 与 SM-00 离线预检、Agent 修复及 iOS 下载恢复修复。Mac 候选为 Ver 2.2 (144)，桌面基线 `155.0.8059.40`；整合范围、验收和保留边界见[整合记录](../../docs/audit/main-quinn-integration-2026-10-09.zh-CN.md)，合入路径为 [#32](https://github.com/gcsagroup/aegis-browser/pull/32)。网络计量仍是本地原型，正式跨平台发行尚未完成。

> **Historical evidence (2026-09-22):** The macOS Ver 2.0 (061) results, including 539 native regressions, belong only to the candidate identified in the [audit record](../../docs/audit/p1-p2-followup-2026-09-22.zh-CN.md). They do not establish acceptance of the current source.

macOS is the current focus; runtime, real-network and distribution validation remain open. Other platforms follow the [roadmap](../../docs/roadmap.md).

The [2026-09-10 audit](../../docs/audit/main-consolidation-2026-09-10.md) records historical replay and test results, not qualification of the current source.

## Pinned Chromium base

| File | Meaning |
|---|---|
| [CHROMIUM_VERSION](./CHROMIUM_VERSION) | 本分支桌面基线 `155.0.8059.40`，尚未正式发布 |
| [CHROMIUM_COMMIT](./CHROMIUM_COMMIT) | Exact Chromium commit used as the patch base |

The pin is a fixed snapshot. It does not track newer Stable releases automatically.

## Documentation

- [Fork architecture](./docs/fork-architecture.md)
- [Android build and acceptance status](./docs/android.md)
- [Play Store readiness draft](./docs/play-store.md)

- [Overlay synchronization rules](./docs/overlay.md)
- [Chromium tree layout](./docs/tree-layout.md)
- [Patch maintenance notes](./patches/README.md)

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

Complete the [workspace setup](../../README.md#getting-started) first. Run commands from the repository root with the mise toolchain active (`mise exec -- <command>` if needed). Bootstrap, fetch, sync and dependency downloads use the network.

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
pnpm run browser:run

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

`overlay/` holds the expected integration source. Export changes into the ordered [Chromium](./patches/series) and [V8](./patches/v8/series) patch lists, then replay them on the pinned bases. Those lists define the current inventory; historical counts and tree hashes belong in [audit records](../../docs/audit/README.md).

A listed patch is not proof of successful replay, build or runtime validation.

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
