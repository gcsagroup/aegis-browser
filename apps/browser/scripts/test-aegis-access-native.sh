#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROWSER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$BROWSER_DIR/../.." && pwd)"
COMPONENT_DIR="$BROWSER_DIR/overlay/components/aegis_access"
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

# Read the same module and vector inputs as CMake and GN.
manifest_entries="$(python3 - "$COMPONENT_DIR/access_sources.json" <<'PYTHON'
import json
from pathlib import Path
import sys

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for files in manifest["core"].values():
    for path in files:
        if path.endswith(".cc"):
            print("core", path, sep="\t")
print("test", manifest["test_support"]["source"], sep="\t")
print("test", manifest["test_main"], sep="\t")
for key in ("route_planner_vectors", "policy_matcher_vectors"):
    entry = manifest[key]
    print("vectors", entry["script"], entry["input"], entry["output"], sep="\t")
PYTHON
)"
CORE_SOURCES=()
TEST_SOURCES=()
while IFS=$'\t' read -r kind path input output; do
  case "$kind" in
    core) CORE_SOURCES+=("$COMPONENT_DIR/$path") ;;
    test) TEST_SOURCES+=("$COMPONENT_DIR/$path") ;;
    vectors)
      run_python "$COMPONENT_DIR/$path" "$COMPONENT_DIR/$input" "$TEST_ROOT/$output"
      ;;
  esac
done <<< "$manifest_entries"
vector_count="$(grep -c '^vectors.push_back' "$TEST_ROOT/policy_matcher_golden_vectors.inc" || true)"
if [[ "$vector_count" != 14 ]]; then
  printf 'FAIL: expected 14 shared policy matcher vectors\n' >&2
  exit 1
fi

"$CXX_BIN" \
  -std=c++20 \
  -Wall -Wextra -Werror -pedantic \
  ${COVERAGE_FLAGS[@]+"${COVERAGE_FLAGS[@]}"} \
  -I"$TEST_ROOT" \
  -I"$BROWSER_DIR/overlay" \
  "${CORE_SOURCES[@]}" "${TEST_SOURCES[@]}" \
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
  AEGIS_ACCESS_COVERAGE_SOURCES="$(printf '%s\n' "${CORE_SOURCES[@]}")" \
    awk -v project_root="$PROJECT_ROOT/" '
    BEGIN {
      count = split(ENVIRON["AEGIS_ACCESS_COVERAGE_SOURCES"], paths, "\n")
      for (i = 1; i <= count; i++) production[paths[i]] = 1
    }
    /^SF:/ {
      source = substr($0, 4)
      keep = source in production
      if (keep) print "SF:" substr(source, length(project_root) + 1)
      next
    }
    keep { print }
    /^end_of_record$/ { keep = 0 }
  ' "$COVERAGE_DIR/lcov.unfiltered.info" > "$COVERAGE_DIR/lcov.info"
  if [[ "$(grep -c '^SF:' "$COVERAGE_DIR/lcov.info")" != "${#CORE_SOURCES[@]}" ]]; then
    printf 'FAIL: native LCOV must contain every standalone production unit\n' >&2
    exit 1
  fi
  rm "$COVERAGE_DIR/lcov.unfiltered.info"
  "$LLVM_COV" export "$TEST_ROOT/aegis_access_native_test" \
    -instr-profile="$COVERAGE_DIR/aegis-access.profdata" \
    -summary-only \
    --sources \
    "${CORE_SOURCES[@]}" \
    > "$COVERAGE_DIR/coverage-summary.json"
  "$LLVM_COV" report "$TEST_ROOT/aegis_access_native_test" \
    -instr-profile="$COVERAGE_DIR/aegis-access.profdata" \
    --sources \
    "${CORE_SOURCES[@]}" \
    > "$COVERAGE_DIR/coverage.txt"
else
  "$TEST_ROOT/aegis_access_native_test"
fi

# The native build identity resolver has a standalone channel/admission matrix.
"$CXX_BIN" -std=c++20 -Wall -Wextra -Werror -pedantic \
  -I"$BROWSER_DIR/overlay" \
  "$COMPONENT_DIR/access_options_capability_test.cc" \
  "$COMPONENT_DIR/browser_request_metadata_seed.cc" \
  -o "$TEST_ROOT/access_options_capability_test"
"$TEST_ROOT/access_options_capability_test"
