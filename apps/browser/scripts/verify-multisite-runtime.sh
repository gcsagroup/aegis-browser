#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

SRC="$CHROMIUM_ROOT/src"
OUT="${OUT_DIR:-$SRC/out/AegisRelease}"
ARGS_FILE="$ROOT_DIR/args/aegis-release.gn"

for arg in "$@"; do
  if [[ "$arg" == --chromium || "$arg" == --chromium=* ]]; then
    printf '正式多站点门不接受 --chromium；请用 OUT_DIR 选择受校验的 Release 输出。\n' >&2
    exit 1
  fi
done

binary="$(verify_runnable_browser_output \
  "Release 桌面产物" "$OUT" false "$ARGS_FILE")"

if [[ "$(uname -s)" == Darwin ]] && \
   ! codesign --verify --deep --strict "$OUT/Chromium.app" >/dev/null 2>&1; then
  printf 'Release App 未通过本地严格签名结构校验；请先运行 browser sign。\n' >&2
  exit 1
fi

cd "$REPO_ROOT"
exec node "$SCRIPT_DIR/verify-multisite-runtime.mjs" \
  --chromium "$binary" "$@"
