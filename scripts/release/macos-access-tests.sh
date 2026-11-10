#!/usr/bin/env bash
# Access checks reused by macOS delivery. No notarization and no DMG required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

node --input-type=module -e '
import "./apps/browser/scripts/macos-access-phase1-evidence.mjs";
'
node --test \
  apps/browser/scripts/macos-access-phase1-evidence_test.mjs
node apps/browser/scripts/macos-access-phase1-evidence.mjs \
  --check docs/audit/evidence/macos-access-product-phase1
bash apps/browser/scripts/test-aegis-access-native.sh
echo "PASS: macOS delivery Access tests"
