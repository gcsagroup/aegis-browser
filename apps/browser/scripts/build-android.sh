#!/usr/bin/env bash
# 在 Linux 上编 chrome_public_apk。macOS 会立刻退出并说明原因。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ensure_depot_tools_on_path

SRC="$CHROMIUM_ROOT/src"
OUT="${OUT_DIR:-$SRC/out/AegisAndroid}"
ARGS_FILE="$ROOT_DIR/args/aegis-android.gn"
OVERLAY="$ROOT_DIR/overlay"

need_gb="${AEGIS_ANDROID_MIN_FREE_GB:-80}"

fail_host() {
  cat <<EOF
无法在本机编 Android APK。

Chromium $VERSION_PIN 写明：Building the Android client on Windows or Mac is not supported.

这台 Mac 可以当工作机，编译要放到 Linux（本机 UTM Ubuntu ARM64，或另一台 Linux）。
磁盘建议至少空余 ${need_gb}GB（Android 依赖 + out/AegisAndroid）。

下一步见 apps/browser/docs/android.md
EOF
  exit 2
}

VERSION_PIN="$(read_pinned_value "$VERSION_FILE")"

if [[ "$(uname -s)" != "Linux" ]]; then
  fail_host
fi

# Chromium 151 主机 clang/rust 只有 Linux_x64。ARM64 上靠 qemu-user 跑它们。
# rustc 默认栈太小会 SIGSEGV。
if [[ "$(uname -m)" == "aarch64" ]]; then
  ulimit -s unlimited 2>/dev/null || ulimit -s 65536
fi

free_gb="$(df -Pk "$CHROMIUM_ROOT" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}')"
if [[ -n "$free_gb" && "$free_gb" -lt "$need_gb" ]]; then
  echo "磁盘只剩 ${free_gb}GB，Android 构建需要约 ${need_gb}GB。先腾空间。"
  exit 2
fi

if [[ ! -d "$SRC" ]]; then
  echo "Chromium src missing — 在 Linux 上先跑 fetch，并给 .gclient 加上 target_os = ['android']"
  exit 1
fi

if ! grep -q "android" "$CHROMIUM_ROOT/.gclient" 2>/dev/null; then
  echo ".gclient 没有 target_os android。先："
  echo "  bash $ROOT_DIR/scripts/enable-android-gclient.sh"
  echo "  pnpm --filter @gcsa-aegis/browser sync"
  exit 1
fi

rsync -a "$OVERLAY/third_party/blink/renderer/core/aegis/" "$SRC/third_party/blink/renderer/core/aegis/"
rsync -a "$OVERLAY/chrome/common/aegis/" "$SRC/chrome/common/aegis/"
rsync -a "$OVERLAY/chrome/browser/aegis/" "$SRC/chrome/browser/aegis/"
rsync -a "$OVERLAY/chrome/browser/ui/webui/aegis/" "$SRC/chrome/browser/ui/webui/aegis/"
rsync -a "$OVERLAY/chrome/browser/resources/aegis/" "$SRC/chrome/browser/resources/aegis/"
rsync -a "$OVERLAY/chrome/android/" "$SRC/chrome/android/"

cd "$SRC"
if [[ ! -f "$OUT/build.ninja" ]]; then
  echo "Generating $OUT with aegis-android.gn…"
  gn gen "$OUT" --args="$(cat "$ARGS_FILE")"
fi

echo "Building chrome_public_apk at $OUT…"
autoninja -C "$OUT" chrome_public_apk
echo "APK: $OUT/apks/ChromePublic.apk"
ls -lh "$OUT/apks/ChromePublic.apk"
