#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ensure_depot_tools_on_path

SRC="$CHROMIUM_ROOT/src"
OUT="${OUT_DIR:-$SRC/out/Aegis}"
ARGS_FILE="$ROOT_DIR/args/aegis.gn"

if [[ ! -d "$SRC" ]]; then
  echo "Chromium src missing — run fetch first."
  exit 1
fi

cd "$SRC"

if [[ ! -f "$OUT/build.ninja" ]]; then
  echo "Generating $OUT with aegis.gn args…"
  gn gen "$OUT" --args="$(cat "$ARGS_FILE")"
fi

echo "Building chrome at $OUT (long)…"
autoninja -C "$OUT" chrome
echo "Build complete: $OUT/Chromium.app or $OUT/chrome"
