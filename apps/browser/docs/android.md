[**English**](./android.md) | [简体中文](./android.zh-CN.md) | [繁體中文](./android.zh-TW.md)

# Android status: No-Go

This document covers the Android browser target only. iOS and a WebView wrapper are outside the current product scope.

## Current evidence boundary

- Android uses formal Stable `155.0.8059.39`; desktop uses `155.0.8059.40`. Android keeps its independent `ci-pins/android.json` and `patches-android/` inputs.
- The reserved application ID is `app.gcsa.aegis`; reservation does not establish a valid package or Play identity.
- The 2026-10-09 source candidate is Ver 2.2 (144), versionCode `2002000144`, with 276 Chromium patches and 3 V8 patches. Full Chromium replay passed; its tree differs from the verified desktop source only in official `chrome/VERSION`. This preserves the shared Agent fixes and desktop-only gesture guards; it does not enable desktop gestures on Android. APK build, signing, package identity and physical-device acceptance remain pending.
- There is no current identity-bound APK or AAB. A historical file such as `$HOME/Desktop/GCSA-aegis.apk` cannot be mapped to the current source and is not an RC.
- v2 source resolves the public page behind the full-page Agent tab and binds current-page tasks to that document. Page capture, redaction, navigation invalidation, and results still require physical-device acceptance.
- v2 source places the process-wide remote-debugging latch in front of Android DevTools HTTP/socket startup, including deferred startup. Once an Incognito Profile trips the latch, pending and later starts are rejected for the rest of the process; physical-device validation remains open.

Android remains **No-Go** until a current-source build and device acceptance are complete.

## Supported build environment

Chromium Android clients cannot be built directly on macOS or Windows. This project requires a separate, supported **x86-64 Linux** checkout with:

- at least 200 GB of available disk space;
- enough memory for a Chromium build;
- the pinned Chromium base and exact patch inputs; and
- no reuse of the macOS checkout as an Android build tree.

Historical ARM64 Linux and QEMU experiments are not the current reproducible build gate.

## Future build entry point

The following commands fetch or synchronize network content. Run them only in an approved Linux environment and only after the exact source identity is fixed.

```bash
export PATH="$HOME/depot_tools:$PATH"

pnpm --filter @gcsa-aegis/browser fetch
bash apps/browser/scripts/enable-android-gclient.sh
pnpm --filter @gcsa-aegis/browser apply-patches
pnpm --filter @gcsa-aegis/browser sync
pnpm --filter @gcsa-aegis/browser build:android
pnpm --filter @gcsa-aegis/browser package:android
```

Expected candidate paths, which **do not currently exist as accepted outputs**, are:

- `$CHROMIUM_ROOT/src/out/AegisAndroid/apks/ChromePublic.apk`
- `apps/browser/dist/GCSA-aegis.apk`
- application ID: `app.gcsa.aegis`
- launcher name: `GCSA-aegis`

An AAB path and Play signing identity must be defined and verified before store work.

## Acceptance criteria

1. In a clean x86-64 Linux checkout, replay all 276 Chromium patches and 3 V8 patches from the independent Android pin, then verify the complete source tree and product version.
2. Build successfully and create a manifest that binds the repository commit, Chromium commit, both patch-series identities, GN arguments, and APK/AAB SHA-256.
3. Verify final package ID, version, launcher name, icons, permissions, native libraries, and signing structure.
4. 在专用实机保留旧版资料，以原包名和签名安装升级包，核对资料兼容、正常网页、`chrome://aegis`与核心保护。首次安装另用隔离设备验证，不通过卸载旧版规避升级兼容问题。
5. Verify page capture, document binding, redaction, confirmation, navigation invalidation, and result handling on device.
6. Run startup, background/foreground, crash, storage, update, and network acceptance without residual processes or unexplained outbound traffic, and verify that delayed DevTools startup cannot bypass the Incognito process latch.
7. Treat a passing internal candidate as separate from Play publication readiness.

## Play Store boundary

See [Play Store readiness](./play-store.md). The project currently has no production upload key, Play Console application, uploaded artifact, or approved Data Safety declaration.

## Deliberately out of scope

- iOS or a WebView shell
- CDP as an Android product feature
- a local model sidecar as an Android promise
- building Android in the existing macOS checkout

Related public documents: [Browser README](../README.md) and [fork architecture](./fork-architecture.md).
