#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ensure_depot_tools_on_path || true

echo "GCSA-aegis Chromium fork status"
echo "  version:  $(read_pinned_value "$VERSION_FILE")"
echo "  commit:   $(read_pinned_value "$COMMIT_FILE")"
echo "  depot:    $DEPOT_TOOLS_DIR ($( [[ -d $DEPOT_TOOLS_DIR/.git ]] && echo ready || echo missing ))"
echo "  checkout: $CHROMIUM_ROOT"
if [[ -d "$CHROMIUM_ROOT/src/.git" ]]; then
  echo "  src HEAD: $(git -C "$CHROMIUM_ROOT/src" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "  src OK:   yes"
else
  echo "  src OK:   no (run pnpm --filter @gcsa-aegis/browser fetch)"
fi
if [[ -d "$CHROMIUM_ROOT/src/out/Aegis" ]]; then
  echo "  out/Aegis: present"
else
  echo "  out/Aegis: not built"
fi
if [[ -d "$CHROMIUM_ROOT/src/out/AegisAndroid" ]]; then
  echo "  out/AegisAndroid: present"
else
  echo "  out/AegisAndroid: not built (Linux only; see docs/android.md)"
fi
host="$(uname -s)"
echo "  host:     $host"
if [[ "$host" != "Linux" ]]; then
  echo "  android:  this OS cannot compile chrome_public_apk (Chromium 151)"
fi
