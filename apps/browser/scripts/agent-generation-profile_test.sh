#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
OVERLAY_DIR="$(cd "${SCRIPT_DIR}/../overlay" && pwd -P)"
TEST_BINARY="$(mktemp "${TMPDIR:-/tmp}/aegis-generation-profile.XXXXXX")"
trap 'rm -f "${TEST_BINARY}"' EXIT
"${CXX:-c++}" -std=c++20 -Wall -Wextra -Werror -I"${OVERLAY_DIR}" \
  "${SCRIPT_DIR}/agent-generation-profile_test.cc" -o "${TEST_BINARY}"
"${TEST_BINARY}"
