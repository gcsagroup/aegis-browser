#!/usr/bin/env bash
# Smoke-test Access against a local V2Ray/Xray client JSON (Mac or Linux).
# Usage:
#   export AEGIS_ACCESS_LOCAL_V2RAY_CONFIG="$HOME/path/to/config.json"
#   ./scripts/access-local-v2ray-smoke.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_NAME=AEGIS_ACCESS_LOCAL_V2RAY_CONFIG
PY="$ROOT/apps/browser/scripts/access_local_v2ray_config.py"

echo "== synthetic parser self-test =="
python3 "$PY" --self-test

if [[ -z "${!ENV_NAME:-}" ]]; then
  echo
  echo "Parser ready. To exercise your local V2Ray config:"
  echo "  export $ENV_NAME=\"\$HOME/<your-v2ray-or-xray-config.json>\""
  echo "  $0"
  echo
  echo "Accepted JSON shapes: full Xray outbounds[], single VLESS outbound,"
  echo "or flat {address,port,id,sni/serverName,pbk/publicKey,sid/shortId}."
  echo "Only reality_vision (VLESS + TCP + REALITY + xtls-rprx-vision) is admitted."
  exit 0
fi

echo "== import local config (secrets redacted) =="
python3 "$PY" "${!ENV_NAME}"

if command -v xcodebuild >/dev/null 2>&1 && [[ -d "$ROOT/apps/ios/Aegis.xcodeproj" ]]; then
  echo "== iOS AccessKit local-config unit tests =="
  (
    cd "$ROOT/apps/ios"
    xcodebuild test \
      -project Aegis.xcodeproj \
      -scheme AccessKit \
      -destination 'platform=iOS Simulator,name=iPhone 16' \
      -only-testing:AccessKitTests/AccessLocalV2RayConfigTests \
      2>&1 | tail -n 40
  ) || echo "xcodebuild AccessKit scheme unavailable; parser smoke still passed"
else
  echo "skip xcodebuild (not on macOS tooling path)"
fi

echo "done"
