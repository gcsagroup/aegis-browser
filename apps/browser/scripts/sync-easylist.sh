#!/usr/bin/env bash
# Fetch EasyList + EasyPrivacy and compile to JSON (not vendored in git).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
detect_and_export_proxy >/dev/null 2>&1 || true

OUT="${1:-$ROOT_DIR/overlay/third_party/aegis_policy/easylist_compiled.json}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

EASYLIST_URL="${EASYLIST_URL:-https://easylist.to/easylist/easylist.txt}"
EASYPRIVACY_URL="${EASYPRIVACY_URL:-https://easylist.to/easylist/easyprivacy.txt}"

echo "Fetching EasyList…"
curl -fsSL --retry 3 --retry-delay 2 "$EASYLIST_URL" -o "$WORKDIR/easylist.txt"
echo "Fetching EasyPrivacy…"
curl -fsSL --retry 3 --retry-delay 2 "$EASYPRIVACY_URL" -o "$WORKDIR/easyprivacy.txt"

node "$REPO_ROOT/packages/core/scripts/compile-easylist.mjs" \
  "$WORKDIR/easylist.txt" "$WORKDIR/easyprivacy.txt" "$OUT"

echo "Done. EasyList is GPL/CC — do not commit the compiled JSON."
