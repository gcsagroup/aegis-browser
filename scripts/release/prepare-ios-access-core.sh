#!/usr/bin/env bash
# Build into a separate output directory. The source lock remains read-only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOCK="${1:-$ROOT/apps/ios/EmbeddedCore/embedded-core-lock.json}"
PRODUCTS="${2:-${AEGIS_EMBEDDED_CORE_PRODUCTS:-$ROOT/.artifacts/ios-embedded-core}}"
"$ROOT/scripts/release/build-ios-access-core.sh" --lock "$LOCK" --output "$PRODUCTS"
python3 -B "$ROOT/scripts/release/ios_embedded_core.py" record \
  --root "$ROOT" --source-lock "$LOCK" --products "$PRODUCTS" \
  --mode "${AEGIS_EMBEDDED_CORE_DIGEST_MODE:-strict}"
python3 -B "$ROOT/scripts/release/ios_embedded_core.py" verify \
  --root "$ROOT" --source-lock "$LOCK" --products "$PRODUCTS"
