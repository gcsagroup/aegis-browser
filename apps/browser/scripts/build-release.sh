#!/usr/bin/env bash
# Build a self-contained (non-component) Chromium.app for distribution.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ensure_depot_tools_on_path
detect_and_export_proxy >/dev/null 2>&1 || true

SRC="$CHROMIUM_ROOT/src"
OUT="${OUT_DIR:-$SRC/out/AegisRelease}"
ARGS_FILE="$ROOT_DIR/args/aegis-release.gn"

if [[ ! -d "$SRC" ]]; then
  echo "Chromium src missing — run fetch first."
  exit 1
fi

cd "$SRC"

echo "Generating $OUT with aegis-release.gn (is_component_build=false)…"
gn gen "$OUT" --args="$(cat "$ARGS_FILE")"

echo "Building chrome at $OUT (this can take a long time)…"
autoninja -C "$OUT" chrome
echo "Build complete: $OUT/Chromium.app"
du -sh "$OUT/Chromium.app"
