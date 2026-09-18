#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROWSER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$BROWSER_DIR/../.." && pwd)"
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

COVERAGE_DIR="${AEGIS_NATIVE_COVERAGE_DIR:-}"
COVERAGE_FLAGS=()
if [[ -n "$COVERAGE_DIR" ]]; then
  if [[ "$COVERAGE_DIR" != /* ]]; then
    printf 'FAIL: AEGIS_NATIVE_COVERAGE_DIR must be absolute\n' >&2
    exit 1
  fi
  mkdir -p "$COVERAGE_DIR"
  COVERAGE_FLAGS=(
    -fprofile-instr-generate
    -fcoverage-mapping
  )
fi

run_python() {
  if [[ -n "${AEGIS_PYTHON_COVERAGE_BIN:-}" ]]; then
    "$AEGIS_PYTHON_COVERAGE_BIN" run \
      --source="${AEGIS_PYTHON_COVERAGE_SOURCE:?}" --parallel-mode "$@"
  else
    python3 "$@"
  fi
}

run_python "$COMPONENT_DIR/generate_route_planner_vectors.py" \
  "$VECTOR_FILE" "$TEST_ROOT/route_planner_golden_vectors.inc"
run_python "$COMPONENT_DIR/generate_policy_matcher_vectors.py" \
  "$POLICY_VECTOR_FILE" "$TEST_ROOT/policy_matcher_golden_vectors.inc"
if [[ "$(rg -c '^vectors.push_back' \
  "$TEST_ROOT/policy_matcher_golden_vectors.inc")" != 14 ]]; then
  printf 'FAIL: expected 14 shared policy matcher vectors\n' >&2
  exit 1
fi

"$CXX_BIN" \
  -std=c++20 \
  -Wall -Wextra -Werror -pedantic \
  ${COVERAGE_FLAGS[@]+"${COVERAGE_FLAGS[@]}"} \
  -I"$TEST_ROOT" \
  -I"$BROWSER_DIR/overlay" \
  "$COMPONENT_DIR/access_route_planner.cc" \
  "$COMPONENT_DIR/site_proxy_rule_group.cc" \
  "$COMPONENT_DIR/request_ownership_registry.cc" \
  "$COMPONENT_DIR/request_dispatch_gate.cc" \
  "$COMPONENT_DIR/browser_request_metadata_seed.cc" \
  "$COMPONENT_DIR/published_request_runtime.cc" \
  "$COMPONENT_DIR/access_identity_generation_state.cc" \
  "$COMPONENT_DIR/access_proxy_selection_generation_state.cc" \
  "$COMPONENT_DIR/access_base_proxy_config_generation_state.cc" \
  "$COMPONENT_DIR/access_route_planner_native_test.cc" \
  -o "$TEST_ROOT/aegis_access_native_test"

if [[ -n "$COVERAGE_DIR" ]]; then
  LLVM_PROFILE_FILE="$COVERAGE_DIR/aegis-access-%p.profraw" \
    "$TEST_ROOT/aegis_access_native_test"

  if command -v xcrun >/dev/null 2>&1; then
    LLVM_PROFDATA="$(xcrun --find llvm-profdata)"
    LLVM_COV="$(xcrun --find llvm-cov)"
  else
    LLVM_PROFDATA="$(command -v llvm-profdata || true)"
    LLVM_COV="$(command -v llvm-cov || true)"
  fi
  if [[ -z "$LLVM_PROFDATA" || -z "$LLVM_COV" ]]; then
    printf 'FAIL: matching llvm-profdata and llvm-cov are required for native coverage\n' >&2
    exit 1
  fi
  CXX_MAJOR="$("$CXX_BIN" --version | head -n 1 | sed -E 's/.*version ([0-9]+).*/\1/')"
  PROFILE_MAJOR="$("$LLVM_PROFDATA" --version | head -n 1 | sed -E 's/.*version ([0-9]+).*/\1/')"
  COV_MAJOR="$("$LLVM_COV" --version | head -n 1 | sed -E 's/.*version ([0-9]+).*/\1/')"
  if [[ -z "$CXX_MAJOR" || "$CXX_MAJOR" != "$PROFILE_MAJOR" || "$CXX_MAJOR" != "$COV_MAJOR" ]]; then
    printf 'FAIL: clang/llvm coverage tool major versions do not match (%s/%s/%s)\n' \
      "$CXX_MAJOR" "$PROFILE_MAJOR" "$COV_MAJOR" >&2
    exit 1
  fi
  "$LLVM_PROFDATA" merge -sparse "$COVERAGE_DIR"/*.profraw \
    -o "$COVERAGE_DIR/aegis-access.profdata"
  "$LLVM_COV" export "$TEST_ROOT/aegis_access_native_test" \
    -instr-profile="$COVERAGE_DIR/aegis-access.profdata" \
    -format=lcov \
    > "$COVERAGE_DIR/lcov.unfiltered.info"
  awk -v project_root="$PROJECT_ROOT/" '
    /^SF:/ {
      source = substr($0, 4)
      route = project_root "apps/browser/overlay/components/aegis_access/access_route_planner.cc"
      group = project_root "apps/browser/overlay/components/aegis_access/site_proxy_rule_group.cc"
      ownership = project_root "apps/browser/overlay/components/aegis_access/request_ownership_registry.cc"
      dispatch_gate = project_root "apps/browser/overlay/components/aegis_access/request_dispatch_gate.cc"
      metadata_seed = project_root "apps/browser/overlay/components/aegis_access/browser_request_metadata_seed.cc"
      published_runtime = project_root "apps/browser/overlay/components/aegis_access/published_request_runtime.cc"
      identity_generation = project_root "apps/browser/overlay/components/aegis_access/access_identity_generation_state.cc"
      selection_generation = project_root "apps/browser/overlay/components/aegis_access/access_proxy_selection_generation_state.cc"
      base_proxy_generation = project_root "apps/browser/overlay/components/aegis_access/access_base_proxy_config_generation_state.cc"
      keep = (source == route || source == group || source == ownership || source == dispatch_gate || source == metadata_seed || source == published_runtime || source == identity_generation || source == selection_generation || source == base_proxy_generation)
      if (keep) {
        print "SF:" substr(source, length(project_root) + 1)
      }
      next
    }
    keep { print }
    /^end_of_record$/ { keep = 0 }
  ' "$COVERAGE_DIR/lcov.unfiltered.info" > "$COVERAGE_DIR/lcov.info"
  if [[ "$(grep -c '^SF:' "$COVERAGE_DIR/lcov.info")" != 9 ]]; then
    printf 'FAIL: native LCOV must contain exactly the nine standalone production units\n' >&2
    exit 1
  fi
  rm "$COVERAGE_DIR/lcov.unfiltered.info"
  "$LLVM_COV" export "$TEST_ROOT/aegis_access_native_test" \
    -instr-profile="$COVERAGE_DIR/aegis-access.profdata" \
    -summary-only \
    --sources \
    "$COMPONENT_DIR/access_route_planner.cc" \
    "$COMPONENT_DIR/site_proxy_rule_group.cc" \
    "$COMPONENT_DIR/request_ownership_registry.cc" \
    "$COMPONENT_DIR/request_dispatch_gate.cc" \
    "$COMPONENT_DIR/browser_request_metadata_seed.cc" \
    "$COMPONENT_DIR/published_request_runtime.cc" \
    "$COMPONENT_DIR/access_identity_generation_state.cc" \
    "$COMPONENT_DIR/access_proxy_selection_generation_state.cc" \
    "$COMPONENT_DIR/access_base_proxy_config_generation_state.cc" \
    > "$COVERAGE_DIR/coverage-summary.json"
  "$LLVM_COV" report "$TEST_ROOT/aegis_access_native_test" \
    -instr-profile="$COVERAGE_DIR/aegis-access.profdata" \
    --sources \
    "$COMPONENT_DIR/access_route_planner.cc" \
    "$COMPONENT_DIR/site_proxy_rule_group.cc" \
    "$COMPONENT_DIR/request_ownership_registry.cc" \
    "$COMPONENT_DIR/request_dispatch_gate.cc" \
    "$COMPONENT_DIR/browser_request_metadata_seed.cc" \
    "$COMPONENT_DIR/published_request_runtime.cc" \
    "$COMPONENT_DIR/access_identity_generation_state.cc" \
    "$COMPONENT_DIR/access_proxy_selection_generation_state.cc" \
    "$COMPONENT_DIR/access_base_proxy_config_generation_state.cc" \
    > "$COVERAGE_DIR/coverage.txt"
else
  "$TEST_ROOT/aegis_access_native_test"
fi
