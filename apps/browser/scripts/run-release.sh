#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

SRC="$CHROMIUM_ROOT/src"
OUT="${OUT_DIR:-$SRC/out/AegisRelease}"

if [[ ! -d "$OUT/Chromium.app" ]]; then
  echo "Missing $OUT/Chromium.app — run: pnpm --filter @gcsa-aegis/browser build:release"
  exit 1
fi

bash "$ROOT_DIR/scripts/sign-chromium-app.sh" "$OUT/Chromium.app" "$OUT"
open "$OUT/Chromium.app" --args "$@"
