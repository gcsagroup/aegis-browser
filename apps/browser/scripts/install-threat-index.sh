#!/usr/bin/env bash
# Install an offline-compiled threat index into the integrated browser profile.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

while [[ "${1:-}" == -- ]]; do
  shift
done
INDEX="${1:-}"
USER_DATA_DIR="${2:-${AEGIS_USER_DATA_DIR:-$CHROMIUM_ROOT/profiles/AegisLocalDev}}"
PROFILE_DIRECTORY="${3:-Default}"
if [[ -n "$INDEX" && "$INDEX" != /* && -n "${INIT_CWD:-}" ]]; then
  INDEX="$INIT_CWD/$INDEX"
fi
if [[ "$USER_DATA_DIR" != /* && -n "${INIT_CWD:-}" ]]; then
  USER_DATA_DIR="$INIT_CWD/$USER_DATA_DIR"
fi
if [[ -z "$INDEX" || ! -f "$INDEX" || -L "$INDEX" ]]; then
  printf '请提供普通文件形式的 threat-index.bin。\n' >&2
  exit 1
fi
if [[ ! "$PROFILE_DIRECTORY" =~ ^[A-Za-z0-9._-]+$ ]] || \
   [[ "$PROFILE_DIRECTORY" == "." || "$PROFILE_DIRECTORY" == ".." ]]; then
  printf '浏览器 Profile 名称无效：%s\n' "$PROFILE_DIRECTORY" >&2
  exit 1
fi
if [[ "$(LC_ALL=C head -c 8 "$INDEX")" != "AEGISTI1" ]]; then
  printf '索引 magic 不匹配，拒绝安装：%s\n' "$INDEX" >&2
  exit 1
fi
if [[ ! -d "$USER_DATA_DIR" ]]; then
  mkdir -p "$USER_DATA_DIR"
fi
ensure_profile_not_in_use "$USER_DATA_DIR"

DEST_DIR="$USER_DATA_DIR/$PROFILE_DIRECTORY/AegisThreatFeeds"
DEST="$DEST_DIR/threat-index.bin"
mkdir -p "$DEST_DIR"
TEMP="$(mktemp "$DEST_DIR/.threat-index.XXXXXX")"
cleanup() {
  rm -f "$TEMP"
}
trap cleanup EXIT
install -m 600 "$INDEX" "$TEMP"
mv "$TEMP" "$DEST"
trap - EXIT
printf '已安装本地威胁索引：%s\n' "$DEST"
