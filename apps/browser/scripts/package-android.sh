#!/usr/bin/env bash
# 把 ChromePublic.apk 拷成可侧载的 GCSA-aegis.apk（包名 app.gcsa.aegis）。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

SRC="$CHROMIUM_ROOT/src"
OUT="${OUT_DIR:-$SRC/out/AegisAndroid}"
VERSION="$(read_pinned_value "$VERSION_FILE" 2>/dev/null || echo "0.0.0")"
APP_VERSION="${AEGIS_PACKAGE_VERSION:-0.1.0}"
DIST_ROOT="${DIST_DIR:-$ROOT_DIR/dist}"

safe_path_component() {
  local value="$1"
  [[ "$value" =~ ^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ ]] && \
    [[ "$value" != *..* ]]
}
if ! safe_path_component "$VERSION" || ! safe_path_component "$APP_VERSION"; then
  echo "Unsafe Android package version path component." >&2
  exit 1
fi
if [[ ! -d "$SRC" || -L "$SRC" ]]; then
  echo "Chromium source must be a real directory: $SRC" >&2
  exit 1
fi
SRC="$(cd "$SRC" && pwd -P)"
if [[ ! -d "$OUT" || -L "$OUT" ]]; then
  echo "Android package OUT_DIR must be an existing real directory: $OUT" >&2
  exit 1
