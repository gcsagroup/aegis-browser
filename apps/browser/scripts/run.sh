#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

SRC="$CHROMIUM_ROOT/src"
OUT="${OUT_DIR:-$SRC/out/AegisLocalDev}"
PROFILE="${AEGIS_USER_DATA_DIR:-$CHROMIUM_ROOT/profiles/AegisLocalDev}"
ARGS_FILE="$ROOT_DIR/args/aegis.gn"
if [[ "${1:-}" == -- ]]; then
  shift
fi
PROFILE="$(resolve_user_data_dir_arg "$PROFILE" "$@")" || {
  printf -- '--user-data-dir 缺少有效路径。\n' >&2
  exit 1
}
ensure_profile_not_in_use "$PROFILE"
binary="$(verify_runnable_browser_output \
  "开发桌面产物" "$OUT" true "$ARGS_FILE")"
run_args=("$@")
if ! has_user_data_dir_arg "$@"; then
  run_args=("--user-data-dir=$PROFILE" "${run_args[@]}")
fi

case "${AEGIS_RUN_DRY_RUN:-0}" in
  0) ;;
  1)
    printf '已验证开发版：%s\n独立 Profile：%s\n启动参数：' "$binary" "$PROFILE"
    printf '%q ' "${run_args[@]}"
    printf '\n'
    exit 0
    ;;
  *)
    printf 'AEGIS_RUN_DRY_RUN 仅接受 0 或 1。\n' >&2
    exit 1
    ;;
esac

if [[ -d "$OUT/Chromium.app" ]]; then
  # Component builds ship linker-signed bundles that Gatekeeper rejects until
  # ad-hoc re-signed. Cheap if already signed.
  bash "$ROOT_DIR/scripts/sign-chromium-app.sh" "$OUT/Chromium.app" "$OUT"
  printf '启动已验证开发版：%s\n独立 Profile：%s\n' "$binary" "$PROFILE"
  open -n "$OUT/Chromium.app" --args "${run_args[@]}"
else
  printf '启动已验证开发版：%s\n独立 Profile：%s\n' "$binary" "$PROFILE"
  "$binary" "${run_args[@]}"
fi
