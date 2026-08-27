#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ensure_depot_tools_on_path

SRC="$CHROMIUM_ROOT/src"
SERIES="$ROOT_DIR/patches/series"

if [[ ! -d "$SRC/.git" ]]; then
  echo "Chromium src missing at $SRC — run fetch first."
  exit 1
fi

if [[ ! -s "$SERIES" ]] || ! grep -vqE '^\s*(#|$)' "$SERIES"; then
  echo "No patches listed in patches/series yet — nothing to apply."
  echo "Checkout OK at $SRC"
  exit 0
fi

cd "$SRC"
while IFS= read -r line; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue
  patch_file="$ROOT_DIR/patches/$line"
  if [[ ! -f "$patch_file" ]]; then
    echo "Missing patch: $patch_file"
    exit 1
  fi
  echo "Applying $line"
  git apply --index "$patch_file" || git am --3way "$patch_file"
done < "$SERIES"

echo "Patches applied."