fi
OUT="$(cd "$OUT" && pwd -P)"
case "$OUT" in
  "$SRC"/out/*) ;;
  *)
    echo "Android package OUT_DIR must be a strict child of $SRC/out" >&2
    exit 1
    ;;
esac

APK_DIR="$OUT/apks"
APK_SRC="$APK_DIR/ChromePublic.apk"
if [[ ! -d "$APK_DIR" || -L "$APK_DIR" ]] || \
   [[ "$(cd "$APK_DIR" 2>/dev/null && pwd -P)" != "$APK_DIR" ]]; then
  echo "Android APK directory must be a real child of OUT: $APK_DIR" >&2
  exit 1
fi
if [[ ! -f "$APK_SRC" || -L "$APK_SRC" ]]; then
  echo "Missing real APK: $APK_SRC" >&2
  echo "在 Linux 上先：pnpm --filter @gcsa-aegis/browser build:android" >&2
  exit 1
fi

# 在任何 dist 写入前规范化目标，并拒绝指回源码或构建目录的路径。
if [[ -L "$DIST_ROOT" ]]; then
  echo "DIST_DIR must not be a symlink: $DIST_ROOT" >&2
  exit 1
fi
dist_parent="$(dirname "$DIST_ROOT")"
dist_leaf="$(basename "$DIST_ROOT")"
if [[ ! -d "$dist_parent" || -L "$dist_parent" || \
      "$dist_leaf" == "." || "$dist_leaf" == ".." || "$dist_leaf" == "/" ]]; then
  echo "DIST_DIR must have an existing real parent and a safe leaf: $DIST_ROOT" >&2
  exit 1
fi
dist_parent="$(cd "$dist_parent" && pwd -P)"
DIST_ROOT="$dist_parent/$dist_leaf"
if [[ -e "$DIST_ROOT" && ! -d "$DIST_ROOT" ]]; then
  echo "DIST_DIR must be a directory: $DIST_ROOT" >&2
  exit 1
fi
if [[ -d "$DIST_ROOT" ]] && \
   [[ "$(cd "$DIST_ROOT" && pwd -P)" != "$DIST_ROOT" ]]; then
  echo "DIST_DIR resolved unexpectedly: $DIST_ROOT" >&2
  exit 1
fi
paths_overlap() {
  local first="$1"
  local second="$2"
  [[ "$first" == "$second" || "$first" == "$second/"* || \
     "$second" == "$first/"* ]]
}
for protected_path in "$SRC" "$OUT" "$APK_DIR" "$APK_SRC"; do
  if paths_overlap "$DIST_ROOT" "$protected_path"; then
    echo "DIST_DIR must not overlap Chromium source or Android build output: $DIST_ROOT" >&2
    exit 1
  fi
done

APK_NAME="GCSA-aegis-${APP_VERSION}-chromium-${VERSION}-android-arm64.apk"
ALIAS_NAME="GCSA-aegis.apk"
IDENTITY_NAME="GCSA-aegis-${APP_VERSION}-chromium-${VERSION}-android-arm64.build-identity.json"
APK_DST="$DIST_ROOT/$APK_NAME"
APK_ALIAS="$DIST_ROOT/$ALIAS_NAME"
IDENTITY="$DIST_ROOT/$IDENTITY_NAME"
FINAL_OUTPUTS=("$APK_DST" "$APK_ALIAS" "$IDENTITY" "$IDENTITY.sha256")
for output in "${FINAL_OUTPUTS[@]}"; do
  if [[ -e "$output" || -L "$output" ]]; then
    echo "Refusing existing Android package output: $output" >&2
    exit 1
  fi
done

# 先在同一文件系统的私有暂存目录生成产物快照。身份校验失败时，
# dist 和现有文件保持不变；校验通过后再用不覆盖的硬链接发布。
PACKAGE_LOCK="$dist_parent/.aegis-android-package.lock"
if [[ -e "$PACKAGE_LOCK" || -L "$PACKAGE_LOCK" ]] || \
   ! mkdir "$PACKAGE_LOCK" 2>/dev/null; then
  echo "Another Android package operation holds: $PACKAGE_LOCK" >&2
  exit 1
fi
PACKAGE_TMP=""
CREATED_DIST=0
PUBLISHED_SOURCES=()
PUBLISHED_TARGETS=()
cleanup() {
  local rc=$?
  local index
  trap - EXIT
  if [[ "$rc" -ne 0 ]]; then
    for ((index = 0; index < ${#PUBLISHED_TARGETS[@]}; index += 1)); do
      if [[ -e "${PUBLISHED_TARGETS[$index]}" ]] && \
         [[ "${PUBLISHED_SOURCES[$index]}" -ef "${PUBLISHED_TARGETS[$index]}" ]]; then
        rm -f "${PUBLISHED_TARGETS[$index]}"
      fi
    done
    if [[ "$CREATED_DIST" -eq 1 ]]; then
      rmdir "$DIST_ROOT" 2>/dev/null || true
    fi
  fi
  if [[ -n "$PACKAGE_TMP" && -d "$PACKAGE_TMP" && ! -L "$PACKAGE_TMP" ]]; then
    rm -rf "$PACKAGE_TMP"
  fi
  rmdir "$PACKAGE_LOCK" 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT

PACKAGE_TMP="$(mktemp -d "$dist_parent/.aegis-android-package.XXXXXX")"
STAGED_ROOT="$PACKAGE_TMP/$dist_leaf"
mkdir "$STAGED_ROOT"
STAGED_APK="$STAGED_ROOT/$APK_NAME"
STAGED_ALIAS="$STAGED_ROOT/$ALIAS_NAME"
STAGED_IDENTITY="$STAGED_ROOT/$IDENTITY_NAME"
cp -p "$APK_SRC" "$STAGED_APK"
cp -p "$APK_SRC" "$STAGED_ALIAS"

identity_args=(
  --phase snapshot
  --output "$STAGED_IDENTITY"
  --out-dir "$OUT"
  --artifact-root "$STAGED_ROOT"
  --artifact "$STAGED_APK"
  --artifact "$STAGED_ALIAS"
)
if [[ "${AEGIS_ALLOW_DIRTY_IDENTITY:-0}" == "1" ]]; then
  identity_args+=(--allow-dirty)
fi
node "$ROOT_DIR/scripts/write-build-identity.mjs" "${identity_args[@]}"

STAGED_OUTPUTS=(
  "$STAGED_APK"
  "$STAGED_ALIAS"
  "$STAGED_IDENTITY"
  "$STAGED_IDENTITY.sha256"
)
for output in "${STAGED_OUTPUTS[@]}"; do
  if [[ ! -f "$output" || -L "$output" ]]; then
    echo "Android package staging output is missing or unsafe: $output" >&2
    exit 1
  fi
done

if [[ ! -d "$DIST_ROOT" ]]; then
  mkdir "$DIST_ROOT"
  CREATED_DIST=1
fi
if [[ -L "$DIST_ROOT" || "$(cd "$DIST_ROOT" && pwd -P)" != "$DIST_ROOT" ]]; then
  echo "DIST_DIR resolved unexpectedly before publish: $DIST_ROOT" >&2
  exit 1
fi
for output in "${FINAL_OUTPUTS[@]}"; do
  if [[ -e "$output" || -L "$output" ]]; then
    echo "Refusing raced Android package output: $output" >&2
    exit 1
  fi
done

publish_file() {
  local source="$1"
  local target="$2"
  if ! ln "$source" "$target"; then
    echo "Failed to publish Android package output without overwrite: $target" >&2
    return 1
  fi
  PUBLISHED_SOURCES+=("$source")
  PUBLISHED_TARGETS+=("$target")
}
for ((index = 0; index < ${#FINAL_OUTPUTS[@]}; index += 1)); do
  publish_file "${STAGED_OUTPUTS[$index]}" "${FINAL_OUTPUTS[$index]}"
done

ls -lh "$APK_DST" "$APK_ALIAS" "$IDENTITY" "$IDENTITY.sha256"
echo "侧载：adb install -r $APK_ALIAS"
echo "包名：app.gcsa.aegis（Play 预留，见 apps/browser/docs/play-store.md）"
