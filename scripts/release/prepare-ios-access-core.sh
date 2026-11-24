#!/usr/bin/env bash
# Build into a separate output directory. The source lock remains read-only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOCK="${1:-$ROOT/apps/ios/EmbeddedCore/embedded-core-lock.json}"
PRODUCTS="${2:-${AEGIS_EMBEDDED_CORE_PRODUCTS:-$ROOT/.artifacts/ios-embedded-core}}"
XCODE_ROOT="${3:-$ROOT}"
XCODE_LOCK="$LOCK"
if [[ $# -ge 3 ]]; then
  XCODE_LOCK="$XCODE_ROOT/apps/ios/EmbeddedCore/embedded-core-lock.json"
fi
"$ROOT/scripts/release/build-ios-access-core.sh" --lock "$LOCK" --output "$PRODUCTS" \
  --record-for "$XCODE_ROOT" "$XCODE_LOCK"
python3 -B "$ROOT/scripts/release/ios_embedded_core.py" verify \
  --root "$XCODE_ROOT" --source-lock "$XCODE_LOCK" --products "$PRODUCTS"
