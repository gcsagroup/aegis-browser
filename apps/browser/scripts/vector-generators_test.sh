#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPONENT_DIR="$(cd "$SCRIPT_DIR/../overlay/components/aegis_access" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aegis-vector-generators.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

run_python() {
  if [[ -n "${AEGIS_PYTHON_COVERAGE_BIN:-}" ]]; then
    "$AEGIS_PYTHON_COVERAGE_BIN" run \
      --source="${AEGIS_PYTHON_COVERAGE_SOURCE:?}" --parallel-mode "$@"
  else
    python3 "$@"
  fi
}

printf '{"schemaVersion":2,"plannerVectors":[]}' > "$TEST_ROOT/invalid-route.json"
if run_python "$COMPONENT_DIR/generate_route_planner_vectors.py" \
  "$TEST_ROOT/invalid-route.json" "$TEST_ROOT/route.inc" >/dev/null 2>&1; then
  printf 'FAIL: route vector generator accepted an unsupported schema\n' >&2
  exit 1
fi

printf '{"schemaVersion":1,"policyVectors":[]}' > "$TEST_ROOT/invalid-policy.json"
if run_python "$COMPONENT_DIR/generate_policy_matcher_vectors.py" \
  "$TEST_ROOT/invalid-policy.json" "$TEST_ROOT/policy.inc" >/dev/null 2>&1; then
  printf 'FAIL: policy vector generator accepted an empty vector set\n' >&2
  exit 1
fi

printf 'PASS: vector generator rejection fixtures (2 checks)\n'
