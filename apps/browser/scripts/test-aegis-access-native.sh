#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROWSER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPONENT_DIR="$BROWSER_DIR/overlay/components/aegis_access"
VECTOR_FILE="$COMPONENT_DIR/testdata/route_planner_vectors.json"
POLICY_VECTOR_FILE="$COMPONENT_DIR/testdata/policy_matcher_vectors.json"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aegis-access-native.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

if ! command -v python3 >/dev/null 2>&1; then
  printf 'FAIL: python3 is required to generate aegis_access vectors\n' >&2
  exit 1
fi

CXX_COMMAND="${CXX:-clang++}"
if [[ "$CXX_COMMAND" == */* ]]; then
  CXX_BIN="$CXX_COMMAND"
else
  CXX_BIN="$(command -v "$CXX_COMMAND" || true)"
fi
if [[ -z "$CXX_BIN" || ! -x "$CXX_BIN" ]]; then
  printf 'FAIL: clang++ is required for the aegis_access native unit\n' >&2
  exit 1
fi

python3 "$COMPONENT_DIR/generate_route_planner_vectors.py" \
  "$VECTOR_FILE" "$TEST_ROOT/route_planner_golden_vectors.inc"
python3 "$COMPONENT_DIR/generate_policy_matcher_vectors.py" \
  "$POLICY_VECTOR_FILE" "$TEST_ROOT/policy_matcher_golden_vectors.inc"
if [[ "$(rg -c '^vectors.push_back' \
  "$TEST_ROOT/policy_matcher_golden_vectors.inc")" != 14 ]]; then
  printf 'FAIL: expected 14 shared policy matcher vectors\n' >&2
  exit 1
fi

"$CXX_BIN" \
  -std=c++20 \
  -Wall -Wextra -Werror -pedantic \
  -I"$TEST_ROOT" \
  -I"$BROWSER_DIR/overlay" \
  "$COMPONENT_DIR/access_route_planner.cc" \
  "$COMPONENT_DIR/site_proxy_rule_group.cc" \
  "$COMPONENT_DIR/access_route_planner_native_test.cc" \
  -o "$TEST_ROOT/aegis_access_native_test"

"$TEST_ROOT/aegis_access_native_test"
