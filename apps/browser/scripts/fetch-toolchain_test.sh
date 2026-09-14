#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/aegis-fetch-toolchain-test.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local expected="$2"
  local label="$3"
  if ! grep -Fqx "$expected" "$file"; then
    fail "$label"
  fi
}

export CHROMIUM_ROOT="$fixture_root/chromium"
export AEGIS_WHEELHOUSE="$fixture_root/wheelhouse"
export AEGIS_FIX_VPYTHON_SOURCE_ONLY=1
# shellcheck disable=SC1091
source "$SCRIPT_DIR/fix-vpython-network.sh"

project_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"
browser_fetch_command="$(python3 - "$project_root/package.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as package_file:
    print(json.load(package_file)["scripts"]["browser:fetch"])
PY
)"
if [[ "$browser_fetch_command" != \
      'pnpm --filter @gcsa-aegis/browser run fetch' ]]; then
  fail 'root browser:fetch must invoke the package script with explicit run'
fi

store_root="$fixture_root/vpython-store"
wheels_req="$store_root/wheels+fixture/contents/requirements.txt"
vpython_req="$store_root/vpython_requirements+fixture/contents/requirements.txt"
mkdir -p "$(dirname "$wheels_req")" "$(dirname "$vpython_req")"
printf 'pyyaml==5.4.1+chromium.1\n' > "$wheels_req"
printf '%s\n' \
  'crcmod==1.7+chromium.4' \
  'aioquic==1.2.0+chromium.1' \
  'aioquic==1.2.0+chromium.2' \
  'unverified-package==2.0+chromium.9' \
  > "$vpython_req"
# shellcheck disable=SC2034  # Consumed by the sourced scan_cached_requirements.
VPYTHON_STORE_ROOTS=("$store_root")

scan_cached_requirements >/dev/null
assert_file_contains "$wheels_req" 'pyyaml==6.0.2' \
  'wheels+ requirements cache was not patched'
assert_file_contains "$vpython_req" 'crcmod==1.7' \
  'vpython_requirements+ cache was not patched'
assert_file_contains "$vpython_req" 'aioquic==1.2.0' \
  'verified aioquic Chromium pin was not mapped to its public wheel'
assert_file_contains "$vpython_req" 'aioquic==1.2.0+chromium.2' \
  'unverified aioquic Chromium revision must remain unchanged'
assert_file_contains "$vpython_req" 'unverified-package==2.0+chromium.9' \
  'unverified Chromium local-version pin must remain unchanged'

if python3 - "$SCRIPT_DIR/fetch-chromium.sh" "$SCRIPT_DIR/status.sh" <<'PY'
from pathlib import Path
import re
import sys

unsafe = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]")
matches = []
for name in sys.argv[1:]:
    for line_number, line in enumerate(Path(name).read_text().splitlines(), 1):
        if unsafe.search(line):
            matches.append(f"{name}:{line_number}:{line}")
if matches:
    print("\n".join(matches))
    raise SystemExit(1)
PY
then
  :
else
  fail 'shell variables next to Chinese punctuation must use braces'
fi

PYTHONDONTWRITEBYTECODE=1 python3 "$SCRIPT_DIR/local-pypi-proxy_test.py"
printf 'PASS: Chromium fetch toolchain fixtures\n'
