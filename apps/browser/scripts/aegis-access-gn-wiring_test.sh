#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROWSER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARGS_FILE="$BROWSER_DIR/args/aegis.gn"
BUILD_SCRIPT="$SCRIPT_DIR/build.sh"
COMPONENT_BUILD="$BROWSER_DIR/overlay/components/aegis_access/BUILD.gn"
PATCH_FILE="$BROWSER_DIR/patches/0114-feat-aegis-add-access-route-planning-contract.patch"
SERIES_FILE="$BROWSER_DIR/patches/series"
TARGET="//components/aegis_access:aegis_access_unittests"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ "$(rg -F -c "$TARGET" "$ARGS_FILE")" == 1 ]] ||
  fail "aegis.gn must add the access test exactly once"
args_block="$(awk '/^root_extra_deps = \[$/,/^\]$/' "$ARGS_FILE")"
[[ "$args_block" == *"$TARGET"* ]] ||
  fail "the access test must be reachable through root_extra_deps"

rg -Fq 'test("aegis_access_unittests")' "$COMPONENT_BUILD" ||
  fail "overlay does not define the independent access test"
rg -Fq '+test("aegis_access_unittests")' "$PATCH_FILE" ||
  fail "patch 0114 does not deliver the independent access test"
[[ "$(rg -F -c '0114-feat-aegis-add-access-route-planning-contract.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "patch 0114 must appear once in series"

# The developer build still requests only Chromium's production chrome target.
# root_extra_deps makes the test discoverable from test-only gn_all and does
# not create a dependency from chrome to the test executable.
rg -Fq 'autoninja -C "$OUT" chrome' "$BUILD_SCRIPT" ||
  fail "developer build no longer selects the production chrome target"
if rg -Fq "$TARGET" "$BROWSER_DIR/args/aegis-release.gn"; then
  fail "release GN args must not include the access test"
fi
if rg -Fq "$TARGET" "$BROWSER_DIR/overlay/chrome"; then
  fail "production Chrome overlay must not depend on the access test"
fi

printf 'PASS: aegis_access GN developer-graph wiring contract\n'
