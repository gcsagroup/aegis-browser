#!/usr/bin/env bash
# Smoke-test Access against a local Reality Vision endpoint.
# Prefer a vless:// text file under .local/access-service/ (gitignored).
# Xray Core and sing-box client JSON are also accepted by the Python importer.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_NAME=AEGIS_ACCESS_LOCAL_V2RAY_CONFIG
PY="$ROOT/apps/browser/scripts/access_local_v2ray_config.py"
DEFAULT_LOCAL="$ROOT/.local/access-service/test-reality-vision.uri"

echo "== synthetic parser self-test (uri + xray + sing-box) =="
python3 "$PY" --self-test

if [[ -z "${!ENV_NAME:-}" && -f "$DEFAULT_LOCAL" ]]; then
  export AEGIS_ACCESS_LOCAL_V2RAY_CONFIG="$DEFAULT_LOCAL"
fi

if [[ -z "${!ENV_NAME:-}" ]]; then
  echo
  echo "Parser ready. For a live import:"
  echo "  mkdir -p .local/access-service"
  echo "  # paste vless://… into .local/access-service/test-reality-vision.uri"
  echo "  export $ENV_NAME=\"\$PWD/.local/access-service/test-reality-vision.uri\""
  echo "  $0"
  exit 0
fi

echo "== import local config (secrets redacted) =="
python3 "$PY" "${!ENV_NAME}"
echo "done"
