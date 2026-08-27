#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ -d "$DEPOT_TOOLS_DIR/.git" ]]; then
  echo "depot_tools already present at $DEPOT_TOOLS_DIR"
  git -C "$DEPOT_TOOLS_DIR" pull --ff-only || true
else
  echo "Cloning depot_tools → $DEPOT_TOOLS_DIR"
  git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS_DIR"
fi

ensure_depot_tools_on_path

# macOS tip: ensure Xcode CLT
if [[ "$(uname -s)" == "Darwin" ]]; then
  xcode-select -p >/dev/null 2>&1 || {
    echo "Installing Xcode Command Line Tools (GUI prompt may appear)…"
    xcode-select --install || true
  }
fi

echo "depot_tools ready."
echo "Add to your shell profile if needed:"
echo "  export PATH=\"$DEPOT_TOOLS_DIR:\$PATH\""
echo "  export DEPOT_TOOLS_UPDATE=0   # optional: skip self-update on each invoke"
command -v gclient >/dev/null
command -v fetch >/dev/null
# Avoid blocking on first-run CIPD self-update here; fetch/build will bootstrap as needed.
ls "$DEPOT_TOOLS_DIR/gclient" "$DEPOT_TOOLS_DIR/fetch" >/dev/null
echo "OK: gclient/fetch present"
