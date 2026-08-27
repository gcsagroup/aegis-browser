#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

SRC="$CHROMIUM_ROOT/src"
OUT="${OUT_DIR:-$SRC/out/Aegis}"

if [[ -d "$OUT/Chromium.app" ]]; then
  # Component builds ship linker-signed bundles that Gatekeeper rejects until
  # ad-hoc re-signed. Cheap if already signed.
  bash "$ROOT_DIR/scripts/sign-chromium-app.sh" "$OUT/Chromium.app" "$OUT"
  open "$OUT/Chromium.app" --args "$@"
elif [[ -x "$OUT/chrome" ]]; then
  "$OUT/chrome" "$@"
elif [[ -x "$OUT/Chromium" ]]; then
  "$OUT/Chromium" "$@"
else
  echo "No built browser found at $OUT — run build first."
  exit 1
fi
