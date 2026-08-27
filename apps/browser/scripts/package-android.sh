#!/usr/bin/env bash
# 把 ChromePublic.apk 拷成可侧载的 GCSA-aegis.apk（包名 app.gcsa.aegis）。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

SRC="$CHROMIUM_ROOT/src"
OUT="${OUT_DIR:-$SRC/out/AegisAndroid}"
VERSION="$(read_pinned_value "$VERSION_FILE" 2>/dev/null || echo "0.0.0")"
APP_VERSION="${AEGIS_PACKAGE_VERSION:-0.1.0}"
DIST_ROOT="${DIST_DIR:-$ROOT_DIR/dist}"
APK_SRC="$OUT/apks/ChromePublic.apk"
APK_DST="$DIST_ROOT/GCSA-aegis-${APP_VERSION}-chromium-${VERSION}-android-arm64.apk"

if [[ ! -f "$APK_SRC" ]]; then
  echo "Missing $APK_SRC"
  echo "在 Linux 上先：pnpm --filter @gcsa-aegis/browser build:android"
  exit 1
fi

mkdir -p "$DIST_ROOT"
cp -p "$APK_SRC" "$APK_DST"
cp -p "$APK_SRC" "$DIST_ROOT/GCSA-aegis.apk"
ls -lh "$APK_DST" "$DIST_ROOT/GCSA-aegis.apk"

echo "侧载：adb install -r $DIST_ROOT/GCSA-aegis.apk"
echo "包名：app.gcsa.aegis（Play 预留，见 apps/browser/docs/play-store.md）"
