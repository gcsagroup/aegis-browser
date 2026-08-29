[**English**](./android.md) | [简体中文](./android.zh-CN.md) | [繁體中文](./android.zh-TW.md)

# Android status: No-Go

This document covers the Android browser target only. iOS and a WebView wrapper are outside the current product scope.

## Current evidence boundary

- Android uses the same pinned Chromium `151.0.7922.77` base as desktop.
- The reserved application ID is `app.gcsa.aegis`; reservation does not establish a valid package or Play identity.
- Current source contains 67 top-level Chromium patches and 2 nested V8 patches, but **no Android build has been produced from this current source**. Historical macOS evidence does not bind or qualify an Android artifact.
- There is no current identity-bound APK or AAB. A historical file such as `$HOME/Desktop/GCSA-aegis.apk` cannot be mapped to the current source and is not an RC.
- The Android WebUI handler cannot currently obtain a normal web-page tab. Page summary must therefore be shown as unavailable on Android.

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

1. Replay all 67 Chromium patches and 2 nested V8 patches from the pinned bases in a clean x86-64 Linux checkout.
2. Build successfully and create a manifest that binds the repository commit, Chromium commit, both patch-series identities, GN arguments, and APK/AAB SHA-256.
3. Verify final package ID, version, launcher name, icons, permissions, native libraries, and signing structure.
4. Uninstall any old build, install the current APK on a representative device, complete First Run, open normal pages and `chrome://aegis`, and exercise core protections.
5. Keep page summary explicitly unavailable until Android can capture and bind a real page document; after implementation, test collection, redaction, confirmation, navigation invalidation, and results on a device.
6. Run startup, background/foreground, crash, storage, update, and network acceptance without residual processes or unexplained outbound traffic.
7. Treat a passing internal candidate as separate from Play publication readiness.

## Play Store boundary

See [Play Store readiness](./play-store.md). The project currently has no production upload key, Play Console application, uploaded artifact, or approved Data Safety declaration.

## Deliberately out of scope

- iOS or a WebView shell
- CDP as an Android product feature
- a local model sidecar as an Android promise
- building Android in the existing macOS checkout

Related public documents: [Browser README](../README.md) and [fork architecture](./fork-architecture.md).
